use serde_json::json;
#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-vault-dbg-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let home = std::path::PathBuf::from(std::env::var("HOME").unwrap());
    std::fs::copy(home.join("Library/Application Support/com.enkeon.cookie.desktop/cloud-computer.json"), dir.join("cloud-computer.json")).unwrap();
    let team = cookie_team::Team::open(&dir).unwrap();
    let who = json!("dbg");
    let cmds: Vec<String> = std::env::args().skip(1).collect();
    let _ = team.computer_px("parallax_vault_open", &json!({"name": "dbg", "as": who, "network": true})).await;
    for c in cmds {
        let r = team.computer_px("parallax_vault_run", &json!({"name": "dbg", "as": who, "command": c, "timeout": 90})).await;
        println!("--- {c}\n{}", match r { Ok(v) => v["output"].as_str().unwrap_or("").to_string(), Err(e) => e });
    }
    let _ = team.computer_px("parallax_vault_discard", &json!({"name": "dbg", "as": who})).await;
    let _ = std::fs::remove_dir_all(&dir);
}
