//! Secrets out of what an agent reads. A key, token or password that comes
//! back in a tool result (a synced email, a page, an app's reply) is masked
//! before the model sees it, before it is written to the session file and
//! before it can travel anywhere a step goes. Short ones are masked whole;
//! long ones keep their first 6 and last 4 characters, so a person can still
//! tell which key it was. The person's own words are never redacted.
//!
//! What counts as a secret:
//! - a known key or token shape (`sk-…`, `ghp_…`, `xoxb-…`, `AKIA…`, `AIza…`,
//!   `glpat-…`, `tr_sk_…`, …),
//! - a JWT (`eyJ….….…`),
//! - the value after `Bearer`, or after a secret-named key (`api_key=`,
//!   `"password": "…"`, `token:`, a URL's `?access_token=`),
//! - a PEM private key block,
//! - a long random string: 48+ hex characters, or 32+ characters mixing
//!   upper case, lower case and digits with high entropy.
//!
//! Ids are not secrets: UUIDs, ULIDs, lowercase hex run ids, git SHAs and
//! ordinary words, paths and URLs pass through untouched.

use std::borrow::Cow;

/// Known secret prefixes, each with the shortest whole token that counts.
const PREFIXES: &[(&str, usize)] = &[
    ("sk-ant-", 20),
    ("sk-proj-", 20),
    ("sk_live_", 16),
    ("sk_test_", 16),
    ("rk_live_", 16),
    ("whsec_", 16),
    ("sk-", 20),
    ("ghp_", 20),
    ("gho_", 20),
    ("ghu_", 20),
    ("ghs_", 20),
    ("ghr_", 20),
    ("github_pat_", 30),
    ("glpat-", 20),
    ("xoxb-", 16),
    ("xoxp-", 16),
    ("xoxa-", 16),
    ("xoxr-", 16),
    ("xoxs-", 16),
    ("xapp-", 16),
    ("hf_", 20),
    ("npm_", 20),
    ("pypi-", 30),
    ("shpat_", 20),
    ("shpss_", 20),
    ("tr_sk_", 16),
    ("tr_em_", 16),
    ("tra_", 16),
    ("trr_", 16),
    ("AIza", 35),
    ("SG.", 30),
];

/// Names whose value is a secret: `name=value`, `"name": "value"`, `name: value`.
const SECRET_KEYS: &[&str] = &[
    "api_key", "apikey", "api-key", "x-api-key", "access_token", "refresh_token", "id_token", "auth_token", "token",
    "secret", "client_secret", "secret_key", "private_key", "password", "passwd", "pwd", "authorization", "session_token",
    "signature", "sig",
];

/// The characters a secret token is made of.
fn token_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | '/' | '+')
}

/// `text` with its secrets masked; borrowed when there were none.
pub fn secrets(text: &str) -> Cow<'_, str> {
    let text = private_keys(text);
    let mut out = String::with_capacity(text.len());
    let mut changed = false;
    let mut rest = text.as_ref();
    let mut before = String::new();
    while !rest.is_empty() {
        let start = rest.find(token_char).unwrap_or(rest.len());
        let (gap, tail) = rest.split_at(start);
        out.push_str(gap);
        before.push_str(gap);
        if tail.is_empty() {
            break;
        }
        let end = tail.find(|c: char| !token_char(c)).unwrap_or(tail.len());
        let (token, after) = tail.split_at(end);
        // A trailing full stop or comma closes the sentence, not the token.
        let core = token.trim_end_matches(['.', ',', '/', '-']);
        let trail = &token[core.len()..];
        if is_secret(core, &before) {
            out.push_str(&mask(core));
            out.push_str(trail);
            changed = true;
        } else {
            out.push_str(token);
        }
        // What came just before the next token: enough to see `api_key=`.
        before.push_str(token);
        if before.len() > 64 {
            let cut = before.char_indices().rev().nth(63).map_or(0, |(i, _)| i);
            before.drain(..cut);
        }
        rest = after;
    }
    match (changed, text) {
        (false, Cow::Borrowed(t)) => Cow::Borrowed(t),
        (false, Cow::Owned(t)) => Cow::Owned(t),
        (true, _) => Cow::Owned(out),
    }
}

/// Secrets in a JSON value's strings (its keys stay as they are).
pub fn value(v: &serde_json::Value) -> serde_json::Value {
    use serde_json::Value;
    match v {
        Value::String(s) => Value::String(secrets(s).into_owned()),
        Value::Array(a) => Value::Array(a.iter().map(value).collect()),
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| (k.clone(), value(x))).collect()),
        other => other.clone(),
    }
}

/// One `redact` line, for a client that keeps its own copies (step logs, stored
/// answers): `{text}` → `{text}` and/or `{value}` → `{value}`, secrets masked.
pub fn rpc(m: &serde_json::Value) -> std::result::Result<serde_json::Value, String> {
    let mut reply = serde_json::json!({});
    if let Some(text) = m.get("text").and_then(serde_json::Value::as_str) {
        reply["text"] = serde_json::json!(secrets(text));
    }
    if let Some(v) = m.get("value") {
        reply["value"] = value(v);
    }
    if reply.as_object().is_some_and(|o| o.is_empty()) {
        return Err("`redact` takes `text` or `value`".into());
    }
    Ok(reply)
}

fn mask(secret: &str) -> String {
    let n = secret.chars().count();
    if n < 24 {
        return "[secret removed]".to_string();
    }
    let head: String = secret.chars().take(6).collect();
    let tail: String = secret.chars().skip(n - 4).collect();
    format!("{head}…{tail}")
}

fn is_secret(token: &str, before: &str) -> bool {
    let n = token.chars().count();
    if n < 8 {
        return false;
    }
    if PREFIXES.iter().any(|(p, min)| token.starts_with(p) && n >= *min && token[p.len()..].chars().any(|c| c.is_ascii_alphanumeric())) {
        return true;
    }
    if aws_key_id(token) || jwt(token) {
        return true;
    }
    if after_secret_name(before) {
        return true;
    }
    random(token)
}

/// `AKIA…` / `ASIA…`: 20 upper-case letters and digits.
fn aws_key_id(t: &str) -> bool {
    t.len() == 20 && (t.starts_with("AKIA") || t.starts_with("ASIA")) && t.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
}

fn jwt(t: &str) -> bool {
    let parts: Vec<&str> = t.split('.').collect();
    parts.len() == 3
        && parts[0].starts_with("eyJ")
        && parts.iter().all(|p| p.len() >= 8 && p.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-'))
}

/// The token right after `Bearer `, `api_key=`, `"password": "`, `?token=`.
fn after_secret_name(before: &str) -> bool {
    let b = before.to_ascii_lowercase();
    if b.trim_end().ends_with("bearer") && b.ends_with(' ') {
        return true;
    }
    // The separator: `=` or `:`, with quotes and spaces around it.
    let trimmed = b.trim_end_matches(['"', '\'', ' ']);
    let Some(sep) = trimmed.chars().last().filter(|c| matches!(c, '=' | ':')) else { return false };
    let name = trimmed[..trimmed.len() - sep.len_utf8()].trim_end_matches(['"', '\'', ' ']);
    let word_start = name.rfind(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '-')).map_or(0, |i| i + 1);
    let word = &name[word_start..];
    SECRET_KEYS.iter().any(|k| word == *k || word.ends_with(&format!("_{k}")) || word.ends_with(&format!("-{k}")))
}

/// A long random string: hex of 48+, or 32+ characters mixing cases and
/// digits with high entropy. Paths, URLs and words are not random.
fn random(t: &str) -> bool {
    let n = t.chars().count();
    if t.contains("//") || t.matches('/').count() > 2 || t.matches('.').count() > 1 {
        return false;
    }
    if n >= 48 && t.chars().all(|c| c.is_ascii_hexdigit()) {
        return true;
    }
    if n < 32 {
        return false;
    }
    let (up, low, dig) = t.chars().fold((false, false, false), |(u, l, d), c| {
        (u || c.is_ascii_uppercase(), l || c.is_ascii_lowercase(), d || c.is_ascii_digit())
    });
    // Measured: random keys sit at 4.7–4.8 bits a character, long camel-case
    // identifiers near 4.0.
    up && low && dig && t.chars().filter(char::is_ascii_digit).count() >= 2 && entropy(t) >= 4.4
}

/// Shannon entropy, in bits per character.
fn entropy(t: &str) -> f64 {
    let mut counts = std::collections::HashMap::new();
    for c in t.chars() {
        *counts.entry(c).or_insert(0usize) += 1;
    }
    let n = t.chars().count() as f64;
    counts.values().map(|&k| {
        let p = k as f64 / n;
        -p * p.log2()
    }).sum()
}

/// PEM private key blocks, whole.
fn private_keys(text: &str) -> Cow<'_, str> {
    const BEGIN: &str = "-----BEGIN ";
    if !text.contains("PRIVATE KEY-----") {
        return Cow::Borrowed(text);
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(b) = rest.find(BEGIN) {
        let header_end = rest[b..].find("-----\n").or_else(|| rest[b + BEGIN.len()..].find("-----").map(|i| i + BEGIN.len()));
        let is_private = header_end.is_some_and(|h| rest[b..b + h].contains("PRIVATE KEY"));
        if !is_private {
            out.push_str(&rest[..b + BEGIN.len()]);
            rest = &rest[b + BEGIN.len()..];
            continue;
        }
        out.push_str(&rest[..b]);
        let after = &rest[b..];
        match after.find("-----END ").and_then(|e| after[e..].find("KEY-----").map(|k| e + k + "KEY-----".len())) {
            Some(end) => {
                out.push_str("[private key removed]");
                rest = &after[end..];
            }
            None => {
                out.push_str("[private key removed]");
                rest = "";
            }
        }
    }
    out.push_str(rest);
    Cow::Owned(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_keys_and_tokens_are_masked() {
        let cases = [
            "sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
            "sk-proj-AbCdEfGhIjKlMnOpQrStUvWx",
            "sk_live_51HxAbCdEfGhIjKl",
            "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
            "github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz",
            "xoxb-1234567890-abcdefABCDEF",
            "AKIAIOSFODNN7EXAMPLE",
            "AIzaSyA-abcdefghijklmnopqrstuvwxyz012345",
            "glpat-abcdefghijklmnopqrst",
            "tr_sk_9f8e7d6c5b4a3210",
            "sk-tinyfish-AbCd0123EfGh-4567IjKl_MnOpQrSt",
        ];
        for key in cases {
            let text = format!("The key is {key} for prod.");
            let out = secrets(&text);
            assert!(!out.contains(key), "{key} leaked: {out}");
            assert!(out.starts_with("The key is ") && out.ends_with(" for prod."), "{out}");
        }
    }

    #[test]
    fn long_secrets_keep_their_ends_short_ones_go_whole() {
        assert_eq!(secrets("ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"), "ghp_Ab…6789");
        assert_eq!(secrets("password=hunter2hunter2"), "password=[secret removed]");
    }

    #[test]
    fn values_after_secret_names_and_bearer_are_masked() {
        let out = secrets(r#"{"api_key": "1b2c3d4e-5f60-4a1b-8c2d-3e4f5a6b7c8d", "name": "Acme"}"#);
        assert!(!out.contains("1b2c3d4e-5f60-4a1b-8c2d-3e4f5a6b7c8d") && out.contains(r#""name": "Acme""#), "{out}");
        let out = secrets("Authorization: Bearer abcdefghijklmnop1234 then more");
        assert!(!out.contains("abcdefghijklmnop1234") && out.ends_with(" then more"), "{out}");
        let out = secrets("GET https://api.x.com/v1/items?limit=10&access_token=Zx81kq0Pa9LmTn44 ok");
        assert!(!out.contains("Zx81kq0Pa9LmTn44") && out.contains("limit=10"), "{out}");
        assert!(!secrets("DB_PASSWORD=s3cr3t-Value!").contains("s3cr3t-Value"));
    }

    #[test]
    fn jwts_private_keys_and_random_strings_are_masked() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
        assert!(!secrets(&format!("token {jwt}")).contains("dozjgNryP4J3"));
        let pem = "before\n-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nIBAAKC\n-----END RSA PRIVATE KEY-----\nafter";
        assert_eq!(secrets(pem), "before\n[private key removed]\nafter");
        assert!(!secrets("aws secret wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY99").contains("wJalrXUtnFEMI"));
        let hex64 = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
        assert!(!secrets(hex64).contains(hex64));
    }

    #[test]
    fn ids_words_paths_and_urls_pass_untouched() {
        let fine = [
            "Acme renews on 12 March for 5,000 EUR; Anna owns the account.",
            "Run 550e8400-e29b-41d4-a716-446655440000 finished.",
            "Memory 01M5J3D8SDMB3MZ7ZBCEFX19RJ was updated.",
            "Job ck_0ec0135180384d428c7abcd78d8b20c2 answered.",
            "Commit 4508d46f1e2a3b4c5d6e7f8091a2b3c4d5e6f708 on main.",
            "See https://www.techcrunch.com/2026/10/22/acme-raises-series-a-to-scale-ai-coding-agents/ today.",
            "Docs at /docs/getting-started/InstallationGuide2026Edition.md for setup.",
            "The skill-based approach is pseudoRandomButReadableCamelCaseIdentifier9 indeed.",
            "token: 5 tokens used",
            "Password policy: at least 12 characters.",
            "sk-learn is a library; xoxo means hugs.",
        ];
        for text in fine {
            assert_eq!(secrets(text), text, "changed: {text}");
        }
        assert!(matches!(secrets("nothing secret here"), Cow::Borrowed(_)));
    }

    #[test]
    fn the_rpc_masks_text_and_values() {
        let r = rpc(&serde_json::json!({"text": "key sk_live_51HxAbCdEfGhIjKl", "value": {"a": "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789"}})).unwrap();
        assert_eq!(r["text"], "key sk_liv…IjKl");
        assert_eq!(r["value"]["a"], "ghp_Ab…6789");
        assert!(rpc(&serde_json::json!({})).is_err());
    }

    #[test]
    fn json_strings_are_masked_and_keys_kept() {
        let v = serde_json::json!({"text": "use ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789", "n": 3, "list": ["sk_live_51HxAbCdEfGhIjKl"]});
        let out = value(&v);
        assert_eq!(out["text"], "use ghp_Ab…6789");
        assert_eq!(out["n"], 3);
        assert_eq!(out["list"][0], "sk_liv…IjKl");
    }
}
