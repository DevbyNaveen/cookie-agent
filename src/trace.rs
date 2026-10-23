//! A run's actions as a log no one can quietly change: each record (a tool
//! call asked for, what was decided about it, its result, a model fallback,
//! the answer) is hashed with the hash of the one before and signed. Records
//! hold digests and names, never content: the log proves what happened
//! without keeping what was said.
//!
//! Opening a log never reads it back. A new log starts from nothing; one that
//! goes on is given the head its caller stored when the last run ended
//! (`Head`, on serve's last line), so whoever holds the head can tell a log
//! that was cut short or rewritten from end to end, which a chain alone
//! cannot. `verify` checks a file against a trusted key.

use std::{
    fs::{File, OpenOptions},
    io::Write,
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

use ring::signature::{Ed25519KeyPair, KeyPair, UnparsedPublicKey, ED25519};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::error::{Error, Result};

/// The `prev` of the first record.
pub const GENESIS: [u8; 32] = [0; 32];

/// Bound into every hash, so a record from another kind of log never verifies here.
const DOMAIN: &[u8] = b"cookie-trace/1\0";

/// Where a log ends: the last record's hash and how many records it holds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Head {
    pub hash: String,
    pub count: u64,
}

/// One line of the log.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    pub seq: u64,
    /// Milliseconds since the Unix epoch.
    pub at: u64,
    pub run: String,
    /// `call`, `decision`, `result`, `fallback`, `answer` or `ended`.
    pub kind: String,
    /// Names, ids, verdicts and `sha256:` digests.
    pub fields: Value,
    pub prev: String,
    pub hash: String,
    /// The signer's public key, so a log signed across a key change still says by whom.
    pub key: String,
    pub sig: String,
}

impl Record {
    /// The bytes hashed: each part length-prefixed, so no two records share them.
    fn canonical(&self, prev: &[u8; 32]) -> Vec<u8> {
        let mut out = DOMAIN.to_vec();
        out.extend(self.seq.to_be_bytes());
        out.extend(self.at.to_be_bytes());
        for part in [self.run.as_bytes(), self.kind.as_bytes(), self.fields.to_string().as_bytes()] {
            out.extend((part.len() as u64).to_be_bytes());
            out.extend(part);
        }
        out.extend(prev);
        out
    }
}

/// `sha256:<hex>` of some bytes: what a record holds in place of content.
pub fn digest(bytes: impl AsRef<[u8]>) -> String {
    format!("sha256:{:x}", Sha256::digest(bytes.as_ref()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Lowercase only: an uppercase letter decodes to the same byte, so allowing
/// it would let a stored hash or signature change without the bytes changing.
fn unhex<const N: usize>(s: &str) -> Option<[u8; N]> {
    let digit = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    };
    let s = s.as_bytes();
    if s.len() != N * 2 {
        return None;
    }
    let mut out = [0u8; N];
    for (i, pair) in s.chunks(2).enumerate() {
        out[i] = digit(pair[0])? << 4 | digit(pair[1])?;
    }
    Some(out)
}

/// A signing key: a 32-byte Ed25519 seed, kept as 64 hex characters.
pub struct SigningKey(Ed25519KeyPair);

impl SigningKey {
    pub fn from_hex(seed: &str) -> Result<Self> {
        let seed = unhex::<32>(seed.trim()).ok_or_else(|| Error::Session("trace key: not 64 lowercase hex characters".into()))?;
        Ed25519KeyPair::from_seed_unchecked(&seed).map(Self).map_err(|e| Error::Session(format!("trace key: {e}")))
    }

    pub fn from_file(path: impl AsRef<Path>) -> Result<Self> {
        Self::from_hex(&std::fs::read_to_string(path.as_ref())?)
    }

    /// The key in `path`, made there once (readable by its owner only) when
    /// there is none yet.
    pub fn load_or_create(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let mut seed = [0u8; 32];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut seed)
            .map_err(|_| Error::Session("trace key: no randomness".into()))?;
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        match options.open(path) {
            Ok(mut file) => {
                file.write_all(format!("{}\n", hex(&seed)).as_bytes())?;
                file.sync_all()?;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e.into()),
        }
        Self::from_file(path)
    }

    /// The public key, as `cookie trace verify --key` takes it.
    pub fn public(&self) -> String {
        hex(self.0.public_key().as_ref())
    }
}

/// An open log, its head kept in memory.
pub struct TraceLog {
    file: File,
    key: SigningKey,
    public: String,
    head: [u8; 32],
    count: u64,
}

impl TraceLog {
    /// Open `path` to append. `after` is the head the caller stored for it;
    /// without one the file must be new or empty, so a log is never continued
    /// from a tail nobody vouched for.
    pub fn open(path: impl AsRef<Path>, key: SigningKey, after: Option<&Head>) -> Result<Self> {
        let path = path.as_ref();
        let file = OpenOptions::new().create(true).append(true).open(path)?;
        let has_records = file.metadata()?.len() > 0;
        let (head, count) = match (after, has_records) {
            (None, false) => (GENESIS, 0),
            (Some(head), true) => {
                let hash = unhex::<32>(&head.hash).ok_or_else(|| Error::Session("trace: the head is not a hash".into()))?;
                (hash, head.count)
            }
            (None, true) => return Err(Error::Session(format!("trace: {} already has records; send the head stored for it", path.display()))),
            (Some(_), false) => return Err(Error::Session(format!("trace: {} is empty but a head was sent for it", path.display()))),
        };
        let public = key.public();
        Ok(Self { file, key, public, head, count })
    }

    pub fn head(&self) -> Head {
        Head { hash: hex(&self.head), count: self.count }
    }

    pub fn public_key(&self) -> &str {
        &self.public
    }

    /// Hash, sign and write one record. A record that could not be written
    /// fails the caller: a log that silently skips is worse than none.
    pub fn append(&mut self, run: &str, kind: &str, fields: Value) -> Result<()> {
        let at = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
        let mut record = Record {
            seq: self.count,
            at,
            run: run.to_string(),
            kind: kind.to_string(),
            fields,
            prev: hex(&self.head),
            hash: String::new(),
            key: self.public.clone(),
            sig: String::new(),
        };
        let hash: [u8; 32] = Sha256::digest(record.canonical(&self.head)).into();
        record.hash = hex(&hash);
        record.sig = hex(self.key.0.sign(&hash).as_ref());
        let mut line = serde_json::to_string(&record)?;
        line.push('\n');
        self.file.write_all(line.as_bytes()).map_err(|e| Error::Session(format!("trace: {e}")))?;
        self.head = hash;
        self.count += 1;
        Ok(())
    }
}

/// A run's log and the run's name in it, shared by the agents of one run
/// (a handoff goes on in the same log).
#[derive(Clone)]
pub struct Tracer {
    log: std::sync::Arc<std::sync::Mutex<TraceLog>>,
    run: String,
}

impl Tracer {
    pub fn new(log: std::sync::Arc<std::sync::Mutex<TraceLog>>, run: impl Into<String>) -> Self {
        Self { log, run: run.into() }
    }

    // ponytail: a plain write under a lock, a few hundred bytes per record, from
    // the run's own task; a writer task if a slow disk ever shows in the run.
    pub fn record(&self, kind: &str, fields: Value) -> Result<()> {
        self.log.lock().expect("trace lock").append(&self.run, kind, fields)
    }

    pub fn head(&self) -> Head {
        self.log.lock().expect("trace lock").head()
    }

    /// Where the log ends and who signed it, as a caller stores it.
    pub fn anchor(&self) -> Value {
        let log = self.log.lock().expect("trace lock");
        let head = log.head();
        serde_json::json!({"head": head.hash, "count": head.count, "key": log.public_key()})
    }
}

/// What makes a log fail to verify, with the record (`seq`, from 0) where.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Broken {
    #[error("record {0} is not a record")]
    Malformed(u64),
    #[error("record {seq} is numbered {found}: records are missing or out of order")]
    Gap { seq: u64, found: u64 },
    #[error("record {0} does not follow the one before it")]
    Link(u64),
    #[error("record {0} was changed after it was written")]
    Hash(u64),
    #[error("record {0} was signed by a key that is not trusted")]
    Untrusted(u64),
    #[error("record {0} has a signature that does not match")]
    Signature(u64),
    #[error("the log ends at {found:?}, not at the head that was stored ({expected:?})")]
    Head { expected: Head, found: Head },
}

/// Check every record of `text` against `trusted` (64 hex characters), and,
/// when given, that the log ends exactly at `head`. Returns where it ends.
pub fn verify_text(text: &str, trusted: &str, head: Option<&Head>) -> std::result::Result<Head, Broken> {
    let trusted_key = unhex::<32>(trusted).ok_or(Broken::Untrusted(0))?;
    let verifier = UnparsedPublicKey::new(&ED25519, trusted_key);
    let mut prev = GENESIS;
    let mut seq = 0u64;
    for line in text.lines().filter(|l| !l.trim().is_empty()) {
        let record: Record = serde_json::from_str(line).map_err(|_| Broken::Malformed(seq))?;
        if record.seq != seq {
            return Err(Broken::Gap { seq, found: record.seq });
        }
        if unhex::<32>(&record.prev) != Some(prev) {
            return Err(Broken::Link(seq));
        }
        let hash: [u8; 32] = Sha256::digest(record.canonical(&prev)).into();
        if unhex::<32>(&record.hash) != Some(hash) {
            return Err(Broken::Hash(seq));
        }
        if unhex::<32>(&record.key) != Some(trusted_key) {
            return Err(Broken::Untrusted(seq));
        }
        let sig = unhex::<64>(&record.sig).ok_or(Broken::Signature(seq))?;
        verifier.verify(&hash, &sig).map_err(|_| Broken::Signature(seq))?;
        prev = hash;
        seq += 1;
    }
    let found = Head { hash: hex(&prev), count: seq };
    match head {
        Some(expected) if *expected != found => Err(Broken::Head { expected: expected.clone(), found }),
        _ => Ok(found),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn key() -> SigningKey {
        SigningKey::from_hex(&"07".repeat(32)).unwrap()
    }

    /// A log of `n` records and its file's text.
    fn log(n: u64) -> (tempfile::TempDir, String, Head, String) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t.jsonl");
        let mut log = TraceLog::open(&path, key(), None).unwrap();
        for i in 0..n {
            log.append("r1", "call", json!({"id": format!("c{i}"), "tool": "weather", "args": digest("{}")})).unwrap();
        }
        let public = log.public_key().to_string();
        (dir, std::fs::read_to_string(&path).unwrap(), log.head(), public)
    }

    fn lines(text: &str) -> Vec<Value> {
        text.lines().map(|l| serde_json::from_str(l).unwrap()).collect()
    }

    fn text_of(records: &[Value]) -> String {
        records.iter().map(|r| format!("{r}\n")).collect()
    }

    #[test]
    fn a_log_verifies_and_ends_at_the_head_it_reported() {
        let (_dir, text, head, public) = log(5);
        assert_eq!(head.count, 5);
        assert_eq!(verify_text(&text, &public, Some(&head)), Ok(head.clone()));
        assert!(!text.contains("weather\",\"args\":\"{}"), "content is never kept, only its digest");
    }

    #[test]
    fn each_kind_of_tampering_is_found_where_it_is() {
        let (_dir, text, head, public) = log(4);
        let records = lines(&text);

        let mut changed = records.clone();
        changed[2]["fields"]["tool"] = json!("send_email");
        assert_eq!(verify_text(&text_of(&changed), &public, None), Err(Broken::Hash(2)));

        let mut gap = records.clone();
        gap.remove(1);
        assert_eq!(verify_text(&text_of(&gap), &public, None), Err(Broken::Gap { seq: 1, found: 2 }));

        let mut swapped = records.clone();
        swapped.swap(1, 2);
        assert!(matches!(verify_text(&text_of(&swapped), &public, None), Err(Broken::Gap { seq: 1, .. })));

        // Renumbered after a removal: the numbers line up, the chain does not.
        let mut relinked = records.clone();
        relinked.remove(1);
        for (i, r) in relinked.iter_mut().enumerate() {
            r["seq"] = json!(i);
        }
        assert_eq!(verify_text(&text_of(&relinked), &public, None), Err(Broken::Link(1)));

        // A record rehashed after it was changed still needs the signature.
        let mut rehashed = records.clone();
        rehashed[3]["fields"]["tool"] = json!("send_email");
        let r: Record = serde_json::from_value(rehashed[3].clone()).unwrap();
        let prev = unhex::<32>(&r.prev).unwrap();
        rehashed[3]["hash"] = json!(format!("{:x}", Sha256::digest(r.canonical(&prev))));
        assert_eq!(verify_text(&text_of(&rehashed), &public, None), Err(Broken::Signature(3)));

        let mut upper = records.clone();
        upper[0]["hash"] = json!(records[0]["hash"].as_str().unwrap().to_uppercase());
        assert!(verify_text(&text_of(&upper), &public, None).is_err(), "an uppercase hash is not the same hash");

        let other = SigningKey::from_hex(&"09".repeat(32)).unwrap().public();
        assert_eq!(verify_text(&text, &other, None), Err(Broken::Untrusted(0)));

        // Cut short: every remaining record verifies; only the stored head shows it.
        let short = text_of(&records[..3]);
        assert!(verify_text(&short, &public, None).is_ok());
        assert!(matches!(verify_text(&short, &public, Some(&head)), Err(Broken::Head { .. })));

        let mut garbage = text.clone();
        garbage.push_str("not json\n");
        assert_eq!(verify_text(&garbage, &public, None), Err(Broken::Malformed(4)));
    }

    #[test]
    fn every_single_byte_change_is_found() {
        let (_dir, text, head, public) = log(3);
        let bytes = text.as_bytes();
        for i in 0..bytes.len() {
            if bytes[i] == b'\n' {
                continue;
            }
            for flip in [0x01u8, 0x20, 0x80] {
                let mut changed = bytes.to_vec();
                changed[i] ^= flip;
                let Ok(changed) = String::from_utf8(changed) else { continue };
                assert!(verify_text(&changed, &public, Some(&head)).is_err(), "byte {i} ^ {flip:#x} went unnoticed");
            }
        }
    }

    #[test]
    fn a_log_goes_on_only_from_the_head_its_caller_stored() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t.jsonl");
        let mut first = TraceLog::open(&path, key(), None).unwrap();
        first.append("r1", "answer", json!({"answer": digest("hi")})).unwrap();
        let head = first.head();
        drop(first);
        assert!(TraceLog::open(&path, key(), None).is_err(), "a log with records needs its head");
        let mut next = TraceLog::open(&path, key(), Some(&head)).unwrap();
        next.append("r2", "answer", json!({"answer": digest("again")})).unwrap();
        let text = std::fs::read_to_string(&path).unwrap();
        assert_eq!(verify_text(&text, &key().public(), Some(&next.head())).unwrap().count, 2);
        assert!(TraceLog::open(dir.path().join("new.jsonl"), key(), Some(&head)).is_err(), "a head for an empty log is refused");
    }

    #[cfg(unix)]
    #[test]
    fn a_made_key_is_kept_once_readable_by_its_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("trace.key");
        let made = SigningKey::load_or_create(&path).unwrap().public();
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(SigningKey::load_or_create(&path).unwrap().public(), made, "made once, then read");
        assert!(SigningKey::from_hex("ZZ").is_err());
    }
}
