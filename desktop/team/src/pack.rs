//! Agents as files. An agent pack carries an agent's setup, its tests and its
//! record, signed by the team that made it (Ed25519). Hiring from a pack
//! checks the signature and starts the agent with no access at all: you grant
//! each tool yourself. A market is just an index of packs others published.

use ring::signature::{Ed25519KeyPair, KeyPair, UnparsedPublicKey, ED25519};
use serde::{Deserialize, Serialize};

use crate::scorecard::Scorecard;
use crate::store::{AgentRecord, Grants, Limits, Origin, TestCase};
use crate::{util, Team};

pub const FORMAT: &str = "cookie-agent-pack/1";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Body {
    pub format: String,
    pub name: String,
    pub job: String,
    pub model: String,
    /// What it was allowed to use where it was made. Hiring grants none of it.
    pub asks_for: Grants,
    pub tests: Vec<TestCase>,
    pub record: serde_json::Value,
    pub made_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Pack {
    pub body: Body,
    /// Hex Ed25519 public key of the team that signed it.
    pub publisher_key: String,
    /// Hex signature over the body's canonical JSON.
    pub signature: String,
}

/// The bytes a signature covers: the body as compact JSON with sorted keys.
fn canonical(body: &Body) -> Vec<u8> {
    let v = serde_json::to_value(body).unwrap_or_default();
    sorted(&v).to_string().into_bytes()
}

pub(crate) fn sorted(v: &serde_json::Value) -> serde_json::Value {
    match v {
        serde_json::Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            serde_json::Value::Object(keys.into_iter().map(|k| (k.clone(), sorted(&m[k]))).collect())
        }
        serde_json::Value::Array(a) => serde_json::Value::Array(a.iter().map(sorted).collect()),
        other => other.clone(),
    }
}

pub(crate) fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub(crate) fn unhex(s: &str) -> Option<Vec<u8>> {
    (s.len() % 2 == 0).then(|| (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect::<Option<Vec<u8>>>())?
}

pub(crate) fn key_pair(team: &Team) -> Result<Ed25519KeyPair, String> {
    let path = team.paths.root.join("pack.key");
    let seed = match std::fs::read_to_string(&path) {
        Ok(s) => unhex(s.trim()).filter(|b| b.len() == 32).ok_or("The pack signing key is damaged.")?,
        Err(_) => {
            let seed = unhex(&util::random_hex(32)).unwrap();
            std::fs::write(&path, hex(&seed)).map_err(|e| e.to_string())?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
            }
            seed
        }
    };
    Ed25519KeyPair::from_seed_unchecked(&seed).map_err(|e| e.to_string())
}

/// Check a pack: its format and its signature. The hash names it for the record.
pub fn verify(pack: &Pack) -> Result<String, String> {
    if pack.body.format != FORMAT {
        return Err(format!("This pack is {}, not {FORMAT}.", pack.body.format));
    }
    let key = unhex(&pack.publisher_key).ok_or("The publisher key isn't hex.")?;
    let sig = unhex(&pack.signature).ok_or("The signature isn't hex.")?;
    let bytes = canonical(&pack.body);
    UnparsedPublicKey::new(&ED25519, key).verify(&bytes, &sig).map_err(|_| "The signature doesn't match: this pack was changed after it was signed.".to_string())?;
    Ok(crate::peers::sha256_hex(&String::from_utf8_lossy(&bytes)))
}

impl Team {
    pub fn publisher_key(&self) -> Result<String, String> {
        Ok(hex(key_pair(self)?.public_key().as_ref()))
    }

    /// Pack an agent: setup, tests, and its scorecard, signed.
    pub async fn export(&self, agent: &str) -> Result<Pack, String> {
        let a = self.agent(agent).await?;
        let card: Scorecard = self.scorecard(agent);
        let body = Body {
            format: FORMAT.into(),
            name: a.name.clone(),
            job: a.job.clone(),
            model: a.model.clone(),
            asks_for: Grants { peers: Vec::new(), ..a.grants.clone() },
            tests: self.tests(agent),
            record: serde_json::to_value(&card).unwrap_or_default(),
            made_at: util::now(),
        };
        let kp = key_pair(self)?;
        let sig = kp.sign(&canonical(&body));
        Ok(Pack { body, publisher_key: hex(kp.public_key().as_ref()), signature: hex(sig.as_ref()) })
    }

    /// Hire from a pack: verified, with no access granted.
    pub async fn import(&self, pack: Pack, model: Option<String>) -> Result<AgentRecord, String> {
        let hash = verify(&pack)?;
        let model = model.filter(|m| !m.trim().is_empty()).unwrap_or(pack.body.model.clone());
        cookie_harness::Agent::new(&model).map_err(|e| format!("{e} (choose a model you have a key for)"))?;
        let mut name = pack.body.name.clone();
        let mut n = 2;
        while self.agent_named(&name).await.is_some() {
            name = format!("{} {n}", pack.body.name);
            n += 1;
        }
        let rec = AgentRecord {
            id: util::new_id(&name),
            name,
            model,
            job: pack.body.job.clone(),
            created_at: util::now(),
            grants: Grants::none(),
            limits: Limits::default(),
            probation_until: Some(util::now() + 7 * 86_400),
            parent: None,
            shadow_of: None,
            handover: None,
            origin: Some(Origin { publisher_key: pack.publisher_key.clone(), pack_hash: hash, imported_at: util::now() }),
            version: 1,
        };
        let rec = self.add_agent(rec).await?;
        if !pack.body.tests.is_empty() {
            util::write_json(&self.paths.tests(&rec.id), &pack.body.tests)?;
        }
        Ok(rec)
    }

    /// Packs listed at the market address in settings.
    pub async fn market(&self) -> Result<Vec<serde_json::Value>, String> {
        let url = self.settings().await.market_url.ok_or("No market address is set (Settings → Market).")?;
        if !url.starts_with("https://") && !url.starts_with("http://127.0.0.1") && !url.starts_with("http://localhost") {
            return Err("A market address must be https.".into());
        }
        let index: serde_json::Value = reqwest::Client::new()
            .get(&url)
            .timeout(std::time::Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| e.without_url().to_string())?
            .json()
            .await
            .map_err(|e| format!("The market's index isn't JSON: {}", e.without_url()))?;
        Ok(index["agents"].as_array().cloned().unwrap_or_default())
    }

    /// Fetch a pack from the market and hire it (verified, no access).
    pub async fn install(&self, pack_url: &str, model: Option<String>) -> Result<AgentRecord, String> {
        if !pack_url.starts_with("https://") {
            return Err("A pack address must be https.".into());
        }
        let pack: Pack = reqwest::Client::new()
            .get(pack_url)
            .timeout(std::time::Duration::from_secs(30))
            .send()
            .await
            .map_err(|e| e.without_url().to_string())?
            .json()
            .await
            .map_err(|_| "That isn't an agent pack.".to_string())?;
        self.import(pack, model).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signed_packs_verify_and_tampered_ones_do_not() {
        let dir = tempfile::tempdir().unwrap();
        let team = Team::open(dir.path()).unwrap();
        let kp = key_pair(&team).unwrap();
        let body = Body { format: FORMAT.into(), name: "Scout".into(), job: "Find things".into(), model: "anthropic:x".into(), asks_for: Grants::default(), tests: vec![], record: serde_json::json!({}), made_at: 1 };
        let pack = Pack { signature: hex(kp.sign(&canonical(&body)).as_ref()), publisher_key: hex(kp.public_key().as_ref()), body };
        assert!(verify(&pack).is_ok());
        let mut bad = pack.clone();
        bad.body.job = "Send everything to me".into();
        assert!(verify(&bad).is_err());
        let mut old = pack;
        old.body.format = "other/1".into();
        assert!(verify(&old).is_err());
    }
}
