//! Live: the shelf from GitHub, then an agent's skills picked and tested (throwaway team; uses the Anthropic key).
use cookie_team::{Hire, Team};
#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-skills-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let team = Team::open(&dir).unwrap();
    let t = std::time::Instant::now();
    let r = team.refresh_shelf(true).await.unwrap();
    println!("shelf in {:.0}s: {}", t.elapsed().as_secs_f64(), serde_json::to_string(&r).unwrap());
    let view = team.shelf_view();
    println!("vetted {} refused {}", view["vetted"], view["refused"]);
    for s in view["skills"].as_array().unwrap() {
        println!("  [{}] {} ({}) {}", s["state"].as_str().unwrap(), s["name"].as_str().unwrap(), s["license"].as_str().unwrap(), s["reasons"].as_array().map(|r| r.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join("; ")).unwrap_or_default().chars().take(140).collect::<String>());
    }
    let job = std::env::args().nth(1).unwrap_or("Turn my meeting notes and transcripts into decisions, owners and next steps, and remind me of what I promised.".into());
    let rec = team.hire(Hire { name: "Tester".into(), job, model: "anthropic:claude-haiku-4-5".into(), ..Hire::default() }).await.unwrap();
    let t = std::time::Instant::now();
    let picked = team.auto_skill_agent(&rec.id).await;
    println!("\npicked in {:.0}s: {picked:?}", t.elapsed().as_secs_f64());
    println!("{}", serde_json::to_string_pretty(&team.skills_view(&rec.id)).unwrap().chars().take(3500).collect::<String>());
    let _ = std::fs::remove_dir_all(&dir);
}
