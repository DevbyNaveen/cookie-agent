//! Job links and a PIN: opening your Cookie from a link it sent you.
//!
//! On a runner with a public address, every job link Cookie sends (a mail
//! reply, a chat answer) carries a token minted for that job. Opening it on
//! a phone or another computer asks for your six-digit PIN, set once in
//! Settings. Link + PIN open a session on this runner for 30 days. A
//! forwarded link is useless without the PIN, and the PIN is useless without
//! a link Cookie sent.
//!
//! - Five wrong PINs on one link kill that link.
//! - Three wrong in a row (on any link) lock the PIN for 15 minutes.
//! - Tokens and sessions are kept only as SHA-256 digests; the PIN only as
//!   PBKDF2-HMAC-SHA256 with its own salt, in the Keychain (or the 0600
//!   secrets file).
//!
//! Dark until a PIN is set and the runner has a public address.
//! Ported from the super console (gateway `cookie/access.rs`).

use std::collections::BTreeMap;
use std::num::NonZeroU32;

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{util, Team};

pub const LINK_DAYS: u64 = 30;
pub const SESSION_DAYS: u64 = 30;
const WRONG_PER_LINK: u32 = 5;
const WRONG_IN_A_ROW: u32 = 3;
const LOCK_SECS: u64 = 15 * 60;
const PBKDF2_ROUNDS: u32 = 210_000;
const PIN_KEY: &str = "link-pin";

fn digest(token: &str) -> String {
    Sha256::digest(token.as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
}

fn hash_pin(pin: &str, salt: &[u8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    ring::pbkdf2::derive(ring::pbkdf2::PBKDF2_HMAC_SHA256, NonZeroU32::new(PBKDF2_ROUNDS).unwrap(), salt, pin.as_bytes(), &mut out);
    out
}

fn b64() -> base64::engine::GeneralPurpose {
    base64::engine::general_purpose::STANDARD_NO_PAD
}

pub fn valid_pin(pin: &str) -> bool {
    pin.len() == 6 && pin.bytes().all(|b| b.is_ascii_digit())
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Link {
    pub agent: String,
    pub job: String,
    pub created_at: u64,
    #[serde(default)]
    pub wrong: u32,
    #[serde(default)]
    pub dead: bool,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(default)]
struct LinkBook {
    /// Token digest → the link.
    links: BTreeMap<String, Link>,
    /// Session digest → when it ends.
    sessions: BTreeMap<String, u64>,
    wrong_in_a_row: u32,
    locked_until: u64,
}

impl Team {
    /// The stored PIN hash: in the Keychain, except in tests (which must never
    /// touch the person's real Keychain) where it sits in the test's folder.
    fn pin_stored(&self) -> Option<String> {
        #[cfg(test)]
        return std::fs::read_to_string(self.paths.root.join("test-pin")).ok();
        #[cfg(not(test))]
        self.keys.get(PIN_KEY)
    }

    fn store_pin(&self, v: &str) -> Result<(), String> {
        #[cfg(test)]
        return std::fs::write(self.paths.root.join("test-pin"), v).map_err(|e| e.to_string());
        #[cfg(not(test))]
        self.keys.set(PIN_KEY, v)
    }

    fn links_path(&self) -> std::path::PathBuf {
        self.paths.root.join("links.json")
    }

    fn book(&self) -> LinkBook {
        let mut b: LinkBook = util::read_json(&self.links_path());
        let now = util::now();
        b.sessions.retain(|_, until| *until > now);
        b.links.retain(|_, l| now.saturating_sub(l.created_at) < LINK_DAYS * 86_400);
        b
    }

    fn save_book(&self, b: &LinkBook) -> Result<(), String> {
        util::write_json(&self.links_path(), b)
    }

    pub fn pin_is_set(&self) -> bool {
        self.pin_stored().is_some()
    }

    /// Set (or change) the PIN. Every open session ends: whoever had one asks again.
    pub fn set_link_pin(&self, pin: &str) -> Result<(), String> {
        if !valid_pin(pin) {
            return Err("A PIN is six digits.".into());
        }
        let salt: [u8; 16] = rand_bytes();
        let stored = format!("pbkdf2-sha256${PBKDF2_ROUNDS}${}${}", b64().encode(salt), b64().encode(hash_pin(pin, &salt)));
        self.store_pin(&stored)?;
        let mut b = self.book();
        b.sessions.clear();
        b.wrong_in_a_row = 0;
        b.locked_until = 0;
        self.save_book(&b)
    }

    fn pin_matches(&self, pin: &str) -> bool {
        let Some(stored) = self.pin_stored() else { return false };
        let parts: Vec<&str> = stored.split('$').collect();
        let [_, rounds, salt, want] = parts.as_slice() else { return false };
        let (Ok(salt), Ok(want), Ok(rounds)) = (b64().decode(salt), b64().decode(want), rounds.parse::<u32>()) else { return false };
        let Some(rounds) = NonZeroU32::new(rounds) else { return false };
        ring::pbkdf2::verify(ring::pbkdf2::PBKDF2_HMAC_SHA256, rounds, &salt, pin.as_bytes(), &want).is_ok()
    }

    /// A link to one job, for a message Cookie sends. `None` without a public address or a PIN.
    pub async fn job_link(&self, agent: &str, job: &str) -> Option<String> {
        let base = self.settings().await.server.public_url?;
        if !self.pin_is_set() {
            return None;
        }
        let token = util::random_hex(24);
        let mut b = self.book();
        b.links.insert(digest(&token), Link { agent: agent.into(), job: job.into(), created_at: util::now(), wrong: 0, dead: false });
        self.save_book(&b).ok()?;
        Some(format!("{}/j/{token}", base.trim_end_matches('/')))
    }

    /// Link + PIN → a session token, and the job the link was for.
    pub fn open_link(&self, token: &str, pin: &str) -> Result<(String, Link), String> {
        let mut b = self.book();
        let now = util::now();
        let key = digest(token.trim());
        if b.locked_until > now {
            return Err(format!("Too many wrong PINs. Try again in {} minutes.", (b.locked_until - now).div_ceil(60)));
        }
        let Some(link) = b.links.get(&key).cloned().filter(|l| !l.dead) else {
            return Err("This link has ended. Open Cookie from a newer message.".into());
        };
        if !self.pin_is_set() {
            return Err("No PIN is set for this Cookie yet.".into());
        }
        if !self.pin_matches(pin.trim()) {
            b.wrong_in_a_row += 1;
            let l = b.links.get_mut(&key).expect("present");
            l.wrong += 1;
            let killed = l.wrong >= WRONG_PER_LINK;
            if killed {
                l.dead = true;
            }
            let locked = b.wrong_in_a_row >= WRONG_IN_A_ROW;
            if locked {
                b.locked_until = now + LOCK_SECS;
                b.wrong_in_a_row = 0;
            }
            self.save_book(&b)?;
            return Err(if killed {
                "Wrong PIN. This link no longer works; open Cookie from a newer message.".into()
            } else if locked {
                "Wrong PIN. Locked for 15 minutes.".into()
            } else {
                "Wrong PIN.".into()
            });
        }
        b.wrong_in_a_row = 0;
        let session = util::random_hex(24);
        b.sessions.insert(digest(&session), now + SESSION_DAYS * 86_400);
        self.save_book(&b)?;
        Ok((session, link))
    }

    /// Is this a live session token?
    pub fn session_ok(&self, token: &str) -> bool {
        let want = digest(token);
        self.book().sessions.get(&want).is_some_and(|until| *until > util::now())
    }

    /// End every session opened with a link (the person's "sign out everywhere").
    pub fn end_link_sessions(&self) -> Result<usize, String> {
        let mut b = self.book();
        let n = b.sessions.len();
        b.sessions.clear();
        self.save_book(&b)?;
        Ok(n)
    }

    pub fn links_status(&self) -> serde_json::Value {
        let b = self.book();
        serde_json::json!({"pin_set": self.pin_is_set(), "sessions": b.sessions.len(), "links": b.links.values().filter(|l| !l.dead).count()})
    }
}

fn rand_bytes<const N: usize>() -> [u8; N] {
    let mut out = [0u8; N];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut out).expect("system randomness");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn team() -> (tempfile::TempDir, std::sync::Arc<Team>) {
        let dir = tempfile::tempdir().unwrap();
        let t = Team::open(dir.path()).unwrap();
        (dir, t)
    }

    fn mint(t: &Team, job: &str) -> String {
        let token = util::random_hex(24);
        let mut b = t.book();
        b.links.insert(digest(&token), Link { agent: "a".into(), job: job.into(), created_at: util::now(), wrong: 0, dead: false });
        t.save_book(&b).unwrap();
        token
    }

    #[test]
    fn link_and_pin_open_a_session_and_nothing_else_does() {
        let (_d, t) = team();
        assert!(t.set_link_pin("12a456").is_err());
        t.set_link_pin("123456").unwrap();
        let link = mint(&t, "job-1");
        assert!(t.open_link("not-a-link", "123456").is_err(), "a PIN without a link opens nothing");
        let (session, l) = t.open_link(&link, "123456").unwrap();
        assert_eq!(l.job, "job-1");
        assert!(t.session_ok(&session) && !t.session_ok("guess"));
        t.set_link_pin("654321").unwrap();
        assert!(!t.session_ok(&session), "a new PIN ends every session");
    }

    #[test]
    fn wrong_pins_kill_the_link_and_lock_the_pin() {
        let (_d, t) = team();
        t.set_link_pin("123456").unwrap();
        let link = mint(&t, "job-1");
        for _ in 0..2 {
            assert_eq!(t.open_link(&link, "000000").unwrap_err(), "Wrong PIN.");
        }
        assert!(t.open_link(&link, "000000").unwrap_err().contains("Locked"), "three in a row lock it");
        assert!(t.open_link(&link, "123456").unwrap_err().contains("Too many"), "even the right PIN waits");
        let mut b = t.book();
        b.locked_until = 0;
        t.save_book(&b).unwrap();
        assert!(t.open_link(&link, "000000").is_err());
        assert!(t.open_link(&link, "000000").unwrap_err().contains("no longer works"), "five on one link kill it");
        assert!(t.open_link(&link, "123456").is_err());
    }
}
