//! One channel's upload bookkeeping: the next sequence number the gateway
//! expects, and the bytes it has not taken yet.
//!
//! The gateway appends each chunk to the channel's spool only when `seq`
//! equals the count it already holds (meetings.rs `meeting_chunk`, the
//! "expected chunk N" check). So `seq` advances only on a landed upload,
//! and a minute that could not upload is not dropped: it stays pending and
//! rides in front of the next minute under the same `seq`. Ogg pages are
//! self-contained, so the concatenation is still a valid continuation.

use crate::api::{Api, ApiError};

/// The gateway refuses chunks above this (meetings.rs `MAX_CHUNK_BYTES`).
pub const MAX_CHUNK_BYTES: usize = 8 * 1024 * 1024;

/// Split a run of whole Ogg pages into pieces of at most `max` bytes, each
/// ending on a page boundary. A minute of 32 kb/s Opus is ~240 KB, so this
/// only splits after a long outage has piled minutes up.
pub fn split_pages(bytes: &[u8], max: usize) -> Result<Vec<&[u8]>, String> {
    let mut pieces = Vec::new();
    let (mut start, mut at) = (0usize, 0usize);
    while at < bytes.len() {
        if bytes.len() - at < 27 || &bytes[at..at + 4] != b"OggS" {
            return Err(format!("not an Ogg page at byte {at}"));
        }
        let segs = bytes[at + 26] as usize;
        let table = bytes.get(at + 27..at + 27 + segs).ok_or("truncated Ogg page")?;
        let len = 27 + segs + table.iter().map(|&b| b as usize).sum::<usize>();
        if at + len > bytes.len() {
            return Err("truncated Ogg page".into());
        }
        if at + len - start > max && at > start {
            pieces.push(&bytes[start..at]);
            start = at;
        }
        at += len;
    }
    if at > start {
        pieces.push(&bytes[start..at]);
    }
    Ok(pieces)
}

/// The retry of a chunk that landed while its answer was lost: the gateway
/// already holds `seq` and now expects `seq + 1`.
pub fn landed(e: &ApiError, seq: u32) -> bool {
    matches!(e, ApiError::Http(409, m) if m.ends_with(&format!("expected chunk {}, got {seq}", seq + 1)))
}

pub struct Channel {
    pub name: &'static str,
    /// The next sequence number the gateway expects for this channel.
    pub seq: u32,
    pending: Vec<u8>,
}

impl Channel {
    pub fn new(name: &'static str) -> Self {
        Self { name, seq: 0, pending: Vec::new() }
    }

    // ponytail: held minutes grow without a cap (~240 KB per channel-minute,
    // ~29 MB for an hour-long outage on both channels); cap it if recordings
    // ever outlast the gateway's 4-hour MAX_DURATION_SECS.
    pub fn push(&mut self, bytes: &[u8]) {
        self.pending.extend_from_slice(bytes);
    }

    pub fn pending_bytes(&self) -> usize {
        self.pending.len()
    }

    /// Upload everything pending, in page-aligned pieces under the
    /// gateway's limit. On error the unsent remainder stays pending.
    pub fn flush(&mut self, api: &Api, project: &str, id: &str) -> Result<(), ApiError> {
        while !self.pending.is_empty() {
            let piece = {
                let pieces = split_pages(&self.pending, MAX_CHUNK_BYTES).map_err(ApiError::Net)?;
                pieces[0].to_vec()
            };
            match api.chunk(project, id, self.name, self.seq, piece.clone()) {
                Ok(_) => {}
                Err(e) if landed(&e, self.seq) => {}
                Err(e) => return Err(e),
            }
            self.seq += 1;
            self.pending.drain(..piece.len());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::mock::serve;
    use crate::audio::{OggOpus, FRAME};
    use std::time::Duration;

    fn chunks(n: usize) -> Vec<Vec<u8>> {
        let mut o = OggOpus::new(9).unwrap();
        let mut out = Vec::new();
        for i in 0..n {
            o.push(&vec![0.2; FRAME * 50]).unwrap();
            out.push(o.take(i + 1 == n).unwrap());
        }
        out
    }

    fn api(base: &str) -> Api {
        let mut a = Api::new(base, "t").unwrap();
        a.unit = Duration::from_millis(1);
        a
    }

    #[test]
    fn every_cut_is_whole_pages_and_splits_land_on_page_boundaries() {
        let cs = chunks(3);
        for c in &cs {
            let whole = split_pages(c, usize::MAX).unwrap();
            assert_eq!(whole.len(), 1, "a cut ends exactly on a page boundary");
            assert_eq!(whole[0].len(), c.len());
        }
        let all: Vec<u8> = cs.concat();
        let small = split_pages(&all, 600).unwrap();
        assert!(small.len() > 3);
        assert_eq!(small.concat(), all, "nothing lost or reordered");
        for p in &small {
            assert_eq!(&p[..4], b"OggS");
            assert!(p.len() <= 600 || split_pages(p, 0).unwrap().len() == 1, "over the cap only if it is one page");
        }
        assert!(split_pages(&all[..all.len() - 3], 600).is_err(), "a torn page is refused");
        assert!(split_pages(b"nope", 600).is_err());
    }

    #[test]
    fn landed_reads_only_the_next_seq() {
        assert!(landed(&ApiError::Http(409, "conflict: expected chunk 4, got 3".into()), 3));
        assert!(!landed(&ApiError::Http(409, "conflict: expected chunk 3, got 3".into()), 3));
        assert!(!landed(&ApiError::Http(409, "conflict: meeting is transcribing".into()), 3));
        assert!(!landed(&ApiError::Http(400, "expected chunk 4, got 3".into()), 3));
    }

    #[test]
    fn seq_advances_only_when_a_chunk_lands() {
        let cs = chunks(3);
        // minute 0 lands; minute 1 fails for good (403 is not retried);
        // minute 1+2 then land together under seq 1.
        let m = serve(vec![
            (200, "{}".into()),
            (403, r#"{"error":{"message":"forbidden: x"}}"#.into()),
            (200, "{}".into()),
        ]);
        let a = api(&m.base);
        let mut ch = Channel::new("mic");
        ch.push(&cs[0]);
        ch.flush(&a, "p", "m").unwrap();
        assert_eq!((ch.seq, ch.pending_bytes()), (1, 0));
        ch.push(&cs[1]);
        assert!(ch.flush(&a, "p", "m").is_err());
        assert_eq!((ch.seq, ch.pending_bytes()), (1, cs[1].len()), "kept, seq unchanged");
        ch.push(&cs[2]);
        ch.flush(&a, "p", "m").unwrap();
        assert_eq!((ch.seq, ch.pending_bytes()), (2, 0));
        let seen = m.seen.lock().unwrap();
        let targets: Vec<_> = seen.iter().map(|s| s.target.as_str()).collect();
        assert_eq!(
            targets,
            [
                "/v1/projects/p/meetings/m/chunk?channel=mic&seq=0",
                "/v1/projects/p/meetings/m/chunk?channel=mic&seq=1",
                "/v1/projects/p/meetings/m/chunk?channel=mic&seq=1",
            ]
        );
        assert_eq!(seen[2].body, [cs[1].clone(), cs[2].clone()].concat());
    }

    #[test]
    fn a_retry_that_finds_its_chunk_landed_moves_on() {
        let m = serve(vec![(502, "{}".into()), (409, r#"{"error":{"message":"conflict: expected chunk 1, got 0"}}"#.into())]);
        let mut ch = Channel::new("tab");
        ch.push(&chunks(1)[0]);
        ch.flush(&api(&m.base), "p", "m").unwrap();
        assert_eq!((ch.seq, ch.pending_bytes()), (1, 0));
    }
}
