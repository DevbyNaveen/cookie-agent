//! Skills that look after themselves: picked, tested, loaded, learned and kept
//! current by Cookie, with the person adding one by hand only as a fallback.
//!
//! The evidence this follows (report: "Cookie automatic skills design", 2026-11-26):
//! curated skills help a lot and skills an agent writes for itself, untested,
//! make it worse; two or three focused skills beat many; an agent left to load
//! skills itself often doesn't; and wholesale rewrites of a skill file collapse it.
//!
//! - **At hire.** Cookie reads the job, searches the shelf by each skill's whole
//!   text, and a model picks at most three, or none (`pick`). Each becomes the
//!   agent's own copy with a short "for this job" section, on *trial*: a paired
//!   exam on hidden practice tasks (with it, without it) makes it *core* only if
//!   it helps; one that doesn't stays *on call*.
//! - **While working.** A core skill that fits the task is loaded into the
//!   job's notes by the harness, not left to the agent (`auto_load`). The rest
//!   are one `find_skill` away (up to seven, or "none fits"); `load_skill`
//!   loads one for this task. A skill that goes well three times becomes core.
//! - **Learning.** The review proposes small itemized edits (`propose_skill_edit`)
//!   and new skills (`propose_new_skill`); nothing it proposes is live until an
//!   exam on tests the agent never sees says it is no worse. A new skill must
//!   come up in two reviews first. Every change is a version with a diff and undo.
//! - **Current.** The shelf refreshes daily; a copy the agent never edited
//!   follows the shelf and is re-tested; a model change re-tests core skills,
//!   and a skill the agent now does as well without retires.
//!
//! Every model call here is recorded as a job of the agent's (the person sees
//! what it cost), and exams stop at a monthly budget.

use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use cookie_harness::tool::{tool, Effect, Tool};
use cookie_harness::{Agent, Event, Message, RunControl, Session};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::bench::{BenchCase, Variant, Verdict};
use crate::learning::SkillMeta;
use crate::shelf::{self, Doc, Files};
use crate::store::{AgentRecord, Job, JobStatus, Trigger};
use crate::{util, Team};

/// Core skills an agent holds at most: two or three focused skills do best.
pub const CORE_MAX: usize = 3;
/// Practice tasks written for an agent's tests.
pub const PRACTICE: usize = 24;
/// Cases one skill exam runs (each on both sides).
pub const EXAM_CASES: usize = 36;
/// Good jobs before a skill found while working becomes core.
pub const PROMOTE_WINS: u32 = 3;
/// What find_skill offers at most.
pub const FIND_K: usize = 7;
/// Characters of a skill loaded into a job's notes.
const LOAD_CHARS: usize = 8_000;
/// Reviews a new skill must come up in before it is tried.
const NEW_SKILL_SEEN: u32 = 2;

/* ---------- types ---------- */

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct SkillTest {
    /// Cases passed with the skill, and without it, out of `total`.
    pub with: usize,
    pub without: usize,
    pub total: usize,
    pub model: String,
    pub at: u64,
    pub exam: String,
    /// `helps` · `no_better` · `worse`
    pub verdict: String,
}

/// One itemized change to a skill's SKILL.md.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Edit {
    pub skill: String,
    /// `add` (a line under a section) · `replace` (one line) · `remove` (one line)
    pub op: String,
    pub section: String,
    pub old: String,
    pub text: String,
}

/// What an exam changes in a copy's skills.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct SkillDelta {
    /// Taken away.
    pub remove: Vec<String>,
    /// Added (name, files), as core.
    pub add: Vec<(String, Files)>,
    /// Treated as core (a trial, tested as if it were).
    pub core: Vec<String>,
    /// Itemized edits applied.
    pub edits: Vec<Edit>,
}

impl SkillDelta {
    /// Change a probe's copy of the skills (its own folder, thrown away after).
    pub(crate) fn apply(&self, team: &Team, probe: &str) -> Result<(), String> {
        let base = team.paths.skills(probe);
        let mut metas = team.metas(probe);
        for n in &self.remove {
            let _ = std::fs::remove_dir_all(base.join(n));
            metas.remove(n);
        }
        for (n, files) in &self.add {
            shelf::write_dir_files(&base.join(n), files)?;
            let m = metas.entry(n.clone()).or_insert_with(|| SkillMeta { name: n.clone(), origin: "shelf".into(), ..Default::default() });
            m.status = "core".into();
            m.archived = false;
        }
        for n in &self.core {
            if let Some(m) = metas.get_mut(n) {
                m.status = "core".into();
            }
        }
        for e in &self.edits {
            let p = base.join(&e.skill).join("SKILL.md");
            let t = std::fs::read_to_string(&p).map_err(|_| format!("{} isn't one of its skills.", e.skill))?;
            std::fs::write(&p, apply_edit(&t, e)?).map_err(|e| e.to_string())?;
        }
        team.save_metas(probe, &metas)
    }
}

/// A change in an agent's skills, for its record and the person.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Change {
    pub at: u64,
    pub skill: String,
    /// `picked` · `core` · `oncall` · `retired` · `edited` · `new` · `not_kept` · `updated` · `added_by_you` · `undone`
    pub kind: String,
    pub what: String,
    pub test: Option<SkillTest>,
    /// The version kept before the change (for the diff and undo).
    pub version: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub(crate) struct Staged {
    id: String,
    edits: Vec<Edit>,
    why: String,
    evidence: String,
    at: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub(crate) struct Proposal {
    name: String,
    description: String,
    when: String,
    steps: Vec<String>,
    why: String,
    evidence: Vec<String>,
    seen: u32,
    reviews: Vec<String>,
    at: u64,
}

/// Monthly limits on what testing skills may spend, and whether it runs at all.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AutoCfg {
    pub tests: bool,
    pub month_dollars: f64,
    pub month_tokens: u64,
    /// `YYYY-MM` → (microdollars, tokens) spent on skill work.
    pub spent: BTreeMap<String, (u64, u64)>,
}

impl Default for AutoCfg {
    fn default() -> Self {
        Self { tests: true, month_dollars: 3.0, month_tokens: 3_000_000, spent: BTreeMap::new() }
    }
}

/// The skills each running job loaded, by job id, until the job is written.
static JOB_SKILLS: LazyLock<Mutex<HashMap<String, Vec<String>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
/// One heavy skill task at a time across the team (a pick, an exam, a gate).
static BUSY: AtomicBool = AtomicBool::new(false);

pub(crate) fn note_job_skill(job: &str, skill: &str) {
    let mut m = JOB_SKILLS.lock().unwrap();
    let v = m.entry(job.to_string()).or_default();
    if !v.iter().any(|s| s == skill) {
        v.push(skill.to_string());
    }
}

/// The skills a job loaded, taken when its record is written.
pub(crate) fn take_job_skills(job: &str) -> Vec<String> {
    JOB_SKILLS.lock().unwrap().remove(job).unwrap_or_default()
}

/* ---------- itemized edits ---------- */

const BULLET: &[char] = &['-', '*', ' '];

/// Apply one itemized edit to a SKILL.md, or say why it can't be.
pub fn apply_edit(md: &str, e: &Edit) -> Result<String, String> {
    let text = e.text.trim();
    if matches!(e.op.as_str(), "add" | "replace") {
        if text.is_empty() || text.contains('\n') || text.len() > 400 {
            return Err("An edit is one line of at most 400 characters.".into());
        }
        let problems = crate::learning::scan(text);
        let mut files = Files::new();
        files.insert("SKILL.md".into(), format!("---\nname: x\ndescription: checking one line of an edit\n---\n{text}"));
        let steering = shelf::vet(&files);
        if !problems.is_empty() || !steering.is_empty() {
            return Err(format!("Refused: {}", problems.into_iter().map(str::to_string).chain(steering).collect::<Vec<_>>().join("; ")));
        }
    }
    let lines: Vec<&str> = md.lines().collect();
    let find_one = |old: &str| -> Result<usize, String> {
        let old = old.trim().trim_start_matches(BULLET).trim();
        if old.is_empty() {
            return Err("Say which line, in its exact words.".into());
        }
        let hits: Vec<usize> = lines.iter().enumerate().filter(|(_, l)| l.contains(old)).map(|(i, _)| i).collect();
        match hits.len() {
            1 => Ok(hits[0]),
            0 => Err(format!("No line says \"{}\".", util::clip(old, 80))),
            n => Err(format!("{n} lines say that; give more of the line.")),
        }
    };
    let mut out: Vec<String> = lines.iter().map(|l| l.to_string()).collect();
    match e.op.as_str() {
        "add" => {
            let section = if e.section.trim().is_empty() { "Notes" } else { e.section.trim() };
            let head = out.iter().position(|l| l.trim_start_matches('#').trim().eq_ignore_ascii_case(section) && l.trim_start().starts_with('#'));
            match head {
                Some(h) => {
                    let end = out.iter().enumerate().skip(h + 1).find(|(_, l)| l.trim_start().starts_with('#')).map(|(i, _)| i).unwrap_or(out.len());
                    // After the last non-empty line of the section.
                    let mut at = end;
                    while at > h + 1 && out[at - 1].trim().is_empty() {
                        at -= 1;
                    }
                    out.insert(at, format!("- {text}"));
                }
                None => {
                    if out.last().is_some_and(|l| !l.trim().is_empty()) {
                        out.push(String::new());
                    }
                    out.push(format!("## {section}"));
                    out.push(format!("- {text}"));
                }
            }
        }
        "replace" => {
            let i = find_one(&e.old)?;
            if i < front_matter_end(&out) {
                return Err("The front matter is changed by Cookie, not by an edit.".into());
            }
            let prefix: String = out[i].chars().take_while(|c| BULLET.contains(c) || c.is_ascii_digit() || *c == '.').collect();
            out[i] = format!("{prefix}{}", text.trim_start_matches(BULLET));
        }
        "remove" => {
            let i = find_one(&e.old)?;
            if i < front_matter_end(&out) {
                return Err("The front matter stays.".into());
            }
            out.remove(i);
        }
        other => return Err(format!("An edit adds, replaces or removes a line, not `{other}`.")),
    }
    let mut s = out.join("\n");
    if md.ends_with('\n') {
        s.push('\n');
    }
    Ok(s)
}

fn front_matter_end(lines: &[String]) -> usize {
    if lines.first().map(|l| l.trim()) != Some("---") {
        return 0;
    }
    lines.iter().enumerate().skip(1).find(|(_, l)| l.trim() == "---").map(|(i, _)| i + 1).unwrap_or(0)
}

/// A line diff, for the person: `  ` same, `- ` gone, `+ ` new.
pub fn diff(before: &str, after: &str) -> Vec<String> {
    let (a, b): (Vec<&str>, Vec<&str>) = (before.lines().collect(), after.lines().collect());
    let (n, m) = (a.len(), b.len());
    if n * m > 4_000_000 {
        return vec!["(too long to compare line by line)".into()];
    }
    let mut lcs = vec![vec![0u32; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i][j] = if a[i] == b[j] { lcs[i + 1][j + 1] + 1 } else { lcs[i + 1][j].max(lcs[i][j + 1]) };
        }
    }
    let (mut i, mut j, mut out) = (0, 0, Vec::new());
    while i < n && j < m {
        if a[i] == b[j] {
            out.push(format!("  {}", a[i]));
            i += 1;
            j += 1;
        } else if lcs[i + 1][j] >= lcs[i][j + 1] {
            out.push(format!("- {}", a[i]));
            i += 1;
        } else {
            out.push(format!("+ {}", b[j]));
            j += 1;
        }
    }
    out.extend(a[i..].iter().map(|l| format!("- {l}")));
    out.extend(b[j..].iter().map(|l| format!("+ {l}")));
    out
}

/// An edit that copies a hidden practice task into a skill is teaching to the test: refused.
fn copies_a_test(text: &str, cases: &[BenchCase]) -> bool {
    let words: Vec<String> = text.to_lowercase().split_whitespace().map(str::to_string).collect();
    if words.len() < 8 {
        return false;
    }
    cases.iter().any(|c| {
        let hay = format!("{} {}", c.input, c.expect).to_lowercase();
        words.windows(8).any(|w| hay.contains(&w.join(" ")))
    })
}

/* ---------- the team side ---------- */

impl Team {
    fn auto_cfg_path(&self) -> std::path::PathBuf {
        self.paths.root.join("autoskills.json")
    }

    pub fn auto_cfg(&self) -> AutoCfg {
        util::read_json(&self.auto_cfg_path())
    }

    pub fn set_auto_cfg(&self, tests: Option<bool>, month_dollars: Option<f64>) -> Result<AutoCfg, String> {
        let mut c = self.auto_cfg();
        if let Some(t) = tests {
            c.tests = t;
        }
        if let Some(d) = month_dollars {
            if !(0.0..=500.0).contains(&d) {
                return Err("A monthly limit between $0 and $500.".into());
            }
            c.month_dollars = d;
        }
        util::write_json(&self.auto_cfg_path(), &c)?;
        Ok(c)
    }

    fn month() -> String {
        chrono::Local::now().format("%Y-%m").to_string()
    }

    /// May skill work spend more this month?
    pub(crate) fn may_spend(&self) -> bool {
        let c = self.auto_cfg();
        let (micro, tokens) = c.spent.get(&Self::month()).copied().unwrap_or((0, 0));
        c.tests && (micro as f64) < c.month_dollars * 1_000_000.0 && tokens < c.month_tokens
    }

    fn add_spend(&self, micro: u64, tokens: u64) {
        let mut c = self.auto_cfg();
        let e = c.spent.entry(Self::month()).or_insert((0, 0));
        e.0 += micro;
        e.1 += tokens;
        let _ = util::write_json(&self.auto_cfg_path(), &c);
    }

    fn learning_dir(&self, agent: &str) -> std::path::PathBuf {
        self.paths.agent(agent).join("learning")
    }

    fn log_change(&self, agent: &str, c: Change) {
        let _ = std::fs::create_dir_all(self.learning_dir(agent));
        let _ = util::append_jsonl(&self.learning_dir(agent).join("changes.jsonl"), &c);
    }

    pub fn skill_changes(&self, agent: &str) -> Vec<Change> {
        let mut v: Vec<Change> = util::read_jsonl(&self.learning_dir(agent).join("changes.jsonl"));
        v.reverse();
        v.truncate(60);
        v
    }

    fn set_meta(&self, agent: &str, name: &str, f: impl FnOnce(&mut SkillMeta)) {
        let mut metas = self.metas(agent);
        if let Some(m) = metas.get_mut(name) {
            f(m);
            let _ = self.save_metas(agent, &metas);
        }
    }

    fn core_count(&self, agent: &str) -> usize {
        self.skills(agent).iter().filter(|s| s.stage() == "core").count()
    }

    /// One model call for skill work, recorded as a job of the agent's: the answer as JSON.
    pub(crate) async fn side_call(&self, rec: &AgentRecord, label: &str, instructions: &str, input: String, schema: Value) -> Result<Value, String> {
        let agent = Agent::new(&rec.model).map_err(|e| e.to_string())?.without_enkeon().instructions(instructions).output_schema(closed(schema)).close_with_answer();
        let agent = match self.settings().await.prices.get(&rec.model) {
            Some(p) => agent.prices(cookie_harness::Price { input: p.input, output: p.output, cache_read: p.cache_read, cache_write: p.cache_write }),
            None => agent,
        };
        let usage = Arc::new(Mutex::new((0u64, 0u64)));
        let (team, aid, us) = (self, rec.id.clone(), usage.clone());
        let mut forward = |event: Event| {
            if let Event::Usage(u) = event {
                let mut g = us.lock().unwrap();
                g.0 += u.input_tokens + u.output_tokens + u.cache_write_tokens;
                g.1 += team.price_of(&aid, &u);
            }
        };
        let started_at = util::now();
        let mut session = Session::in_memory();
        let control = RunControl::default();
        let run = agent.run_streaming_all(&mut session, vec![Message::untrusted(input, cookie_harness::label::Source::File)], &control, &mut forward);
        let r = tokio::time::timeout(Duration::from_secs(180), run).await.map_err(|_| "It took more than three minutes.".to_string()).and_then(|r| r.map_err(|e| e.to_string()));
        let (tokens, micro) = *usage.lock().unwrap();
        self.add_spend(micro, tokens);
        let job = Job {
            id: util::new_id("job"),
            agent: rec.id.clone(),
            trigger: Trigger::Review,
            input: format!("Skills: {label}"),
            started_at,
            finished_at: Some(util::now()),
            status: if r.is_ok() { JobStatus::Done } else { JobStatus::Failed },
            answer: r.as_ref().map(|a| util::clip(a, 2000)).unwrap_or_default(),
            error: r.as_ref().err().cloned(),
            tokens,
            microdollars: micro,
            version: rec.version,
            ..Default::default()
        };
        let _ = util::append_jsonl(&self.paths.jobs(&rec.id), &job);
        serde_json::from_str(&r?).map_err(|e| format!("Its answer couldn't be read: {e}"))
    }

    /* ---------- practice tasks: tests the agent never sees ---------- */

    fn practice_path(&self, agent: &str) -> std::path::PathBuf {
        // In the agent's folder, outside its work and skills: no tool of its reaches it, and exam copies don't carry it.
        self.learning_dir(agent).join("practice.json")
    }

    fn practice(&self, agent: &str) -> Vec<BenchCase> {
        util::read_json(&self.practice_path(agent))
    }

    /// Practice tasks for its job, written once by a model: real-looking requests and what a good answer does.
    async fn ensure_practice(&self, rec: &AgentRecord) -> Result<Vec<BenchCase>, String> {
        let have = self.practice(&rec.id);
        if have.len() >= PRACTICE {
            return Ok(have);
        }
        let v = self
            .side_call(
                rec,
                "writing practice tasks for its tests",
                "You write practice tasks to test an AI agent at its one job. Each is a request the person could really send it, self-contained \
                 (any facts it needs are in the request; nothing needs their accounts or files), and what a good answer must do, checkable by a \
                 reader. Vary them: easy and hard, the job's different kinds of work. Answer only in the schema.",
                format!("The agent's one job: {}\n\nWrite {PRACTICE} practice tasks.", rec.job),
                json!({"type": "object", "properties": {"tasks": {"type": "array", "items": {"type": "object", "properties": {
                    "input": {"type": "string"}, "expect": {"type": "string"}}, "required": ["input", "expect"], "additionalProperties": false}}},
                    "required": ["tasks"], "additionalProperties": false}),
            )
            .await?;
        let cases: Vec<BenchCase> = v["tasks"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|t| {
                let (input, expect) = (t["input"].as_str()?.trim(), t["expect"].as_str()?.trim());
                (!input.is_empty() && !expect.is_empty()).then(|| BenchCase { id: util::new_id("practice"), agent: rec.id.clone(), input: input.into(), expect: expect.into(), added_at: util::now(), ..Default::default() })
            })
            .take(PRACTICE)
            .collect();
        if cases.len() < 3 {
            return Err("The practice tasks didn't come out usable.".into());
        }
        let _ = std::fs::create_dir_all(self.learning_dir(&rec.id));
        util::write_json(&self.practice_path(&rec.id), &cases)?;
        Ok(cases)
    }

    /// The cases a skill exam runs: its own real jobs first, then practice tasks.
    async fn skill_cases(&self, rec: &AgentRecord) -> Result<Vec<BenchCase>, String> {
        let mut cases: Vec<BenchCase> = self.bench_for(&rec.id).into_iter().take(EXAM_CASES / 2).collect();
        cases.extend(self.ensure_practice(rec).await?);
        cases.truncate(EXAM_CASES);
        Ok(cases)
    }

    /// A paired exam: `with` against `without`. Counts its spend.
    pub(crate) async fn skill_exam(self: &Arc<Self>, rec: &AgentRecord, what: &str, with: Variant, without: Variant) -> Result<(SkillTest, Verdict), String> {
        if !self.may_spend() {
            return Err("Skill tests have reached this month's limit (Settings → Skills).".into());
        }
        let cases = self.skill_cases(rec).await?;
        let exam = self.exam_between(&rec.id, what, cases, with, without).await?;
        self.add_spend(exam.before.microdollars + exam.after.microdollars, exam.before.tokens + exam.after.tokens);
        // `before` ran with the skill; `after` without. The verdict reads whether "without" is good enough.
        let v = crate::bench::verdict(&exam.before, &exam.after);
        let verdict = match v {
            Verdict::Drop => "helps",
            _ if exam.after.passed > exam.before.passed => "worse",
            _ => "no_better",
        };
        Ok((SkillTest { with: exam.before.passed, without: exam.after.passed, total: exam.before.total, model: rec.model.clone(), at: util::now(), exam: exam.id, verdict: verdict.into() }, v))
    }

    /* ---------- at hire ---------- */

    /// Pick an agent's skills from the shelf, give it its own copies on trial, and test them. Once per agent.
    pub async fn auto_skill_agent(self: &Arc<Self>, agent: &str) -> Result<Vec<String>, String> {
        let rec = self.agent(agent).await?;
        let marker = self.learning_dir(agent).join("picked.json");
        if marker.is_file() || rec.shadow_of.is_some() || crate::bench::is_probe(agent) {
            return Ok(Vec::new());
        }
        self.seed_shelf();
        let have: Vec<String> = self.skills(agent).into_iter().map(|s| s.name).collect();
        let docs: Vec<Doc> = self.shelf_docs().into_iter().filter(|d| !have.contains(&d.key)).collect();
        let candidates = shelf::rank(&rec.job, &docs, 8, 2);
        let _ = std::fs::create_dir_all(self.learning_dir(agent));
        if candidates.is_empty() {
            util::write_json(&marker, &json!({"at": util::now(), "picked": [], "why": "Nothing on the shelf fits its job."}))?;
            return Ok(Vec::new());
        }
        let listing: String = candidates
            .iter()
            .filter_map(|(k, _)| docs.iter().find(|d| &d.key == k))
            .map(|d| format!("### {}\n{}\n{}\n", d.name, d.description, util::clip(&d.body, 900)))
            .collect();
        let room = CORE_MAX.saturating_sub(self.core_count(agent));
        let v = self
            .side_call(
                &rec,
                "choosing skills for its job",
                "You choose skills for an AI agent with one job. Pick only skills it will use often in that job, at most the number allowed, and \
                 none if none really fits: a wrong skill makes it worse. For each pick, write why in one line, and 2 to 4 short lines on how it \
                 applies to this job (no new procedures, no instructions to skip the person's approval). Answer only in the schema.",
                format!("The agent's one job: {}\n\nAt most {room} skills.\n\nCandidates:\n{listing}", rec.job),
                json!({"type": "object", "properties": {"picks": {"type": "array", "items": {"type": "object", "properties": {
                    "name": {"type": "string"}, "why": {"type": "string"}, "for_this_job": {"type": "array", "items": {"type": "string"}}},
                    "required": ["name", "why", "for_this_job"], "additionalProperties": false}}},
                    "required": ["picks"], "additionalProperties": false}),
            )
            .await;
        let picks: Vec<(String, String, Vec<String>)> = match v {
            Ok(v) => v["picks"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|p| {
                    let name = p["name"].as_str()?.trim().to_string();
                    candidates.iter().any(|(k, _)| k == &name).then(|| (name, p["why"].as_str().unwrap_or("").to_string(), p["for_this_job"].as_array().into_iter().flatten().filter_map(|l| l.as_str().map(str::to_string)).take(4).collect()))
                })
                .take(room)
                .collect(),
            // Without a model's reading, only a clear lead by the search.
            Err(_) => candidates.iter().take(1).filter(|(_, s)| *s >= 2.0).map(|(k, _)| (k.clone(), "It matches the job's own words most closely.".into(), Vec::new())).collect(),
        };
        let mut installed = Vec::new();
        for (name, why, notes) in &picks {
            let mut files = self.shelf_files(name);
            let entry = self.shelf_entries().get(name).cloned().unwrap_or_default();
            if let Some(md) = files.get_mut("SKILL.md") {
                let clean: Vec<String> = notes.iter().map(|l| l.trim().trim_start_matches(BULLET).trim().to_string()).filter(|l| !l.is_empty() && l.len() <= 300 && crate::learning::scan(l).is_empty()).collect();
                if !clean.is_empty() {
                    md.push_str(&format!("\n\n## For {}\n{}\n", rec.name, clean.iter().map(|l| format!("- {l}")).collect::<Vec<_>>().join("\n")));
                }
            }
            if self.install_copy(agent, name, &files, "shelf", &entry.hash, why, "trial").is_ok() {
                installed.push(name.clone());
                self.log_change(agent, Change { at: util::now(), skill: name.clone(), kind: "picked".into(), what: why.clone(), ..Default::default() });
            }
        }
        util::write_json(&marker, &json!({"at": util::now(), "picked": installed, "considered": candidates.iter().map(|c| &c.0).collect::<Vec<_>>()}))?;
        if !installed.is_empty() {
            self.emit(crate::events::TeamEvent::Learned { agent: agent.into(), changes: installed.iter().map(|n| format!("picked the skill {n}, now testing it")).collect() });
            self.trial(&rec, installed.clone()).await;
        }
        Ok(installed)
    }

    /// Copy a skill into an agent's folder with its status and why.
    fn install_copy(&self, agent: &str, name: &str, files: &Files, origin: &str, base_hash: &str, why: &str, status: &str) -> Result<(), String> {
        let dir = self.skill_dir(agent, name, false);
        if dir.join("SKILL.md").is_file() {
            self.keep_version(agent, name, "SKILL.md")?;
        }
        shelf::write_dir_files(&dir, files)?;
        let mut metas = self.metas(agent);
        let now = util::now();
        let m = metas.entry(name.to_string()).or_insert_with(|| SkillMeta { name: name.to_string(), created_at: now, ..Default::default() });
        m.origin = origin.into();
        m.status = status.into();
        m.why = why.into();
        m.archived = false;
        m.updated_at = now;
        m.description = crate::learning::front_matter(files.get("SKILL.md").map(String::as_str).unwrap_or("")).1.unwrap_or_default();
        if origin == "shelf" {
            m.shelf = Some(name.to_string());
            m.base_hash = Some(base_hash.to_string());
        }
        m.update_available = false;
        self.save_metas(agent, &metas)?;
        // Seen on disk by `skills()` too.
        let _ = self.skills(agent);
        Ok(())
    }

    /// Test skills on trial together: core if they help, on call if the agent does as well without.
    async fn trial(self: &Arc<Self>, rec: &AgentRecord, names: Vec<String>) {
        let what = format!("Skills on trial: {}", names.join(", "));
        let with = Variant { skills: Some(SkillDelta { core: names.clone(), ..Default::default() }), ..Default::default() };
        let without = Variant { skills: Some(SkillDelta { remove: names.clone(), ..Default::default() }), ..Default::default() };
        match self.skill_exam(rec, &what, with, without).await {
            Ok((test, v)) => {
                for n in &names {
                    let helps = v == Verdict::Drop;
                    let room = self.core_count(&rec.id) < CORE_MAX;
                    let status = if helps && room { "core" } else { "oncall" };
                    let why_now = if helps && room {
                        format!("It helps: {} of {} with it, {} without.", test.with, test.total, test.without)
                    } else if helps {
                        "It helps, but three core skills is the most; it waits on call.".to_string()
                    } else if test.verdict == "worse" {
                        format!("It did worse with it: {} of {} with it, {} without. On call only, for a task that asks for it.", test.with, test.total, test.without)
                    } else {
                        format!("Not needed every time: {} of {} with it, {} without. On call when a task asks for it.", test.with, test.total, test.without)
                    };
                    let t = test.clone();
                    self.set_meta(&rec.id, n, |m| {
                        m.status = status.into();
                        m.test = Some(t);
                        if !m.why.contains("It helps") && !m.why.contains("Not needed") && !m.why.contains("It did worse") {
                            m.why = format!("{} {}", m.why.trim(), why_now);
                        } else {
                            m.why = why_now.clone();
                        }
                    });
                    self.log_change(&rec.id, Change { at: util::now(), skill: n.clone(), kind: status.into(), what: why_now, test: Some(test.clone()), ..Default::default() });
                }
            }
            // No test now (no budget, no model): kept on call, tested later.
            Err(e) => {
                for n in &names {
                    self.set_meta(&rec.id, n, |m| {
                        m.status = "oncall".into();
                        m.why = format!("{} Not tested yet: {e}", m.why.trim());
                    });
                }
            }
        }
        self.emit(crate::events::TeamEvent::RosterChanged);
    }

    /* ---------- while working ---------- */

    /// Core skills that fit this task, loaded into the job's notes by the harness. Counts as a use.
    pub(crate) fn auto_load(&self, agent: &str, job: &str, text: &str) -> Option<String> {
        let skills = self.skills(agent);
        let core: Vec<&SkillMeta> = skills.iter().filter(|s| s.stage() == "core").collect();
        if core.is_empty() || text.trim().len() < 12 {
            return None;
        }
        let docs: Vec<Doc> = core
            .iter()
            .map(|s| Doc { key: s.name.clone(), name: s.name.clone(), description: s.description.clone(), body: std::fs::read_to_string(self.skill_dir(agent, &s.name, false).join("SKILL.md")).unwrap_or_default() })
            .collect();
        let need = if shelf::terms(text).len() >= 8 { 2 } else { 1 };
        let hits = shelf::rank(text, &docs, 2, need);
        if hits.is_empty() {
            return None;
        }
        let mut out = String::from("Skills loaded for this task because they fit it. Follow them:\n");
        for (name, _) in &hits {
            let body = docs.iter().find(|d| &d.key == name).map(|d| d.body.clone()).unwrap_or_default();
            let more = if body.len() > LOAD_CHARS { format!("\n(It continues: skill_view {name} for the rest.)") } else { String::new() };
            out.push_str(&format!("\n<skill name=\"{name}\">\n{}{more}\n</skill>\n", util::clip(&body, LOAD_CHARS)));
            note_job_skill(job, name);
            self.set_meta(agent, name, |m| {
                m.uses += 1;
                m.used_at = Some(util::now());
            });
        }
        Some(out)
    }

    /// What find_skill offers: its own skills on call, then the shelf's; or nothing.
    pub fn find_skills(&self, agent: &str, query: &str) -> Vec<Value> {
        let mine = self.skills(agent);
        let own: Vec<Doc> = mine
            .iter()
            .filter(|s| matches!(s.stage(), "oncall" | "trial" | "core"))
            .map(|s| Doc { key: format!("own:{}", s.name), name: s.name.clone(), description: s.description.clone(), body: std::fs::read_to_string(self.skill_dir(agent, &s.name, false).join("SKILL.md")).unwrap_or_default() })
            .collect();
        let names: Vec<&str> = mine.iter().map(|s| s.name.as_str()).collect();
        let shelf: Vec<Doc> = self.shelf_docs().into_iter().filter(|d| !names.contains(&d.key.as_str())).map(|d| Doc { key: format!("shelf:{}", d.key), ..d }).collect();
        let all: Vec<Doc> = own.into_iter().chain(shelf).collect();
        shelf::rank(query, &all, FIND_K, 2)
            .into_iter()
            .filter_map(|(k, _)| {
                let d = all.iter().find(|d| d.key == k)?;
                Some(json!({"name": d.name, "what": d.description, "where": if k.starts_with("own:") { "yours" } else { "Cookie's shelf" }}))
            })
            .collect()
    }

    /// Load a skill for this task: its own, or a shelf skill (it gets its own copy, on call).
    pub fn load_skill(&self, agent: &str, job: &str, name: &str, task: &str) -> Result<String, String> {
        let name = name.trim().to_lowercase();
        let mine = self.skills(agent).into_iter().find(|s| s.name == name && !s.archived);
        if mine.is_none() {
            let entry = self.shelf_entries().get(&name).cloned().filter(|e| e.state == "vetted" || e.state == "held").ok_or_else(|| format!("No skill called {name}. find_skill lists what there is."))?;
            let files = self.shelf_files(&name);
            self.install_copy(agent, &name, &files, "shelf", &entry.hash, &format!("Found while working on: {}", util::clip(task, 120)), "oncall")?;
            self.log_change(agent, Change { at: util::now(), skill: name.clone(), kind: "oncall".into(), what: format!("Found it on the shelf while working on: {}", util::clip(task, 160)), ..Default::default() });
        }
        let body = std::fs::read_to_string(self.skill_dir(agent, &name, false).join("SKILL.md")).map_err(|_| format!("{name} has no SKILL.md."))?;
        note_job_skill(job, &name);
        self.set_meta(agent, &name, |m| {
            m.uses += 1;
            m.used_at = Some(util::now());
        });
        Ok(format!("{}\n\n(Loaded for this task. Supporting files: skill_view with file_path.)", util::clip(&body, LOAD_CHARS)))
    }

    /// After a job: how its skills did. Three good jobs make an on-call skill core; three bad ones send a core skill back.
    pub(crate) fn record_outcome(&self, rec: &AgentRecord, job: &Job) {
        if job.skills.is_empty() || matches!(job.trigger, Trigger::Test { .. } | Trigger::Shadow { .. } | Trigger::Review | Trigger::Prep { .. } | Trigger::Rehearse) {
            return;
        }
        let good = job.status == JobStatus::Done && job.grade != Some(-1) && !job.cut_off && !job.approvals.iter().any(|a| a.outcome == "no");
        for name in &job.skills {
            self.set_meta(&rec.id, name, |m| if good { m.wins += 1 } else { m.losses += 1 });
            self.review_standing(rec, name);
        }
    }

    /// The person graded a job not good after the fact: its skills lose the win it gave them.
    pub(crate) fn regrade_skills(&self, agent: &str, job: &Job) {
        for name in &job.skills {
            self.set_meta(agent, name, |m| {
                m.wins = m.wins.saturating_sub(1);
                m.losses += 1;
            });
        }
    }

    /// Move a skill between core and on call on its record.
    fn review_standing(&self, rec: &AgentRecord, name: &str) {
        let Some(m) = self.metas(&rec.id).get(name).cloned() else { return };
        let stage = m.stage().to_string();
        if stage == "oncall" && m.wins >= PROMOTE_WINS && m.losses * 3 <= m.wins && self.core_count(&rec.id) < CORE_MAX {
            let why = format!("It went well {} times out of {} when it was used.", m.wins, m.wins + m.losses);
            self.set_meta(&rec.id, name, |m| {
                m.status = "core".into();
                m.why = why.clone();
            });
            self.log_change(&rec.id, Change { at: util::now(), skill: name.into(), kind: "core".into(), what: why.clone(), ..Default::default() });
            self.notice(&rec.id, &format!("{} now uses {name} by itself", rec.name), &why, None, false);
            // A skill it learned, proven at work, goes on the shelf for its teammates (vetted like any other).
            if m.origin == "learned" {
                let files = shelf::read_dir_files(&self.skill_dir(&rec.id, name, false));
                self.shelve(files, &format!("learned:{}", rec.id), "", &format!("learned by {}", rec.name));
            }
        } else if stage == "core" && m.losses >= 3 && m.losses > m.wins {
            let why = format!("It went badly {} times out of {}; back on call.", m.losses, m.wins + m.losses);
            self.set_meta(&rec.id, name, |m| {
                m.status = "oncall".into();
                m.why = why.clone();
            });
            self.log_change(&rec.id, Change { at: util::now(), skill: name.into(), kind: "oncall".into(), what: why, ..Default::default() });
        }
    }

    /* ---------- learning: proposals, held until tests say yes ---------- */

    fn staged_path(&self, agent: &str) -> std::path::PathBuf {
        self.learning_dir(agent).join("staged.json")
    }

    fn proposals_path(&self, agent: &str) -> std::path::PathBuf {
        self.learning_dir(agent).join("proposals.json")
    }

    pub(crate) fn stage_edit(&self, agent: &str, edits: Vec<Edit>, why: &str, evidence: &str) -> Result<String, String> {
        if edits.is_empty() || edits.len() > 6 {
            return Err("One to six itemized edits at a time.".into());
        }
        // Each edit must apply to the skill as it is now.
        for e in &edits {
            let p = self.skill_dir(agent, &e.skill, false).join("SKILL.md");
            let t = std::fs::read_to_string(&p).map_err(|_| format!("{} isn't one of your skills. propose_new_skill for a new one.", e.skill))?;
            apply_edit(&t, e)?;
        }
        let _ = std::fs::create_dir_all(self.learning_dir(agent));
        let mut staged: Vec<Staged> = util::read_json(&self.staged_path(agent));
        let id = util::new_id("edit");
        staged.push(Staged { id: id.clone(), edits, why: why.into(), evidence: util::clip(evidence, 600), at: util::now() });
        util::write_json(&self.staged_path(agent), &staged)?;
        Ok(format!("Proposed ({id}). It goes live only if its tests say it's no worse."))
    }

    pub(crate) fn propose_new(&self, agent: &str, review: &str, mut p: Proposal) -> Result<String, String> {
        p.name = p.name.trim().to_lowercase();
        if !(1..=64).contains(&p.name.len()) || !p.name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
            return Err("Name it for the kind of task: a-z, 0-9 and -.".into());
        }
        if p.steps.len() < 2 || p.description.trim().len() < 12 {
            return Err("A new skill needs a description of when to use it and at least two steps.".into());
        }
        if self.skills(agent).iter().any(|s| s.name == p.name) {
            return Err(format!("{} exists: propose_skill_edit improves it.", p.name));
        }
        let _ = std::fs::create_dir_all(self.learning_dir(agent));
        let mut all: Vec<Proposal> = util::read_json(&self.proposals_path(agent));
        let seen = match all.iter_mut().find(|x| x.name == p.name) {
            Some(x) => {
                if !x.reviews.iter().any(|r| r == review) {
                    x.seen += 1;
                    x.reviews.push(review.into());
                    x.evidence.push(p.evidence.first().cloned().unwrap_or_default());
                }
                // The latest wording, the evidence of both.
                x.description = p.description;
                x.steps = p.steps;
                x.when = p.when;
                x.why = p.why;
                x.seen
            }
            None => {
                p.seen = 1;
                p.reviews = vec![review.into()];
                p.at = util::now();
                all.push(p);
                1
            }
        };
        util::write_json(&self.proposals_path(agent), &all)?;
        Ok(if seen >= NEW_SKILL_SEEN { "Noted again: it will be tested as a new skill.".into() } else { "Noted. If this kind of task comes up again, it becomes a skill to test.".into() })
    }

    /// After a review: test what it proposed, keep only what the tests say is no worse.
    pub async fn gate_learning(self: &Arc<Self>, agent: &str) {
        let Ok(rec) = self.agent(agent).await else { return };
        let staged: Vec<Staged> = util::read_json(&self.staged_path(agent));
        let mut left = Vec::new();
        for s in staged {
            let cases = self.practice(agent);
            if s.edits.iter().any(|e| copies_a_test(&e.text, &cases)) {
                self.log_change(agent, Change { at: util::now(), skill: s.edits[0].skill.clone(), kind: "not_kept".into(), what: "It copied one of its tests into the skill.".into(), ..Default::default() });
                continue;
            }
            let after = Variant { skills: Some(SkillDelta { edits: s.edits.clone(), ..Default::default() }), ..Default::default() };
            // Here `before` is the edited copy and `after` the skill as it is: the edit must not lose to it.
            let with_edit = after;
            let as_is = Variant::default();
            match self.skill_exam(&rec, &format!("Proposed edit: {}", util::clip(&s.why, 80)), with_edit, as_is).await {
                Ok((test, v)) => {
                    let skill = s.edits[0].skill.clone();
                    // Kept only when the edited copy passed strictly more of its cases: a tie is noise,
                    // and a skill that changes itself on noise drifts (self-written edits help only when checked).
                    if v == Verdict::Drop && test.with > test.without {
                        match self.apply_edits(agent, &s.edits) {
                            Ok(version) => {
                                let what = format!("{} ({} of {} with the change, {} before)", s.why, test.with, test.total, test.without);
                                // Live on trial: read against real work, put back if it does clearly worse (`trials`).
                                if let Some(v) = &version {
                                    self.start_trial(agent, &skill, v, &what);
                                }
                                self.log_change(agent, Change { at: util::now(), skill: skill.clone(), kind: "edited".into(), what: what.clone(), test: Some(test), version });
                                self.notice(agent, &format!("{} improved {skill}", rec.name), &what, None, false);
                            }
                            Err(e) => self.log_change(agent, Change { at: util::now(), skill, kind: "not_kept".into(), what: e, ..Default::default() }),
                        }
                    } else {
                        let what = format!("{}: its tests did no better with it ({} of {}, {} without).", s.why, test.with, test.total, test.without);
                        self.log_change(agent, Change { at: util::now(), skill, kind: "not_kept".into(), what, test: Some(test), ..Default::default() });
                    }
                }
                // No test now: it waits, and is tried again later.
                Err(_) => left.push(s),
            }
        }
        let _ = util::write_json(&self.staged_path(agent), &left);
        // New skills that came up in enough reviews: written, then on trial like any other.
        let mut proposals: Vec<Proposal> = util::read_json(&self.proposals_path(agent));
        let ready: Vec<Proposal> = proposals.iter().filter(|p| p.seen >= NEW_SKILL_SEEN).cloned().collect();
        for p in ready {
            let md = format!(
                "---\nname: {}\ndescription: {}\n---\n# {}\n\nWhen: {}\n\n## Steps\n{}\n",
                p.name,
                p.description.replace('\n', " "),
                p.name.replace('-', " "),
                p.when.replace('\n', " "),
                p.steps.iter().enumerate().map(|(i, s)| format!("{}. {}", i + 1, s.replace('\n', " "))).collect::<Vec<_>>().join("\n")
            );
            let mut files = Files::new();
            files.insert("SKILL.md".into(), md);
            let problems = shelf::vet(&files);
            proposals.retain(|x| x.name != p.name);
            if !problems.is_empty() {
                self.log_change(agent, Change { at: util::now(), skill: p.name.clone(), kind: "not_kept".into(), what: format!("Refused: {}", problems.join("; ")), ..Default::default() });
                continue;
            }
            if self.install_copy(agent, &p.name, &files, "learned", "", &format!("Learned from your conversations: {}", p.why), "trial").is_ok() {
                self.log_change(agent, Change { at: util::now(), skill: p.name.clone(), kind: "new".into(), what: format!("{} (came up {} times)", p.why, p.seen), ..Default::default() });
                self.trial(&rec, vec![p.name.clone()]).await;
                // A learned skill the tests didn't keep as core is removed rather than left to drift.
                if self.metas(agent).get(&p.name).is_some_and(|m| m.test.as_ref().is_some_and(|t| t.verdict != "helps")) {
                    let _ = self.skill_set(agent, &p.name, "archive");
                    self.set_meta(agent, &p.name, |m| m.status = "retired".into());
                    self.log_change(agent, Change { at: util::now(), skill: p.name.clone(), kind: "retired".into(), what: "Its tests did no better with it.".into(), ..Default::default() });
                }
            }
        }
        let _ = util::write_json(&self.proposals_path(agent), &proposals);
        self.emit(crate::events::TeamEvent::RosterChanged);
    }

    /// Apply tested edits for real, keeping the version before. Returns that version.
    fn apply_edits(&self, agent: &str, edits: &[Edit]) -> Result<Option<String>, String> {
        let mut version = None;
        let mut by_skill: BTreeMap<&str, Vec<&Edit>> = BTreeMap::new();
        for e in edits {
            by_skill.entry(e.skill.as_str()).or_default().push(e);
        }
        for (skill, es) in by_skill {
            let p = self.skill_dir(agent, skill, false).join("SKILL.md");
            let mut t = std::fs::read_to_string(&p).map_err(|_| format!("{skill} is gone."))?;
            for e in es {
                t = apply_edit(&t, e)?;
            }
            self.skill_write(agent, skill, "SKILL.md", &t, "learned")?;
            version = self.skill_versions(agent, skill).first().and_then(|v| v["version"].as_str().map(str::to_string));
        }
        Ok(version)
    }

    /// A skill's file as it was in `version` against now, line by line.
    pub fn skill_diff(&self, agent: &str, name: &str, version: &str) -> Result<Vec<String>, String> {
        if version.contains('/') || version.contains("..") {
            return Err("No such version.".into());
        }
        let then = std::fs::read_to_string(self.paths.skills(agent).join(".history").join(name).join(version).join("SKILL.md")).map_err(|_| "No such version.".to_string())?;
        let archived = self.metas(agent).get(name).is_some_and(|m| m.archived);
        let now = std::fs::read_to_string(self.skill_dir(agent, name, archived).join("SKILL.md")).unwrap_or_default();
        Ok(diff(&then, &now))
    }

    /// Undo: put a skill back as it was before a change.
    pub fn undo_skill_change(&self, agent: &str, name: &str, version: &str) -> Result<(), String> {
        self.skill_revert(agent, name, version, "SKILL.md")?;
        self.log_change(agent, Change { at: util::now(), skill: name.into(), kind: "undone".into(), what: "You put it back as it was.".into(), ..Default::default() });
        Ok(())
    }

    /* ---------- by hand, the fallback ---------- */

    /// The person adds a shelf skill (or a folder of theirs, vetted the same way): on trial, then tested.
    pub async fn add_skill_by_hand(self: &Arc<Self>, agent: &str, shelf_name: Option<&str>, path: Option<&str>) -> Result<String, String> {
        let rec = self.agent(agent).await?;
        let (name, files, hash, origin) = match (shelf_name, path) {
            (Some(n), _) => {
                let e = self.shelf_entries().get(n).cloned().filter(|e| e.state == "vetted" || e.state == "held").ok_or("That skill isn't on the shelf.")?;
                (n.to_string(), self.shelf_files(n), e.hash, "shelf")
            }
            (None, Some(p)) => {
                let dir = std::path::PathBuf::from(p.trim().replacen('~', &std::env::var("HOME").unwrap_or_default(), 1));
                let files = shelf::read_dir_files(&dir);
                let problems = shelf::vet(&files);
                if !problems.is_empty() {
                    return Err(format!("Refused: {}.", problems.join("; ")));
                }
                let name = crate::learning::front_matter(files.get("SKILL.md").map(String::as_str).unwrap_or("")).0.ok_or("Its SKILL.md has no name.")?;
                (name, files.clone(), shelf::hash_files(&files), "imported")
            }
            _ => return Err("Choose a skill from the shelf or a folder.".into()),
        };
        self.install_copy(agent, &name, &files, origin, &hash, "You added it.", "trial")?;
        self.log_change(agent, Change { at: util::now(), skill: name.clone(), kind: "added_by_you".into(), what: "You added it; it's being tested.".into(), ..Default::default() });
        let (team, n) = (self.clone(), name.clone());
        tokio::spawn(async move { team.trial(&rec, vec![n]).await });
        Ok(name)
    }

    /* ---------- current ---------- */

    /// A model change: test its core skills again; retire what it now does as well without.
    pub async fn recheck_skills(self: &Arc<Self>, agent: &str) {
        let Ok(rec) = self.agent(agent).await else { return };
        let core: Vec<String> = self.skills(agent).into_iter().filter(|s| s.stage() == "core").map(|s| s.name).collect();
        for name in core {
            let with = Variant::default();
            let without = Variant { skills: Some(SkillDelta { remove: vec![name.clone()], ..Default::default() }), ..Default::default() };
            let Ok((test, v)) = self.skill_exam(&rec, &format!("Re-test of {name} on {}", rec.model), with, without).await else { return };
            let t = test.clone();
            self.set_meta(agent, &name, |m| m.test = Some(t));
            if v != Verdict::Drop {
                let _ = self.skill_set(agent, &name, "archive");
                let why = format!("On {} it does as well without it ({} of {} without, {} with).", rec.model, test.without, test.total, test.with);
                self.set_meta(agent, &name, |m| {
                    m.status = "retired".into();
                    m.why = why.clone();
                });
                self.log_change(agent, Change { at: util::now(), skill: name.clone(), kind: "retired".into(), what: why.clone(), test: Some(test), ..Default::default() });
                self.notice(agent, &format!("{} retired {name}", rec.name), &why, None, false);
            }
        }
        self.emit(crate::events::TeamEvent::RosterChanged);
    }

    /// Bring agents' shelf copies up to date: a copy the agent never changed follows the shelf (and is re-tested
    /// if core); one with its own edits keeps them and is marked as having an update.
    async fn follow_shelf(self: &Arc<Self>) {
        let entries = self.shelf_entries();
        for a in self.agents().await.into_iter().filter(|a| a.shadow_of.is_none() && !crate::bench::is_probe(&a.id)) {
            for s in self.skills(&a.id).into_iter().filter(|s| !s.archived) {
                let (Some(src), Some(base)) = (s.shelf.clone(), s.base_hash.clone()) else { continue };
                let Some(e) = entries.get(&src).filter(|e| e.state == "vetted" && e.hash != base) else { continue };
                // Its own edits since: the shelf copy plus the "For" section it was given is not the same as an edited copy.
                let edited = self.skill_versions(&a.id, &s.name).iter().any(|v| v["at"].as_u64().unwrap_or(0) > s.created_at + 5);
                if edited {
                    self.set_meta(&a.id, &s.name, |m| m.update_available = true);
                    continue;
                }
                let mut files = self.shelf_files(&src);
                let mine = std::fs::read_to_string(self.skill_dir(&a.id, &s.name, false).join("SKILL.md")).unwrap_or_default();
                if let (Some(md), Some(i)) = (files.get_mut("SKILL.md"), mine.find(&format!("\n## For {}", a.name))) {
                    md.push_str(&mine[i..]);
                }
                if self.install_copy(&a.id, &s.name, &files, "shelf", &e.hash, &s.why, s.stage()).is_ok() {
                    self.log_change(&a.id, Change { at: util::now(), skill: s.name.clone(), kind: "updated".into(), what: format!("The shelf's copy changed ({}); this one follows it.", e.source), ..Default::default() });
                    if s.stage() == "core" {
                        self.trial(&a, vec![s.name.clone()]).await;
                    }
                }
            }
        }
    }

    /// Each tick: the shelf once a day, then at most one agent's skill work, one at a time.
    pub(crate) async fn skills_tick(self: &Arc<Self>) {
        if BUSY.swap(true, Ordering::SeqCst) {
            return;
        }
        let team = self.clone();
        tokio::spawn(async move {
            let day = team.shelf_state().refreshed_at;
            if team.refresh_shelf(false).await.is_ok() && team.shelf_state().refreshed_at != day {
                team.judge_shelf().await;
                team.follow_shelf().await;
            }
            // An agent not yet given its skills (hired before this, or from a pack or a split).
            let agents = team.agents().await;
            if let Some(a) = agents.iter().find(|a| a.shadow_of.is_none() && !crate::bench::is_probe(&a.id) && !team.learning_dir(&a.id).join("picked.json").is_file()) {
                if let Err(e) = team.auto_skill_agent(&a.id).await {
                    tracing::warn!("skills for {}: {e}", a.name);
                }
            } else if let Some(a) = agents.iter().find(|a| util::read_json::<Vec<Staged>>(&team.staged_path(&a.id)).len() + util::read_json::<Vec<Proposal>>(&team.proposals_path(&a.id)).iter().filter(|p| p.seen >= NEW_SKILL_SEEN).count() > 0) {
                team.gate_learning(&a.id).await;
            }
            BUSY.store(false, Ordering::SeqCst);
        });
    }

    /// What the Skills tab shows.
    pub fn skills_view(&self, agent: &str) -> Value {
        let skills: Vec<Value> = self
            .skills(agent)
            .into_iter()
            .map(|s| {
                let src = s.shelf.as_ref().and_then(|n| self.shelf_entries().get(n).cloned());
                json!({
                    "name": s.name, "description": s.description, "stage": s.stage(), "origin": s.origin, "why": s.why,
                    "test": s.test, "wins": s.wins, "losses": s.losses, "uses": s.uses, "used_at": s.used_at,
                    "update_available": s.update_available, "pinned": s.pinned,
                    "source": src.as_ref().map(|e| json!({"name": e.name, "source": e.source, "url": e.url, "license": e.license})),
                    "versions": self.skill_versions(agent, &s.name).into_iter().take(5).collect::<Vec<_>>(),
                })
            })
            .collect();
        let cfg = self.auto_cfg();
        let spent = cfg.spent.get(&Self::month()).copied().unwrap_or((0, 0));
        json!({
            "skills": skills,
            "changes": self.skill_changes(agent),
            "waiting": util::read_json::<Vec<Staged>>(&self.staged_path(agent)).len(),
            "proposed": util::read_json::<Vec<Proposal>>(&self.proposals_path(agent)).iter().map(|p| json!({"name": p.name, "seen": p.seen, "needs": NEW_SKILL_SEEN})).collect::<Vec<_>>(),
            "picked_at": util::read_json::<Value>(&self.learning_dir(agent).join("picked.json"))["at"],
            "tests": {"on": cfg.tests, "month_dollars": cfg.month_dollars, "spent_microdollars": spent.0, "spent_tokens": spent.1},
        })
    }
}

/* ---------- the agent's tools ---------- */

/// `find_skill` and `load_skill`, for one job.
pub(crate) fn tools(team: &Arc<Team>, agent: &str, job: &str) -> Vec<Arc<dyn Tool>> {
    let w = Arc::downgrade(team);
    let (aid, jid) = (agent.to_string(), job.to_string());
    let find = tool(
        "find_skill",
        "Find a skill for a kind of task your core skills don't cover: your own skills on call and Cookie's vetted shelf, by what they say. \
         Up to 7, or none fits (then do the task without one). Then load_skill the one that fits.",
        json!({"type": "object", "properties": {"task": {"type": "string", "description": "the kind of task, in plain words"}}, "required": ["task"]}),
        Effect::Read,
        {
            let (w, aid) = (w.clone(), aid.clone());
            move |args: Value| {
                let (w, aid) = (w.clone(), aid.clone());
                async move {
                    let team = w.upgrade().ok_or("Cookie is closing.")?;
                    let found = team.find_skills(&aid, args["task"].as_str().unwrap_or_default());
                    if found.is_empty() {
                        return Ok("None fits. Do the task without a skill.".into());
                    }
                    Ok(serde_json::to_string_pretty(&json!({"skills": found})).unwrap_or_default())
                }
            }
        },
    );
    let load = tool(
        "load_skill",
        "Load one skill for this task (from find_skill) and follow it.",
        json!({"type": "object", "properties": {"name": {"type": "string"}, "task": {"type": "string", "description": "the task you're loading it for"}}, "required": ["name"]}),
        Effect::Read,
        move |args: Value| {
            let (w, aid, jid) = (w.clone(), aid.clone(), jid.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                team.load_skill(&aid, &jid, args["name"].as_str().unwrap_or_default(), args["task"].as_str().unwrap_or_default())
            }
        },
    );
    vec![Arc::new(find), Arc::new(load)]
}

/// What the learning pass may do with skills: read them, and propose. Nothing it proposes is live until tested.
pub(crate) fn propose_tools(team: &Arc<Team>, agent: &str, review: &str) -> Vec<Arc<dyn Tool>> {
    let w = Arc::downgrade(team);
    let aid = agent.to_string();
    let rid = review.to_string();
    let edit = tool(
        "propose_skill_edit",
        "Propose small itemized changes to one of your skills: add a line under a section, replace one line, or remove one line. \
         Each line is a rule with its reason, from what the person did or said (cite it in evidence). Never rewrite a whole skill. \
         Load it with skill_view first. It goes live only if tests you can't see say it's no worse.",
        json!({"type": "object", "properties": {
            "skill": {"type": "string"},
            "edits": {"type": "array", "items": {"type": "object", "properties": {
                "op": {"type": "string", "enum": ["add", "replace", "remove"]},
                "section": {"type": "string", "description": "for add: the heading to add under (e.g. Steps, Pitfalls, For <agent>)"},
                "old": {"type": "string", "description": "for replace/remove: the line's exact words"},
                "text": {"type": "string", "description": "for add/replace: the new line"}
            }, "required": ["op"]}},
            "why": {"type": "string"},
            "evidence": {"type": "string", "description": "what in the conversation shows it: the person's words or decision"}
        }, "required": ["skill", "edits", "why", "evidence"]}),
        Effect::Write,
        {
            let (w, aid) = (w.clone(), aid.clone());
            move |args: Value| {
                let (w, aid) = (w.clone(), aid.clone());
                async move {
                    let team = w.upgrade().ok_or("Cookie is closing.")?;
                    let skill = args["skill"].as_str().unwrap_or_default().trim().to_lowercase();
                    let edits: Vec<Edit> = args["edits"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .map(|e| Edit { skill: skill.clone(), op: e["op"].as_str().unwrap_or("").into(), section: e["section"].as_str().unwrap_or("").into(), old: e["old"].as_str().unwrap_or("").into(), text: e["text"].as_str().unwrap_or("").into() })
                        .collect();
                    team.stage_edit(&aid, edits, args["why"].as_str().unwrap_or(""), args["evidence"].as_str().unwrap_or(""))
                }
            }
        },
    );
    let new = tool(
        "propose_new_skill",
        "Propose a new skill for a KIND of task this person keeps asking for, that no skill of yours covers: when to use it and the steps. \
         It becomes a skill only after it comes up in another review too, and then only if tests say it helps.",
        json!({"type": "object", "properties": {
            "name": {"type": "string", "description": "a-z, 0-9 and -, naming the kind of task"},
            "description": {"type": "string", "description": "one line: when to use it"},
            "when": {"type": "string"},
            "steps": {"type": "array", "items": {"type": "string"}},
            "why": {"type": "string"},
            "evidence": {"type": "string"}
        }, "required": ["name", "description", "steps", "why", "evidence"]}),
        Effect::Write,
        move |args: Value| {
            let (w, aid, rid) = (w.clone(), aid.clone(), rid.clone());
            async move {
                let team = w.upgrade().ok_or("Cookie is closing.")?;
                let p = Proposal {
                    name: args["name"].as_str().unwrap_or("").into(),
                    description: args["description"].as_str().unwrap_or("").into(),
                    when: args["when"].as_str().unwrap_or("").into(),
                    steps: args["steps"].as_array().into_iter().flatten().filter_map(|s| s.as_str().map(str::to_string)).take(15).collect(),
                    why: args["why"].as_str().unwrap_or("").into(),
                    evidence: vec![args["evidence"].as_str().unwrap_or("").into()],
                    ..Default::default()
                };
                team.propose_new(&aid, &rid, p)
            }
        },
    );
    vec![Arc::new(edit), Arc::new(new)]
}

#[cfg(test)]
mod tests {
    use super::*;

    const MD: &str = "---\nname: invoice-reminders\ndescription: Chase overdue invoices.\n---\n# Invoice reminders\n\n## Steps\n- Find overdue invoices.\n- Draft a polite reminder.\n\n## Pitfalls\n- Never threaten.\n";

    fn e(op: &str, section: &str, old: &str, text: &str) -> Edit {
        Edit { skill: "invoice-reminders".into(), op: op.into(), section: section.into(), old: old.into(), text: text.into() }
    }

    #[test]
    fn edits_are_small_and_exact() {
        let added = apply_edit(MD, &e("add", "Steps", "", "Cite the invoice number and amount: the person asked for it.")).unwrap();
        assert!(added.contains("- Draft a polite reminder.\n- Cite the invoice number"), "{added}");
        let replaced = apply_edit(MD, &e("replace", "", "Never threaten.", "Never threaten; firm after 30 days.")).unwrap();
        assert!(replaced.contains("- Never threaten; firm after 30 days.") && !replaced.contains("- Never threaten.\n"));
        let removed = apply_edit(MD, &e("remove", "", "Find overdue invoices.", "")).unwrap();
        assert!(!removed.contains("Find overdue"));
        let new_section = apply_edit(MD, &e("add", "Tone", "", "Warm, short, signed with the person's name.")).unwrap();
        assert!(new_section.ends_with("## Tone\n- Warm, short, signed with the person's name.\n"), "{new_section}");
        assert!(apply_edit(MD, &e("replace", "", "draft", "x")).is_err() || apply_edit(MD, &e("replace", "", "nothing like this", "x")).is_err());
        assert!(apply_edit(MD, &e("add", "Steps", "", "Send it without asking the person first.")).is_err(), "an edit can't steer around the person");
        assert!(apply_edit(MD, &e("add", "Steps", "", "line one\nline two")).is_err(), "one line at a time");
        assert!(apply_edit(MD, &e("replace", "", "name: invoice-reminders", "name: other")).is_err(), "the front matter stays");
    }

    #[test]
    fn a_diff_shows_what_changed() {
        let d = diff("a\nb\nc", "a\nB\nc\nd");
        assert_eq!(d, vec!["  a", "- b", "+ B", "  c", "+ d"]);
    }

    #[test]
    fn copying_a_test_into_a_skill_is_caught() {
        let cases = vec![BenchCase { input: "Write a reminder to Acme about invoice 1042 for 3,200 euros overdue since March".into(), expect: "polite".into(), ..Default::default() }];
        assert!(copies_a_test("Always: write a reminder to Acme about invoice 1042 for 3,200 euros", &cases));
        assert!(!copies_a_test("Cite the invoice number and the amount in every reminder", &cases));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn skills_move_on_their_record_and_learning_waits_for_tests() {
        let dir = std::env::temp_dir().join(format!("cookie-auto-{}", util::random_hex(4)));
        let team = Team::open(&dir).unwrap();
        let rec = team
            .add_agent(AgentRecord {
                id: "inv".into(), name: "Invoice Chaser".into(), model: "anthropic:x".into(), job: "Chase overdue invoices".into(), created_at: 0,
                grants: Default::default(), limits: Default::default(), probation_until: None, parent: None, shadow_of: None, handover: None, origin: None, version: 1,
            })
            .await
            .unwrap();
        let mut f = Files::new();
        f.insert("SKILL.md".into(), MD.to_string());
        team.install_copy("inv", "invoice-reminders", &f, "shelf", "h0", "picked", "oncall").unwrap();
        assert_eq!(team.skills("inv")[0].stage(), "oncall");
        assert!(team.skills_block("inv").unwrap().contains("find_skill"), "on-call skills are a search away");
        // Loaded three times in good jobs: core.
        for i in 0..3 {
            let job = Job { id: format!("j{i}"), agent: "inv".into(), trigger: Trigger::Chat, status: JobStatus::Done, skills: vec!["invoice-reminders".into()], ..Default::default() };
            team.record_outcome(&rec, &job);
        }
        assert_eq!(team.skills("inv")[0].stage(), "core");
        assert!(team.skills_block("inv").unwrap().contains("invoice-reminders"));
        // A fitting task loads it by itself; an unrelated one doesn't.
        assert!(team.auto_load("inv", "job-x", "Please draft a reminder for the overdue invoices from March").is_some());
        assert!(take_job_skills("job-x").contains(&"invoice-reminders".to_string()));
        assert!(team.auto_load("inv", "job-y", "What's the weather in Riga tomorrow?").is_none());
        // A proposed edit is staged, not live.
        let r = team.stage_edit("inv", vec![e("add", "Steps", "", "Cite the invoice number and amount.")], "the person asked for numbers", "'always put the number in'").unwrap();
        assert!(r.contains("only if its tests"));
        assert!(!std::fs::read_to_string(team.skill_dir("inv", "invoice-reminders", false).join("SKILL.md")).unwrap().contains("Cite the invoice"), "not live before its test");
        assert!(team.stage_edit("inv", vec![e("add", "Steps", "", "Send it without asking the person.")], "x", "y").is_err());
        // A new skill needs to come up in two reviews.
        let p = |n: &str| Proposal { name: n.into(), description: "Reconcile payments against invoices.".into(), steps: vec!["Match amounts.".into(), "Flag gaps.".into()], why: "asked twice".into(), evidence: vec!["x".into()], ..Default::default() };
        assert!(team.propose_new("inv", "r1", p("payment-reconcile")).unwrap().contains("comes up again"));
        assert!(team.propose_new("inv", "r1", p("payment-reconcile")).unwrap().contains("comes up again"), "the same review doesn't count twice");
        assert!(team.propose_new("inv", "r2", p("payment-reconcile")).unwrap().contains("tested"));
        // The view carries what the tab needs.
        let v = team.skills_view("inv");
        assert_eq!(v["skills"][0]["stage"], "core");
        assert_eq!(v["waiting"], 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// A schema every provider's structured output accepts: each object says it takes no other keys.
/// Providers refuse a schema that leaves that out, and one forgotten line must not cost a job.
pub(crate) fn closed(mut schema: Value) -> Value {
    fn walk(v: &mut Value) {
        match v {
            Value::Object(map) => {
                if map.get("type").and_then(Value::as_str) == Some("object") && !map.contains_key("additionalProperties") {
                    map.insert("additionalProperties".into(), Value::Bool(false));
                }
                map.values_mut().for_each(walk);
            }
            Value::Array(items) => items.iter_mut().for_each(walk),
            _ => {}
        }
    }
    walk(&mut schema);
    schema
}

#[cfg(test)]
mod closed_tests {
    use super::*;

    #[test]
    fn every_object_in_a_schema_is_closed() {
        let s = closed(serde_json::json!({"type": "object", "properties": {"a": {"type": "array", "items": {"type": "object", "properties": {"b": {"type": "string"}}}}, "c": {"type": "object", "additionalProperties": true}}}));
        assert_eq!(s["additionalProperties"], false);
        assert_eq!(s["properties"]["a"]["items"]["additionalProperties"], false);
        assert_eq!(s["properties"]["c"]["additionalProperties"], true, "a choice already made is kept");
    }
}
