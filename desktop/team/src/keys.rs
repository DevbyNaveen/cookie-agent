//! Secrets: model keys, the Telegram bot token, the runner's access token.
//!
//! On a Mac they live in the login Keychain (through `security`, so no
//! secret ever touches Cookie's folder). Elsewhere they live in one file,
//! readable by this user only (0600). On a server, where the team runs in the
//! cloud beside its worlds and keeps working with the person's Mac closed,
//! that file is sealed: with `COOKIE_SECRETS_KEY` set (32 bytes, base64, from
//! the host's key service, never on the same disk) every value is encrypted
//! with AES-256-GCM, so a copy of the disk or a backup holds no usable key.
//! Tests always use the file, inside their own folder: they never touch the
//! person's real Keychain. Providers read keys from the
//! environment, as everywhere in the harness: at start, each saved model key
//! is put into this process's environment and nowhere else.

use std::path::{Path, PathBuf};

pub const SERVICE: &str = "com.enkeon.cookie";

/// The model keys Cookie knows how to save, with the variable each provider reads.
pub const PROVIDERS: &[(&str, &str, &str)] = &[
    ("anthropic", "Anthropic", "ANTHROPIC_API_KEY"),
    ("openai", "OpenAI", "OPENAI_API_KEY"),
    ("gemini", "Gemini", "GEMINI_API_KEY"),
    // Models from every lab behind one key (`openrouter:anthropic/claude-sonnet-4.5`).
    ("openrouter", "OpenRouter", "OPENROUTER_API_KEY"),
    // Amazon Bedrock with your own AWS account (models like `bedrock:eu.anthropic.claude-sonnet-4-6`).
    ("bedrock", "AWS Bedrock: access key ID", "AWS_ACCESS_KEY_ID"),
    ("bedrock_secret", "AWS Bedrock: secret access key", "AWS_SECRET_ACCESS_KEY"),
    ("bedrock_region", "AWS Bedrock: region (for models without eu./us.)", "AWS_REGION"),
    ("exa", "Exa search", "EXA_API_KEY"),
    ("brave", "Brave search", "BRAVE_SEARCH_API_KEY"),
    ("elevenlabs", "ElevenLabs voice", "ELEVENLABS_API_KEY"),
    // Images and video made with Higgsfield (`media`): a key ID and its secret, from console.higgsfield.ai.
    ("higgsfield", "Higgsfield: API key ID", "HF_API_KEY_ID"),
    ("higgsfield_secret", "Higgsfield: API key secret", "HF_API_KEY_SECRET"),
];

pub struct Keys {
    /// The fallback file when there is no Keychain.
    #[cfg_attr(all(target_os = "macos", not(test)), allow(dead_code))]
    file: PathBuf,
}

impl Keys {
    pub fn new(dir: &Path) -> Self {
        Self { file: dir.join("secrets.json") }
    }

    pub fn get(&self, name: &str) -> Option<String> {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            let out = std::process::Command::new("security")
                .args(["find-generic-password", "-s", SERVICE, "-a", name, "-w"])
                .output()
                .ok()?;
            if out.status.success() {
                let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
                return (!v.is_empty()).then_some(v);
            }
            None
        }
        #[cfg(any(not(target_os = "macos"), test))]
        {
            let map: std::collections::BTreeMap<String, String> = crate::util::read_json(&self.file);
            map.get(name).and_then(|v| sealed::open(v))
        }
    }

    pub fn set(&self, name: &str, value: &str) -> Result<(), String> {
        let value = value.trim();
        if value.is_empty() {
            return self.remove(name);
        }
        #[cfg(all(target_os = "macos", not(test)))]
        {
            // -U updates an existing item; the value goes in as an argument to a
            // child process, never through a shell.
            let st = std::process::Command::new("security")
                .args(["add-generic-password", "-U", "-s", SERVICE, "-a", name, "-w", value])
                .status()
                .map_err(|e| e.to_string())?;
            if !st.success() {
                return Err("The Keychain refused to save it.".into());
            }
            Ok(())
        }
        #[cfg(any(not(target_os = "macos"), test))]
        {
            let mut map: std::collections::BTreeMap<String, String> = crate::util::read_json(&self.file);
            map.insert(name.to_string(), sealed::seal(value)?);
            crate::util::write_json(&self.file, &map)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = std::fs::set_permissions(&self.file, std::fs::Permissions::from_mode(0o600));
            }
            Ok(())
        }
    }

    pub fn remove(&self, name: &str) -> Result<(), String> {
        #[cfg(all(target_os = "macos", not(test)))]
        {
            let _ = std::process::Command::new("security").args(["delete-generic-password", "-s", SERVICE, "-a", name]).output();
            Ok(())
        }
        #[cfg(any(not(target_os = "macos"), test))]
        {
            let mut map: std::collections::BTreeMap<String, String> = crate::util::read_json(&self.file);
            map.remove(name);
            crate::util::write_json(&self.file, &map)
        }
    }

    /// Put every saved model and search key into this process's environment,
    /// unless the environment already has one (a key you exported wins).
    pub fn load_into_env(&self) {
        for (name, _, var) in PROVIDERS {
            if std::env::var(var).is_ok_and(|v| !v.is_empty()) {
                continue;
            }
            if let Some(v) = self.get(name) {
                // Called once at start, before agents (which read it) are built.
                std::env::set_var(var, v);
            }
        }
    }

    /// Which providers have a key right now (names only, never values).
    pub fn present() -> Vec<&'static str> {
        PROVIDERS.iter().filter(|(_, _, var)| std::env::var(var).is_ok_and(|v| !v.is_empty())).map(|(n, _, _)| *n).collect()
    }

    /// Save a key and make it live for this run at once.
    pub fn set_provider(&self, name: &str, value: &str) -> Result<(), String> {
        let (_, _, var) = PROVIDERS.iter().find(|(n, _, _)| *n == name).ok_or("Cookie doesn't know that provider.")?;
        self.set(name, value)?;
        // Providers read the variable only when an agent is built, after this returns.
        if value.trim().is_empty() {
            std::env::remove_var(var)
        } else {
            std::env::set_var(var, value.trim())
        }
        Ok(())
    }
}

/// Sealing values in the key file, when the host gives a key to seal with.
#[cfg_attr(all(target_os = "macos", not(test)), allow(dead_code))]
pub(crate) mod sealed {
    use base64::Engine;
    use ring::aead::{Aad, LessSafeKey, Nonce, UnboundKey, AES_256_GCM, NONCE_LEN};
    use ring::rand::{SecureRandom, SystemRandom};

    /// What marks a sealed value: `v1:` then base64 of nonce and ciphertext.
    const PREFIX: &str = "sealed:v1:";

    fn key() -> Option<LessSafeKey> {
        let raw = std::env::var("COOKIE_SECRETS_KEY").ok()?;
        let bytes = base64::engine::general_purpose::STANDARD.decode(raw.trim()).ok().filter(|b| b.len() == 32)?;
        Some(LessSafeKey::new(UnboundKey::new(&AES_256_GCM, &bytes).ok()?))
    }

    /// The value as stored: sealed when there is a key, as it is otherwise.
    pub fn seal(value: &str) -> Result<String, String> {
        seal_with(key().as_ref(), value)
    }

    pub(super) fn seal_with(key: Option<&LessSafeKey>, value: &str) -> Result<String, String> {
        let Some(key) = key else { return Ok(value.to_string()) };
        let mut nonce = [0u8; NONCE_LEN];
        SystemRandom::new().fill(&mut nonce).map_err(|_| "no randomness to seal with")?;
        let mut data = value.as_bytes().to_vec();
        key.seal_in_place_append_tag(Nonce::assume_unique_for_key(nonce), Aad::from(PREFIX), &mut data).map_err(|_| "sealing failed")?;
        let mut out = nonce.to_vec();
        out.extend(data);
        Ok(format!("{PREFIX}{}", base64::engine::general_purpose::STANDARD.encode(out)))
    }

    /// The value as it was given; `None` for a sealed value without the key
    /// that sealed it (never the sealed text passed off as a key).
    pub fn open(stored: &str) -> Option<String> {
        open_with(key().as_ref(), stored)
    }

    pub(super) fn open_with(key: Option<&LessSafeKey>, stored: &str) -> Option<String> {
        let Some(b64) = stored.strip_prefix(PREFIX) else { return Some(stored.to_string()) };
        let key = key?;
        let mut bytes = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
        if bytes.len() <= NONCE_LEN {
            return None;
        }
        let mut data = bytes.split_off(NONCE_LEN);
        let nonce = Nonce::try_assume_unique_for_key(&bytes).ok()?;
        let plain = key.open_in_place(nonce, Aad::from(PREFIX), &mut data).ok()?;
        String::from_utf8(plain.to_vec()).ok()
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn k(byte: u8) -> LessSafeKey {
            LessSafeKey::new(UnboundKey::new(&AES_256_GCM, &[byte; 32]).unwrap())
        }

        #[test]
        fn a_sealed_key_opens_only_with_the_key_that_sealed_it() {
            let stored = seal_with(Some(&k(7)), "sk-ant-secret").unwrap();
            assert!(stored.starts_with(PREFIX) && !stored.contains("sk-ant"), "nothing readable on disk");
            assert_eq!(open_with(Some(&k(7)), &stored).as_deref(), Some("sk-ant-secret"));
            assert_eq!(open_with(Some(&k(8)), &stored), None, "another key opens nothing");
            assert_eq!(open_with(None, &stored), None, "no key: no value, not the sealed text");
            assert_ne!(seal_with(Some(&k(7)), "x").unwrap(), seal_with(Some(&k(7)), "x").unwrap(), "a fresh nonce each time");
        }

        #[test]
        fn without_a_host_key_values_are_kept_as_before() {
            assert_eq!(seal_with(None, "plain").unwrap(), "plain");
            assert_eq!(open_with(None, "plain").as_deref(), Some("plain"), "an older file still reads");
        }
    }
}
