//! Live, against the paired brain (throwaway team): spaces and owners, open plans, a prime, and erasure.
use cookie_team::{Hire, Team};
use serde_json::json;
#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-brain-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let home = std::path::PathBuf::from(std::env::var("HOME").unwrap());
    std::fs::copy(home.join("Library/Application Support/com.enkeon.cookie.desktop/enkeon.json"), dir.join("enkeon.json")).unwrap();
    let team = Team::open(&dir).unwrap();
    team.load_pairing();
    let model = "anthropic:claude-haiku-4-5";
    let leads = team.hire(Hire { name: "Lead Pipeline Desk".into(), job: "Qualify new inbound leads (cafes, bakeries, clinics, gyms) and draft a short, personal first reply for the good ones.".into(), model: model.into(), ..Hire::default() }).await.unwrap();
    let _ = team.hire(Hire { name: "Code Helper".into(), job: "Review and fix code in the person's GitHub repositories.".into(), model: model.into(), ..Hire::default() }).await.unwrap();
    let t = std::time::Instant::now();
    let r = team.refresh_spaces(true).await;
    println!("spaces in {:.0}s: {}", t.elapsed().as_secs_f64(), r.as_ref().map(|v| format!("{} spaces, {} new, {} assigned", v["spaces"], v["new"].as_array().map(|a| a.len()).unwrap_or(0), v["assigned"].as_array().map(|a| a.len()).unwrap_or(0))).unwrap_or_else(|e| e.clone()));
    let spaces = team.spaces();
    let mut by: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    for s in spaces.values() { by.entry(format!("{}{}", s.owner.clone().unwrap_or("-".into()), if s.wakes { " (wakes)" } else { "" })).or_default().push(s.name.clone()); }
    for (o, v) in &by { println!("  {o}: {} e.g. {}", v.len(), v.iter().take(6).cloned().collect::<Vec<_>>().join(", ")); }
    println!("plans: {:?}", team.refresh_plans().await);
    println!("lead follows {} spaces", team.followed(&leads.id).len());
    for n in ["rigacakestudio", "kaivon", "khpgym", "thinkingroot", "cookie", "devbynaveen-thinkingroot"] { if let Some(x) = spaces.get(n) { println!("  {n}: owner={:?} wakes={} why={}", x.owner, x.wakes, x.why); } }
    let p = team.prime(&leads, "job-x", "Draft a short first reply to rigacakestudio about our pricing").await;
    println!("\nPRIME:\n{}\n", p.unwrap_or("(nothing)".into()));
    if std::env::var("SKIP_ERASE").is_ok() { let _ = std::fs::remove_dir_all(&dir); return; }
    // Erasure: a memory in a scratch agent space, then the space forgotten.
    let space = format!("cookie-agent-erase-test-{}", std::process::id());
    let saved = cookie_team::memory::enkeon_call_pub("remember", json!({"text": "Erase test: the scratch agent likes green tea.", "purpose": "A test of erasure; it should be gone right after.", "kind": "fact", "weight": null, "feeling": null, "about": null, "name": null, "updates": null, "branch": space, "due": null, "to": null, "owner": null, "resources": null, "depends_on": null, "acceptance": null})).await;
    println!("saved: {}", saved.as_ref().map(|s| s.chars().take(80).collect::<String>()).unwrap_or_else(|e| e.clone()));
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    let (done, left) = team.forget_space_pub(&space).await;
    println!("forgot {done}, left {}", left.len());
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let after = cookie_team::memory::enkeon_call_pub("recall", json!({"query": "scratch agent likes green tea erase test", "top_k": 5, "since": null, "until": null, "type": null, "state": null, "workspace": null, "branch": null, "budget_tokens": 0, "as_of": null, "check": null, "folder": null, "proof": false})).await.unwrap_or_default();
    println!("still findable anywhere: {}", after.contains("green tea"));
    let _ = cookie_team::memory::enkeon_call_pub("delete_branch", json!({"branch": space, "workspace": null})).await;
    let _ = std::fs::remove_dir_all(&dir);
}
