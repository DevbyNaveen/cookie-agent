//! What a job's tool calls came to, read from what they actually returned.
//!
//! - **Why a call failed.** One taxonomy, answering "who must act": nobody
//!   (the person said no, or the run was stopped), the person (a permission
//!   to give), the agent itself (a tool name or arguments to fix), or the
//!   world (anything else, the only kind where work may not have landed).
//!   Read from the error text the harness and Cookie's tools really return;
//!   anything unrecognised is `Upstream`, so a wording change degrades to
//!   "it failed" and never to silence.
//! - **Whether the job ended failed.** A call that failed and was then made
//!   again and worked does not count: the job that fixed its own call is the
//!   one worth learning from.
//! - **Which tools have been working.** Every call of the last 14 days,
//!   ranked by a Wilson lower bound: proven tools and failing ones go into
//!   the agent's instructions; everything in between is left unsaid.
//!
//! Ported from the super console (gateway `chat/tool_failure.rs`,
//! `chat/selection.rs`, `chat/procedures.rs`), with the desktop's own error
//! strings in place of the gateway's.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::store::Job;

/// Why a tool call failed: who has to act on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureKind {
    /// The person said no. Nothing ran, nothing was lost.
    Declined,
    /// A permission the person has to give (a folder, a Mac app, a grant).
    Refused,
    /// The rules held: a value from content the person didn't write tried
    /// to choose who, where or how much. The system working, not failing.
    Blocked,
    /// No tool by that name: the agent's own mistake, and fixable.
    UnknownTool,
    /// The tool exists; the arguments were wrong. Fixable by the agent.
    BadArguments,
    /// Not run: the job was stopped, or it kept repeating itself.
    NotRun,
    /// Everything else: an app, a site or the network. The only kind where
    /// work may genuinely be missing.
    Upstream,
}

impl FailureKind {
    pub fn as_str(self) -> &'static str {
        match self {
            FailureKind::Declined => "declined",
            FailureKind::Refused => "refused",
            FailureKind::Blocked => "blocked",
            FailureKind::UnknownTool => "unknown_tool",
            FailureKind::BadArguments => "bad_arguments",
            FailureKind::NotRun => "not_run",
            FailureKind::Upstream => "upstream",
        }
    }

    pub fn parse(s: &str) -> FailureKind {
        match s {
            "declined" => FailureKind::Declined,
            "refused" => FailureKind::Refused,
            "blocked" => FailureKind::Blocked,
            "unknown_tool" => FailureKind::UnknownTool,
            "bad_arguments" => FailureKind::BadArguments,
            "not_run" => FailureKind::NotRun,
            _ => FailureKind::Upstream,
        }
    }

    /// Can the same call, sent again unchanged, ever work? Only `Upstream`.
    pub fn is_retriable(self) -> bool {
        self == FailureKind::Upstream
    }

    /// Does this count against the job's record? A no from the person, a
    /// stopped run and the rules holding are not the agent's failures.
    pub fn counts_against(self) -> bool {
        matches!(self, FailureKind::Refused | FailureKind::UnknownTool | FailureKind::BadArguments | FailureKind::Upstream)
    }
}

/// Read the kind out of a tool's error text.
pub fn classify(text: &str) -> FailureKind {
    let t = text.to_lowercase();
    if t.contains("the person declined this action") {
        return FailureKind::Declined;
    }
    if t.starts_with("not run:") || t.starts_with("interrupted:") {
        return FailureKind::NotRun;
    }
    if t.contains("there is no tool called") {
        return FailureKind::UnknownTool;
    }
    if t.contains("came from content the person didn't write") || t.contains("has no value the person can be shown") {
        return FailureKind::Blocked;
    }
    if t.contains("hasn't allowed cookie")
        || t.contains("you can only see your own folder")
        || t.contains("is outside the folders you were given")
        || t.contains("is where secrets")
        || t.contains("only reachable on a mac")
        || t.contains("not granted")
    {
        return FailureKind::Refused;
    }
    if t.contains("were not valid json")
        || t.contains("give a full path")
        || t.contains("isn't a time")
        || t.contains("isn't a day of the week")
        || t.contains("isn't a real date")
        || t.contains("dates look like")
        || t.contains("times look like")
        || t.contains(" must be ")
        || t.starts_with("say what")
        || t.contains("missing field")
        || t.contains("invalid type")
    {
        return FailureKind::BadArguments;
    }
    FailureKind::Upstream
}

/// One tool call of a job, as its record keeps it (no arguments: those can
/// hold the person's content, and a record is read by every surface).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Step {
    pub tool: String,
    #[serde(default)]
    pub failed: bool,
    /// `FailureKind::as_str` when it failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

/// The calls a run made, in order, with the arguments that were sent (for a
/// routine's recipe) and how each ended. `messages` are the ones the run added.
pub fn calls_in(messages: &[cookie_harness::Message]) -> Vec<(Step, Value)> {
    let mut results = std::collections::HashMap::new();
    for m in messages {
        for c in m.content() {
            if let cookie_harness::message::Content::ToolResult { id, output, is_error } = c {
                results.insert(id.clone(), (output.clone(), *is_error));
            }
        }
    }
    let mut out = Vec::new();
    for m in messages {
        for (id, name, args) in m.tool_calls() {
            let (output, failed) = results.get(id).cloned().unwrap_or_default();
            let kind = failed.then(|| classify(&output).as_str().to_string());
            out.push((Step { tool: name.to_string(), failed, kind }, args.clone()));
        }
    }
    out
}

/// A later call to the same tool worked.
fn recovered(steps: &[Step], i: usize) -> bool {
    steps[i + 1..].iter().any(|s| !s.failed && s.tool == steps[i].tool)
}

/// The calls still failing when the job ended, that count against it.
pub fn still_failing(steps: &[Step]) -> Vec<(FailureKind, &str)> {
    steps
        .iter()
        .enumerate()
        .filter(|(i, s)| s.failed && !recovered(steps, *i))
        .map(|(_, s)| (FailureKind::parse(s.kind.as_deref().unwrap_or("")), s.tool.as_str()))
        .filter(|(k, _)| k.counts_against())
        .collect()
}

/// The job's tool work ended failed.
pub fn ended_failed(steps: &[Step]) -> bool {
    !still_failing(steps).is_empty()
}

/// What stopped it: the last call still failing.
pub fn failing(steps: &[Step]) -> Option<(FailureKind, String)> {
    still_failing(steps).last().map(|(k, t)| (*k, t.to_string()))
}

/// A clean job: finished, answered, nothing left failing, not graded bad.
pub fn clean(job: &Job) -> bool {
    job.status == crate::store::JobStatus::Done && !job.answer.trim().is_empty() && !ended_failed(&job.steps) && job.grade != Some(-1)
}

/* ---------- which tools have been working ---------- */

/// Wilson score interval (z = 1.96) of `wins / n`. (0, 1) with no data.
pub fn wilson(wins: i64, n: i64) -> (f64, f64) {
    if n <= 0 {
        return (0.0, 1.0);
    }
    let z = 1.96_f64;
    let n = n as f64;
    let p = wins as f64 / n;
    let denom = 1.0 + z * z / n;
    let centre = p + z * z / (2.0 * n);
    let spread = z * ((p * (1.0 - p) + z * z / (4.0 * n)) / n).sqrt();
    ((centre - spread) / denom, (centre + spread) / denom)
}

pub fn wilson_lower(wins: i64, n: i64) -> f64 {
    wilson(wins, n).0
}

/// Fewer calls than this and a rate is noise.
const MIN_CALLS: i64 = 3;
const MAX_PROVEN: usize = 8;
const MAX_FAILING: usize = 6;
pub const RECORD_DAYS: u64 = 14;

/// `(tool, calls, failed)` over the jobs started since `since`. A no from
/// the person or a stopped run is not a failure of the tool.
pub fn tool_records(jobs: &[Job], since: u64) -> Vec<(String, i64, i64)> {
    let mut by: std::collections::BTreeMap<String, (i64, i64)> = Default::default();
    for j in jobs.iter().filter(|j| j.started_at >= since) {
        for s in &j.steps {
            let kind = FailureKind::parse(s.kind.as_deref().unwrap_or(""));
            if s.failed && !kind.counts_against() {
                continue;
            }
            let e = by.entry(s.tool.clone()).or_default();
            e.0 += 1;
            if s.failed {
                e.1 += 1;
            }
        }
    }
    by.into_iter().map(|(t, (c, f))| (t, c, f)).collect()
}

/// The track record block for an agent's instructions; empty when nothing
/// is clearly working or clearly failing.
pub fn tool_record_block(records: &[(String, i64, i64)]) -> String {
    let mut proven = Vec::new();
    let mut bad = Vec::new();
    for (tool, calls, failed) in records {
        if *calls < MIN_CALLS {
            continue;
        }
        let wins = calls - failed;
        let (lo, hi) = wilson(wins, *calls);
        if lo >= 0.6 {
            proven.push((tool, wins, *calls, lo));
        } else if hi < 0.5 {
            bad.push((tool, *failed, *calls, hi));
        }
    }
    if proven.is_empty() && bad.is_empty() {
        return String::new();
    }
    proven.sort_by(|a, b| b.3.total_cmp(&a.3));
    bad.sort_by(|a, b| a.3.total_cmp(&b.3));
    let mut s = format!("Your tools' record over the last {RECORD_DAYS} days (every call counted):\n");
    if !proven.is_empty() {
        s.push_str("Working; prefer these when they fit the job:\n");
        for (tool, wins, calls, _) in proven.iter().take(MAX_PROVEN) {
            s.push_str(&format!("- {tool}: {wins} of {calls} calls worked\n"));
        }
    }
    if !bad.is_empty() {
        s.push_str("Failing; don't reach for these first, and if nothing else can do the job, say so before calling one:\n");
        for (tool, failed, calls, _) in bad.iter().take(MAX_FAILING) {
            s.push_str(&format!("- {tool}: {failed} of {calls} calls failed\n"));
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_error_lands_with_who_must_act() {
        assert_eq!(classify("The person declined this action."), FailureKind::Declined);
        assert_eq!(classify("There is no tool called `send_mail`."), FailureKind::UnknownTool);
        assert_eq!(classify("The arguments for `x` were not valid JSON (eof). Send the call again with valid JSON."), FailureKind::BadArguments);
        assert_eq!(classify("`to` = \"a@b.c\" came from content the person didn't write, so it can't choose who, where or how much."), FailureKind::Blocked);
        assert_eq!(classify("macOS hasn't allowed Cookie to use that app. Allow it in System Settings."), FailureKind::Refused);
        assert_eq!(classify("`/etc/x` is outside the folders you were given: ~/Docs."), FailureKind::Refused);
        assert_eq!(classify("Not run: the run was cancelled first."), FailureKind::NotRun);
        assert_eq!(classify("Interrupted: this may or may not have run. Check before trying again."), FailureKind::NotRun);
        assert_eq!(classify("Dates look like 2026-11-25 or 2026-11-25 14:30, not \"tomorrow\"."), FailureKind::BadArguments);
        assert_eq!(classify("connection reset by peer"), FailureKind::Upstream, "unknown text fails safe");
        assert!(FailureKind::Upstream.is_retriable() && !FailureKind::BadArguments.is_retriable());
    }

    fn step(tool: &str, failed: bool, kind: &str) -> Step {
        Step { tool: tool.into(), failed, kind: failed.then(|| kind.into()) }
    }

    #[test]
    fn a_call_fixed_later_in_the_job_does_not_fail_it() {
        let fixed = [step("mac_files_write", true, "bad_arguments"), step("mac_files_write", false, "")];
        assert!(!ended_failed(&fixed));
        let broken = [step("read_url", false, ""), step("mac_files_write", true, "bad_arguments")];
        assert_eq!(failing(&broken), Some((FailureKind::BadArguments, "mac_files_write".into())));
        let said_no = [step("send_email", true, "declined")];
        assert!(!ended_failed(&said_no), "the person's no is not the agent's failure");
    }

    #[test]
    fn the_record_names_only_what_is_clearly_working_or_failing() {
        assert_eq!(tool_record_block(&[("a".into(), 2, 0)]), "", "two calls are noise");
        let s = tool_record_block(&[("good".into(), 20, 1), ("bad".into(), 10, 9), ("meh".into(), 10, 5)]);
        assert!(s.contains("good: 19 of 20") && s.contains("bad: 9 of 10 calls failed"));
        assert!(!s.contains("meh"), "in between is left unsaid");
        assert!(wilson_lower(3, 3) < 0.6, "3 of 3 is not proven");
    }
}
