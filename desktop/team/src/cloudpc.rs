//! The cloud computer: one Parallax machine on AWS that wakes when an agent
//! needs a full computer and sleeps after 15 idle minutes.
//!
//! - **The machine sleeps itself.** It stops after 15 minutes with no Cookie
//!   command, no awake world and no session (its own timer); its disk keeps
//!   every world and snapshot while it sleeps. Spot capacity, so when AWS needs
//!   it back it stops the same way, and wakes again on the next job.
//! - **Cookie holds a narrow key.** It may only wake, sleep and run commands on
//!   machines tagged `cookie-parallax` (Keychain: `computer:aws:key`/`secret`).
//! - **Hours are counted from what Cookie sees**: a wake opens a session, the
//!   first look that finds the machine stopped closes it (checked every few
//!   minutes while it runs), so a month's hours are a close count, said as one.

use std::path::PathBuf;

use parallax::cloud::aws::{self, Creds};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{util, Team};

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn hmac(key: &[u8], data: &str) -> Vec<u8> {
    ring::hmac::sign(&ring::hmac::Key::new(ring::hmac::HMAC_SHA256, key), data.as_bytes()).as_ref().to_vec()
}

fn sha_hex(b: &[u8]) -> String {
    use sha2::Digest;
    hex(&sha2::Sha256::digest(b))
}

/// One AWS Systems Manager call (JSON 1.1 over POST, signed with SigV4).
async fn ssm(cr: &Creds, target: &str, body: &Value) -> Result<Value, String> {
    let host = format!("ssm.{}.amazonaws.com", cr.region);
    let payload = body.to_string();
    let (amz, date) = aws::amz_dates(util::now());
    let ct = "application/x-amz-json-1.1";
    let tgt = format!("AmazonSSM.{target}");
    let signed = "content-type;host;x-amz-date;x-amz-target";
    let creq = format!("POST\n/\n\ncontent-type:{ct}\nhost:{host}\nx-amz-date:{amz}\nx-amz-target:{tgt}\n\n{signed}\n{}", sha_hex(payload.as_bytes()));
    let scope = format!("{date}/{}/ssm/aws4_request", cr.region);
    let sts = format!("AWS4-HMAC-SHA256\n{amz}\n{scope}\n{}", sha_hex(creq.as_bytes()));
    let k = hmac(&hmac(&hmac(&hmac(format!("AWS4{}", cr.secret).as_bytes(), &date), &cr.region), "ssm"), "aws4_request");
    let auth = format!("AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed}, Signature={}", cr.key, hex(&hmac(&k, &sts)));
    let resp = reqwest::Client::new()
        .post(format!("https://{host}/"))
        .header("content-type", ct)
        .header("x-amz-date", &amz)
        .header("x-amz-target", &tgt)
        .header("authorization", auth)
        .timeout(std::time::Duration::from_secs(30))
        .body(payload)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    let ok = resp.status().is_success();
    let v: Value = resp.json().await.unwrap_or(Value::Null);
    if ok {
        Ok(v)
    } else {
        let kind = v["__type"].as_str().unwrap_or("").rsplit('#').next().unwrap_or("").to_string();
        Err(format!("{kind}: {}", v["message"].as_str().or(v["Message"].as_str()).unwrap_or("refused")))
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct CloudComputer {
    pub instance: String,
    pub region: String,
    /// Dollars an hour while it runs (its Spot price, as set up).
    pub hourly: f64,
    pub kind: String,
    /// Each time it ran: [woke, slept]; slept is 0 while it runs.
    pub sessions: Vec<[u64; 2]>,
}

fn month_bounds(month: &str) -> Option<(u64, u64)> {
    use chrono::{Datelike, Local, NaiveDate, TimeZone};
    let start = NaiveDate::parse_from_str(&format!("{month}-01"), "%Y-%m-%d").ok()?;
    let next = if start.month() == 12 { NaiveDate::from_ymd_opt(start.year() + 1, 1, 1)? } else { NaiveDate::from_ymd_opt(start.year(), start.month() + 1, 1)? };
    let t = |d: NaiveDate| Local.from_local_datetime(&d.and_hms_opt(0, 0, 0)?).single().map(|x| x.timestamp() as u64);
    Some((t(start)?, t(next)?))
}

/// Seconds of the sessions that fall inside the month (an open one runs to `now`).
fn seconds_in(sessions: &[[u64; 2]], month: &str, now: u64) -> u64 {
    let Some((a, b)) = month_bounds(month) else { return 0 };
    sessions
        .iter()
        .map(|[s, e]| {
            let e = if *e == 0 { now } else { *e };
            e.min(b).saturating_sub((*s).max(a))
        })
        .sum()
}

impl Team {
    fn computer_path(&self) -> PathBuf {
        self.paths.root.join("cloud-computer.json")
    }

    pub fn computer(&self) -> Option<CloudComputer> {
        let c: CloudComputer = util::read_json(&self.computer_path());
        (!c.instance.is_empty()).then_some(c)
    }

    fn save_computer(&self, c: &CloudComputer) -> Result<(), String> {
        util::write_json(&self.computer_path(), c)
    }

    fn computer_creds(&self, region: &str) -> Result<Creds, String> {
        Ok(Creds {
            key: self.keys.get("computer:aws:key").ok_or("The cloud computer's key isn't on this Mac.")?,
            secret: self.keys.get("computer:aws:secret").ok_or("The cloud computer's key isn't on this Mac.")?,
            token: None,
            region: region.to_string(),
        })
    }

    /// Record what Cookie saw: a running machine has an open session, a stopped one none.
    fn note_state(&self, state: &str) {
        let Some(mut c) = self.computer() else { return };
        let open = c.sessions.last().is_some_and(|s| s[1] == 0);
        let now = util::now();
        match (state, open) {
            ("running" | "pending", false) => c.sessions.push([now, 0]),
            ("stopped" | "stopping" | "terminated" | "shutting-down", true) => {
                if let Some(s) = c.sessions.last_mut() {
                    s[1] = now;
                }
            }
            _ => return,
        }
        // Keep a year of sessions.
        let cutoff = now.saturating_sub(366 * 86_400);
        c.sessions.retain(|s| s[1] == 0 || s[1] > cutoff);
        let _ = self.save_computer(&c);
    }

    pub async fn computer_status(&self) -> Value {
        let Some(c) = self.computer() else {
            return json!({"set_up": false});
        };
        let state = match self.computer_creds(&c.region) {
            Ok(cr) => aws::state(&cr, &c.instance).await,
            Err(e) => Err(e),
        };
        if let Ok(s) = &state {
            self.note_state(s);
        }
        let month = chrono::Local::now().format("%Y-%m").to_string();
        let mut v = self.cloud_computer_usage(&month);
        v["state"] = json!(state.as_ref().ok());
        v["error"] = json!(state.err());
        v
    }

    pub async fn computer_wake(&self) -> Result<Value, String> {
        let c = self.computer().ok_or("There's no cloud computer set up.")?;
        let cr = self.computer_creds(&c.region)?;
        if aws::state(&cr, &c.instance).await? != "running" {
            // Spot capacity comes and goes in minutes: keep asking for a while before giving up.
            let mut wait = 10;
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(300);
            loop {
                match aws::ec2(&cr, "StartInstances", &[("InstanceId.1".into(), c.instance.clone())]).await {
                    Ok(_) => break,
                    Err(e) if e.contains("capacity") && std::time::Instant::now() < deadline => {
                        tokio::time::sleep(std::time::Duration::from_secs(wait)).await;
                        wait = (wait * 2).min(60);
                    }
                    Err(e) if e.contains("capacity") => {
                        return Err("AWS has had no spare capacity for the cloud computer for five minutes; try again soon.".into());
                    }
                    Err(e) => return Err(e),
                }
            }
        }
        self.note_state("running");
        Ok(self.computer_status().await)
    }

    pub async fn computer_sleep(&self) -> Result<Value, String> {
        let c = self.computer().ok_or("There's no cloud computer set up.")?;
        let cr = self.computer_creds(&c.region)?;
        aws::ec2(&cr, "StopInstances", &[("InstanceId.1".into(), c.instance.clone())]).await?;
        self.note_state("stopped");
        Ok(self.computer_status().await)
    }

    /// Call the cloud computer's Parallax (one of its MCP tools), waking it first.
    /// The command goes through AWS Systems Manager: the machine has no open port.
    pub async fn computer_px(&self, tool: &str, args: &Value) -> Result<Value, String> {
        use base64::Engine;
        let c = self.computer().ok_or("There's no cloud computer set up.")?;
        let cr = self.computer_creds(&c.region)?;
        if aws::state(&cr, &c.instance).await? != "running" {
            self.computer_wake().await?;
        }
        let b64 = base64::engine::general_purpose::STANDARD.encode(args.to_string());
        let file = format!("/tmp/cookie-{}.json", util::random_hex(6));
        let tool: String = tool.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_').collect();
        let cmd = format!("echo {b64} | base64 -d > {file} && px {tool} \"$(cat {file})\"; rm -f {file}");
        let send = json!({"InstanceIds": [c.instance], "DocumentName": "AWS-RunShellScript", "Parameters": {"commands": [cmd], "executionTimeout": ["900"]}});
        // A machine that just woke takes a minute before its agent answers.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(240);
        let id = loop {
            match ssm(&cr, "SendCommand", &send).await {
                Ok(v) => break v["Command"]["CommandId"].as_str().unwrap_or_default().to_string(),
                Err(e) if e.starts_with("InvalidInstanceId") && std::time::Instant::now() < deadline => tokio::time::sleep(std::time::Duration::from_secs(4)).await,
                Err(e) => return Err(format!("The cloud computer didn't take the command: {e}")),
            }
        };
        let ask = json!({"CommandId": id, "InstanceId": c.instance});
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(960);
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(600)).await;
            let v = match ssm(&cr, "GetCommandInvocation", &ask).await {
                Ok(v) => v,
                Err(e) if e.starts_with("InvocationDoesNotExist") => continue,
                Err(e) => return Err(e),
            };
            match v["Status"].as_str().unwrap_or("") {
                "Success" => {
                    let out = v["StandardOutputContent"].as_str().unwrap_or_default();
                    let rpc: Value = serde_json::from_str(out.trim()).map_err(|_| format!("The cloud computer answered oddly: {}", util::clip(out, 300)))?;
                    if let Some(e) = rpc["error"]["message"].as_str() {
                        return Err(e.to_string());
                    }
                    let text = rpc["result"]["content"][0]["text"].as_str().unwrap_or_default();
                    if rpc["result"]["isError"].as_bool().unwrap_or(false) {
                        return Err(text.to_string());
                    }
                    return Ok(serde_json::from_str(text).unwrap_or_else(|_| json!(text)));
                }
                "Failed" | "Cancelled" | "TimedOut" | "Cancelling" => {
                    return Err(format!("The command failed on the cloud computer: {}", util::clip(v["StandardErrorContent"].as_str().or(v["StandardOutputContent"].as_str()).unwrap_or(""), 400)));
                }
                _ if std::time::Instant::now() > deadline => return Err("The cloud computer took too long.".into()),
                _ => {}
            }
        }
    }

    /// The month's hours and their cost, from the sessions Cookie saw.
    pub(crate) fn cloud_computer_usage(&self, month: &str) -> Value {
        let Some(c) = self.computer() else {
            return json!({"set_up": false});
        };
        let secs = seconds_in(&c.sessions, month, util::now());
        let hours = secs as f64 / 3600.0;
        json!({
            "set_up": true, "instance": c.instance, "region": c.region, "kind": c.kind, "hourly": c.hourly,
            "hours": (hours * 100.0).round() / 100.0, "dollars": (hours * c.hourly * 100.0).round() / 100.0,
            "running_since": c.sessions.last().filter(|s| s[1] == 0).map(|s| s[0]),
        })
    }

    /// While the machine may be running, look every few minutes, so its sleep closes the session.
    pub(crate) fn spawn_computer_watch(self: &std::sync::Arc<Self>) {
        let team = std::sync::Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(240)).await;
                let Some(t) = team.upgrade() else { return };
                if t.computer().is_some_and(|c| c.sessions.last().is_some_and(|s| s[1] == 0)) {
                    let _ = t.computer_status().await;
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_months_share_of_each_session_counts() {
        let (a, b) = month_bounds("2026-11").unwrap();
        assert_eq!((b - a) / 86_400, 30, "November has 30 days");
        let s = [[a - 3600, a + 3600], [a + 10_000, a + 13_600], [b - 1800, 0]];
        // 1 h after the month starts, 1 h in the middle, and an open session counted to the month's end.
        assert_eq!(seconds_in(&s, "2026-11", b + 99_999), 3600 + 3600 + 1800);
        assert_eq!(seconds_in(&s, "2026-10", b), 3600, "October gets only its own hour");
    }

    #[test]
    fn what_cookie_sees_opens_and_closes_sessions() {
        let dir = std::env::temp_dir().join(format!("cookie-pc-{}", util::random_hex(4)));
        let team = Team::open(&dir).unwrap();
        assert_eq!(team.cloud_computer_usage("2026-11")["set_up"], false);
        team.save_computer(&CloudComputer { instance: "i-1".into(), region: "eu-north-1".into(), hourly: 0.02, ..Default::default() }).unwrap();
        team.note_state("running");
        team.note_state("running");
        assert_eq!(team.computer().unwrap().sessions.len(), 1, "one wake, one session");
        team.note_state("stopped");
        let c = team.computer().unwrap();
        assert!(c.sessions[0][1] >= c.sessions[0][0] && c.sessions[0][1] > 0);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
