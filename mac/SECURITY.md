# Cookie security

Cookie can see your screen, hear you, catch keys system-wide and (later) act
in your apps. That makes it a high-value target and a high-trust product.
This file is the threat model, what is built, and the rules every future
part must follow. Research behind it (with sources, 2026-10-12):
`thinkingrootdbcloud/research_notes/Cookie security 2026/`.

## Ground truth

Prompt injection is unsolved. On screen agents the best published model was
still steered 17.8% of the time on one attempt and 57% within 200 attempts
(Opus 4.6 system card, secondary source), and 12 published defences claiming
near-zero attack success fell to adaptive attacks at over 90%
(arxiv.org/abs/2510.09023). So Cookie is designed so that **a fooled model
cannot send, delete, pay or leak anything** without a deterministic check or
a person seeing the actual effect. Model-side defences are a second layer,
never the guarantee.

## Threats

| # | Threat | Where it enters |
|---|---|---|
| T1 | Instructions hidden in what's on screen (web page, email, PDF, image) steer Cookie | screenshots, circled area, attachments |
| T2 | Secrets on screen leave the Mac (passwords, card/bank numbers, API keys) | screenshots |
| T3 | Other people's personal data on screen leaves the Mac | screenshots |
| T4 | Chats read by another app or person on this Mac | chat storage |
| T5 | Code injected into Cookie inherits its screen, keyboard and Accessibility grants | dylib hijack, plugins, helpers |
| T6 | A sidecar (goose, Cua Driver, MCP server, Claude Code) misused | child processes, tool descriptions |
| T7 | Tampered update | updater |
| T8 | Stolen token used from another machine | gateway auth |
| T9 | Prompts/screenshots kept or reviewed by the model host | gateway, model route |

## Built (in this repo)

| Control | Threats | Where |
|---|---|---|
| Looks only on request: ⌃⌥ held, a message sent, or an area circled. Screenshots live in memory only, never on disk | T2, T3 | `CompanionManager.swift`, `CompanionScreenCaptureUtility.swift` |
| **Capture guard**: no picture while secure keyboard input is on anywhere (TN2150), while an `AXSecureTextField` is focused, or while a blocked app is in front. Cookie still answers from your words and says why it didn't look | T2 | `CookieSafety.swift` `CaptureGuard` |
| **Blocked apps cut out of every picture** (`SCContentFilter(excludingApplications:)`): 1Password, Bitwarden, KeePassXC, LastPass, Passwords, Keychain Access, plus any app the user adds. Cookie's own windows likewise | T2, T3 | `CookieSafety.swift`, `CompanionScreenCaptureUtility.swift` |
| **On-device redaction before upload**: Vision OCR finds card numbers (Luhn-checked), IBANs (mod-97-checked), API keys/tokens (OpenAI, Anthropic, AWS, GitHub, GitLab, Slack, Google, Enkeon), JWTs and PEM private keys and blacks them out; faces are blurred (detection only, never recognition). The reply's steps say how many items were hidden. A safeguard, not a guarantee — OCR can miss text | T2, T3 | `CookieSafety.swift` `Redactor`, `SensitiveText` |
| **Screen is data, never instructions**: every screenshot and circled area is labelled `UNTRUSTED screen content` (attachments `UNTRUSTED file content`); the system prompt says only the user's own words are instructions, never to repeat secrets or guess under black boxes, and never to put addresses from the screen into suggestions | T1 | `CompanionManager.swift` system prompt |
| **Suggestion chips** (which become your words when clicked) are dropped if long or containing a URL or `@` | T1 | `CompanionManager.extractNextSteps` |
| **No rendering path for exfiltration**: replies are plain text — no markdown images, no auto-loaded links (the EchoLeak class, CVE-2025-32711) | T1 | `CookieChat.swift` |
| **Chats encrypted at rest**: AES-256-GCM, key in the Keychain (data-protection keychain when entitled, otherwise the login keychain whose ACL is bound to Cookie's signature), folder 0700, file 0600. A plaintext file from before is sealed then overwritten and removed. An unreadable file is set aside, never overwritten | T4 | `CookieSafety.swift` `ChatVault`, `CookieModels.swift` |
| **Optional Touch ID** before chats show (peek, home, notices); relocks when the screen locks or after 15 minutes. Delete all chats in Settings | T4 | `CookieSafety.swift` `ChatLock`, `CookieSettings.swift` |
| **Voice stays on the Mac**: Apple speech with `requiresOnDeviceRecognition`; if on-device isn't available, Cookie refuses rather than sending audio to a server | T3 | `AppleSpeechTranscriptionProvider.swift` |
| **Hardened runtime, zero exception entitlements** (only `device.audio-input`); build fails if the runtime flag is missing; `--release` notarizes and staples | T5 | `build.sh`, `Cookie/Cookie.entitlements` |
| **Minimal event taps**: key tap is listen-only and logs nothing; the mouse tap that captures drags exists only while ⌃⌥ is held and is invalidated when Accessibility is revoked (a live tap after revocation can freeze input) | T5 | `GlobalPushToTalkShortcutMonitor.swift`, `CircleSelect.swift`, `CompanionManager.refreshAllPermissions` |
| **You always know when it looked**: the notch glints on every capture (plus macOS's own screen-recording indicator) | T2, T3 | `NotchIsland.swift` |
| **AI disclosure** (EU AI Act Art. 50, in force 2026-08-02): "Cookie is an AI and can be wrong" on the chat and in Settings | — | `CookieChat.swift`, `CookieSettings.swift` |
| No analytics, no API keys built into the app, no upstream endpoints. The person's own model key lives in the Keychain and reaches only the helper's environment, which is built from scratch (nothing inherited) | T8 | `CookieAnalytics.swift` (no-op), `HarnessClient.swift` `CookieModelSettings` |
| **Thinking runs in a bundled helper** (`cookie serve` from this repo's core, `Contents/Helpers/cookie`), signed with Cookie's identity and the hardened runtime, no entitlements. Screenshots (after the capture guard and redaction) go as the run's `images`, which the harness sends as one message marked untrusted, so text in a picture can never count as the person's words or pick a recipient. Cookie offers the model no tool that acts; anything needing a person shows an approval card, and no answer is no | T1, T5, T6 | `build.sh`, `HarnessClient.swift`, `CookieChat.swift` `ApprovalCard` |

## Binding rules for parts not built yet

These are requirements, not ideas. A part that can't meet them doesn't ship.

### Acting (click, type, send, delete, pay) — amended 2026-10-13 by the founder
Cookie operates the Mac when asked (founder decision 2026-10-13, Enkeon `01M4VAHWNJ8QAEQV9FTPMGSTC3`). The rules it does that under:
1. **A task is approved once.** Before Cookie acts on the screen, the person sees the plan in plain words and the apps it will touch, and says yes. Inside that task, `write` actions in those apps run without a card; any app not in the plan asks again. (Replaces the Rule of Two wording for screen tasks: the approved task is the person's decision; nothing outward is covered by it.)
2. Plan only from the person's words. A recipient, URL or amount read from the screen, a file or the web is **put to the person, marked "Not typed by you"** (harness `confirm_data`, approval `from_data`); it is never used unasked, never answered by earned trust or by "open without asking".
3. `outbound` (send, post, publish) and `destroy` (delete, pay, buy) always show the real effect — recipient, content, diff, amount — and never auto-earn on the trust ladder. Several in one turn come on one card, answered one by one.
4. Esc stops any task at once. Nothing is operated while secure input is on (`IsSecureEventInputEnabled`) or in a password field.
5. Banking, medical, payment and password-manager apps and sites are never operated (built-in list plus the person's own). Every action is written to an append-only log on the Mac, and actions are rate-limited.
6. Anything Cookie sends to another person says it was written with AI (Art. 50).

### Sidecars (goose, Cua Driver) and Claude Code
1. Built and signed by us from pinned commits; never downloaded at runtime.
2. Launch constraints so only Cookie can start them; XPC/stdio peers checked against our Team ID and identifier.
3. A child must not inherit Cookie's grants unchecked (Sparkle CVE-2025-10015 class): shell/exec tools off or gated per call.
4. goose: no recipes, no free-form extensions (CVE-2026-85623; Block red team 2026-01-15).
5. Claude Code: the user's own installed, signed-in binary, a minimum version, and **never** `--dangerously-skip-permissions` (abused by Nx "s1ngularity", 2025-08-26). Screen-derived text never flows into a code task unmarked.

### MCP connectors
1. Allow-list only; record a hash of each server's tool list and ask again when it changes (tool poisoning / rug pull).
2. Audience-bound, least-privilege tokens; no token passthrough (MCP security best practices).
3. Open authorization URLs only if `http(s)`, never via a shell (CVE-2025-6514 class); show the full command before running any local server.

### Updates
Sparkle ≥ 2.9.6, delivered as `.app` (never `.pkg`), EdDSA-signed feeds, no delta updates, signing key kept off CI.

### Sign-in and gateway
1. OAuth 2.1 + PKCE in the system browser, `iss` checked; refresh token in the Keychain, this device only.
2. Tokens bound to the device with DPoP (RFC 9449) using a Secure Enclave key; App Attest only where `isSupported`.
3. No certificate pinning (Cloudflare rotates edge certificates).
4. The gateway keeps no screenshot or prompt in logs and has no admin path to payloads (Apple PCC posture).

### Model route
Bedrock **EU geographic** inference profile, `data_retention_mode: none` enforced by policy, and a model whose terms allow zero retention (the research found Fable 5.x requires `aws_review`: up to 30 days and possible human review). Never the global profile.

### Enkeon memory
Saving to Enkeon is opt-in and shown per fact; screenshots are never stored there; screen-derived facts are marked as such.

## Privacy and law (EU)

Cookie is a GDPR controller (the household exemption doesn't cover a vendor — Recital 18). Before launch:
- **DPIA** (Art. 35): at least three WP248 criteria apply — new technology, highly personal data, people on screen who can't object.
- **Legitimate-interest balancing test** in writing for third parties on screen (EDPB Opinion 28/2024).
- Privacy policy: what is captured and when, redaction, retention (none for screenshots; chats local and encrypted), processors (gateway, model host, region), deletion.
- No emotion inference from screenshots in a work context (AI Act Art. 5).

## Residual risk

- A steered model can still give a wrong or manipulated *answer*. Labelling, prompt rules and redaction lower this; they don't remove it.
- OCR redaction can miss text (angled, tiny, stylised). The capture guard and blocked-app list are the first line.
- Screen Recording re-prompts monthly on macOS 26+; accepted rather than worked around.
- Login-keychain fallback for the chat key: another app can request the item, and macOS shows the user a prompt. The data-protection keychain arrives with a provisioning profile.
