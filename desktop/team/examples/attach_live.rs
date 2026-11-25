//! Each kind of file given to an agent, prepared as the model will see it (throwaway team).
use cookie_team::Team;
#[tokio::main(flavor = "multi_thread")]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-attach-live-{}", std::process::id()));
    let team = Team::open(&dir).unwrap();
    let rec = team.hire(cookie_team::Hire { name: "A".into(), job: "j".into(), model: "anthropic:claude-haiku-4-5".into(), ..Default::default() }).await.unwrap();
    let paths: Vec<String> = std::env::args().skip(1).collect();
    let t = std::time::Instant::now();
    let out = team.attach_paths(&rec.id, paths).await.unwrap();
    for f in out.as_array().unwrap() {
        let c = &f["card"];
        let parts: Vec<String> = f["attachments"].as_array().unwrap().iter().map(|a| if a["data"].is_string() { format!("[image {} {} KB]", a["media_type"].as_str().unwrap(), a["data"].as_str().unwrap().len() * 3 / 4 / 1024) } else { format!("[text {} chars: {:?}]", a["text"].as_str().unwrap().len(), a["text"].as_str().unwrap().chars().take(110).collect::<String>()) }).collect();
        println!("{} | {} | {} | thumb: {}\n   {}", c["name"], c["label"], c["size"], c["thumb"].is_string(), parts.join("\n   "));
    }
    println!("all in {:.1} s; kept: {:?}", t.elapsed().as_secs_f64(), std::fs::read_dir(dir.join("agents/a/work/attachments")).map(|r| r.flatten().map(|e| e.file_name()).collect::<Vec<_>>()).unwrap_or_default());
    let _ = std::fs::remove_dir_all(&dir);
}
