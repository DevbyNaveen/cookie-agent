//! Wake the cloud computer and put it back to sleep, through Cookie's own code and scoped key.
#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-pc-cycle-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let home = std::path::PathBuf::from(std::env::var("HOME").unwrap());
    std::fs::copy(home.join("Library/Application Support/com.enkeon.cookie.desktop/cloud-computer.json"), dir.join("cloud-computer.json")).unwrap();
    let team = cookie_team::Team::open(&dir).unwrap();
    println!("before: {}", team.computer_status().await["state"]);
    let t = std::time::Instant::now();
    match team.computer_wake().await { Ok(v) => println!("wake asked: {}", v["state"]), Err(e) => { println!("wake failed: {e}"); return; } }
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        let s = team.computer_status().await;
        if s["state"] == "running" { println!("running after {} s", t.elapsed().as_secs()); break; }
        if t.elapsed().as_secs() > 240 { println!("still {} after 4 min", s["state"]); break; }
    }
    let t2 = std::time::Instant::now();
    match team.computer_sleep().await { Ok(v) => println!("sleep asked: {}", v["state"]), Err(e) => println!("sleep failed: {e}") }
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        let s = team.computer_status().await;
        if s["state"] == "stopped" { println!("stopped after {} s; this test: {} h counted", t2.elapsed().as_secs(), s["hours"]); break; }
        if t2.elapsed().as_secs() > 240 { println!("still {} after 4 min", s["state"]); break; }
    }
    let _ = std::fs::remove_dir_all(&dir);
}
