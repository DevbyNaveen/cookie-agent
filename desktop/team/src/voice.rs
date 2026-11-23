//! Voice: talk to your agents instead of typing.
//!
//! Speech becomes text on this computer when it can: `whisper-cli`
//! (whisper.cpp) with a model Cookie downloads once into its own folder, and
//! `ffmpeg` to read any recording. Nothing leaves the Mac. Without them, and
//! with an OpenAI key, Cookie uses OpenAI's transcription instead (and says
//! so). Reading replies aloud happens in the window itself (the system voice).
//!
//! Telegram voice notes go through the same path. Adapted from Hermes Agent's
//! transcription design (local faster-whisper first, cloud as fallback; MIT).

use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use base64::Engine as _;
use serde::Serialize;

use crate::{util, Team};

/// The model downloaded for local transcription: whisper.cpp's multilingual
/// base model (148 MB): good on clear speech in many languages, fast on a Mac.
const MODEL_FILE: &str = "ggml-base.bin";
const MODEL_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin";
/// The longest recording accepted, in bytes (about 20 minutes of compressed speech).
const MAX_AUDIO: usize = 25 * 1024 * 1024;

#[derive(Debug, Clone, Serialize)]
pub struct VoiceStatus {
    /// Transcription on this computer is ready.
    pub local: bool,
    pub whisper: Option<String>,
    pub ffmpeg: Option<String>,
    pub model: Option<String>,
    /// An OpenAI key is set, so cloud transcription is possible.
    pub cloud: bool,
    /// Which one a recording would use now.
    pub using: Option<String>,
}

fn which(name: &str) -> Option<String> {
    let paths = std::env::var("PATH").unwrap_or_default();
    // A Mac app's PATH is short: also look where Homebrew installs.
    let extra = ["/opt/homebrew/bin", "/usr/local/bin"];
    let found = paths.split(':').chain(extra).map(|d| PathBuf::from(d).join(name)).find(|p| p.is_file());
    found.map(|p| p.to_string_lossy().to_string())
}

impl Team {
    fn model_path(&self) -> PathBuf {
        self.paths.root.join("models").join(MODEL_FILE)
    }

    pub fn voice_status(&self) -> VoiceStatus {
        let whisper = which("whisper-cli").or_else(|| which("whisper-cpp"));
        let ffmpeg = which("ffmpeg");
        let model = self.model_path().is_file().then(|| self.model_path().to_string_lossy().to_string());
        let local = whisper.is_some() && ffmpeg.is_some() && model.is_some();
        let cloud = std::env::var("OPENAI_API_KEY").is_ok_and(|k| !k.is_empty());
        let using = if local { Some("this Mac (whisper.cpp)".into()) } else if cloud { Some("OpenAI".into()) } else { None };
        VoiceStatus { local, whisper, ffmpeg, model, cloud, using }
    }

    /// Download the speech model once (148 MB) into Cookie's folder.
    pub async fn voice_setup(&self) -> Result<VoiceStatus, String> {
        let path = self.model_path();
        if !path.is_file() {
            std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
            let tmp = path.with_extension("part");
            let mut resp = reqwest::Client::new().get(MODEL_URL).timeout(Duration::from_secs(1800)).send().await.map_err(|e| format!("Couldn't download the speech model: {e}"))?;
            if !resp.status().is_success() {
                return Err(format!("The model download answered {}.", resp.status()));
            }
            let mut file = tokio::fs::File::create(&tmp).await.map_err(|e| e.to_string())?;
            use tokio::io::AsyncWriteExt;
            let mut got: u64 = 0;
            while let Some(chunk) = resp.chunk().await.map_err(|e| e.to_string())? {
                got += chunk.len() as u64;
                file.write_all(&chunk).await.map_err(|e| e.to_string())?;
            }
            file.flush().await.map_err(|e| e.to_string())?;
            if got < 50 * 1024 * 1024 {
                let _ = std::fs::remove_file(&tmp);
                return Err("The download was cut short; try again.".into());
            }
            std::fs::rename(&tmp, &path).map_err(|e| e.to_string())?;
        }
        Ok(self.voice_status())
    }

    /// Speech to text. `audio` is the recording's bytes; `ext` its kind (webm, ogg, m4a, wav…).
    pub async fn transcribe(&self, audio: &[u8], ext: &str) -> Result<String, String> {
        if audio.is_empty() {
            return Err("The recording is empty.".into());
        }
        if audio.len() > MAX_AUDIO {
            return Err("That recording is too long (over 25 MB).".into());
        }
        let ext: String = ext.chars().filter(|c| c.is_ascii_alphanumeric()).take(5).collect();
        let st = self.voice_status();
        if st.local {
            return self.transcribe_local(audio, &ext, &st).await;
        }
        if st.cloud {
            return transcribe_openai(audio, &ext).await;
        }
        Err("Voice isn't set up. In Settings → Voice, download the speech model (works on this Mac, nothing leaves it), or add an OpenAI key.".into())
    }

    async fn transcribe_local(&self, audio: &[u8], ext: &str, st: &VoiceStatus) -> Result<String, String> {
        let dir = std::env::temp_dir().join(format!("cookie-voice-{}", util::random_hex(6)));
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let input = dir.join(format!("in.{}", if ext.is_empty() { "bin" } else { ext }));
        let wav = dir.join("speech.wav");
        std::fs::write(&input, audio).map_err(|e| e.to_string())?;
        let result = async {
            let conv = tokio::process::Command::new(st.ffmpeg.as_deref().unwrap())
                .args(["-y", "-loglevel", "error", "-i"])
                .arg(&input)
                .args(["-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le"])
                .arg(&wav)
                .stdin(Stdio::null())
                .output()
                .await
                .map_err(|e| e.to_string())?;
            if !conv.status.success() {
                return Err(format!("Couldn't read the recording: {}", String::from_utf8_lossy(&conv.stderr).trim()));
            }
            let run = tokio::process::Command::new(st.whisper.as_deref().unwrap())
                .arg("-m")
                .arg(st.model.as_deref().unwrap())
                .arg("-f")
                .arg(&wav)
                .args(["-nt", "-l", "auto", "-np"])
                .stdin(Stdio::null())
                .kill_on_drop(true)
                .output();
            let out = tokio::time::timeout(Duration::from_secs(300), run).await.map_err(|_| "Transcribing took more than five minutes.".to_string())?.map_err(|e| e.to_string())?;
            if !out.status.success() {
                return Err(format!("whisper.cpp failed: {}", String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or("").trim()));
            }
            let text = String::from_utf8_lossy(&out.stdout).lines().map(str::trim).filter(|l| !l.is_empty() && *l != "[BLANK_AUDIO]").collect::<Vec<_>>().join(" ");
            if text.trim().is_empty() { Err("No speech was heard in that recording.".into()) } else { Ok(text.trim().to_string()) }
        }
        .await;
        let _ = std::fs::remove_dir_all(&dir);
        result
    }

    /// Speech to text from base64 (what the window and the HTTP API send).
    pub async fn transcribe_b64(&self, b64: &str, ext: &str) -> Result<String, String> {
        let bytes = base64::engine::general_purpose::STANDARD.decode(b64.trim()).map_err(|_| "The recording didn't arrive intact.".to_string())?;
        self.transcribe(&bytes, ext).await
    }
}

async fn transcribe_openai(audio: &[u8], ext: &str) -> Result<String, String> {
    let key = std::env::var("OPENAI_API_KEY").map_err(|_| "No OpenAI key.")?;
    let part = reqwest::multipart::Part::bytes(audio.to_vec()).file_name(format!("speech.{}", if ext.is_empty() { "webm" } else { ext }));
    let form = reqwest::multipart::Form::new().text("model", "gpt-4o-mini-transcribe").part("file", part);
    let resp = reqwest::Client::new()
        .post("https://api.openai.com/v1/audio/transcriptions")
        .bearer_auth(key)
        .multipart(form)
        .timeout(Duration::from_secs(300))
        .send()
        .await
        .map_err(|e| format!("Couldn't reach OpenAI: {e}"))?;
    let status = resp.status();
    let body: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!("OpenAI transcription failed: {}", body["error"]["message"].as_str().unwrap_or("unknown error")));
    }
    let text = body["text"].as_str().unwrap_or_default().trim().to_string();
    if text.is_empty() { Err("No speech was heard in that recording.".into()) } else { Ok(text) }
}
