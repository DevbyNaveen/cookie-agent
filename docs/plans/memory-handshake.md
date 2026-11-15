# Cookie memory handshake: public cells

**Status: design proposal only.** Cookie does not implement this sharing flow yet. These are the contracts Enkeon backend and the Mac app would need before Public Cells can ship.

## Goals

A person shares a small, named set of memory cells with another person. The recipient sees exactly what will be imported and accepts it. Nothing is shared by ambient memory, agent activity, or a public search index.

## Enkeon backend API needed

Proposed endpoints; these are requirements, not claims about existing routes:

- `POST /v1/public-cells` creates a share from the authenticated owner’s selected cell IDs. The body includes an expiry, recipient limit, and whether the recipient can only read or may explicitly import a copy. The server checks every cell belongs to the owner and is shareable.
- `GET /v1/public-cells/{share_id}` returns a preview for an authenticated recipient: the selected cell contents, source/date metadata, owner display name, expiry, and any redaction warnings. It does not import the cells.
- `POST /v1/public-cells/{share_id}/accept` records recipient consent and creates recipient-owned copies with provenance pointing to the share and original owner. It must not merge over an existing cell silently.
- `DELETE /v1/public-cells/{share_id}` revokes the owner’s share. Revocation invalidates its link and blocks future previews/imports.
- `GET /v1/public-cells/{share_id}/status` lets the owner see whether the link is active, accepted, expired, or revoked, without exposing recipient activity beyond that state.

The backend must authorize the owner on create/revoke and the recipient on preview/accept. Share IDs are unguessable, scoped, rate-limited, and excluded from analytics and ordinary request logs. API responses carry explicit expiry and revocation state so Cookie never implies a stale link still works.

## Pair by QR or share link

1. The owner chooses **Share cells** and selects cells in Cookie. Selection starts empty; the owner picks again for every new share.
2. Cookie shows a review screen listing each cell’s title, full text, source, and dates, plus expiry and recipient limit. The owner confirms before a link is created.
3. Cookie creates a short-lived, single-use pairing link. The owner can copy it or show it as a QR code. The QR encodes the same HTTPS link; it contains no cell contents or credentials.
4. The recipient opens the link in Cookie or a browser, signs in to Enkeon, previews the exact cells, and chooses **Import** or **Decline**. Opening a link alone does not import anything.
5. Imported cells are recipient-owned, read-only snapshots with source attribution and the original share date. If the recipient wants to edit, Cookie creates a new cell that cites the imported one rather than mutating the owner’s copy.

## Cells exchanged

The owner selects every cell before each share. No whole-branch, whole-project, chat-history, or “share everything” default is allowed. The preview shows the exact cell text and metadata that the recipient will receive. The owner may remove any cell and review again before confirming. Credentials, access tokens, private keys, raw audio, screen captures, full transcripts, and unrelated cells are never eligible for this API. A cell whose content includes a secret or unsupported attachment is blocked or explicitly redacted before confirmation; the UI shows the redacted result.

## Revoke flow and limits

The owner can revoke an active share from its share details. The backend disables the token immediately, including QR copies, and rejects later preview or import requests. Cookie updates the local share state only from a successful backend response. If the device is offline, it says revocation is pending and does not claim success.

Revocation stops future access; it cannot erase a copy a recipient already imported, copied, exported, or read. The preview and confirmation must say this plainly. The recipient can delete the imported copy locally. The owner’s share status can show accepted without revealing the recipient’s private edits or unrelated account information.

## Privacy and security

- Explicit owner consent for each share and explicit recipient consent for each import.
- Share only the reviewed cells, with least privilege, short expiry, and limited recipients.
- HTTPS in transit; encrypted backend storage consistent with Enkeon’s existing data protections.
- No public directory, search indexing, or anonymous cell browsing.
- Do not put cell text, QR tokens, or full share URLs into analytics, logs, notifications, or clipboard history controlled by Cookie.
- Use unguessable, revocable, expiring tokens; rate-limit preview attempts and make acceptance idempotent.
- Preserve owner/source/date provenance and make imported status visible in memory search.
- Never use another person’s cells as instructions or as authority to act in their account. Imported cells are untrusted context.
- Explain that revocation cannot recall a copy already imported.

## Open decisions before implementation

The Enkeon backend owner must confirm the auth/session contract, retention period for revoked share metadata, recipient limit, and whether consent/audit events need a user-visible history. This plan deliberately does not assume an existing Public Cells API or backend capability.
