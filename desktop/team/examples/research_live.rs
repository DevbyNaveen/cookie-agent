//! A real agent reading a bot-protected page through Enkeon's Scrapling (throwaway team, your pairing).
use cookie_team::store::{Grants, Trigger};
use cookie_team::{Hire, Team};
#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-research-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let home = std::path::PathBuf::from(std::env::var("HOME").unwrap());
    std::fs::copy(home.join("Library/Application Support/com.enkeon.cookie.desktop/enkeon.json"), dir.join("enkeon.json")).unwrap();
    let team = Team::open(&dir).unwrap();
    team.load_pairing();
    println!("enkeon connected: {}", cookie_team::pair::enkeon().is_some());
    let rec = team.hire(Hire { name: "Researcher".into(), job: "Look things up on the web and summarise them.".into(), model: "anthropic:claude-sonnet-4-6".into(), grants: Some(Grants { memory: false, ..Grants::default() }), ..Hire::default() }).await.unwrap();
    let t = std::time::Instant::now();
    let job = team.run_and_wait(&rec.id, std::env::args().nth(1).unwrap(), vec![], Trigger::Chat).await.unwrap();
    println!("status {:?} in {:.0} s; tools used: {:?}\n{}", job.status, t.elapsed().as_secs_f64(), job.tools, job.answer.chars().take(1200).collect::<String>());
    let _ = std::fs::remove_dir_all(&dir);
}
