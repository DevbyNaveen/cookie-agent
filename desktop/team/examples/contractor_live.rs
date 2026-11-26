//! Live: an agent brings in a contractor for a fresh-eyes review (throwaway team; uses the Anthropic key).
use cookie_team::store::Trigger;
use cookie_team::{Hire, Team};
#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-contractor-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let team = Team::open(&dir).unwrap();
    let rec = team.hire(Hire { name: "Writer".into(), job: "Write short, clear emails for the person.".into(), model: "anthropic:claude-haiku-4-5".into(), ..Hire::default() }).await.unwrap();
    let ask = "Here's my draft to a client: 'Hi Mara, as discussed we will deliver the redesign by friday and invoice 4k, let me know if ok, thx'. \
               Bring in a contractor for a fresh-eyes review of it (a client-communication reviewer), then give me the improved version.";
    let t = std::time::Instant::now();
    let job = team.run_and_wait(&rec.id, ask.into(), vec![], Trigger::Chat).await.unwrap();
    println!("status {:?} in {:.0}s; tools: {:?}\n\n{}\n", job.status, t.elapsed().as_secs_f64(), job.tools, job.answer.chars().take(900).collect::<String>());
    for c in team.contracts(&rec.id) {
        println!("contract: role={} kind={} state={} outcome={} model={} tools_used={:?} skills={:?} {}ms note={}", c.role, c.kind, c.state, c.outcome, c.model, c.tools_used, c.skills, c.ms, c.note);
    }
    let _ = std::fs::remove_dir_all(&dir);
}
