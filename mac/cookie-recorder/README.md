# cookie-recorder

Records a meeting on the Mac with no bot in the call. Your microphone and
the system audio (the call) go on two separate channels, each encoded to
Opus in an Ogg stream and uploaded to Enkeon's gateway
(`https://api.thinkingroot.com`) a minute at a time. Cookie spawns it.

The capture and encoding code is adapted from Enkeon's desktop app
(`thinkingrootdbcloud/apps/desktop/src-tauri/src/audio.rs`, `meeting.rs`,
`api.rs`).

## Interface

The bearer token is read from the environment variable `COOKIE_TOKEN`. It
never goes on argv and is never printed or logged. Every output is one JSON
line on stdout.

### record

```
COOKIE_TOKEN=… cookie-recorder record --project <project_id> --title <title> [--site <site>]
```

`--site` defaults to `desktop`. The command:

1. Starts the meeting: `POST /v1/projects/{project}/meetings` with `{"branch":"","site":…,"title":…}`.
2. Captures both channels and prints, about once a second:
   `{"state":"recording","meeting_id":"…","secs":12,"level":0.083}`.
   `level` is the microphone's peak, from 0 to 1.
3. Every 60 s it cuts each channel at an Ogg page boundary and uploads it:
   `POST …/meetings/{id}/chunk?channel=mic|tab&seq=N` (raw bytes).
4. Stops when it reads the line `stop` on stdin, or when stdin closes. It
   flushes the last partial minute (end of stream marked), calls
   `POST …/meetings/{id}/stop` with `{"duration_secs":…}`, then prints
   `{"state":"stopped","meeting_id":"…"}`.

Other lines:

- `{"state":"mic_only","meeting_id":"…","message":"system audio unavailable, recording the microphone only: …"}`
  means system audio could not be captured. Recording goes on with the
  microphone.
- `{"state":"error","message":"…"}` is any failure. Some examples: start
  refused, microphone missing, a chunk that did not upload, or stop refused.

Exit code: 0 if everything landed; 1 if anything was lost or a call failed;
2 for bad arguments or a missing token.

**Uploads and retries.** A request is retried on network errors, 408, 429
and 5xx: up to 5 attempts, with waits of 1, 2, 4 and 8 s (`api::retry_after`).
`seq` goes up only when a chunk lands, because the gateway appends a chunk
only when `seq` equals the count it already holds. A minute that still
fails after the retries stays in memory. It is sent in front of the next
minute under the same `seq`. Ogg pages are self-contained, so the joined
bytes are still a valid continuation. A retry may find that its chunk landed
earlier and only the answer was lost. The gateway then answers 409 "expected
chunk N+1", and that counts as landed. A failure that retrying cannot fix
(401, 403, a meeting that is no longer recording) stops the recording and
reports it. Pieces are kept under the gateway's 8 MiB `MAX_CHUNK_BYTES` and
split only at page boundaries.

`start` is repeated only when the gateway cannot have acted on it:
connection refused, 429 or 503. Otherwise a lost answer could leave an
orphan meeting. A `stop` whose answer was lost is repeated. If the repeat
gets 409, the recorder reads the meeting back to confirm it stopped.

### decide

```
COOKIE_TOKEN=… cookie-recorder decide --project <p> --meeting <id> --keep|--discard
```

Sends `POST …/meetings/{id}/decide` with `{"action":"keep"|"discard","names":{}}`
and prints the gateway's JSON (the meeting row). The gateway accepts this
only once the meeting is `ready`.

### get

```
COOKIE_TOKEN=… cookie-recorder get --project <p> --meeting <id>
```

Sends `GET …/meetings/{id}` and prints the gateway's JSON. When `state` is
`ready`, the row carries the transcript, summary and promises (the card).

Project and meeting ids must be `[A-Za-z0-9_-]`. Anything else is refused
before any request is sent.

## Permissions (macOS)

- **Microphone**: needed for the `mic` channel. Without it, `record` fails
  with an error line.
- **Screen Recording**: needed for the `tab` channel. System audio comes
  from ScreenCaptureKit, which asks for this permission even when it captures
  audio only. If it is refused, the recorder records the microphone only and
  says so in a `mic_only` line. It never fails silently.

macOS normally gives these permissions to the *responsible* app, here
Cookie, which spawns the helper. That means Cookie's `Info.plist` needs
`NSMicrophoneUsageDescription`, and the user grants Screen Recording to
Cookie. This is how TCC usually treats child processes. It has not been
tested with Cookie yet.

## Data handling

- Audio is held in memory only. The encoder keeps the current minute until
  it is cut. A minute that could not upload is held until it can be sent.
  Nothing is written to disk.
- Audio goes to one place only: the gateway, over HTTPS, with your bearer
  token.
- The gateway handles transcription. Quoting
  `thinkingrootdbcloud/services/gateway/src/chat/meetings.rs:7-10`: "On Stop
  the chunks are joined, uploaded to S3 in the same region, and Amazon
  Transcribe (eu-central-1, speaker partitioning on) turns each channel into
  utterances. The audio is then deleted: derived text is kept, the heavy
  binary is not."
- Nothing reaches the brain until you choose Keep (`decide --keep`). The
  same file says so at lines 15-17.

## Build and test

```
cargo build --release      # target/release/cookie-recorder (arm64, libopus linked statically)
cargo test                 # no test calls the real gateway; HTTP tests use a local 127.0.0.1 server
cargo clippy --all-targets
```

## Dependencies

These are the direct dependencies, read from `cargo metadata`:

| crate | version | licence |
|---|---|---|
| block2 | 0.6.2 | MIT |
| cpal | 0.17.3 | Apache-2.0 |
| objc2 | 0.6.5 | MIT |
| objc2-core-media | 0.3.2 | Zlib OR Apache-2.0 OR MIT |
| objc2-foundation | 0.3.2 | MIT |
| objc2-screen-capture-kit | 0.3.2 | Zlib OR Apache-2.0 OR MIT |
| ogg | 0.9.2 | BSD-3-Clause |
| opus | 0.4.0 | MIT/Apache-2.0 |
| reqwest (blocking, rustls) | 0.12.28 | MIT OR Apache-2.0 |
| serde_json | 1.0.154 | MIT OR Apache-2.0 |

Notable crates further down the tree:

| crate | version | licence | why it matters |
|---|---|---|---|
| opusic-sys | 0.7.5 | BSD-3-Clause | builds libopus (BSD-3-Clause) into the binary |
| ring | 0.17.14 | Apache-2.0 AND ISC | TLS cryptography |
| rustls | 0.23.45 | Apache-2.0 OR ISC OR MIT | TLS |
| webpki-roots | 1.0.9 | CDLA-Permissive-2.0 | root certificates |

The full tree of 205 crates has no copyleft-only licence. One crate is
offered under `MIT OR Apache-2.0 OR LGPL-2.1-or-later`, so you can take it
under MIT or Apache-2.0.

## Long meetings

An access token lives an hour. While recording, the parent can send `token <new access token>` on stdin; the next request uses it. `stop` ends the recording.
