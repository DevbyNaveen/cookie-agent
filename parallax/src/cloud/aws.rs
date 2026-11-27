//! AWS hosts that start and stop with the work.
//!
//! With no users nothing runs: the hosts (EC2 instances, e.g. m7i-flex, which
//! run Firecracker without bare metal) are stopped, and only their disks cost.
//! A job arriving for a stopped pool starts one (`ensure_up`) and waits until
//! it runs; a pool with no awake worlds for `idle_stop_secs` is stopped again
//! (`maybe_stop`). Sleeping worlds are files: on a host's disk, or in S3.
//!
//! Requests are signed with AWS Signature Version 4 (checked against AWS's
//! own published test vector) and sent to the EC2 Query API; credentials come
//! from the environment (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
//! optionally `AWS_SESSION_TOKEN`), the region from `AWS_REGION`.

use std::time::Duration;

use ring::hmac;

use crate::util;

#[derive(Clone)]
pub struct Creds {
    pub key: String,
    pub secret: String,
    pub token: Option<String>,
    pub region: String,
}

impl Creds {
    pub fn from_env() -> Result<Creds, String> {
        let v = |k: &str| std::env::var(k).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        Ok(Creds {
            key: v("AWS_ACCESS_KEY_ID").ok_or("AWS_ACCESS_KEY_ID isn't set.")?,
            secret: v("AWS_SECRET_ACCESS_KEY").ok_or("AWS_SECRET_ACCESS_KEY isn't set.")?,
            token: v("AWS_SESSION_TOKEN"),
            region: v("AWS_REGION").or_else(|| v("AWS_DEFAULT_REGION")).ok_or("AWS_REGION isn't set.")?,
        })
    }
}

impl Creds {
    /// The credentials of the role this EC2 machine runs as, from its metadata service
    /// (IMDSv2: a session token first, so a request forged through the machine can't
    /// read them). Short-lived; the caller asks again as they near expiry.
    pub async fn from_instance_role(region: &str) -> Result<(Creds, u64), String> {
        let http = reqwest::Client::builder().timeout(Duration::from_secs(3)).build().map_err(|e| e.to_string())?;
        let base = "http://169.254.169.254/latest";
        let token = http.put(format!("{base}/api/token")).header("X-aws-ec2-metadata-token-ttl-seconds", "300").send().await.map_err(|e| format!("no instance metadata: {e}"))?.text().await.map_err(|e| e.to_string())?;
        let get = |path: String| {
            let (http, token) = (http.clone(), token.clone());
            async move { http.get(format!("{base}/{path}")).header("X-aws-ec2-metadata-token", token).send().await.map_err(|e| e.to_string())?.error_for_status().map_err(|e| e.to_string())?.text().await.map_err(|e| e.to_string()) }
        };
        let role = get("meta-data/iam/security-credentials/".into()).await?.lines().next().unwrap_or("").trim().to_string();
        if role.is_empty() {
            return Err("This machine has no role.".into());
        }
        let v: serde_json::Value = serde_json::from_str(&get(format!("meta-data/iam/security-credentials/{role}")).await?).map_err(|e| e.to_string())?;
        let field = |k: &str| v[k].as_str().map(str::to_string).ok_or_else(|| format!("The role's credentials have no {k}."));
        let expires = chrono_free_expiry(v["Expiration"].as_str().unwrap_or(""));
        Ok((Creds { key: field("AccessKeyId")?, secret: field("SecretAccessKey")?, token: Some(field("Token")?), region: region.to_string() }, expires))
    }
}

/// `2026-11-28T12:34:56Z` as epoch seconds; now + 10 minutes when it can't be read.
fn chrono_free_expiry(s: &str) -> u64 {
    let n = |a: usize, b: usize| s.get(a..b).and_then(|x| x.parse::<i64>().ok());
    let fallback = util::now() + 600;
    let (Some(y), Some(mo), Some(d), Some(h), Some(mi), Some(se)) = (n(0, 4), n(5, 7), n(8, 10), n(11, 13), n(14, 16), n(17, 19)) else { return fallback };
    // Days from civil (Howard Hinnant).
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let doy = (153 * (if mo > 2 { mo - 3 } else { mo + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let t = days * 86_400 + h * 3600 + mi * 60 + se;
    if t > 0 { t as u64 } else { fallback }
}

fn hmac_sha256(key: &[u8], data: &str) -> Vec<u8> {
    hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, key), data.as_bytes()).as_ref().to_vec()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// RFC 3986 encoding, as SigV4 wants it.
pub fn uri_encode(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

/// `20150830T123600Z` and `20150830` for epoch seconds (UTC).
pub fn amz_dates(secs: u64) -> (String, String) {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Civil from days (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    let date = format!("{y:04}{m:02}{d:02}");
    (format!("{date}T{:02}{:02}{:02}Z", rem / 3600, (rem / 60) % 60, rem % 60), date)
}

/// SigV4 for a GET with a query: the Authorization header's value.
pub fn sign_get(c: &Creds, service: &str, host: &str, path: &str, query: &[(String, String)], amz_date: &str, date: &str) -> String {
    let mut q: Vec<(String, String)> = query.iter().map(|(k, v)| (uri_encode(k), uri_encode(v))).collect();
    q.sort();
    let canonical_query = q.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("&");
    let mut headers = vec![("host".to_string(), host.to_string()), ("x-amz-date".to_string(), amz_date.to_string())];
    if let Some(t) = &c.token {
        headers.push(("x-amz-security-token".into(), t.clone()));
    }
    headers.sort();
    let canonical_headers: String = headers.iter().map(|(k, v)| format!("{k}:{}\n", v.trim())).collect();
    let signed: String = headers.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>().join(";");
    let payload = util::sha256_hex(b"");
    let canonical = format!("GET\n{path}\n{canonical_query}\n{canonical_headers}\n{signed}\n{payload}");
    let scope = format!("{date}/{}/{service}/aws4_request", c.region);
    let to_sign = format!("AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{}", util::sha256_hex(canonical.as_bytes()));
    let k = hmac_sha256(format!("AWS4{}", c.secret).as_bytes(), date);
    let k = hmac_sha256(&k, &c.region);
    let k = hmac_sha256(&k, service);
    let k = hmac_sha256(&k, "aws4_request");
    let sig = hex(&hmac_sha256(&k, &to_sign));
    format!("AWS4-HMAC-SHA256 Credential={}/{scope}, SignedHeaders={signed}, Signature={sig}", c.key)
}

/// One EC2 Query API call; the XML answer.
pub async fn ec2(c: &Creds, action: &str, params: &[(String, String)]) -> Result<String, String> {
    let host = format!("ec2.{}.amazonaws.com", c.region);
    let mut q = vec![("Action".to_string(), action.to_string()), ("Version".to_string(), "2016-11-15".to_string())];
    q.extend_from_slice(params);
    let (amz, date) = amz_dates(util::now());
    let auth = sign_get(c, "ec2", &host, "/", &q, &amz, &date);
    let query = q.iter().map(|(k, v)| format!("{}={}", uri_encode(k), uri_encode(v))).collect::<Vec<_>>().join("&");
    let mut req = reqwest::Client::new().get(format!("https://{host}/?{query}")).header("x-amz-date", &amz).header("Authorization", auth).timeout(Duration::from_secs(30));
    if let Some(t) = &c.token {
        req = req.header("x-amz-security-token", t);
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status();
    let body = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        let msg = between(&body, "<Message>", "</Message>").unwrap_or(&body);
        return Err(format!("EC2 {action}: {msg}"));
    }
    Ok(body)
}

fn between<'a>(s: &'a str, a: &str, b: &str) -> Option<&'a str> {
    let i = s.find(a)? + a.len();
    let j = s[i..].find(b)? + i;
    Some(&s[i..j])
}

/// The state of an instance: pending · running · stopping · stopped · …
pub async fn state(c: &Creds, instance: &str) -> Result<String, String> {
    let xml = ec2(c, "DescribeInstances", &[("InstanceId.1".into(), instance.into())]).await?;
    let st = between(&xml, "<instanceState>", "</instanceState>").ok_or("EC2 didn't say the instance's state.")?;
    Ok(between(st, "<name>", "</name>").unwrap_or("unknown").to_string())
}

/// A pool of hosts that runs only while there is work.
pub struct Pool {
    pub instances: Vec<String>,
    pub idle_stop_secs: u64,
}

impl Pool {
    /// Make sure one host runs: start the first stopped one and wait (up to 3 minutes).
    pub async fn ensure_up(&self, c: &Creds) -> Result<String, String> {
        for i in &self.instances {
            if state(c, i).await? == "running" {
                return Ok(i.clone());
            }
        }
        let first = self.instances.first().ok_or("The pool has no hosts.")?;
        ec2(c, "StartInstances", &[("InstanceId.1".into(), first.clone())]).await?;
        for _ in 0..36 {
            tokio::time::sleep(Duration::from_secs(5)).await;
            if state(c, first).await? == "running" {
                return Ok(first.clone());
            }
        }
        Err(format!("{first} didn't reach running in three minutes."))
    }

    /// Stop the running hosts when nothing has worked for a while.
    pub async fn maybe_stop(&self, c: &Creds, last_work_at: u64) -> Result<Vec<String>, String> {
        if util::now().saturating_sub(last_work_at) < self.idle_stop_secs {
            return Ok(Vec::new());
        }
        let mut stopped = Vec::new();
        for i in &self.instances {
            if state(c, i).await? == "running" {
                ec2(c, "StopInstances", &[("InstanceId.1".into(), i.clone())]).await?;
                stopped.push(i.clone());
            }
        }
        Ok(stopped)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_role_credentials_expiry_reads_as_epoch_seconds() {
        assert_eq!(chrono_free_expiry("2026-11-27T00:00:00Z"), 1_795_737_600);
        assert_eq!(chrono_free_expiry("2026-11-27T08:30:15Z"), 1_795_737_600 + 8 * 3600 + 30 * 60 + 15);
        assert!(chrono_free_expiry("garbage") > util::now());
    }

    /// AWS's SigV4 test suite, "get-vanilla": a GET of / on example.amazonaws.com.
    #[test]
    fn signs_like_aws_says() {
        let c = Creds { key: "AKIDEXAMPLE".into(), secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY".into(), token: None, region: "us-east-1".into() };
        let auth = sign_get(&c, "service", "example.amazonaws.com", "/", &[], "20150830T123600Z", "20150830");
        assert_eq!(auth, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31");
    }

    #[test]
    fn dates_are_utc_calendar_dates() {
        assert_eq!(amz_dates(1_440_938_160), ("20150830T123600Z".to_string(), "20150830".to_string()));
        assert_eq!(amz_dates(951_782_400).1, "20000229", "a leap day");
        assert_eq!(uri_encode("a b/c~"), "a%20b%2Fc~");
    }
}
