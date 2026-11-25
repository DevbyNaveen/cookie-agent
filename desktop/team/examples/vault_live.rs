//! A vault on the cloud computer, end to end, through Cookie's own code (SSM, no open ports).
use serde_json::json;
#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-vault-live-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let home = std::path::PathBuf::from(std::env::var("HOME").unwrap());
    std::fs::copy(home.join("Library/Application Support/com.enkeon.cookie.desktop/cloud-computer.json"), dir.join("cloud-computer.json")).unwrap();
    let team = cookie_team::Team::open(&dir).unwrap();
    let who = json!("vault-test");
    let steps: Vec<(&str, serde_json::Value)> = vec![
        ("parallax_vault_open", json!({"name": "trial", "as": who})),
        ("parallax_vault_launch", json!({"name": "trial", "as": who, "app": "zenity --entry --title=CookieVault --text='Your name?' > /root/answer.txt"})),
        ("parallax_vault_look", json!({"name": "trial", "as": who, "app": "zenity"})),
        ("parallax_vault_sleep", json!({"name": "trial", "as": who})),
        ("parallax_vault_open", json!({"name": "trial", "as": who})),
        ("parallax_vault_look", json!({"name": "trial", "as": who, "app": "zenity"})),
        ("parallax_vault_act", json!({"name": "trial", "as": who, "app": "zenity", "steps": [{"role": "textfield", "do": "set", "value": "hello from a cloud vault"}, {"role": "button", "name": "OK", "do": "press"}]})),
        ("parallax_vault_run", json!({"name": "trial", "as": who, "command": "sleep 1; cat /root/answer.txt; uname -r"})),
        ("parallax_vault_discard", json!({"name": "trial", "as": who})),
    ];
    for (tool, args) in steps {
        let t = std::time::Instant::now();
        let r = team.computer_px(tool, &args).await;
        let text = match &r { Ok(v) => v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string()), Err(e) => format!("ERROR {e}") };
        println!("--- {tool} ({} ms)\n{}", t.elapsed().as_millis(), text.chars().take(700).collect::<String>());
    }
    let _ = std::fs::remove_dir_all(&dir);
}
