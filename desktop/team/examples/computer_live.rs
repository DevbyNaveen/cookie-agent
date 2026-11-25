//! The cloud computer's status through Cookie's own code and its scoped key (read only).
#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-pc-live-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let src = dirs_home().join("Library/Application Support/com.enkeon.cookie.desktop/cloud-computer.json");
    std::fs::copy(src, dir.join("cloud-computer.json")).unwrap();
    let team = cookie_team::Team::open(&dir).unwrap();
    let t = std::time::Instant::now();
    println!("{}", serde_json::to_string_pretty(&team.computer_status().await).unwrap());
    println!("took {} ms", t.elapsed().as_millis());
    let _ = std::fs::remove_dir_all(&dir);
}
fn dirs_home() -> std::path::PathBuf { std::path::PathBuf::from(std::env::var("HOME").unwrap()) }
