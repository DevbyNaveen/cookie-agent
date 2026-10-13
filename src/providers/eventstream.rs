//! `application/vnd.amazon.eventstream`: the binary framing Bedrock's
//! ConverseStream answers in. Both checksums are checked on every message.

use crate::error::{Error, Result};

/// One message: its string headers and its payload.
#[derive(Debug, Clone, PartialEq)]
pub struct Frame {
    pub headers: Vec<(String, String)>,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(n, _)| n == name).map(|(_, v)| v.as_str())
    }
}

/// Turns bytes, split anywhere, into whole messages.
#[derive(Default)]
pub struct Decoder {
    pending: Vec<u8>,
}

/// The largest frame accepted.
const MAX_FRAME: usize = 16 * 1024 * 1024;

impl Decoder {
    pub fn feed(&mut self, chunk: &[u8]) -> Result<Vec<Frame>> {
        self.pending.extend_from_slice(chunk);
        let mut frames = Vec::new();
        while self.pending.len() >= 12 {
            let word = |at: usize| u32::from_be_bytes(self.pending[at..at + 4].try_into().expect("4 bytes"));
            if crc32(&self.pending[..8]) != word(8) {
                return Err(Error::Provider("event stream: the prelude checksum does not match".into()));
            }
            let (total, headers) = (word(0) as usize, word(4) as usize);
            // The event-stream spec caps headers at 128 KB; no reply frame is near 16 MB.
            if total > MAX_FRAME || headers > 128 * 1024 {
                return Err(Error::Provider(format!("event stream: a message of {total} bytes is too large")));
            }
            if total < 16 || headers > total - 16 {
                return Err(Error::Provider(format!("event stream: a message of {total} bytes with {headers} bytes of headers")));
            }
            if self.pending.len() < total {
                break;
            }
            let message: Vec<u8> = self.pending.drain(..total).collect();
            let expected = u32::from_be_bytes(message[total - 4..].try_into().expect("4 bytes"));
            if crc32(&message[..total - 4]) != expected {
                return Err(Error::Provider("event stream: the message checksum does not match".into()));
            }
            frames.push(Frame { headers: parse_headers(&message[12..12 + headers])?, payload: message[12 + headers..total - 4].to_vec() });
        }
        Ok(frames)
    }

    /// The stream closed: anything left over is a cut-off message.
    pub fn end(&mut self) -> Result<()> {
        if self.pending.is_empty() {
            Ok(())
        } else {
            Err(Error::Provider(format!("event stream: cut off inside a message ({} bytes left)", self.pending.len())))
        }
    }
}

/// String headers are kept; every other type is read past.
fn parse_headers(mut bytes: &[u8]) -> Result<Vec<(String, String)>> {
    let short = || Error::Provider("event stream: a header runs past its message".into());
    let take = |bytes: &mut &[u8], n: usize| -> Result<Vec<u8>> {
        if bytes.len() < n {
            return Err(short());
        }
        let (head, rest) = bytes.split_at(n);
        *bytes = rest;
        Ok(head.to_vec())
    };
    let mut headers = Vec::new();
    while !bytes.is_empty() {
        let name_len = take(&mut bytes, 1)?[0] as usize;
        let name = String::from_utf8(take(&mut bytes, name_len)?).map_err(|_| short())?;
        let kind = take(&mut bytes, 1)?[0];
        let fixed = match kind {
            0 | 1 => 0,
            2 => 1,
            3 => 2,
            4 => 4,
            5 | 8 => 8,
            9 => 16,
            6 | 7 => {
                let len = take(&mut bytes, 2)?;
                u16::from_be_bytes([len[0], len[1]]) as usize
            }
            other => return Err(Error::Provider(format!("event stream: unknown header type {other}"))),
        };
        let value = take(&mut bytes, fixed)?;
        if kind == 7 {
            headers.push((name, String::from_utf8(value).map_err(|_| short())?));
        }
    }
    Ok(headers)
}

/// CRC-32 (IEEE), as the framing specifies.
pub fn crc32(bytes: &[u8]) -> u32 {
    const TABLE: [u32; 256] = {
        let mut table = [0u32; 256];
        let mut i = 0;
        while i < 256 {
            let mut c = i as u32;
            let mut k = 0;
            while k < 8 {
                c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
                k += 1;
            }
            table[i] = c;
            i += 1;
        }
        table
    };
    !bytes.iter().fold(!0u32, |c, b| TABLE[((c ^ u32::from(*b)) & 0xFF) as usize] ^ (c >> 8))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::error::Error;

    /// A message with string headers, for tests. The checksum it uses is
    /// checked against an independent encoder below.
    pub(crate) fn frame(headers: &[(&str, &str)], payload: &[u8]) -> Vec<u8> {
        let mut encoded = Vec::new();
        for (name, value) in headers {
            encoded.push(name.len() as u8);
            encoded.extend_from_slice(name.as_bytes());
            encoded.push(7);
            encoded.extend_from_slice(&(value.len() as u16).to_be_bytes());
            encoded.extend_from_slice(value.as_bytes());
        }
        raw_frame(&encoded, payload)
    }

    fn raw_frame(headers: &[u8], payload: &[u8]) -> Vec<u8> {
        let total = (16 + headers.len() + payload.len()) as u32;
        let mut out = Vec::new();
        out.extend_from_slice(&total.to_be_bytes());
        out.extend_from_slice(&(headers.len() as u32).to_be_bytes());
        out.extend_from_slice(&crc32(&out).to_be_bytes());
        out.extend_from_slice(headers);
        out.extend_from_slice(payload);
        out.extend_from_slice(&crc32(&out).to_be_bytes());
        out
    }

    /// Encoded by Python's `zlib.crc32`, not by this crate.
    const MESSAGE_STOP: &str = "0000007a00000051ca2c46650b3a6576656e742d7479706507000b6d65737361676553746f700d3a636f6e74656e742d747970650700106170706c69636174696f6e2f6a736f6e0d3a6d6573736167652d747970650700056576656e747b2273746f70526561736f6e223a22656e645f7475726e227d5fbf09fc";

    fn unhex(hex: &str) -> Vec<u8> {
        (0..hex.len()).step_by(2).map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap()).collect()
    }

    #[test]
    fn crc32_is_the_standard_one() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
        assert_eq!(crc32(b""), 0);
    }

    #[test]
    fn decodes_a_message_fed_one_byte_at_a_time() {
        let bytes = unhex(MESSAGE_STOP);
        assert_eq!(bytes, frame(&[(":event-type", "messageStop"), (":content-type", "application/json"), (":message-type", "event")], b"{\"stopReason\":\"end_turn\"}"));
        let mut decoder = Decoder::default();
        let mut frames = Vec::new();
        for byte in bytes.iter().chain(bytes.iter()) {
            frames.extend(decoder.feed(std::slice::from_ref(byte)).unwrap());
        }
        decoder.end().unwrap();
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].header(":event-type"), Some("messageStop"));
        assert_eq!(frames[0].header(":message-type"), Some("event"));
        assert_eq!(frames[0].payload, b"{\"stopReason\":\"end_turn\"}");
    }

    #[test]
    fn every_header_type_is_read_past() {
        let mut headers = Vec::new();
        let mut add = |name: &str, kind: u8, value: &[u8]| {
            headers.push(name.len() as u8);
            headers.extend_from_slice(name.as_bytes());
            headers.push(kind);
            headers.extend_from_slice(value);
        };
        add("t", 0, &[]);
        add("f", 1, &[]);
        add("b", 2, &[1]);
        add("s", 3, &[0, 2]);
        add("i", 4, &[0, 0, 0, 3]);
        add("l", 5, &[0; 8]);
        add("y", 6, &[0, 2, 0xAB, 0xCD]);
        add("ts", 8, &[0; 8]);
        add("u", 9, &[0; 16]);
        add(":event-type", 7, &[0, 4, b't', b'e', b'x', b't']);
        let frames = Decoder::default().feed(&raw_frame(&headers, b"{}")).unwrap();
        assert_eq!(frames[0].headers, vec![(":event-type".to_string(), "text".to_string())]);
        let mut unknown = headers.clone();
        unknown.extend_from_slice(&[1, b'x', 10]);
        assert!(matches!(Decoder::default().feed(&raw_frame(&unknown, b"{}")), Err(Error::Provider(_))));
    }

    #[test]
    fn a_bad_checksum_or_a_cut_message_is_an_error() {
        let good = unhex(MESSAGE_STOP);
        let mut prelude = good.clone();
        prelude[9] ^= 1;
        assert!(matches!(Decoder::default().feed(&prelude), Err(Error::Provider(m)) if m.contains("prelude")));
        let mut body = good.clone();
        body[30] ^= 1;
        assert!(matches!(Decoder::default().feed(&body), Err(Error::Provider(m)) if m.contains("checksum")));
        let mut cut = Decoder::default();
        assert!(cut.feed(&good[..good.len() - 1]).unwrap().is_empty());
        assert!(matches!(cut.end(), Err(Error::Provider(_))));
        let mut short = good.clone();
        short[..4].copy_from_slice(&8u32.to_be_bytes());
        assert!(Decoder::default().feed(&short).is_err(), "shorter than a prelude and checksum");
    }

    #[test]
    fn a_frame_claiming_to_be_huge_is_refused_at_once() {
        let mut prelude = Vec::new();
        prelude.extend_from_slice(&(u32::MAX).to_be_bytes());
        prelude.extend_from_slice(&0u32.to_be_bytes());
        let crc = crc32(&prelude);
        prelude.extend_from_slice(&crc.to_be_bytes());
        assert!(Decoder::default().feed(&prelude).is_err());
    }
}
