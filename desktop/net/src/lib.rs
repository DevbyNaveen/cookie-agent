//! The Cookie Network wire format, shared by the relay and every Cookie.
//!
//! - **Addresses.** A person is `@handle`; each of their agents is
//!   `@handle/agent`. The handle is a label: identity is the Ed25519 key that
//!   signed the person's profile, so contacts survive a change of relay.
//! - **Profiles.** A person publishes one signed [`Profile`]: their keys and a
//!   card per agent. The relay stores it only if the signature holds and the
//!   handle is free or already theirs.
//! - **Messages.** Every message is an [`Inner`] (who, to whom, what kind,
//!   signed by the sender) sealed to the recipient's X25519 key: an ephemeral
//!   X25519 agreement, HKDF-SHA256, and AES-256-GCM. The relay carries
//!   [`Sealed`] bytes it cannot read. The same construction runs in a browser
//!   with WebCrypto, which is how guests without Cookie chat on a card page.

use base64::Engine as _;
use curve25519_dalek::montgomery::MontgomeryPoint;
use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM};
use ring::hkdf::{Salt, HKDF_SHA256};
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{Ed25519KeyPair, KeyPair, UnparsedPublicKey, ED25519};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTO: &str = "cookie-net/1";
/// Largest sealed message a relay accepts.
pub const MAX_SEALED: usize = 64 * 1024;
/// How far a signed request's clock may drift from the relay's.
pub const CLOCK_SKEW: u64 = 300;

/* ---------- bytes ---------- */

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 || !s.is_ascii() {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect()
}

fn unhex32(s: &str) -> Option<[u8; 32]> {
    unhex(s)?.try_into().ok()
}

pub fn random<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    SystemRandom::new().fill(&mut b).expect("the system random source failed");
    b
}

pub fn sha256_hex(b: &[u8]) -> String {
    hex(ring::digest::digest(&ring::digest::SHA256, b).as_ref())
}

/// The bytes a signature covers: compact JSON with object keys sorted. A
/// browser reproduces it with `JSON.stringify` over the same sorted value,
/// so signed payloads carry integers, never floats.
pub fn canonical(v: &Value) -> Vec<u8> {
    fn sorted(v: &Value) -> Value {
        match v {
            Value::Object(m) => {
                let mut keys: Vec<&String> = m.keys().collect();
                keys.sort();
                Value::Object(keys.into_iter().map(|k| (k.clone(), sorted(&m[k]))).collect())
            }
            Value::Array(a) => Value::Array(a.iter().map(sorted).collect()),
            other => other.clone(),
        }
    }
    sorted(v).to_string().into_bytes()
}

/* ---------- addresses ---------- */

/// `naveen` in `@naveen/invoices`: 3 to 24 of a-z, 0-9 and `-`, starting with a letter or digit.
pub fn valid_handle(h: &str) -> bool {
    (3..=24).contains(&h.len())
        && h.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        && !h.starts_with('-')
        && !matches!(h, "v1" | "api" | "face" | "about" | "admin" | "relay" | "cookie" | "directory" | "guest" | "static")
}

/// `invoices` in `@naveen/invoices`: 1 to 40 of a-z, 0-9 and `-`.
pub fn valid_slug(s: &str) -> bool {
    (1..=40).contains(&s.len()) && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') && !s.starts_with('-')
}

/// An agent's name as an address part: "Invoice Chaser" → `invoice-chaser`.
pub fn slugify(name: &str) -> String {
    let mut s = String::new();
    for c in name.trim().to_lowercase().chars() {
        if c.is_ascii_alphanumeric() {
            s.push(c);
        } else if !s.ends_with('-') && !s.is_empty() {
            s.push('-');
        }
    }
    let s: String = s.trim_end_matches('-').chars().take(40).collect();
    if s.is_empty() { "agent".into() } else { s.trim_end_matches('-').to_string() }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Address {
    pub handle: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
}

impl Address {
    /// `@naveen`, `@naveen/invoices`, `naveen/invoices`, or a card link
    /// `https://relay.example/naveen/invoices`.
    pub fn parse(s: &str) -> Option<Address> {
        let s = s.trim().trim_end_matches('/');
        let path = match s.split_once("://") {
            Some((_, rest)) => rest.split_once('/').map(|(_, p)| p)?,
            None => s.trim_start_matches('@'),
        };
        let path = path.split(['?', '#']).next()?;
        let mut parts = path.split('/');
        let handle = parts.next()?.trim_start_matches('@').to_lowercase();
        let agent = parts.next().map(str::to_lowercase).filter(|a| !a.is_empty());
        if parts.next().is_some() || !valid_handle(&handle) || agent.as_deref().is_some_and(|a| !valid_slug(a)) {
            return None;
        }
        Some(Address { handle, agent })
    }
}

impl std::fmt::Display for Address {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.agent {
            Some(a) => write!(f, "@{}/{a}", self.handle),
            None => write!(f, "@{}", self.handle),
        }
    }
}

/* ---------- keys ---------- */

/// The signing key: who you are on the network.
pub struct SignKey(Ed25519KeyPair);

impl SignKey {
    pub fn from_seed(seed: &[u8; 32]) -> Result<Self, String> {
        Ed25519KeyPair::from_seed_unchecked(seed).map(SignKey).map_err(|e| e.to_string())
    }
    pub fn public_hex(&self) -> String {
        hex(self.0.public_key().as_ref())
    }
    pub fn sign_hex(&self, bytes: &[u8]) -> String {
        hex(self.0.sign(bytes).as_ref())
    }
}

pub fn verify(public_hex: &str, bytes: &[u8], sig_hex: &str) -> bool {
    match (unhex(public_hex), unhex(sig_hex)) {
        (Some(k), Some(s)) if k.len() == 32 && s.len() == 64 => UnparsedPublicKey::new(&ED25519, k).verify(bytes, &s).is_ok(),
        _ => false,
    }
}

/// The box key: what others seal messages to.
#[derive(Clone)]
pub struct BoxKey([u8; 32]);

impl BoxKey {
    pub fn from_secret(secret: [u8; 32]) -> Self {
        BoxKey(secret)
    }
    pub fn generate() -> Self {
        BoxKey(random())
    }
    pub fn secret(&self) -> [u8; 32] {
        self.0
    }
    pub fn public(&self) -> [u8; 32] {
        MontgomeryPoint::mul_base_clamped(self.0).to_bytes()
    }
    pub fn public_hex(&self) -> String {
        hex(&self.public())
    }
}

fn agree(secret: [u8; 32], public: [u8; 32]) -> Result<[u8; 32], String> {
    let shared = MontgomeryPoint(public).mul_clamped(secret).to_bytes();
    if shared == [0u8; 32] {
        return Err("That key can't be used (low order).".into());
    }
    Ok(shared)
}

fn aead_key(shared: &[u8; 32], epk: &[u8; 32], rpk: &[u8; 32]) -> Result<LessSafeKey, String> {
    let mut salt = Vec::with_capacity(64);
    salt.extend_from_slice(epk);
    salt.extend_from_slice(rpk);
    let info = [PROTO.as_bytes()];
    let prk = Salt::new(HKDF_SHA256, &salt).extract(shared);
    let okm = prk.expand(&info, &AES_256_GCM).map_err(|_| "key derivation failed")?;
    Ok(LessSafeKey::new(UnboundKey::from(okm)))
}

/* ---------- sealed messages ---------- */

/// What the relay carries: only the recipient can open it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Sealed {
    pub v: u32,
    /// Hex ephemeral X25519 public key.
    pub epk: String,
    /// Hex 12-byte nonce.
    pub n: String,
    /// Base64 AES-256-GCM ciphertext with its tag.
    pub ct: String,
}

pub fn seal(recipient_hex: &str, plaintext: &[u8]) -> Result<Sealed, String> {
    let rpk = unhex32(recipient_hex).ok_or("The recipient's box key isn't 32 bytes of hex.")?;
    let eph = BoxKey::generate();
    let epk = eph.public();
    let key = aead_key(&agree(eph.secret(), rpk)?, &epk, &rpk)?;
    let nonce: [u8; 12] = random();
    let mut buf = plaintext.to_vec();
    key.seal_in_place_append_tag(Nonce::assume_unique_for_key(nonce), Aad::empty(), &mut buf).map_err(|_| "sealing failed")?;
    let sealed = Sealed { v: 1, epk: hex(&epk), n: hex(&nonce), ct: base64::engine::general_purpose::STANDARD.encode(buf) };
    if serde_json::to_vec(&sealed).map(|b| b.len()).unwrap_or(usize::MAX) > MAX_SEALED {
        return Err("That message is too long to send.".into());
    }
    Ok(sealed)
}

pub fn open(key: &BoxKey, sealed: &Sealed) -> Result<Vec<u8>, String> {
    if sealed.v != 1 {
        return Err(format!("Unknown message version {}.", sealed.v));
    }
    let epk = unhex32(&sealed.epk).ok_or("bad ephemeral key")?;
    let nonce: [u8; 12] = unhex(&sealed.n).and_then(|n| n.try_into().ok()).ok_or("bad nonce")?;
    let mut buf = base64::engine::general_purpose::STANDARD.decode(&sealed.ct).map_err(|_| "bad ciphertext")?;
    let k = aead_key(&agree(key.secret(), epk)?, &epk, &key.public())?;
    let plain = k.open_in_place(Nonce::assume_unique_for_key(nonce), Aad::empty(), &mut buf).map_err(|_| "This message wasn't sealed for this key, or was changed on the way.")?;
    Ok(plain.to_vec())
}

/* ---------- what is inside ---------- */

/// The sender. A Cookie user has a handle and a signing key; a guest on a
/// card page has only a box key, kept in their browser.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Party {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handle: Option<String>,
    /// The sending agent's slug; None when the person wrote it themselves.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// Hex Ed25519 key (absent for guests).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sign: Option<String>,
    /// Hex X25519 key to seal replies to.
    #[serde(rename = "box")]
    pub boxk: String,
    /// A display name: the agent's or the person's.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

impl Party {
    pub fn address(&self) -> Option<Address> {
        Some(Address { handle: self.handle.clone()?, agent: self.agent.clone() })
    }
    pub fn is_guest(&self) -> bool {
        self.handle.is_none()
    }
}

/// One message, before sealing. `kind` says what it is (`knock`, `accept`,
/// `decline`, `msg`, `deal_offer`, `deal_accept`, `deal_decline`,
/// `room_invite`, `room_join`, `room_msg`); `body` carries its fields.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Inner {
    pub id: String,
    pub at: u64,
    pub from: Party,
    pub to: Address,
    pub kind: String,
    pub body: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sig: Option<String>,
}

impl Inner {
    fn signed_bytes(&self) -> Vec<u8> {
        let mut v = serde_json::to_value(self).unwrap_or_default();
        if let Some(o) = v.as_object_mut() {
            o.remove("sig");
        }
        canonical(&v)
    }
    pub fn sign(mut self, key: &SignKey) -> Self {
        self.sig = None;
        self.sig = Some(key.sign_hex(&self.signed_bytes()));
        self
    }
    /// A Cookie user's message must carry a signature by the key it claims.
    /// Guests sign nothing; they are only ever treated as guests.
    pub fn verify(&self) -> Result<(), String> {
        match (&self.from.sign, &self.sig) {
            (Some(k), Some(s)) if verify(k, &self.signed_bytes(), s) => Ok(()),
            (None, None) if self.from.is_guest() => Ok(()),
            _ => Err("The message's signature doesn't match its sender.".into()),
        }
    }
}

/* ---------- profiles and cards ---------- */

/// What a card shows of an agent's record. Integers only: it is signed.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Record {
    pub jobs: u64,
    pub failed: u64,
    pub promises_kept: u64,
    pub promises_missed: u64,
    pub approvals_asked: u64,
    pub since: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentCard {
    /// The agent's id inside its team: with the owner's key, it seeds the face.
    pub id: String,
    pub slug: String,
    pub name: String,
    pub job: String,
    pub record: Record,
    /// Anyone may message it at talk level, without knocking (business agents).
    pub open: bool,
    /// People without Cookie may chat with it on its card page.
    pub guests: bool,
    /// Shown on the person's page and in the directory.
    pub listed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Profile {
    pub handle: String,
    /// The person's display name.
    pub name: String,
    pub sign: String,
    #[serde(rename = "box")]
    pub boxk: String,
    /// Every agent has an address; only `listed` ones show on the page.
    pub agents: Vec<AgentCard>,
    pub at: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SignedProfile {
    pub profile: Profile,
    pub sig: String,
}

impl SignedProfile {
    pub fn sign(profile: Profile, key: &SignKey) -> Self {
        let sig = key.sign_hex(&canonical(&serde_json::to_value(&profile).unwrap_or_default()));
        SignedProfile { profile, sig }
    }
    pub fn verify(&self) -> Result<(), String> {
        let p = &self.profile;
        if !valid_handle(&p.handle) {
            return Err("That handle isn't allowed: 3 to 24 of a-z, 0-9 and -.".into());
        }
        if unhex32(&p.boxk).is_none() {
            return Err("The box key isn't 32 bytes of hex.".into());
        }
        if p.agents.iter().any(|a| !valid_slug(&a.slug)) {
            return Err("An agent's address isn't allowed.".into());
        }
        let mut slugs: Vec<&str> = p.agents.iter().map(|a| a.slug.as_str()).collect();
        slugs.sort();
        if slugs.windows(2).any(|w| w[0] == w[1]) {
            return Err("Two agents share an address.".into());
        }
        if !verify(&p.sign, &canonical(&serde_json::to_value(p).unwrap_or_default()), &self.sig) {
            return Err("The profile's signature doesn't match its key.".into());
        }
        Ok(())
    }
    pub fn card(&self, slug: &str) -> Option<&AgentCard> {
        self.profile.agents.iter().find(|a| a.slug == slug)
    }
}

/* ---------- deals ---------- */

/// What two people agree through their agents. The offer is signed by the
/// proposer; the receipt adds the acceptor's signature over the same bytes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Deal {
    pub id: String,
    pub from: Address,
    pub to: Address,
    pub terms: String,
    pub at: u64,
}

impl Deal {
    pub fn bytes(&self) -> Vec<u8> {
        canonical(&serde_json::to_value(self).unwrap_or_default())
    }
}

/* ---------- signed requests to the relay ---------- */

/// `x-cookie-auth: <handle> <unix seconds> <hex sig>` over
/// `"<METHOD> <path and query> <unix seconds>"`.
pub fn auth_header(handle: &str, key: &SignKey, method: &str, path_and_query: &str, now: u64) -> String {
    let sig = key.sign_hex(format!("{method} {path_and_query} {now}").as_bytes());
    format!("{handle} {now} {sig}")
}

pub fn check_auth(header: &str, method: &str, path_and_query: &str, now: u64, key_of: impl Fn(&str) -> Option<String>) -> Result<String, String> {
    let mut it = header.split(' ');
    let (handle, ts, sig) = (it.next().unwrap_or(""), it.next().unwrap_or(""), it.next().unwrap_or(""));
    let ts: u64 = ts.parse().map_err(|_| "bad time")?;
    if ts.abs_diff(now) > CLOCK_SKEW {
        return Err("The request's clock is off by more than five minutes.".into());
    }
    let key = key_of(handle).ok_or("No such handle on this relay.")?;
    if !verify(&key, format!("{method} {path_and_query} {ts}").as_bytes(), sig) {
        return Err("The request's signature doesn't match.".into());
    }
    Ok(handle.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sealed_messages_open_only_for_their_recipient() {
        let alice = BoxKey::generate();
        let eve = BoxKey::generate();
        let s = seal(&alice.public_hex(), b"hello").unwrap();
        assert_eq!(open(&alice, &s).unwrap(), b"hello");
        assert!(open(&eve, &s).is_err());
        let mut bent = s.clone();
        bent.ct.replace_range(0..2, if bent.ct.starts_with("AA") { "AB" } else { "AA" });
        assert!(open(&alice, &bent).is_err());
    }

    #[test]
    fn signed_inner_detects_a_changed_word_and_a_forged_sender() {
        let me = SignKey::from_seed(&[7; 32]).unwrap();
        let other = SignKey::from_seed(&[8; 32]).unwrap();
        let inner = Inner {
            id: "m1".into(),
            at: 1,
            from: Party { handle: Some("naveen".into()), agent: Some("invoices".into()), sign: Some(me.public_hex()), boxk: BoxKey::generate().public_hex(), name: Some("Invoices".into()) },
            to: Address { handle: "acme".into(), agent: None },
            kind: "msg".into(),
            body: serde_json::json!({"text": "pay 100", "n": 3}),
            sig: None,
        }
        .sign(&me);
        assert!(inner.verify().is_ok());
        let mut changed = inner.clone();
        changed.body = serde_json::json!({"text": "pay 900", "n": 3});
        assert!(changed.verify().is_err());
        let forged = Inner { from: Party { sign: Some(other.public_hex()), ..inner.from.clone() }, ..inner.clone() };
        assert!(forged.verify().is_err());
        let guest = Inner { from: Party { handle: None, agent: None, sign: None, boxk: "00".into(), name: None }, sig: None, ..inner };
        assert!(guest.verify().is_ok());
    }

    #[test]
    fn profiles_verify_and_refuse_tampering() {
        let k = SignKey::from_seed(&[1; 32]).unwrap();
        let p = Profile { handle: "naveen".into(), name: "Naveen".into(), sign: k.public_hex(), boxk: BoxKey::generate().public_hex(), agents: vec![], at: 5 };
        let mut sp = SignedProfile::sign(p, &k);
        assert!(sp.verify().is_ok());
        sp.profile.name = "Mallory".into();
        assert!(sp.verify().is_err());
    }

    #[test]
    fn addresses_parse_from_every_form() {
        let a = Address { handle: "naveen".into(), agent: Some("invoices".into()) };
        for s in ["@naveen/invoices", "naveen/invoices", "https://relay.example/naveen/invoices", "https://relay.example/naveen/invoices/", "@Naveen/Invoices"] {
            assert_eq!(Address::parse(s), Some(a.clone()), "{s}");
        }
        assert_eq!(Address::parse("@naveen"), Some(Address { handle: "naveen".into(), agent: None }));
        assert_eq!(a.to_string(), "@naveen/invoices");
        assert!(Address::parse("@x").is_none());
        assert!(Address::parse("@naveen/a/b").is_none());
        assert!(Address::parse("@v1").is_none());
        assert_eq!(slugify("Invoice Chaser!"), "invoice-chaser");
        assert_eq!(slugify("  ✨ "), "agent");
    }

    #[test]
    fn signed_requests_expire_and_bind_to_the_path() {
        let k = SignKey::from_seed(&[3; 32]).unwrap();
        let pk = k.public_hex();
        let h = auth_header("naveen", &k, "GET", "/v1/inbox?after=0", 1000);
        let key_of = |_: &str| Some(pk.clone());
        assert_eq!(check_auth(&h, "GET", "/v1/inbox?after=0", 1100, key_of).unwrap(), "naveen");
        assert!(check_auth(&h, "GET", "/v1/inbox?after=9", 1100, key_of).is_err());
        assert!(check_auth(&h, "GET", "/v1/inbox?after=0", 2000, key_of).is_err());
    }
}
