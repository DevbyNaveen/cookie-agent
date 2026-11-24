//! An agent's passport: who it is and what it has done, signed by your team.
//!
//! A passport is a small JSON document: the agent's name, job and model, its
//! career stage and rank, its record (jobs, how many finished cleanly, the
//! person's grades and noes, how long it has worked), its last tests and its
//! last exam — every number read from its own record, none estimated. It is
//! signed with your team's Ed25519 key (the one that signs agent packs), so
//! anyone can check it was issued by your team and not changed since:
//! `verify` needs only the passport itself.
//!
//! It carries no conversation, no files, no memory: only the record.

use ring::signature::{KeyPair, UnparsedPublicKey, ED25519};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::pack::{hex, key_pair, sorted, unhex};
use crate::store::Job;
use crate::{util, Team};

pub const FORMAT: &str = "cookie-passport/1";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Passport {
    pub body: Value,
    /// The team's public key (hex), which signed `body`.
    pub issuer: String,
    /// Ed25519 over the body as canonical JSON (keys sorted), hex.
    pub signature: String,
}

fn bytes(body: &Value) -> Vec<u8> {
    sorted(body).to_string().into_bytes()
}

/// Check a passport: its format and that its body is exactly what was signed.
pub fn verify(p: &Passport) -> Result<Value, String> {
    if p.body["format"] != FORMAT {
        return Err(format!("This isn't a {FORMAT} passport."));
    }
    let key = unhex(&p.issuer).ok_or("The issuer key isn't hex.")?;
    let sig = unhex(&p.signature).ok_or("The signature isn't hex.")?;
    UnparsedPublicKey::new(&ED25519, key).verify(&bytes(&p.body), &sig).map_err(|_| "The signature doesn't match: this passport was changed after it was signed.".to_string())?;
    Ok(json!({"valid": true, "issuer": p.issuer, "agent": p.body["agent"], "issued_at": p.body["issued_at"]}))
}

impl Team {
    /// Issue a passport for an agent, from its record now.
    pub async fn passport(&self, agent: &str) -> Result<Passport, String> {
        let rec = self.agent(agent).await?;
        let jobs: Vec<Job> = util::read_jsonl(&self.paths.jobs(agent));
        let real: Vec<&Job> = jobs.iter().filter(|j| crate::experience::real(j)).collect();
        let (rank, facts) = self.rank(&rec);
        let (stage, _) = crate::evolve::stage(rank, rec.on_probation(util::now()), real.len());
        let card = self.scorecard(agent);
        let tests = self.test_runs(agent).into_iter().find(|r| r.finished_at.is_some()).map(|r| json!({"passed": r.results.iter().filter(|x| x.pass).count(), "total": r.results.len(), "at": r.finished_at}));
        let exam = self.exams(agent).into_iter().next().map(|e| json!({"passed": e.before.passed, "total": e.before.total, "at": e.finished_at}));
        let first = jobs.iter().map(|j| j.started_at).min();
        let body = json!({
            "format": FORMAT,
            "agent": {"id": rec.id, "name": rec.name, "job": rec.job, "model": rec.model, "hired_at": rec.created_at},
            "stage": stage,
            "rank": rank.label(),
            "record": {
                "jobs": card.jobs, "done": card.done, "failed": card.failed,
                "clean_90d": facts.clean, "jobs_90d": facts.jobs, "noes_90d": facts.noes,
                "graded_good": card.graded_good, "graded_bad": card.graded_bad,
                "earned_actions": facts.earned, "tenure_days": facts.tenure_days,
                "first_job_at": first,
            },
            "tests": tests,
            "exam": exam,
            "issued_at": util::now(),
        });
        let kp = key_pair(self)?;
        let sig = kp.sign(&bytes(&body));
        Ok(Passport { body, issuer: hex(kp.public_key().as_ref()), signature: hex(sig.as_ref()) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_passport_verifies_and_a_changed_one_does_not() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("agents.json"), r#"[{"id":"a1","name":"Sorter","model":"anthropic:claude-haiku-4-5","job":"tidy","created_at":1}]"#).unwrap();
        let t = Team::open(dir.path()).unwrap();
        let p = t.passport("a1").await.unwrap();
        assert_eq!(verify(&p).unwrap()["valid"], true);
        assert_eq!(p.body["stage"], "new");
        let mut forged = p.clone();
        forged.body["record"]["jobs"] = json!(9999);
        assert!(verify(&forged).is_err());
    }
}
