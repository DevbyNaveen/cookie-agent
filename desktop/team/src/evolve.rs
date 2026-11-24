//! Agents that evolve, a little each night, and only when an exam says so.
//!
//! Off until you turn it on (Settings → Evolution): every exam runs real model
//! calls on your bench, so a night has a budget. At the hour you choose, with
//! nothing at work, each agent with bench cases gets at most one change tried:
//!
//! - **A habit (`habit`)**: a lesson the bandit proved (`lessons::proven`:
//!   enough wins, and better than the agent's own jobs without it) is tried as
//!   a standing instruction. Kept only if the exam says so.
//! - **A harness knob (`knob`)**: one setting of how the harness runs it
//!   (when tool results are cleared, how much recent work is kept, when the
//!   conversation is summarised), each value tried once a month at most.
//! - **Right-sizing (`model`)**, once a week per agent: a cheaper model you
//!   have a key and a price for, on the same cases. Same results for clearly
//!   less is *offered*, never switched by itself: a model change is yours to
//!   accept. An agent passing under 60% is offered a stronger one that did better.
//!
//! Then, team-wide:
//!
//! - **Teaching (`taught`)**: a Lead or Executive's proven lessons (never one
//!   learned from outside content) go to teammates whose work is alike, as new
//!   lessons the bandit still has to prove there.
//! - **Splitting** and **retiring** are offered, never done: an agent whose
//!   work has become two different kinds, or one with nothing to do for 45
//!   days (or failing most of what it gets).
//!
//! Every change is in the agent's Evolution tab with its exam and an Undo; a
//! change tried and dropped is listed too, so nothing happens out of sight.

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::bench::{BenchCase, Variant, Verdict};
use crate::rank::Rank;
use crate::store::{Job, JobStatus};
use crate::tuning::{Change, Tuning};
use crate::{util, Team};

/// Knob values tried, in order; each at most once a month per agent.
const KNOBS: &[(&str, &str)] = &[
    ("clear_tool_results_after", "5"),
    ("clear_tool_results_after", "12"),
    ("keep_recent_turns", "2"),
    ("keep_recent_turns", "6"),
    ("summarize_above_tokens", "60000"),
    ("summarize_above_tokens", "200000"),
];
const RETRY_AFTER_DAYS: u64 = 30;
const IDLE_DAYS: u64 = 45;
const SPLIT_MIN_JOBS: usize = 16;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct EvolveCfg {
    pub nightly: bool,
    /// Local hour the night starts.
    pub hour: u32,
    /// Bench cases per exam (each runs twice: as it is, and changed).
    pub cases: usize,
    /// Most a night may spend on exams, in dollars (when prices are set).
    pub max_dollars: f64,
    /// Most exams a night when no price is known.
    pub max_exams: usize,
}

impl Default for EvolveCfg {
    fn default() -> Self {
        Self { nightly: false, hour: 3, cases: 6, max_dollars: 1.0, max_exams: 6 }
    }
}

/// An offer to split or retire an agent: the person decides.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Offer {
    pub id: String,
    pub agent: String,
    /// `split` · `retire`
    pub kind: String,
    pub why: String,
    /// Split: the two kinds of work, a few of its own requests each.
    pub kinds: Vec<Vec<String>>,
    pub at: u64,
    /// open · accepted · declined
    pub state: String,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct Night {
    day: String,
    started_at: u64,
    finished_at: u64,
    microdollars: u64,
    exams: usize,
    log: Vec<String>,
}

/// A career stage, from the record: what the agent has earned the right to do.
pub fn stage(rank: Rank, on_probation: bool, real_jobs: usize) -> (&'static str, &'static str) {
    if on_probation {
        return ("probation", "Works in shadow: its changes are recorded, not made.");
    }
    if real_jobs < 5 {
        return ("new", "Still building a record.");
    }
    match rank {
        Rank::Associate => ("associate", "Learns from its own jobs."),
        Rank::Senior => ("senior", "Its routines keep recipes; it can be exam-tuned at night."),
        Rank::Lead => ("lead", "Teaches its proven lessons to teammates with alike work."),
        Rank::Executive => ("executive", "Teaches; and an agent retiring can hand its work to a new hire through it."),
    }
}

/// The two kinds of work in a list of requests, if there are two: each at least
/// 35% of the whole, and each kind clearly more alike inside than across.
pub fn two_kinds(inputs: &[String]) -> Option<(Vec<usize>, Vec<usize>)> {
    use cookie_harness::lessons::similarity;
    let n = inputs.len();
    if n < SPLIT_MIN_JOBS {
        return None;
    }
    // The two requests least alike are the seeds.
    let (mut sa, mut sb, mut low) = (0, 1, f64::MAX);
    for i in 0..n {
        for j in i + 1..n {
            let s = similarity(&inputs[i], &inputs[j]);
            if s < low {
                (sa, sb, low) = (i, j, s);
            }
        }
    }
    let (mut a, mut b) = (Vec::new(), Vec::new());
    for (i, t) in inputs.iter().enumerate() {
        if similarity(t, &inputs[sa]) >= similarity(t, &inputs[sb]) { a.push(i) } else { b.push(i) }
    }
    let share = |v: &Vec<usize>| v.len() as f64 / n as f64;
    if share(&a) < 0.35 || share(&b) < 0.35 {
        return None;
    }
    let mean = |xs: &[usize], ys: &[usize], same: bool| {
        let mut sum = 0.0;
        let mut k = 0.0;
        for &x in xs {
            for &y in ys {
                if same && x >= y {
                    continue;
                }
                sum += similarity(&inputs[x], &inputs[y]);
                k += 1.0;
            }
        }
        if k == 0.0 { 0.0 } else { sum / k }
    };
    let inside = (mean(&a, &a, true) + mean(&b, &b, true)) / 2.0;
    let across = mean(&a, &b, false);
    (inside >= across + 0.12).then_some((a, b))
}

fn today() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

impl Team {
    fn night_path(&self) -> std::path::PathBuf {
        self.paths.root.join("evolve.json")
    }

    fn evolve_offers_path(&self) -> std::path::PathBuf {
        self.paths.root.join("evolve-offers.json")
    }

    pub fn offers(&self) -> Vec<Offer> {
        util::read_json(&self.evolve_offers_path())
    }

    pub fn evolve_status(&self) -> Value {
        let n: Night = util::read_json(&self.night_path());
        json!({"last_night": (!n.day.is_empty()).then_some(json!({"day": n.day, "spent_microdollars": n.microdollars, "exams": n.exams, "log": n.log})), "offers": self.offers().into_iter().filter(|o| o.state == "open").collect::<Vec<_>>()})
    }

    /// Called on the minute tick: start the night when it is time.
    pub(crate) async fn maybe_evolve(self: &Arc<Self>) {
        let cfg = self.settings().await.evolve;
        if !cfg.nightly || chrono::Timelike::hour(&chrono::Local::now()) != cfg.hour || !self.busy().is_empty() {
            return;
        }
        let mut n: Night = util::read_json(&self.night_path());
        if n.day == today() {
            return;
        }
        n = Night { day: today(), started_at: util::now(), ..Night::default() };
        let _ = util::write_json(&self.night_path(), &n);
        let team = self.clone();
        tokio::spawn(async move { team.night(cfg).await });
    }

    /// One night: a change tried per agent, right-sizing weekly, teaching, offers.
    pub async fn night(self: &Arc<Self>, cfg: EvolveCfg) {
        let mut n: Night = util::read_json(&self.night_path());
        let day_no = util::now() / 86_400;
        let agents: Vec<_> = self.agents().await.into_iter().filter(|a| a.shadow_of.is_none() && !crate::bench::is_probe(&a.id) && !self.is_asleep(&a.id)).collect();
        let over = |n: &Night| (n.microdollars as f64 / 1e6) >= cfg.max_dollars || n.exams >= cfg.max_exams.max(1) * 4;
        for a in &agents {
            if over(&n) {
                n.log.push("The night's budget was spent; the rest wait for tomorrow.".into());
                break;
            }
            let cases = pick_cases(self.bench_for(&a.id), cfg.cases, day_no);
            if cases.len() < 3 {
                continue;
            }
            // One change a night: a proven habit first, else a knob.
            if let Some((kind, what, tuning)) = self.next_change(&a.id) {
                match self.exam(&a.id, &what, cases.clone(), Variant { model: None, tuning: Some(tuning.clone()) }).await {
                    Ok(e) => {
                        n.exams += 1;
                        n.microdollars += e.before.microdollars + e.after.microdollars;
                        let v = crate::bench::verdict(&e.before, &e.after);
                        let exam = exam_json(&e);
                        if matches!(v, Verdict::Keep | Verdict::Cheaper) {
                            let _ = self.apply_change(&a.id, kind, &what, "nightly", Some(tuning), None, Some(exam)).await;
                            n.log.push(format!("{}: kept — {what}", a.name));
                        } else {
                            self.record_tried(&a.id, kind, &what, "dropped", exam);
                            n.log.push(format!("{}: tried and dropped — {what}", a.name));
                        }
                    }
                    Err(e) => n.log.push(format!("{}: no exam ({e})", a.name)),
                }
            }
            // Right-sizing, once a week per agent (on its own day).
            if !over(&n) && (day_no + a.id.bytes().map(u64::from).sum::<u64>()) % 7 == 0 {
                self.right_size(a, &cases, &mut n).await;
            }
            let _ = util::write_json(&self.night_path(), &n);
        }
        self.teach(&agents, &mut n).await;
        self.find_offers(&agents).await;
        n.finished_at = util::now();
        let _ = util::write_json(&self.night_path(), &n);
        if !n.log.is_empty() {
            self.notice(crate::front::COOKIE_ID, "Last night's tuning", &n.log.join("\n"), None, false);
        }
    }

    /// The change to try next: a proven habit not yet held, else the next knob.
    fn next_change(&self, agent: &str) -> Option<(&'static str, String, Tuning)> {
        let t = self.tuning(agent);
        let tried = self.tried_lately(agent);
        if t.habits.len() < crate::tuning::MAX_HABITS {
            for l in self.lessons(agent) {
                if l.state == "archived" || l.outside {
                    continue;
                }
                let text = util::clip(l.text.trim(), 300);
                if t.habits.contains(&text) || tried.contains(&format!("Habit: {text}")) {
                    continue;
                }
                if cookie_harness::lessons::proven(l.arm(), self.baseline(agent, &l.cue)) {
                    let mut next = t.clone();
                    next.habits.push(text.clone());
                    return Some(("habit", format!("Habit: {text}"), next));
                }
            }
        }
        for (knob, value) in KNOBS {
            let what = format!("Setting: {knob} = {value}");
            if tried.contains(&what) {
                continue;
            }
            let mut next = t.clone();
            let changed = match *knob {
                "clear_tool_results_after" => value.parse().ok().filter(|v| *v != t.clear_tool_results_after).map(|v| next.clear_tool_results_after = v),
                "keep_recent_turns" => value.parse().ok().filter(|v| *v != t.keep_recent_turns).map(|v| next.keep_recent_turns = v),
                "summarize_above_tokens" => value.parse().ok().filter(|v| *v != t.summarize_above_tokens).map(|v| next.summarize_above_tokens = v),
                _ => None,
            };
            if changed.is_some() {
                return Some(("knob", what, next));
            }
        }
        None
    }

    /// What was tried (kept, dropped or offered) in the last month, by its words.
    fn tried_lately(&self, agent: &str) -> Vec<String> {
        let since = util::now().saturating_sub(RETRY_AFTER_DAYS * 86_400);
        self.evolution(agent).into_iter().filter(|c| c.at >= since).map(|c| c.what).collect()
    }

    fn record_tried(&self, agent: &str, kind: &str, what: &str, state: &str, exam: Value) {
        let c = Change { id: util::new_id("chg"), agent: agent.into(), at: util::now(), kind: kind.into(), what: what.into(), by: "nightly".into(), exam: Some(exam), state: state.into(), ..Change::default() };
        let _ = util::append_jsonl(&self.paths.agent(agent).join("evolution.jsonl"), &c);
    }

    /// A cheaper model with the same results, or a stronger one when it is failing: offered.
    async fn right_size(self: &Arc<Self>, a: &crate::store::AgentRecord, cases: &[BenchCase], n: &mut Night) {
        let s = self.settings().await;
        let Some(mine) = s.prices.get(&a.model).map(|p| p.input + p.output) else { return };
        let keyed = crate::keys::Keys::present();
        let usable = |m: &str| m.split_once(':').is_some_and(|(p, _)| p == "ollama" || keyed.contains(&p));
        let tried = self.tried_lately(&a.id);
        let mut cheaper: Vec<(f64, String)> = s.prices.iter().filter(|(m, p)| *m != &a.model && usable(m) && p.input + p.output < mine).map(|(m, p)| (p.input + p.output, m.clone())).collect();
        cheaper.sort_by(|x, y| y.0.total_cmp(&x.0)); // the closest step down first
        let mut stronger: Vec<(f64, String)> = s.prices.iter().filter(|(m, p)| *m != &a.model && usable(m) && p.input + p.output > mine).map(|(m, p)| (p.input + p.output, m.clone())).collect();
        stronger.sort_by(|x, y| x.0.total_cmp(&y.0));
        let failing = self.exams(&a.id).first().is_some_and(|e| e.before.total > 0 && (e.before.passed as f64) < 0.6 * e.before.total as f64);
        let pool = if failing { stronger } else { cheaper };
        for (_, model) in pool.into_iter().take(1) {
            let what = format!("Model: {} → {model}", a.model);
            if tried.contains(&what) {
                continue;
            }
            match self.exam(&a.id, &what, cases.to_vec(), Variant { model: Some(model.clone()), tuning: None }).await {
                Ok(e) => {
                    n.exams += 1;
                    n.microdollars += e.before.microdollars + e.after.microdollars;
                    let v = crate::bench::verdict(&e.before, &e.after);
                    let good = if failing { e.after.passed > e.before.passed } else { v == Verdict::Cheaper };
                    let state = if good { "proposed" } else { "dropped" };
                    let c = Change { id: util::new_id("chg"), agent: a.id.clone(), at: util::now(), kind: "model".into(), what: what.clone(), by: "right-size".into(), model_before: Some(a.model.clone()), model_after: Some(model.clone()), exam: Some(exam_json(&e)), state: state.into(), ..Change::default() };
                    let _ = util::append_jsonl(&self.paths.agent(&a.id).join("evolution.jsonl"), &c);
                    n.log.push(format!("{}: {} — {what}", a.name, if good { "offered" } else { "tried and dropped" }));
                }
                Err(e) => n.log.push(format!("{}: no right-size exam ({e})", a.name)),
            }
        }
    }

    /// Accept an offered model change.
    pub async fn accept_change(&self, agent: &str, id: &str) -> Result<Change, String> {
        let all = self.evolution(agent);
        let c = all.into_iter().find(|c| c.id == id && c.state == "proposed").ok_or("No such offer, or it was already decided.")?;
        self.close_proposal(agent, id, "accepted")?;
        self.apply_change(agent, &c.kind, &c.what, "you", None, c.model_after.clone(), c.exam.clone()).await
    }

    pub fn decline_change(&self, agent: &str, id: &str) -> Result<(), String> {
        self.close_proposal(agent, id, "declined")
    }

    fn close_proposal(&self, agent: &str, id: &str, state: &str) -> Result<(), String> {
        let path = self.paths.agent(agent).join("evolution.jsonl");
        let mut all: Vec<Change> = util::read_jsonl(&path);
        let c = all.iter_mut().find(|c| c.id == id && c.state == "proposed").ok_or("No such offer, or it was already decided.")?;
        c.state = state.into();
        util::write_jsonl(&path, &all)
    }

    /// Leads and Executives hand their proven lessons to teammates with alike work.
    async fn teach(&self, agents: &[crate::store::AgentRecord], n: &mut Night) {
        for teacher in agents {
            let (rank, _) = self.rank(teacher);
            if !matches!(rank, Rank::Lead | Rank::Executive) {
                continue;
            }
            for l in self.lessons(&teacher.id) {
                if l.state == "archived" || !cookie_harness::lessons::may_publish(&l, self.baseline(&teacher.id, &l.cue)) {
                    continue;
                }
                for learner in agents.iter().filter(|x| x.id != teacher.id) {
                    // Alike work: the lesson's cue is like the learner's job or one of its recent requests.
                    let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(&learner.id));
                    let alike = cookie_harness::lessons::similarity(&l.cue, &learner.job) >= 0.25 || jobs.iter().rev().take(40).any(|j| cookie_harness::lessons::similarity(&l.cue, &j.input) >= 0.35);
                    if !alike {
                        continue;
                    }
                    let held = self.lessons(&learner.id);
                    // Archived ones count: a lesson the learner already let go is not taught back.
                    let texts: Vec<&str> = held.iter().map(|h| h.text.as_str()).collect();
                    if cookie_harness::lessons::is_duplicate(&l.text, &texts) {
                        continue;
                    }
                    let mut taught = l.clone();
                    taught.id = util::new_id("les");
                    // Proven there, not here: the learner's bandit starts it fresh.
                    taught.wins = 0;
                    taught.losses = 0;
                    taught.withheld = 0;
                    taught.created_at = util::now() as f64;
                    taught.last_used_at = None;
                    let mut all = held.clone();
                    all.push(taught.clone());
                    if self.save_lessons(&learner.id, &all).is_err() {
                        continue;
                    }
                    let what = format!("Taught by {}: {}", teacher.name, util::clip(&l.text, 200));
                    let c = Change { id: util::new_id("chg"), agent: learner.id.clone(), at: util::now(), kind: "taught".into(), what: what.clone(), by: teacher.name.clone(), lesson: Some(taught.id), state: "kept".into(), ..Change::default() };
                    let _ = util::append_jsonl(&self.paths.agent(&learner.id).join("evolution.jsonl"), &c);
                    n.log.push(format!("{} → {}: {}", teacher.name, learner.name, util::clip(&l.text, 100)));
                }
            }
        }
    }

    /// Offers to split an agent doing two kinds of work, or to retire one with none.
    async fn find_offers(&self, agents: &[crate::store::AgentRecord]) {
        let mut offers = self.offers();
        let open = |offers: &[Offer], agent: &str, kind: &str| offers.iter().any(|o| o.agent == agent && o.kind == kind && (o.state == "open" || util::now().saturating_sub(o.at) < 60 * 86_400));
        let now = util::now();
        for a in agents.iter().filter(|a| a.id != crate::front::COOKIE_ID) {
            let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(&a.id));
            let recent: Vec<&Job> = jobs.iter().filter(|j| crate::experience::real(j) && now.saturating_sub(j.started_at) < 60 * 86_400).collect();
            let last = jobs.iter().map(|j| j.started_at).max().unwrap_or(a.created_at);
            let idle = now.saturating_sub(last) > IDLE_DAYS * 86_400 && now.saturating_sub(a.created_at) > IDLE_DAYS * 86_400;
            let judged: Vec<&&Job> = recent.iter().filter(|j| j.status != JobStatus::Stopped).collect();
            let failing = judged.len() >= 10 && judged.iter().filter(|j| crate::outcome::clean(j)).count() * 10 < judged.len() * 4;
            if (idle || failing) && !open(&offers, &a.id, "retire") {
                let why = if idle { format!("No work for {} days.", now.saturating_sub(last) / 86_400) } else { format!("Finished cleanly {} of its last {} jobs.", judged.iter().filter(|j| crate::outcome::clean(j)).count(), judged.len()) };
                offers.push(Offer { id: util::new_id("off"), agent: a.id.clone(), kind: "retire".into(), why, at: now, state: "open".into(), ..Offer::default() });
            }
            let inputs: Vec<String> = recent.iter().map(|j| j.input.clone()).take(100).collect();
            if !open(&offers, &a.id, "split") {
                if let Some((x, y)) = two_kinds(&inputs) {
                    let sample = |ix: &[usize]| ix.iter().take(3).map(|i| util::clip(&inputs[*i], 120)).collect::<Vec<_>>();
                    offers.push(Offer {
                        id: util::new_id("off"),
                        agent: a.id.clone(),
                        kind: "split".into(),
                        why: format!("Its last {} requests are two different kinds of work ({} and {}).", inputs.len(), x.len(), y.len()),
                        kinds: vec![sample(&x), sample(&y)],
                        at: now,
                        state: "open".into(),
                    });
                }
            }
        }
        let _ = util::write_json(&self.evolve_offers_path(), &offers);
    }

    /// Decline an offer; it is not made again for 60 days.
    pub fn decline_offer(&self, id: &str) -> Result<(), String> {
        let mut offers = self.offers();
        let o = offers.iter_mut().find(|o| o.id == id && o.state == "open").ok_or("No such offer.")?;
        o.state = "declined".into();
        util::write_json(&self.evolve_offers_path(), &offers)
    }

    /// Split: a new agent takes the second kind of work, with the parent's
    /// model, permissions and skills, and the lessons and tests alike to that
    /// work. The person names it and writes its one job.
    pub async fn accept_split(self: &Arc<Self>, id: &str, name: &str, job: &str, parent_job: Option<String>) -> Result<crate::store::AgentRecord, String> {
        let mut offers = self.offers();
        let o = offers.iter().find(|o| o.id == id && o.kind == "split" && o.state == "open").cloned().ok_or("No such offer.")?;
        let parent = self.agent(&o.agent).await?;
        let child = self.hire(crate::Hire { name: name.into(), job: job.into(), model: parent.model.clone(), grants: Some(parent.grants.clone()), probation_days: 0, handover: None, id: None, inherit: None, template: None }).await?;
        let kind_b = o.kinds.get(1).cloned().unwrap_or_default().join(" ");
        // Its skills, and the lessons and tests alike to its work.
        let skills = self.paths.agent(&parent.id).join("skills");
        if skills.exists() {
            let _ = crate::sleep::clone_path(&skills, &self.paths.agent(&child.id).join("skills"));
        }
        let alike = |t: &str| cookie_harness::lessons::similarity(t, &kind_b) >= 0.2 || cookie_harness::lessons::similarity(t, job) >= 0.2;
        let moved: Vec<_> = self.lessons(&parent.id).into_iter().filter(|l| alike(&l.cue) || alike(&l.text)).map(|mut l| {
            l.id = util::new_id("les");
            l
        }).collect();
        self.save_lessons(&child.id, &moved)?;
        let tests: Vec<_> = self.tests(&parent.id).into_iter().filter(|t| alike(&t.input)).collect();
        util::write_json(&self.paths.tests(&child.id), &tests)?;
        if let Some(pj) = parent_job.map(|j| j.trim().to_string()).filter(|j| !j.is_empty()) {
            let mut agents = self.agents.write().await;
            if let Some(p) = agents.iter_mut().find(|a| a.id == parent.id) {
                p.job = pj;
                p.version += 1;
            }
            let snapshot = agents.clone();
            drop(agents);
            util::write_json(&self.paths.roster(), &snapshot)?;
        }
        for (agent, what) in [(&parent.id, format!("Split: {name} took part of its work")), (&child.id, format!("Split from {}", parent.name))] {
            let c = Change { id: util::new_id("chg"), agent: agent.clone(), at: util::now(), kind: "split".into(), what, by: "you".into(), state: "kept".into(), ..Change::default() };
            let _ = util::append_jsonl(&self.paths.agent(agent).join("evolution.jsonl"), &c);
        }
        if let Some(x) = offers.iter_mut().find(|x| x.id == id) {
            x.state = "accepted".into();
        }
        util::write_json(&self.evolve_offers_path(), &offers)?;
        self.emit(crate::events::TeamEvent::RosterChanged);
        Ok(child)
    }

    /// Retire: what it learned is kept for a successor (`inherit`), then it is let go.
    pub async fn accept_retire(self: &Arc<Self>, id: &str) -> Result<String, String> {
        let mut offers = self.offers();
        let o = offers.iter().find(|o| o.id == id && o.kind == "retire" && o.state == "open").cloned().ok_or("No such offer.")?;
        let archive = self.retire(&o.agent).await?;
        if let Some(x) = offers.iter_mut().find(|x| x.id == id) {
            x.state = "accepted".into();
        }
        util::write_json(&self.evolve_offers_path(), &offers)?;
        Ok(archive)
    }
}

/// Cases for tonight: a different slice of the agent's bench each night.
pub fn pick_cases(mut cases: Vec<BenchCase>, n: usize, day: u64) -> Vec<BenchCase> {
    if cases.len() <= n {
        return cases;
    }
    cases.sort_by(|a, b| a.id.cmp(&b.id));
    let start = (day as usize * n) % cases.len();
    cases.rotate_left(start);
    cases.truncate(n);
    cases
}

fn exam_json(e: &crate::bench::Exam) -> Value {
    json!({
        "id": e.id, "cases": e.before.total,
        "before": {"passed": e.before.passed, "microdollars": e.before.microdollars, "tokens": e.before.tokens},
        "after": {"passed": e.after.passed, "microdollars": e.after.microdollars, "tokens": e.after.tokens},
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_kinds_of_work_are_found_and_one_kind_is_not_split() {
        let mut inputs: Vec<String> = (0..10).map(|i| format!("chase the overdue invoice {i} for the client and send a reminder")).collect();
        inputs.extend((0..10).map(|i| format!("write a linkedin post about our product launch number {i}")));
        let (a, b) = two_kinds(&inputs).expect("two kinds");
        assert_eq!(a.len() + b.len(), 20);
        assert!(a.iter().all(|i| *i < 10) || a.iter().all(|i| *i >= 10), "each kind together");
        let one: Vec<String> = (0..20).map(|i| format!("chase the overdue invoice {i} for the client")).collect();
        assert!(two_kinds(&one).is_none());
        assert!(two_kinds(&inputs[..8].to_vec()).is_none(), "too few to tell");
    }

    #[test]
    fn stages_follow_the_record() {
        assert_eq!(stage(Rank::Executive, true, 500).0, "probation");
        assert_eq!(stage(Rank::Lead, false, 3).0, "new");
        assert_eq!(stage(Rank::Lead, false, 80).0, "lead");
    }

    #[test]
    fn each_night_takes_another_slice_of_the_bench() {
        let cases: Vec<BenchCase> = (0..10).map(|i| BenchCase { id: format!("c{i}"), ..BenchCase::default() }).collect();
        let a = pick_cases(cases.clone(), 4, 0);
        let b = pick_cases(cases.clone(), 4, 1);
        assert_eq!(a.len(), 4);
        assert_ne!(a[0].id, b[0].id);
        assert_eq!(pick_cases(cases[..3].to_vec(), 4, 5).len(), 3);
    }
}
