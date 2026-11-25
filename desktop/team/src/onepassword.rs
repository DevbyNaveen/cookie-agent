//! 1Password: agents sign in for you without ever seeing a password.
//!
//! - **The model never holds a secret.** An agent asks to sign in with a
//!   login by name; Cookie fetches it with 1Password's own CLI (`op`), puts the
//!   username, password and one-time code straight into the fields through
//!   Cookie Hands, and tells the agent only "filled". Nothing secret reaches a
//!   prompt, a tool result, a log, a recipe or the clipboard.
//! - **Only where it belongs.** On a web page, a login fills only when the
//!   page's address is the login's saved website or under it (`accounts.x.com`
//!   for `x.com`). In an app with no web address, the approval says so plainly.
//! - **You say yes every time.** A fill always asks you, and 1Password itself
//!   asks for Touch ID when it unlocks.
//! - **Only the vaults you choose.** Agents list and use logins from the vaults
//!   you allow in Connect apps → 1Password; none until you pick.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use cookie_hands::{Act, Look};
use cookie_harness::tool::{tool, Effect, Tool};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{util, Team};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct OnePassword {
    /// Vault ids agents may use.
    pub vaults: Vec<String>,
}

/// The `op` CLI: `COOKIE_OP_BIN` (tests), Homebrew's places, or the PATH.
fn op_bin() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("COOKIE_OP_BIN") {
        return Some(PathBuf::from(p));
    }
    for p in ["/opt/homebrew/bin/op", "/usr/local/bin/op"] {
        if std::path::Path::new(p).exists() {
            return Some(PathBuf::from(p));
        }
    }
    std::env::var_os("PATH").and_then(|path| std::env::split_paths(&path).map(|d| d.join("op")).find(|p| p.exists()))
}

/// Run `op` and read its JSON. Errors never carry what `op` printed on success.
async fn op(args: &[&str]) -> Result<Value, String> {
    let bin = op_bin().ok_or("1Password's command-line tool isn't installed: Connect apps → 1Password shows how.")?;
    let mut cmd = tokio::process::Command::new(bin);
    cmd.args(args).kill_on_drop(true);
    let out = tokio::time::timeout(Duration::from_secs(60), cmd.output()).await.map_err(|_| "1Password didn't answer (was the Touch ID prompt left open?).".to_string())?.map_err(|e| e.to_string())?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        let first = err.lines().find(|l| !l.trim().is_empty()).unwrap_or("1Password refused.").trim();
        // `op`'s own words, cut short: they name what went wrong, never a secret.
        return Err(format!("1Password: {}", crate::util::clip(first.trim_start_matches("[ERROR]").trim(), 200)));
    }
    serde_json::from_slice(&out.stdout).map_err(|_| "1Password answered in a way Cookie can't read.".to_string())
}

/// The host of a web address, lower case, without `www.`.
fn host(url: &str) -> Option<String> {
    let rest = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    let h = rest.split(['/', '?', '#']).next()?.rsplit('@').next()?.split(':').next()?.trim().to_lowercase();
    let h = h.strip_prefix("www.").unwrap_or(&h).to_string();
    (h.contains('.') && !h.is_empty()).then_some(h)
}

/// A page may take a login when its host is the login's site or under it.
fn site_matches(page: &str, sites: &[String]) -> bool {
    let Some(p) = host(page) else { return false };
    sites.iter().filter_map(|s| host(s)).any(|s| p == s || p.ends_with(&format!(".{s}")))
}

/// A login as an agent may see it: never a field's value.
#[derive(Debug, Clone, PartialEq)]
struct Login {
    id: String,
    title: String,
    vault: String,
    sites: Vec<String>,
}

fn logins_of(list: &Value) -> Vec<Login> {
    list.as_array()
        .into_iter()
        .flatten()
        .map(|i| Login {
            id: i["id"].as_str().unwrap_or_default().to_string(),
            title: i["title"].as_str().unwrap_or_default().to_string(),
            vault: i["vault"]["id"].as_str().unwrap_or_default().to_string(),
            sites: i["urls"].as_array().into_iter().flatten().filter_map(|u| u["href"].as_str().map(str::to_string)).collect(),
        })
        .filter(|l| !l.id.is_empty())
        .collect()
}

/// What a fill needs from an item, kept only as long as the fill takes.
struct Secret {
    username: String,
    password: String,
    sites: Vec<String>,
    vault: String,
    has_otp: bool,
}

fn secret_of(item: &Value) -> Secret {
    let fields = item["fields"].as_array().cloned().unwrap_or_default();
    let by = |purpose: &str, id: &str| {
        fields.iter().find(|f| f["purpose"].as_str() == Some(purpose) || f["id"].as_str() == Some(id)).and_then(|f| f["value"].as_str()).unwrap_or_default().to_string()
    };
    Secret {
        username: by("USERNAME", "username"),
        password: by("PASSWORD", "password"),
        sites: item["urls"].as_array().into_iter().flatten().filter_map(|u| u["href"].as_str().map(str::to_string)).collect(),
        vault: item["vault"]["id"].as_str().unwrap_or_default().to_string(),
        has_otp: fields.iter().any(|f| f["type"].as_str() == Some("OTP")),
    }
}

impl Team {
    fn op_path(&self) -> PathBuf {
        self.paths.root.join("onepassword.json")
    }

    pub fn onepassword(&self) -> OnePassword {
        util::read_json(&self.op_path())
    }

    /// For Connect apps: installed? signed in (which account, .com or .eu)? which vaults, which allowed?
    /// Not `deep`, it doesn't ask 1Password anything, so opening a sheet never sets off Touch ID.
    pub async fn onepassword_status(&self, deep: bool) -> Value {
        let Some(bin) = op_bin() else {
            return json!({"installed": false, "allowed": self.onepassword().vaults});
        };
        if !deep {
            return json!({"installed": true, "allowed": self.onepassword().vaults});
        }
        let version = tokio::process::Command::new(&bin).arg("--version").output().await.ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
        let me = op(&["whoami", "--format", "json"]).await;
        let mut out = json!({"installed": true, "version": version, "allowed": self.onepassword().vaults});
        match me {
            Ok(me) => {
                let url = me["url"].as_str().unwrap_or_default().to_string();
                out["signed_in"] = json!(true);
                out["account"] = json!(host(&url).unwrap_or(url));
                out["vaults"] = op(&["vault", "list", "--format", "json"]).await.map(|v| json!(v.as_array().into_iter().flatten().map(|x| json!({"id": x["id"], "name": x["name"]})).collect::<Vec<_>>())).unwrap_or(json!([]));
            }
            Err(e) => {
                out["signed_in"] = json!(false);
                out["reason"] = json!(e);
            }
        }
        out
    }

    pub fn onepassword_set_vaults(&self, vaults: Vec<String>) -> Result<Value, String> {
        let mut c = self.onepassword();
        c.vaults = vaults.into_iter().filter(|v| v.chars().all(|c| c.is_ascii_alphanumeric())).collect();
        util::write_json(&self.op_path(), &c)?;
        Ok(json!({"allowed": c.vaults}))
    }

    /// The logins agents may use: titles and sites only.
    async fn allowed_logins(&self) -> Result<Vec<Login>, String> {
        let vaults = self.onepassword().vaults;
        if vaults.is_empty() {
            return Err("No 1Password vault is allowed for agents yet: the person picks them in Connect apps → 1Password.".into());
        }
        let mut out = Vec::new();
        for v in &vaults {
            out.extend(logins_of(&op(&["item", "list", "--categories", "Login", "--vault", v, "--format", "json"]).await?));
        }
        Ok(out)
    }
}

fn s(a: &Value, k: &str) -> String {
    a[k].as_str().unwrap_or_default().trim().to_string()
}

/// The login an agent named: exact title, then one title containing it.
fn pick<'a>(all: &'a [Login], name: &str) -> Option<&'a Login> {
    let n = name.to_lowercase();
    all.iter().find(|l| l.id == name || l.title.to_lowercase() == n).or_else(|| all.iter().find(|l| l.title.to_lowercase().contains(&n)))
}

/// Where the username, password and code go in a look.
fn fields_in(snap: &cookie_hands::Snapshot) -> (Option<u32>, Option<u32>, Option<u32>) {
    let password = snap.nodes.iter().find(|n| n.role == "password").map(|n| n.id);
    let named = |words: &[&str]| {
        snap.nodes.iter().find(|n| matches!(n.role.as_str(), "textfield" | "combobox") && words.iter().any(|w| n.name.to_lowercase().contains(w))).map(|n| n.id)
    };
    let user = named(&["email", "user", "login", "account", "phone"]).or_else(|| {
        // Else the text field just before the password field.
        let pi = password.and_then(|p| snap.nodes.iter().position(|n| n.id == p))?;
        snap.nodes[..pi].iter().rev().find(|n| n.role == "textfield").map(|n| n.id)
    });
    let code = named(&["code", "otp", "one-time", "verification", "2fa", "authenticator"]);
    // One field is never both the username and the code.
    let user = user.filter(|u| Some(*u) != code);
    (user, password, code)
}

/// Put a secret in a field without it ever leaving this function: set it, or focus and type.
fn put(body: &dyn cookie_hands::Body, pid: i32, id: u32, secret: &str, web: bool) -> Result<(), String> {
    // Web pages listen for typing; native fields take a set value.
    if !web && body.act(pid, id, &Act::Set(secret.to_string())).is_ok() {
        return Ok(());
    }
    body.act(pid, id, &Act::Focus).map_err(|_| "couldn't reach the field".to_string())?;
    let all = if body.system() == "macos" { "cmd+a" } else { "ctrl+a" };
    body.keys(Some(pid), &cookie_hands::Combo::parse(all).unwrap()).ok();
    body.type_text(Some(pid), secret).map_err(|_| "couldn't type into the field".to_string())
}

pub(crate) fn tools(team: &Arc<Team>) -> Vec<Arc<dyn Tool>> {
    let mut out: Vec<Arc<dyn Tool>> = Vec::new();
    let t = team.clone();
    out.push(Arc::new(tool(
        "logins",
        "The person's 1Password logins you may use: each one's name and website. Never a password; to sign in, use sign_in.",
        json!({"type": "object", "properties": {"search": {"type": "string", "description": "part of a name or site"}}}),
        Effect::Read,
        move |a: Value| {
            let t = t.clone();
            async move {
                let q = s(&a, "search").to_lowercase();
                let all = t.allowed_logins().await?;
                let hits: Vec<String> = all
                    .iter()
                    .filter(|l| q.is_empty() || l.title.to_lowercase().contains(&q) || l.sites.iter().any(|u| u.to_lowercase().contains(&q)))
                    .take(40)
                    .map(|l| format!("{} — {}", l.title, l.sites.iter().filter_map(|u| host(u)).collect::<Vec<_>>().join(", ")))
                    .collect();
                Ok(if hits.is_empty() { "No login matches.".into() } else { hits.join("\n") })
            }
        },
    )));

    let t = team.clone();
    out.push(Arc::new(
        tool(
            "sign_in",
            "Sign in with one of the person's 1Password logins on the page or app in front of you (or `app`): Cookie fills the \
             username, password and, with `code: true`, the one-time code straight into the fields. You never see them; you're told \
             only what was filled. On a web page it fills only when the page is the login's website. Look first so the sign-in form \
             is showing; press the sign-in button yourself afterwards.",
            json!({"type": "object", "properties": {
                "login": {"type": "string", "description": "the login's name, from `logins`"},
                "app": {"type": "string", "description": "the app showing the sign-in form; empty for the app in front"},
                "code": {"type": "boolean", "description": "also fill the one-time code"}
            }, "required": ["login"]}),
            // A fill always asks the person, however trusted the agent.
            Effect::Outbound,
            move |a: Value| {
                let t = t.clone();
                async move {
                    let name = s(&a, "login");
                    let all = t.allowed_logins().await?;
                    let login = pick(&all, &name).cloned().ok_or_else(|| format!("No allowed 1Password login is called {name:?}; `logins` lists them."))?;
                    let body = cookie_hands::body().ok_or("Signing in needs Cookie Hands, which this system doesn't have yet.")?;
                    body.ready()?;
                    let q = Look { app: Some(s(&a, "app")).filter(|x| !x.is_empty()), pid: None, limit: 400 };
                    let snap = tokio::task::spawn_blocking(move || body.look(&q)).await.map_err(|e| e.to_string())??;
                    // Where it would go, checked before 1Password is even asked.
                    if let Some(page) = &snap.url {
                        if !site_matches(page, &login.sites) {
                            return Err(format!(
                                "Not filled: this page is {} and the login \"{}\" is for {}. Logins only fill on their own website.",
                                host(page).unwrap_or_default(),
                                login.title,
                                login.sites.iter().filter_map(|u| host(u)).collect::<Vec<_>>().join(", ")
                            ));
                        }
                    }
                    let (user_f, pass_f, code_f) = fields_in(&snap);
                    if user_f.is_none() && pass_f.is_none() {
                        return Err("There's no sign-in field showing; look, and open the sign-in form first.".into());
                    }
                    let item = op(&["item", "get", &login.id, "--vault", &login.vault, "--reveal", "--format", "json"]).await?;
                    let secret = secret_of(&item);
                    // The vault and the site are checked again on what 1Password actually returned.
                    if !t.onepassword().vaults.contains(&secret.vault) {
                        return Err("That login isn't in a vault agents may use.".into());
                    }
                    if let Some(page) = &snap.url {
                        if !site_matches(page, &secret.sites) {
                            return Err("Not filled: the login's website doesn't match this page.".into());
                        }
                    }
                    let code = if a["code"].as_bool().unwrap_or(false) && secret.has_otp && code_f.is_some() {
                        op(&["item", "get", &login.id, "--vault", &login.vault, "--otp"]).await.ok().and_then(|v| v.as_str().map(str::to_string).or_else(|| Some(v.to_string().trim_matches('"').to_string())))
                    } else {
                        None
                    };
                    let (pid, web) = (snap.pid, snap.url.is_some());
                    let filled = tokio::task::spawn_blocking(move || {
                        let mut filled = Vec::new();
                        if let (Some(f), false) = (user_f, secret.username.is_empty()) {
                            put(body, pid, f, &secret.username, web).map_err(|e| format!("username: {e}"))?;
                            filled.push("username");
                        }
                        if let (Some(f), false) = (pass_f, secret.password.is_empty()) {
                            put(body, pid, f, &secret.password, web).map_err(|e| format!("password: {e}"))?;
                            filled.push("password");
                        }
                        if let (Some(f), Some(c)) = (code_f, code.as_deref()) {
                            put(body, pid, f, c, web).map_err(|e| format!("one-time code: {e}"))?;
                            filled.push("one-time code");
                        }
                        Ok::<_, String>(filled)
                    })
                    .await
                    .map_err(|e| e.to_string())??;
                    if filled.is_empty() {
                        return Err("Nothing could be filled: the login has no username or password for the fields showing.".into());
                    }
                    Ok(format!("Filled the {} for \"{}\". Press the sign-in button to continue.", filled.join(" and "), login.title))
                }
            },
        )
        .with_preview(|a| {
            let app = a["app"].as_str().filter(|x| !x.is_empty()).map(|x| format!(" in {x}")).unwrap_or_default();
            format!("Sign in with your 1Password login “{}”{app}{}", a["login"].as_str().unwrap_or_default(), if a["code"].as_bool().unwrap_or(false) { ", with its one-time code" } else { "" })
        }),
    ));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_login_fills_only_on_its_own_site() {
        let sites = vec!["https://www.github.com/login".to_string()];
        assert!(site_matches("https://github.com/session", &sites));
        assert!(site_matches("https://gist.github.com/x", &sites), "under its site");
        assert!(!site_matches("https://github.com.evil.io/login", &sites), "a lookalike is not its site");
        assert!(!site_matches("https://evilgithub.com/", &sites));
        assert!(!site_matches("https://user:pw@evil.io/@github.com", &sites));
        assert!(!site_matches("not a url", &sites));
        assert_eq!(host("https://user@Accounts.Google.com:443/x?y"), Some("accounts.google.com".into()));
    }

    #[test]
    fn agents_see_names_and_sites_never_values() {
        let list = json!([{"id": "abc", "title": "GitHub", "vault": {"id": "v1"}, "urls": [{"href": "https://github.com"}]}]);
        let l = logins_of(&list);
        assert_eq!(l, vec![Login { id: "abc".into(), title: "GitHub".into(), vault: "v1".into(), sites: vec!["https://github.com".into()] }]);
        let item = json!({"vault": {"id": "v1"}, "urls": [{"href": "https://github.com"}], "fields": [
            {"id": "username", "purpose": "USERNAME", "value": "me@x.com"},
            {"id": "password", "purpose": "PASSWORD", "type": "CONCEALED", "value": "s3cret"},
            {"id": "one", "type": "OTP", "value": "otpauth://totp/x"}
        ]});
        let sec = secret_of(&item);
        assert_eq!((sec.username.as_str(), sec.password.as_str(), sec.has_otp), ("me@x.com", "s3cret", true));
        assert_eq!(pick(&l, "git").map(|x| x.id.as_str()), Some("abc"));
    }

    #[test]
    fn fields_are_found_by_name_or_by_sitting_before_the_password() {
        let n = |id, role: &str, name: &str| cookie_hands::Node { id, role: role.into(), name: name.into(), value: String::new(), depth: 0, enabled: true, focused: false, frame: None };
        let snap = cookie_hands::Snapshot { nodes: vec![n(1, "text", "Sign in"), n(2, "textfield", ""), n(3, "password", "Password"), n(4, "textfield", "Verification code")], ..Default::default() };
        assert_eq!(fields_in(&snap), (Some(2), Some(3), Some(4)), "the field before the password is the username; the code field is apart");
        let snap = cookie_hands::Snapshot { nodes: vec![n(1, "textfield", "Account code"), n(2, "password", "")], ..Default::default() };
        let (user, _, code) = fields_in(&snap);
        assert!(user.is_none() || user != code, "a username never goes in the code's field");
        let snap = cookie_hands::Snapshot { nodes: vec![n(1, "textfield", "Search"), n(2, "textfield", "Email address"), n(3, "password", "")], ..Default::default() };
        assert_eq!(fields_in(&snap).0, Some(2));
    }

    /// A stand-in for `op`, so the whole path runs without a real vault.
    #[tokio::test]
    async fn status_and_logins_go_through_op_and_only_allowed_vaults_show() {
        let dir = std::env::temp_dir().join(format!("cookie-op-{}", util::random_hex(4)));
        std::fs::create_dir_all(&dir).unwrap();
        let fake = dir.join("op");
        std::fs::write(
            &fake,
            "#!/bin/sh\ncase \"$1 $2\" in\n\
             \"--version \") echo 2.30.0 ;;\n\
             \"whoami --format\") echo '{\"url\":\"https://my.1password.eu\"}' ;;\n\
             \"vault list\") echo '[{\"id\":\"v1\",\"name\":\"Cookie\"},{\"id\":\"v2\",\"name\":\"Private\"}]' ;;\n\
             \"item list\") if [ \"$6\" = v1 ]; then echo '[{\"id\":\"a\",\"title\":\"GitHub\",\"vault\":{\"id\":\"v1\"},\"urls\":[{\"href\":\"https://github.com\"}]}]'; else echo '[{\"id\":\"b\",\"title\":\"Bank\",\"vault\":{\"id\":\"v2\"}}]'; fi ;;\n\
             *) echo 'unknown' >&2; exit 1 ;;\n\
             esac\n",
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        // SAFETY: this test is the only one that reads COOKIE_OP_BIN.
        unsafe { std::env::set_var("COOKIE_OP_BIN", &fake) };
        let team = Team::open(dir.join("team")).unwrap();
        assert_eq!(team.onepassword_status(false).await["installed"], true);
        let st = team.onepassword_status(true).await;
        assert_eq!(st["signed_in"], true);
        assert_eq!(st["account"], "my.1password.eu", "the account's region shows");
        assert_eq!(st["vaults"].as_array().unwrap().len(), 2);
        assert!(team.allowed_logins().await.unwrap_err().contains("No 1Password vault is allowed"), "none until the person picks");
        team.onepassword_set_vaults(vec!["v1".into(), "../x".into()]).unwrap();
        assert_eq!(team.onepassword().vaults, vec!["v1".to_string()], "only real vault ids are kept");
        let l = team.allowed_logins().await.unwrap();
        assert_eq!(l.iter().map(|x| x.title.as_str()).collect::<Vec<_>>(), ["GitHub"], "the private vault's Bank never shows");
        unsafe { std::env::remove_var("COOKIE_OP_BIN") };
        let _ = std::fs::remove_dir_all(&dir);
    }
}
