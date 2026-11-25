# Cookie privacy policy

*Last updated 25 November 2026. Cookie is in private use by its maker; this
policy says what the app does today, and will be reviewed before Cookie is
offered to anyone else.*

Cookie is a Mac app. Your agents, their conversations, their files and your
settings live in Cookie's folder on your Mac
(`~/Library/Application Support/com.enkeon.cookie.desktop`). Keys live in your
macOS Keychain under the service `com.enkeon.cookie`.

## What leaves your Mac, and when

| Where it goes | What | When |
|---|---|---|
| The model you choose for an agent (Anthropic, OpenAI, Google, AWS Bedrock, or Enkeon) | The agent's instructions, the job, and what its tools return | Every job that agent runs. Local models (Ollama) never leave the Mac. |
| Enkeon (when you sign in) | Each agent's memories, in its own space in your brain; what your connected apps sync there | As agents remember and recall |
| Enkeon cloud runs (only agents you allow) | The agent's name, job and routines; never files, notes, keys or the conversation | Once a minute while Cookie runs, so the cloud can run due routines while your Mac is off |
| Enkeon's store (off unless you turn it on) | Waiting approvals, notices and finished answers, as text | When they happen |
| Chats you link (Slack, Telegram, Discord, iMessage, Signal, …) | The messages you send and receive there | When you use them |
| Web search (Brave, Exa) | The words searched | When an agent searches |

Cookie has no analytics and no tracking. It does not sell or share your data.

## Crash reports

Off unless you turn them on (Settings → General). When on, a crash is written
to `crashes/` in Cookie's folder: what failed, where, the app version and the
OS. Home folder paths are shortened and anything shaped like a key is removed.
Reports are never sent anywhere; you can read, copy or clear them.

## Deleting your data

Settings → General → **Delete everything on this Mac** removes every agent,
conversation, memory ledger, file and setting in Cookie's folder, and every
key Cookie saved in the Keychain, then quits. Data in Enkeon (your brain and
its connected apps) is deleted in the Enkeon Console. An agent's own Slack app
is deleted in Slack when you take the agent out of Slack.

## Contact

Questions about this policy: the maintainer listed in the project's README.
