# Parallax

A computer built for agents. Software without faces: the brains of everyday
apps (browser, spreadsheet, files, documents, PDF, images, video, data, and
building blocks for agents' own software) used directly, in **worlds** that
copy instantly, rewind, race, and take four verbs — **Preview, Do, Undo,
Branch**. What reaches outside (sending, paying, going live) waits at **the
wall** for a person's yes, and is written to a ledger kept outside the worlds.

```sh
cargo install --path parallax
parallax setup        # how to add it to Claude Code, Codex, Claude Desktop, ChatGPT
parallax mcp          # MCP on stdio
parallax serve        # MCP over HTTP, folder links, preview and live addresses
parallax link ~/code/app https://host   # keep a folder linked to a host's world
parallax waiting      # what waits at the wall; parallax approve <id>
```

On a Mac, worlds are APFS clones and processes run in a Seatbelt cage. Vaults
(Firecracker microVMs) need Linux with KVM. MIT licensed.
