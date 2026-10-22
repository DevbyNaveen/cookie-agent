//! When the model itself keeps failing — refused, throttled, unreachable —
//! every new job would fail the same way and bill the team for nothing.
//! After three such failures in a row, new jobs wait for the breaker to
//! close instead of starting. The client keeps the record; the rule is here.

use serde_json::{json, Value};

/// Failures in a row that open the breaker.
pub const IN_A_ROW: usize = 3;
/// How long it stays open after the last one.
pub const OPEN_FOR: f64 = 10.0 * 60.0;
/// Older failures are history.
pub const WINDOW: f64 = 30.0 * 60.0;

/// The failure kinds that are the model's or the provider's, not the job's.
pub fn systemic(kind: &str) -> bool {
    matches!(kind, "provider" | "setup" | "harness" | "context_full")
}

/// `recent`: the newest runs first, `(kind or "", ended at)`. `Some(until)`
/// when new jobs should wait until then.
pub fn open_until(recent: &[(String, f64)], now: f64) -> Option<f64> {
    let streak: Vec<f64> = recent.iter().take_while(|(k, at)| systemic(k) && now - at <= WINDOW).map(|(_, at)| *at).collect();
    if streak.len() < IN_A_ROW {
        return None;
    }
    let until = streak[0] + OPEN_FOR;
    (until > now).then_some(until)
}

/// One `breaker` line: `{recent: [[kind, at]], now}` → `{open, until?}`.
pub fn rpc(m: &Value) -> Result<Value, String> {
    let recent: Vec<(String, f64)> = serde_json::from_value(m["recent"].clone()).map_err(|e| format!("`recent`: {e}"))?;
    let now = m["now"].as_f64().ok_or("`now` is missing")?;
    Ok(match open_until(&recent, now) {
        Some(until) => json!({"open": true, "until": until}),
        None => json!({"open": false}),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn three_model_failures_in_a_row_hold_new_jobs_for_ten_minutes() {
        let f = |k: &str, at: f64| (k.to_string(), at);
        let now = 10_000.0;
        assert_eq!(open_until(&[f("provider", 9_900.0), f("provider", 9_800.0), f("provider", 9_700.0)], now), Some(9_900.0 + OPEN_FOR));
        assert_eq!(open_until(&[f("provider", 9_900.0), f("", 9_800.0), f("provider", 9_700.0)], now), None, "a clean run breaks the streak");
        assert_eq!(open_until(&[f("budget", 9_900.0), f("loop", 9_800.0), f("tool", 9_700.0)], now), None, "the job's own failures are not the model's");
        assert_eq!(open_until(&[f("provider", 9_000.0), f("provider", 8_900.0), f("provider", 8_800.0)], 9_000.0 + OPEN_FOR + 1.0), None, "closes by itself");
    }
}
