//! Accounts, plans and metering for hosted Parallax.
//!
//! Plans (proposed 2026-11-24, untested prices):
//! - **Free**: Parallax on your own Mac; no cloud world-hours.
//! - **Pro**: $20 a month with 100 cloud world-hours; more at $0.10 an hour.
//! - **Pay as you go**: $0.10 a world-hour.
//! - **Team**: $40 a person a month, 100 world-hours each, pooled.
//!
//! A world-hour is an hour a world is awake on a host. Asleep is free: an
//! idle world is files on disk. The meter adds each awake world's minutes to
//! its account (`usage-<yyyymm>.json`); a month's bill is read from it. Usage
//! goes to Stripe's Billing Meter (`/v1/billing/meter_events`, idempotent
//! per account and minute) and plans start through Stripe Checkout; both use
//! `STRIPE_SECRET_KEY` and run only when it is set.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::util;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Plan {
    Free,
    Pro,
    PayAsYouGo,
    Team,
}

impl Plan {
    /// (monthly cents per seat, included world-hours per seat, cents per extra hour)
    pub fn terms(self) -> (u64, u64, u64) {
        match self {
            Plan::Free => (0, 0, 0),
            Plan::Pro => (2_000, 100, 10),
            Plan::PayAsYouGo => (0, 0, 10),
            Plan::Team => (4_000, 100, 10),
        }
    }

    /// May this plan run worlds on hosts at all?
    pub fn cloud(self) -> bool {
        self != Plan::Free
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Account {
    pub id: String,
    pub plan: Plan,
    #[serde(default = "one")]
    pub seats: u64,
    /// SHA-256 of the account's token (the token itself is shown once).
    pub token_sha256: String,
    #[serde(default)]
    pub stripe_customer: Option<String>,
    /// A cap the person set, in world-hours a month (none = no cap).
    #[serde(default)]
    pub cap_hours: Option<u64>,
}

fn one() -> u64 {
    1
}

pub struct Billing {
    pub dir: PathBuf,
}

/// A month as `yyyymm` for epoch seconds.
pub fn month_of(secs: u64) -> String {
    let (_, d) = super::aws::amz_dates(secs);
    d[..6].to_string()
}

/// What a month costs on a plan, in cents, for `seconds` awake.
pub fn bill(plan: Plan, seats: u64, seconds: u64) -> Value {
    let (base, included, extra) = plan.terms();
    let hours = seconds as f64 / 3_600.0;
    let included_hours = (included * seats) as f64;
    let over = (hours - included_hours).max(0.0);
    let over_cents = (over * extra as f64).ceil() as u64;
    json!({"plan": plan, "seats": seats, "hours": (hours * 100.0).round() / 100.0, "included_hours": included_hours, "extra_hours": (over * 100.0).round() / 100.0, "base_cents": base * seats, "extra_cents": over_cents, "total_cents": base * seats + over_cents})
}

impl Billing {
    pub fn new(home: &Path) -> Self {
        Self { dir: home.join("billing") }
    }

    fn accounts(&self) -> Vec<Account> {
        util::read_json(&self.dir.join("accounts.json"))
    }

    /// Make an account; its token is returned once and only its hash is kept.
    pub fn create(&self, id: &str, plan: Plan) -> Result<(Account, String), String> {
        if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
            return Err("An account id is letters, digits and -.".into());
        }
        let mut all = self.accounts();
        if all.iter().any(|a| a.id == id) {
            return Err("That account exists.".into());
        }
        let token = format!("px_{}", util::random_hex(24));
        let a = Account { id: id.into(), plan, seats: 1, token_sha256: util::sha256_hex(token.as_bytes()), stripe_customer: None, cap_hours: None };
        all.push(a.clone());
        util::write_json(&self.dir.join("accounts.json"), &all)?;
        Ok((a, token))
    }

    /// The account a bearer token belongs to.
    pub fn account_for(&self, token: &str) -> Option<Account> {
        let h = util::sha256_hex(token.trim().as_bytes());
        self.accounts().into_iter().find(|a| a.token_sha256 == h)
    }

    fn usage_path(&self, month: &str) -> PathBuf {
        self.dir.join(format!("usage-{month}.json"))
    }

    /// Add awake seconds for an account (the meter calls this every minute per awake world).
    pub fn add(&self, account: &str, world: &str, seconds: u64) -> Result<(), String> {
        let month = month_of(util::now());
        let p = self.usage_path(&month);
        let mut u: BTreeMap<String, BTreeMap<String, u64>> = util::read_json(&p);
        *u.entry(account.into()).or_default().entry(world.into()).or_default() += seconds;
        util::write_json(&p, &u)
    }

    pub fn seconds(&self, account: &str, month: &str) -> u64 {
        let u: BTreeMap<String, BTreeMap<String, u64>> = util::read_json(&self.usage_path(month));
        u.get(account).map(|w| w.values().sum()).unwrap_or(0)
    }

    /// May this account wake another world now? (Its plan, and its own cap.)
    pub fn may_run(&self, account: &Account) -> Result<(), String> {
        if !account.plan.cloud() {
            return Err("The Free plan runs Parallax on your own Mac. Choose Pro or Pay as you go for cloud worlds.".into());
        }
        if let Some(cap) = account.cap_hours {
            if self.seconds(&account.id, &month_of(util::now())) >= cap * 3_600 {
                return Err(format!("This month's cap of {cap} world-hours is reached."));
            }
        }
        Ok(())
    }

    pub fn statement(&self, account: &Account, month: &str) -> Value {
        bill(account.plan, account.seats, self.seconds(&account.id, month))
    }
}

fn stripe_key() -> Result<String, String> {
    std::env::var("STRIPE_SECRET_KEY").ok().filter(|k| k.starts_with("sk_")).ok_or_else(|| "STRIPE_SECRET_KEY isn't set.".into())
}

async fn stripe_post(path: &str, form: &[(&str, String)], idempotency: Option<&str>) -> Result<Value, String> {
    let mut req = reqwest::Client::new().post(format!("https://api.stripe.com{path}")).bearer_auth(stripe_key()?).form(form).timeout(std::time::Duration::from_secs(30));
    if let Some(k) = idempotency {
        req = req.header("Idempotency-Key", k);
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status();
    let v: Value = resp.json().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(v.pointer("/error/message").and_then(Value::as_str).unwrap_or("Stripe refused.").to_string());
    }
    Ok(v)
}

/// Report a minute's world-seconds to Stripe's meter for a customer.
pub async fn report_usage(meter_event: &str, customer: &str, seconds: u64, minute: u64) -> Result<(), String> {
    let id = format!("{customer}-{minute}");
    stripe_post("/v1/billing/meter_events", &[("event_name", meter_event.into()), ("payload[stripe_customer_id]", customer.into()), ("payload[value]", seconds.to_string()), ("timestamp", minute.to_string()), ("identifier", id.clone())], Some(&id)).await.map(|_| ())
}

/// A Stripe Checkout page for a plan's price: its URL.
pub async fn checkout(price: &str, customer: Option<&str>, success: &str, cancel: &str) -> Result<String, String> {
    let mut form = vec![("mode", "subscription".to_string()), ("line_items[0][price]", price.into()), ("line_items[0][quantity]", "1".into()), ("success_url", success.into()), ("cancel_url", cancel.into())];
    if let Some(c) = customer {
        form.push(("customer", c.into()));
    }
    let v = stripe_post("/v1/checkout/sessions", &form, None).await?;
    v["url"].as_str().map(str::to_string).ok_or_else(|| "Stripe sent no checkout address.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_month_costs_what_the_plan_says() {
        let pro = bill(Plan::Pro, 1, 120 * 3_600);
        assert_eq!((pro["base_cents"].as_u64(), pro["extra_cents"].as_u64(), pro["total_cents"].as_u64()), (Some(2_000), Some(200), Some(2_200)));
        assert_eq!(bill(Plan::Pro, 1, 50 * 3_600)["total_cents"], 2_000, "within the hours");
        assert_eq!(bill(Plan::PayAsYouGo, 1, 3 * 3_600 + 60)["total_cents"], 31, "billed up to the cent");
        assert_eq!(bill(Plan::Team, 3, 250 * 3_600)["total_cents"], 12_000, "pooled hours");
    }

    #[test]
    fn tokens_are_kept_as_hashes_and_free_stays_home() {
        let d = tempfile::tempdir().unwrap();
        let b = Billing::new(d.path());
        let (a, token) = b.create("acme", Plan::Free).unwrap();
        assert!(!std::fs::read_to_string(d.path().join("billing/accounts.json")).unwrap().contains(&token));
        assert_eq!(b.account_for(&token).unwrap().id, "acme");
        assert!(b.may_run(&a).is_err());
        let (mut p, _) = b.create("bo", Plan::Pro).unwrap();
        p.cap_hours = Some(1);
        b.add("bo", "w1", 3_600).unwrap();
        assert!(b.may_run(&p).unwrap_err().contains("cap"));
    }
}
