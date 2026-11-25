//! Move the cloud computer to full price and back to Spot, keeping its disk. Writes the result back to Cookie's own file.
#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-move-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let real = std::path::PathBuf::from(std::env::var("HOME").unwrap()).join("Library/Application Support/com.enkeon.cookie.desktop/cloud-computer.json");
    std::fs::copy(&real, dir.join("cloud-computer.json")).unwrap();
    let team = cookie_team::Team::open(&dir).unwrap();
    for market in ["on-demand", "spot"] {
        let t = std::time::Instant::now();
        match team.computer_move(market).await {
            Ok(v) => println!("{market}: {} in {} s", v, t.elapsed().as_secs()),
            Err(e) => { println!("{market}: FAILED {e}"); break; }
        }
        std::fs::copy(dir.join("cloud-computer.json"), &real).unwrap();
    }
    let t = std::time::Instant::now();
    match team.computer_px("parallax_vaults", &serde_json::json!({"as": "move-test"})).await {
        Ok(v) => println!("after the moves, the host answers: {v} ({} s, includes waking)", t.elapsed().as_secs()),
        Err(e) => println!("after the moves: {e}"),
    }
    std::fs::copy(dir.join("cloud-computer.json"), &real).unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}
