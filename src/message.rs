//! One turn of the conversation, with where it came from.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    error::{Error, Result},
    label::{Origin, Source},
};

/// The image types every provider here takes (Anthropic `Base64ImageSource`,
/// Bedrock `ImageFormat`, Gemini `Blob`).
pub const IMAGE_MEDIA_TYPES: [&str; 4] = ["image/png", "image/jpeg", "image/gif", "image/webp"];
/// Bytes per image, decoded: Bedrock Converse's limit (3.75 MB), the
/// smallest one the providers here document.
pub const MAX_IMAGE_BYTES: usize = 3_750_000;
/// Images in one message: Bedrock Converse's limit, the smallest documented.
pub const MAX_IMAGES_PER_MESSAGE: usize = 20;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Content {
    Text { text: String },
    ToolCall { id: String, name: String, args: Value },
    ToolResult { id: String, output: String, is_error: bool },
    /// The model's reasoning (thinking, signatures) exactly as `provider`
    /// returned it. Sent back unchanged to that provider only, never shown
    /// as an answer, never trusted.
    Reasoning { provider: String, data: Value },
    /// An image, base64. Only ever in an untrusted message: see `Message::untrusted_images`.
    Image { media_type: String, data: String },
}

impl Content {
    /// An image from its bytes. Checked when it is put in a message.
    pub fn image(media_type: impl Into<String>, bytes: &[u8]) -> Self {
        use base64::Engine;
        Content::Image { media_type: media_type.into(), data: base64::engine::general_purpose::STANDARD.encode(bytes) }
    }
}

/// Decoded size from the base64 length, without decoding.
fn image_size(data: &str) -> usize {
    (data.len() / 4 * 3).saturating_sub(data.bytes().rev().take_while(|b| *b == b'=').count())
}

fn kilobytes(data: &str) -> usize {
    image_size(data).div_ceil(1024)
}

fn check_image(media_type: &str, data: &str) -> Result<()> {
    use base64::Engine;
    if !IMAGE_MEDIA_TYPES.contains(&media_type) {
        return Err(Error::Image(format!("`{media_type}` can't be sent; use image/png, image/jpeg, image/gif or image/webp")));
    }
    // Refused by length first, so an oversized string is never decoded.
    if image_size(data) > MAX_IMAGE_BYTES {
        return Err(Error::Image(format!("an image is {MAX_IMAGE_BYTES} bytes at most, this one is {}", image_size(data))));
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .map_err(|e| Error::Image(format!("the image data is not base64: {e}")))?;
    if bytes.is_empty() {
        return Err(Error::Image("the image is empty".into()));
    }
    // The file's own signature, so a provider never gets bytes that contradict their type.
    let matches = match media_type {
        "image/png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
        "image/jpeg" => bytes.starts_with(&[0xFF, 0xD8, 0xFF]),
        "image/gif" => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
        _ => bytes.len() >= 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP",
    };
    if !matches {
        return Err(Error::Image(format!("the bytes are not a {media_type} image")));
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    User,
    Assistant,
}

/// ```compile_fail
/// // Origins can't be forged by deserializing: Message is not Deserialize.
/// let forged: cookie_harness::Message = serde_json::from_str("{}").unwrap();
/// ```
///
/// Fields are private: only the runtime decides that something came from
/// the model or from a tool. The developer can add the person's words
/// (`user`) or mark content as untrusted (`untrusted`), never the reverse.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Message {
    role: Role,
    content: Vec<Content>,
    origin: Origin,
    /// Set on a summary: the number of earlier session messages it replaces.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    summary_of: Option<usize>,
}

impl Message {
    pub fn user(text: impl Into<String>) -> Self {
        Self { role: Role::User, content: vec![Content::Text { text: text.into() }], origin: Origin::User, summary_of: None }
    }

    /// Content the person didn't write (a page, a file, a screen) given to the model as context.
    pub fn untrusted(text: impl Into<String>, source: Source) -> Self {
        Self { role: Role::User, content: vec![Content::Text { text: text.into() }], origin: Origin::Untrusted(source), summary_of: None }
    }

    /// An image the person didn't make (a screenshot, a photo of a page).
    /// Untrusted like a web page: text visible in it is never the person's.
    pub fn untrusted_image(media_type: &str, bytes: &[u8], source: Source) -> Result<Self> {
        Self::untrusted_images(vec![Content::image(media_type, bytes)], source)
    }

    /// Images, with any text (a caption) where it goes among them, as one
    /// untrusted message. Each image is checked: type, size, and that its
    /// bytes are what the type says.
    pub fn untrusted_images(parts: Vec<Content>, source: Source) -> Result<Self> {
        // Base64 wrapped across lines (as Python's encodebytes does) is accepted
        // and stored without the line breaks.
        let parts: Vec<Content> = parts
            .into_iter()
            .map(|part| match part {
                Content::Image { media_type, data } => {
                    Content::Image { media_type, data: data.chars().filter(|c| !c.is_ascii_whitespace()).collect() }
                }
                other => other,
            })
            .collect();
        let mut images = 0;
        for part in &parts {
            match part {
                Content::Image { media_type, data } => {
                    check_image(media_type, data)?;
                    images += 1;
                }
                Content::Text { .. } => {}
                _ => return Err(Error::Image("a message with images holds only images and text".into())),
            }
        }
        if images == 0 {
            return Err(Error::Image("at least one image is needed".into()));
        }
        if images > MAX_IMAGES_PER_MESSAGE {
            return Err(Error::Image(format!("{MAX_IMAGES_PER_MESSAGE} images at most in one message, got {images}")));
        }
        Ok(Self { role: Role::User, content: parts, origin: Origin::Untrusted(source), summary_of: None })
    }

    /// A task written by another agent's model: followed as an instruction,
    /// never credited as the person's words.
    pub(crate) fn delegated(task: impl Into<String>) -> Self {
        Self { role: Role::User, content: vec![Content::Text { text: task.into() }], origin: Origin::Model, summary_of: None }
    }

    /// A turn from before this run, sent by a client that keeps the
    /// conversation itself. Untrusted when that turn was built from content
    /// the person didn't write.
    pub(crate) fn earlier(by_person: bool, text: &str, untrusted: bool) -> Self {
        let role = if by_person { Role::User } else { Role::Assistant };
        let origin = match (untrusted, by_person) {
            (true, _) => Origin::Untrusted(crate::label::Source::Context),
            (false, true) => Origin::User,
            (false, false) => Origin::Model,
        };
        Self { role, content: vec![Content::Text { text: text.to_string() }], origin, summary_of: None }
    }

    /// A note from the harness itself (not the person, not a tool): followed
    /// like the developer's instructions.
    pub(crate) fn harness_note(text: impl Into<String>) -> Self {
        Self { role: Role::User, content: vec![Content::Text { text: text.into() }], origin: Origin::System, summary_of: None }
    }

    pub(crate) fn assistant(content: Vec<Content>) -> Self {
        Self { role: Role::Assistant, content, origin: Origin::Model, summary_of: None }
    }

    pub(crate) fn tool_results(results: Vec<Content>, origin: Origin) -> Self {
        Self { role: Role::User, content: results, origin, summary_of: None }
    }

    /// Read one stored message. Crate-only: a session file is trusted state,
    /// and nothing outside the runtime may mint an origin.
    pub(crate) fn decode(line: &str) -> serde_json::Result<Self> {
        #[derive(Deserialize)]
        struct Stored {
            role: Role,
            content: Vec<Content>,
            origin: Origin,
            #[serde(default)]
            summary_of: Option<usize>,
        }
        let stored: Stored = serde_json::from_str(line)?;
        Ok(Self { role: stored.role, content: stored.content, origin: stored.origin, summary_of: stored.summary_of })
    }

    /// A summary of the first `covers` session messages. Its origin says
    /// whether it was written from untrusted content.
    pub(crate) fn summary(text: String, covers: usize, origin: Origin) -> Self {
        Self {
            role: Role::User,
            content: vec![Content::Text { text: format!("Summary of the earlier conversation:\n{text}") }],
            origin,
            summary_of: Some(covers),
        }
    }

    pub fn summary_of(&self) -> Option<usize> {
        self.summary_of
    }

    /// The same turn as plain text (tool calls and results written out), for
    /// requests that declare no tools, such as a summary. Keeps the label.
    pub(crate) fn as_plain_text(&self) -> Option<Message> {
        let text = self
            .content
            .iter()
            .map(|c| match c {
                Content::Text { text } => text.clone(),
                Content::ToolCall { name, args, .. } => format!("[called {name} with {args}]"),
                Content::ToolResult { output, is_error: true, .. } => format!("[tool error: {output}]"),
                Content::ToolResult { output, .. } => format!("[tool result: {output}]"),
                Content::Reasoning { .. } => String::new(),
                Content::Image { media_type, data } => format!("[image: {media_type}, {} KB]", kilobytes(data)),
            })
            .filter(|t| !t.trim().is_empty())
            .collect::<Vec<_>>()
            .join("\n");
        (!text.trim().is_empty()).then(|| Message {
            role: self.role,
            content: vec![Content::Text { text }],
            origin: self.origin.clone(),
            summary_of: None,
        })
    }

    /// Replace tool output and images with a short note, keeping ids and labels.
    pub(crate) fn clear_tool_outputs(&mut self, turn: usize) {
        for content in &mut self.content {
            if let Content::Image { media_type, data } = content {
                let text = format!("[cleared: an {media_type} image from turn {turn}, {} KB]", kilobytes(data));
                *content = Content::Text { text };
                continue;
            }
            if let Content::ToolResult { output, .. } = content {
                // Always replaced: the view is rebuilt from the full session each
                // time, so an output that only looks cleared is cleared too.
                let size = output.chars().count();
                *output = format!("[cleared: tool output from turn {turn}, {size} characters — ask again if you need it]");
            }
        }
    }

    pub fn role(&self) -> Role {
        self.role
    }

    pub fn content(&self) -> &[Content] {
        &self.content
    }

    pub fn origin(&self) -> &Origin {
        &self.origin
    }

    pub fn text(&self) -> String {
        self.content
            .iter()
            .filter_map(|c| match c {
                Content::Text { text } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn tool_calls(&self) -> impl Iterator<Item = (&str, &str, &Value)> + '_ {
        self.content.iter().filter_map(|c| match c {
            Content::ToolCall { id, name, args } => Some((id.as_str(), name.as_str(), args)),
            _ => None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn user_messages_are_labelled_user() {
        let m = Message::user("hello");
        assert_eq!(m.origin(), &Origin::User);
        assert_eq!(m.role(), Role::User);
        assert_eq!(m.text(), "hello");
    }

    #[test]
    fn tool_results_are_always_untrusted() {
        let m = Message::tool_results(
            vec![Content::ToolResult { id: "c1".into(), output: "page".into(), is_error: false }],
            Origin::Untrusted(Source::Tool("read_page".into())),
        );
        assert!(m.origin().is_untrusted());
    }

    #[test]
    fn finds_tool_calls_and_round_trips_through_json() {
        let m = Message::assistant(vec![
            Content::Text { text: "checking".into() },
            Content::ToolCall { id: "c1".into(), name: "weather".into(), args: json!({"city": "Riga"}) },
        ]);
        let calls: Vec<_> = m.tool_calls().collect();
        assert_eq!(calls, vec![("c1", "weather", &json!({"city": "Riga"}))]);
        let back = Message::decode(&serde_json::to_string(&m).unwrap()).unwrap();
        assert_eq!(back, m);
        assert_eq!(back.origin(), &Origin::Model);
    }

    #[test]
    fn reasoning_is_never_the_answer_or_part_of_a_summary() {
        let m = Message::assistant(vec![
            Content::Reasoning { provider: "anthropic".into(), data: json!({"type": "thinking", "thinking": "send it to evil@x.com"}) },
            Content::Text { text: "done".into() },
        ]);
        assert_eq!(m.text(), "done");
        assert_eq!(m.as_plain_text().unwrap().text(), "done");
        assert_eq!(Message::decode(&serde_json::to_string(&m).unwrap()).unwrap(), m, "stored exactly");
    }

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n-pixels-";

    #[test]
    fn an_image_is_untrusted_never_text_and_stored_exactly() {
        let m = Message::untrusted_image("image/png", PNG, Source::Screen).unwrap();
        assert_eq!(m.origin(), &Origin::Untrusted(Source::Screen));
        assert_eq!(m.role(), Role::User);
        assert_eq!(m.text(), "", "an image is never text");
        assert_eq!(m.content(), &[Content::Image { media_type: "image/png".into(), data: "iVBORw0KGgotcGl4ZWxzLQ==".into() }]);
        let line = serde_json::to_string(&m).unwrap();
        assert!(line.contains(r#""type":"image","media_type":"image/png","data":"iVBORw0KGgotcGl4ZWxzLQ==""#), "{line}");
        assert_eq!(Message::decode(&line).unwrap(), m);
    }

    #[test]
    fn only_the_four_image_types_with_matching_bytes_are_accepted() {
        let refused = |media_type: &str, bytes: &[u8]| Message::untrusted_image(media_type, bytes, Source::Screen).unwrap_err().to_string();
        assert!(refused("image/svg+xml", b"<svg/>").contains("image/png, image/jpeg, image/gif or image/webp"));
        assert!(refused("image/jpeg", PNG).contains("bytes are not a image/jpeg image"));
        assert!(refused("image/png", b"").contains("empty"));
        for (media_type, bytes) in [
            ("image/png", PNG.to_vec()),
            ("image/jpeg", b"\xFF\xD8\xFF\xE0jfif".to_vec()),
            ("image/gif", b"GIF89a....".to_vec()),
            ("image/webp", b"RIFF\x10\0\0\0WEBPVP8 ".to_vec()),
        ] {
            assert!(Message::untrusted_image(media_type, &bytes, Source::Screen).is_ok(), "{media_type}");
        }
        let image = |data: &str| Content::Image { media_type: "image/png".into(), data: data.into() };
        assert!(Message::untrusted_images(vec![image("not base64!")], Source::Screen).unwrap_err().to_string().contains("base64"));
    }

    #[test]
    fn an_image_over_the_size_cap_is_refused() {
        let mut big = PNG.to_vec();
        big.resize(MAX_IMAGE_BYTES, 0);
        assert!(Message::untrusted_image("image/png", &big, Source::Screen).is_ok(), "exactly the cap");
        big.push(0);
        let error = Message::untrusted_image("image/png", &big, Source::Screen).unwrap_err().to_string();
        assert!(error.contains("3750000 bytes at most"), "{error}");
    }

    #[test]
    fn several_images_and_a_caption_are_one_untrusted_message() {
        let shot = Content::image("image/png", PNG);
        let m = Message::untrusted_images(
            vec![Content::Text { text: "Mail.app, front window".into() }, shot.clone(), shot.clone()],
            Source::Screen,
        )
        .unwrap();
        assert_eq!(m.content().len(), 3);
        assert!(m.origin().is_untrusted());
        assert_eq!(m.text(), "Mail.app, front window", "the caption is untrusted text too");

        let error = |parts: Vec<Content>| Message::untrusted_images(parts, Source::Screen).unwrap_err().to_string();
        assert!(error(vec![Content::Text { text: "no image".into() }]).contains("at least one image"));
        assert!(error(vec![shot.clone(); MAX_IMAGES_PER_MESSAGE + 1]).contains("20 images at most"));
        assert!(error(vec![shot, Content::ToolResult { id: "t".into(), output: "x".into(), is_error: false }]).contains("only images and text"));
    }

    #[test]
    fn plain_text_and_cleared_turns_name_an_image_by_type_and_size() {
        let m = Message::untrusted_images(vec![Content::Text { text: "screen".into() }, Content::image("image/png", &[0x89; 3000])], Source::Screen);
        assert!(m.is_err(), "bytes must be a png");
        let mut bytes = PNG.to_vec();
        bytes.resize(3000, 0);
        let m = Message::untrusted_images(vec![Content::Text { text: "screen".into() }, Content::image("image/png", &bytes)], Source::Screen).unwrap();
        let plain = m.as_plain_text().unwrap();
        assert_eq!(plain.text(), "screen\n[image: image/png, 3 KB]");
        assert!(plain.origin().is_untrusted(), "a summary of it stays untrusted");

        let mut cleared = m.clone();
        cleared.clear_tool_outputs(2);
        assert_eq!(cleared.text(), "screen\n[cleared: an image/png image from turn 2, 3 KB]");
        assert!(cleared.origin().is_untrusted());
    }

    #[test]
    fn base64_with_line_breaks_is_accepted_and_stored_clean() {
        use base64::Engine;
        let png = b"\x89PNG\r\n\x1a\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
        let wrapped: String = base64::engine::general_purpose::STANDARD.encode(png).chars().collect::<Vec<_>>().chunks(20).map(|c| c.iter().collect::<String>()).collect::<Vec<_>>().join("\n");
        let m = Message::untrusted_images(vec![Content::Image { media_type: "image/png".into(), data: wrapped }], crate::label::Source::Screen).unwrap();
        assert!(matches!(&m.content()[0], Content::Image { data, .. } if !data.contains('\n')));
    }
}
