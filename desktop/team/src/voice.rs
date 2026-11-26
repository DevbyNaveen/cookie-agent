//! Voice: talk to your agents instead of typing, and hear them answer.
//!
//! Replies are spoken by ElevenLabs when a key is saved (the same voice and
//! model as Cookie for Mac: "Jessica" on `eleven_flash_v2_5`, or the voice
//! chosen in Settings); without one, the window uses the Mac's own voice.
//!
//! Speech becomes text on this computer when it can: `whisper-cli`
//! (whisper.cpp) with a model Cookie downloads once into its own folder, and
//! `ffmpeg` to read any recording. Nothing leaves the Mac. Without them, and
//! with an OpenAI key, Cookie uses OpenAI's transcription instead (and says
//! so). Reading replies aloud happens in the window itself (the system voice).
//!
//! Telegram voice notes go through the same path: local faster-whisper first,
//! the cloud as a fallback.

use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use base64::Engine as _;
use serde::{Deserialize, Serialize};

use crate::{util, Team};

/// The model downloaded for local transcription: whisper.cpp's multilingual
/// base model (148 MB): good on clear speech in many languages, fast on a Mac.
const MODEL_FILE: &str = "ggml-base.bin";
const MODEL_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin";
/// The longest recording accepted, in bytes (about 20 minutes of compressed speech).
const MAX_AUDIO: usize = 25 * 1024 * 1024;

/// ElevenLabs "Jessica" (playful, bright, warm), Cookie for Mac's default: a
/// premade voice, so it works on the free plan too.
const DEFAULT_VOICE: &str = "cgSgspJ2msm6clMCkdW9";
const DEFAULT_VOICE_NAME: &str = "Jessica";
/// ElevenLabs' fastest model, as on the Mac.
const TTS_MODEL: &str = "eleven_flash_v2_5";
const STT_MODEL: &str = "scribe_v2";
const ELEVEN: &str = "https://api.elevenlabs.io";
/// Where Cookie for Mac keeps its ElevenLabs key (login Keychain).
const MAC_SERVICE: &str = "com.enkeon.cookie.provider-keys";
const MAC_ACCOUNT: &str = "ELEVENLABS_API_KEY";
/// The longest text spoken in one call.
const MAX_SPEAK: usize = 4_000;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct VoicePrefs {
    #[serde(default)]
    voice: String,
    #[serde(default)]
    voice_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ElevenVoice {
    #[serde(rename = "voice_id")]
    pub id: String,
    pub name: String,
}

fn eleven_key() -> Option<String> {
    std::env::var("ELEVENLABS_API_KEY").ok().filter(|k| !k.trim().is_empty())
}

fn valid_voice(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric())
}

/// Cookie for Mac saved an ElevenLabs key (reads only the item's existence, never its value).
fn mac_key_exists() -> bool {
    cfg!(target_os = "macos")
        && std::process::Command::new("security")
            .args(["find-generic-password", "-s", MAC_SERVICE, "-a", MAC_ACCOUNT])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
}

#[derive(Debug, Clone, Serialize)]
pub struct VoiceStatus {
    /// Transcription on this computer is ready.
    pub local: bool,
    pub whisper: Option<String>,
    pub ffmpeg: Option<String>,
    pub model: Option<String>,
    /// An OpenAI key is set, so cloud transcription is possible.
    pub cloud: bool,
    /// An ElevenLabs key is set: replies are spoken by ElevenLabs, and it can write speech down.
    pub eleven: bool,
    /// The ElevenLabs voice that speaks.
    pub voice: String,
    pub voice_name: String,
    /// Cookie for Mac has an ElevenLabs key this app can take (when it has none).
    pub mac_key: bool,
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
        let eleven = eleven_key().is_some();
        let using = if local { Some("this Mac (whisper.cpp)".into()) } else if eleven { Some("ElevenLabs".into()) } else if cloud { Some("OpenAI".into()) } else { None };
        let (voice, voice_name) = self.voice_choice();
        VoiceStatus { local, whisper, ffmpeg, model, cloud, eleven, voice, voice_name, mac_key: !eleven && mac_key_exists(), using }
    }

    fn voice_choice(&self) -> (String, String) {
        let p: VoicePrefs = util::read_json(&self.paths.root.join("voice.json"));
        if valid_voice(&p.voice) {
            let name = if p.voice_name.is_empty() { "Your voice".to_string() } else { p.voice_name };
            (p.voice, name)
        } else {
            (DEFAULT_VOICE.into(), DEFAULT_VOICE_NAME.into())
        }
    }

    /// The voices on the ElevenLabs account, by name.
    pub async fn voice_voices(&self) -> Result<Vec<ElevenVoice>, String> {
        let key = eleven_key().ok_or("Add an ElevenLabs key first.")?;
        let resp = reqwest::Client::new()
            .get(format!("{ELEVEN}/v2/voices?page_size=100&sort=name&sort_direction=asc&include_total_count=false"))
            .header("xi-api-key", key)
            .timeout(Duration::from_secs(20))
            .send()
            .await
            .map_err(|e| format!("Couldn't reach ElevenLabs: {e}"))?;
        if !resp.status().is_success() {
            return Err(format!("ElevenLabs answered {}.", resp.status()));
        }
        #[derive(Deserialize)]
        struct Page {
            voices: Vec<ElevenVoice>,
        }
        let page: Page = resp.json().await.map_err(|e| e.to_string())?;
        Ok(page.voices.into_iter().filter(|v| valid_voice(&v.id)).collect())
    }

    /// Choose the voice that speaks; empty goes back to Jessica.
    pub fn voice_choose(&self, voice: &str) -> Result<VoiceStatus, String> {
        let (id, name) = voice.split_once('|').unwrap_or((voice, ""));
        let id = id.trim();
        if !id.is_empty() && !valid_voice(id) {
            return Err("That isn't an ElevenLabs voice id (letters and digits only).".into());
        }
        util::write_json(&self.paths.root.join("voice.json"), &VoicePrefs { voice: id.into(), voice_name: name.trim().chars().take(60).collect() })?;
        Ok(self.voice_status())
    }

    /// Take Cookie for Mac's ElevenLabs key. macOS asks once whether this app may read it.
    pub fn voice_use_mac_key(&self) -> Result<VoiceStatus, String> {
        let out = std::process::Command::new("security")
            .args(["find-generic-password", "-s", MAC_SERVICE, "-a", MAC_ACCOUNT, "-w"])
            .output()
            .map_err(|e| e.to_string())?;
        let key = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if !out.status.success() || key.is_empty() {
            return Err("Couldn't read Cookie for Mac's key (it may have been refused). Paste the key instead.".into());
        }
        self.keys.set_provider("elevenlabs", &key)?;
        Ok(self.voice_status())
    }

    /// Text to speech with ElevenLabs: MP3, as base64. Errors when there is no key,
    /// so the window falls back to the Mac's voice.
    pub async fn speak(&self, text: &str) -> Result<String, String> {
        let key = eleven_key().ok_or("No ElevenLabs key.")?;
        let text: String = text.trim().chars().take(MAX_SPEAK).collect();
        if text.is_empty() {
            return Err("Nothing to say.".into());
        }
        let (voice, _) = self.voice_choice();
        let resp = reqwest::Client::new()
            .post(format!("{ELEVEN}/v1/text-to-speech/{voice}?output_format=mp3_44100_128"))
            .header("xi-api-key", key)
            .json(&serde_json::json!({"text": text, "model_id": TTS_MODEL}))
            .timeout(Duration::from_secs(60))
            .send()
            .await
            .map_err(|e| format!("Couldn't reach ElevenLabs: {e}"))?;
        let status = resp.status();
        if !status.is_success() {
            let body: serde_json::Value = resp.json().await.unwrap_or_default();
            let why = body["detail"]["message"].as_str().or(body["detail"].as_str()).unwrap_or("").to_string();
            return Err(format!("ElevenLabs answered {status}{}", if why.is_empty() { String::new() } else { format!(": {why}") }));
        }
        let bytes = resp.bytes().await.map_err(|e| e.to_string())?;
        Ok(base64::engine::general_purpose::STANDARD.encode(bytes))
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
        if st.eleven {
            return transcribe_eleven(audio, &ext).await;
        }
        if st.cloud {
            return transcribe_openai(audio, &ext).await;
        }
        Err("Voice isn't set up. In Settings → Voice, download the speech model (works on this Mac, nothing leaves it), or add an ElevenLabs or OpenAI key.".into())
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

async fn transcribe_eleven(audio: &[u8], ext: &str) -> Result<String, String> {
    let key = eleven_key().ok_or("No ElevenLabs key.")?;
    let part = reqwest::multipart::Part::bytes(audio.to_vec()).file_name(format!("speech.{}", if ext.is_empty() { "webm" } else { ext }));
    let form = reqwest::multipart::Form::new().text("model_id", STT_MODEL).part("file", part);
    let resp = reqwest::Client::new()
        .post(format!("{ELEVEN}/v1/speech-to-text"))
        .header("xi-api-key", key)
        .multipart(form)
        .timeout(Duration::from_secs(300))
        .send()
        .await
        .map_err(|e| format!("Couldn't reach ElevenLabs: {e}"))?;
    let status = resp.status();
    let body: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!("ElevenLabs couldn't write it down ({status})."));
    }
    let text = body["text"].as_str().unwrap_or_default().trim().to_string();
    if text.is_empty() { Err("No speech was heard in that recording.".into()) } else { Ok(text) }
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
