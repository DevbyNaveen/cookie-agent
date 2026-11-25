//! A vault with the internet, and one without: apps, reach, walls, sleep. Through Cookie's own code.
use serde_json::json;
#[tokio::main]
async fn main() {
    let dir = std::env::temp_dir().join(format!("cookie-vault-net-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let home = std::path::PathBuf::from(std::env::var("HOME").unwrap());
    std::fs::copy(home.join("Library/Application Support/com.enkeon.cookie.desktop/cloud-computer.json"), dir.join("cloud-computer.json")).unwrap();
    let team = cookie_team::Team::open(&dir).unwrap();
    let who = json!("net-test");
    let checks = "for c in firefox libreoffice mousepad zenity; do command -v $c >/dev/null && echo \"have $c\" || echo \"MISSING $c\"; done; \
        echo web: $(curl -s -o /dev/null -m 8 -w '%{http_code}' https://example.com); \
        echo metadata: $(curl -s -o /dev/null -m 4 -w '%{http_code}' http://169.254.169.254/latest/meta-data/ || echo blocked); \
        echo private: $(curl -s -o /dev/null -m 4 -w '%{http_code}' http://10.0.0.1/ || echo blocked); \
        echo host: $(curl -s -o /dev/null -m 4 -w '%{http_code}' http://172.30.0.1:4610/ || echo blocked)";
    let steps: Vec<(&str, serde_json::Value)> = vec![
        ("parallax_vault_open", json!({"name": "web", "as": who, "network": true})),
        ("parallax_vault_run", json!({"name": "web", "as": who, "command": checks, "timeout": 60})),
        ("parallax_vault_launch", json!({"name": "web", "as": who, "app": "firefox --new-instance https://example.com"})),
        ("parallax_vault_run", json!({"name": "web", "as": who, "command": "sleep 12; echo ok", "timeout": 30})),
        ("parallax_vault_look", json!({"name": "web", "as": who, "app": "firefox"})),
        ("parallax_vault_sleep", json!({"name": "web", "as": who})),
        ("parallax_vaults", json!({"as": who})),
        ("parallax_vault_run", json!({"name": "web", "as": who, "command": "echo still here: $(curl -s -o /dev/null -m 8 -w '%{http_code}' https://example.com)", "timeout": 30})),
        ("parallax_vault_open", json!({"name": "offline", "as": who})),
        ("parallax_vault_run", json!({"name": "offline", "as": who, "command": "echo web: $(curl -s -o /dev/null -m 4 -w '%{http_code}' https://example.com || echo none)", "timeout": 30})),
        ("parallax_vault_discard", json!({"name": "web", "as": who})),
        ("parallax_vault_discard", json!({"name": "offline", "as": who})),
    ];
    for (tool, args) in steps {
        let t = std::time::Instant::now();
        let r = team.computer_px(tool, &args).await;
        let text = match &r { Ok(v) => v.as_str().map(str::to_string).unwrap_or_else(|| v.to_string()), Err(e) => format!("ERROR {e}") };
        println!("--- {tool} ({} ms)\n{}", t.elapsed().as_millis(), text.chars().take(900).collect::<String>());
    }
    let _ = std::fs::remove_dir_all(&dir);
}
