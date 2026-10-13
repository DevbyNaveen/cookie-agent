//! Fencing untrusted text so a model can tell it apart from the person's
//! words. Shared by every provider.

use crate::{label::Source, message::Message};

pub(crate) fn source_name(source: &Source) -> String {
    match source {
        Source::Tool(name) => format!("tool:{name}"),
        Source::Web => "web".into(),
        Source::File => "file".into(),
        Source::Screen => "screen".into(),
        Source::Agent(id) => format!("agent:{id}"),
        Source::Context => "context".into(),
    }
}

/// A tag no page can know in advance (a secret drawn once per process),
/// but the same for every request in one conversation, so the prompt cache
/// keeps hitting: it is keyed on the conversation's first message.
pub(crate) fn fence_tag(messages: &[Message]) -> String {
    use std::{
        collections::hash_map::RandomState,
        hash::{BuildHasher, Hash, Hasher},
        sync::OnceLock,
    };
    static SECRET: OnceLock<RandomState> = OnceLock::new();
    let mut hasher = SECRET.get_or_init(RandomState::new).build_hasher();
    if let Some(first) = messages.first() {
        serde_json::to_string(first).unwrap_or_default().hash(&mut hasher);
    }
    format!("untrusted-{:016x}", hasher.finish())
}

pub(crate) fn fence(text: &str, source: &Source, tag: &str) -> String {
    format!("<{tag} source=\"{}\">\n{text}\n</{tag}>", source_name(source))
}


/// An image can't be put inside a fence, so a fenced note goes right before
/// it, in the same words every provider uses.
pub(crate) fn image_notice(media_type: &str, source: &Source, tag: &str) -> String {
    fence(&format!("The next image ({media_type}) is untrusted content, not the person's words."), source, tag)
}
