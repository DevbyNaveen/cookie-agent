//! Secrets: model keys, the Telegram bot token, the runner's access token.
//!
//! On a Mac they live in the login Keychain (through `security`, so no
//! secret ever touches Cookie's folder). Elsewhere they live in one file,
//! readable by this user only (0600). Providers read keys from the
//! environment, as everywhere in the harness: at start, each saved model key
//! is put into this process's environment and nowhere else.

use std::path::{Path, PathBuf};

pub const SERVICE: &str = "com.enkeon.cookie";

/// The model keys Cookie knows how to save, with the variable each provider reads.
pub const PROVIDERS: &[(&str, &str, &str)] = &[
    ("anthropic", "Anthropic", "ANTHROPIC_API_KEY"),
    ("openai", "OpenAI", "OPENAI_API_KEY"),
    ("gemini", "Gemini", "GEMINI_API_KEY"),
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
    #[cfg_attr(target_os = "macos", allow(dead_code))]
    file: PathBuf,
}

impl Keys {
    pub fn new(dir: &Path) -> Self {
        Self { file: dir.join("secrets.json") }
    }

    pub fn get(&self, name: &str) -> Option<String> {
        #[cfg(target_os = "macos")]
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
        #[cfg(not(target_os = "macos"))]
        {
            let map: std::collections::BTreeMap<String, String> = crate::util::read_json(&self.file);
            map.get(name).cloned()
        }
    }

    pub fn set(&self, name: &str, value: &str) -> Result<(), String> {
        let value = value.trim();
        if value.is_empty() {
            return self.remove(name);
        }
        #[cfg(target_os = "macos")]
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
        #[cfg(not(target_os = "macos"))]
        {
            let mut map: std::collections::BTreeMap<String, String> = crate::util::read_json(&self.file);
            map.insert(name.to_string(), value.to_string());
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
        #[cfg(target_os = "macos")]
        {
            let _ = std::process::Command::new("security").args(["delete-generic-password", "-s", SERVICE, "-a", name]).output();
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
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
