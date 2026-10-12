//! Server-sent events, read per spec: bytes may arrive split anywhere
//! (inside a line or a character), lines end in CRLF, LF or a lone CR, and
//! an event's `data:` lines are joined by newlines. Shared by every
//! provider that streams over SSE.

use crate::error::{Error, Result};

#[derive(Default)]
pub(crate) struct SseDecoder {
    pending: Vec<u8>,
}

impl SseDecoder {
    /// The data of every event completed by this chunk. Events without data
    /// (comments, pings with no `data:`) are skipped.
    pub(crate) fn feed(&mut self, chunk: &[u8]) -> Result<Vec<String>> {
        self.pending.extend_from_slice(chunk);
        normalize_newlines(&mut self.pending);
        let mut out = Vec::new();
        // An event ends at a blank line; complete events are whole UTF-8.
        while let Some(at) = self.pending.windows(2).position(|w| w == b"\n\n") {
            let raw: Vec<u8> = self.pending.drain(..at + 2).collect();
            out.extend(data_of(&raw)?);
        }
        Ok(out)
    }

    /// The stream closed: a last event without its blank line still counts.
    pub(crate) fn end(&mut self) -> Result<Option<String>> {
        data_of(&std::mem::take(&mut self.pending))
    }
}

fn data_of(raw: &[u8]) -> Result<Option<String>> {
    let text = std::str::from_utf8(raw).map_err(|e| Error::Provider(format!("stream is not UTF-8: {e}")))?;
    let data: Vec<&str> = text
        .split('\n')
        .filter_map(|line| line.strip_prefix("data:"))
        .map(|d| d.strip_prefix(' ').unwrap_or(d).trim_end_matches('\r'))
        .collect();
    let data = data.join("\n");
    Ok((!data.trim().is_empty()).then_some(data))
}

/// SSE lines end in CRLF, LF or a lone CR; make them all LF. A CR at the very
/// end is kept, since its LF may arrive in the next chunk.
fn normalize_newlines(bytes: &mut Vec<u8>) {
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\r' if i + 1 == bytes.len() => {
                out.push(b'\r');
            }
            b'\r' if bytes[i + 1] == b'\n' => {
                out.push(b'\n');
                i += 1;
            }
            b'\r' => out.push(b'\n'),
            other => out.push(other),
        }
        i += 1;
    }
    *bytes = out;
}
