# cookie-py

Cookie's Python tools, served as an MCP server over stdio (newline-delimited
JSON-RPC 2.0, standard library only, no MCP SDK). Cookie starts it with the
bundled interpreter and connects to it through its core
(`McpServer::stdio`), which speaks MCP `2025-06-18` / `2025-03-26` /
`2024-11-05`; the server answers with the client's version when it is one of
those, else `2025-06-18`.

```sh
scripts/bundle-python.sh                         # builds vendor/python (pinned, hash-checked)
vendor/python/bin/python3 -I -B cookie-py/server.py --root ~/Documents/Cookie
```

Always run with `-I` (ignore `PYTHON*` env vars, user site, cwd) and `-B`
(write no `.pyc` — inside a signed app a new file would break the seal).

## Tools

| Tool | Arguments | Returns (JSON text) |
|---|---|---|
| `fetch_page` | `url`, `max_chars` (default 20000) | `url`, `final_url`, `title`, `fetched_at` (UTC ISO), `sha256` (of the full extracted text), `chars`, `truncated`, `text`, and a `note` when truncated |
| `fetch_pages` | `urls` (1–5), `max_chars` | `results`: one per URL, each `ok: true` + the above or `ok: false` + `error` |
| `check_quote` | `url`, `quote` | `found`, `occurrences`, `sentence` (the sentence(s) around it), the normalised `quote`, `from_cache`, `fetched_at`, `sha256` |
| `make_deck` | `path`, `title`, `subtitle?`, `overwrite?`, `slides: [{title, bullets?, notes?, chart?, table?}]` | `path`, `slides`, `bytes` |

- **Fetching** is static HTTP (no JavaScript). Text is extracted with
  Scrapling's parser (`scrapling.parser.Selector`): the title from `<title>`,
  then `og:title`, then `<h1>`; the text from the largest `article` / `main` /
  `[role=main]` region, or — if that has under 200 characters — all visible
  body text. Scripts, styles, nav, header, footer, aside and forms are left out.
  Only `text/html`, `application/xhtml+xml` and `text/plain` are accepted.
- **check_quote** compares after Unicode NFC and collapsing every run of
  whitespace to one space; it is case-sensitive and otherwise exact. It checks
  the very text `fetch_page` returned earlier in this process (an in-process
  cache of the last 64 URLs) and fetches only when the URL is not cached.
- **make_deck** uses python-pptx's default template (4:3). Bullet-only slides
  use "Title and Content"; a slide with a chart or a table uses "Title Only",
  with any bullets in a left column. Charts are native PowerPoint charts
  (`column` → clustered column, `bar` → clustered bar, `line` → line with
  markers, `pie` → pie with percentage labels), so their data stays editable.
  A slide holds a chart or a table, not both.

Tool failures come back as a normal result with `isError: true` and a sentence
saying why; an unknown tool is a JSON-RPC `-32602` error.

## Safety

Fetching (every hop):
- `http`/`https` only; no user name or password in the URL.
- The host is resolved and **every** returned address must be public. Refused:
  0.0.0.0/8, loopback (127/8, ::1), RFC 1918 (10/8, 172.16/12, 192.168/16),
  CGNAT 100.64/10, link-local 169.254/16 (incl. 169.254.169.254 metadata) and
  fe80::/10, unique-local fc00::/7, multicast (224/4, ff00::/8), ::, and
  anything else Python's `ipaddress` does not call global (documentation,
  benchmarking, reserved ranges). IPv4 inside IPv6 (`::ffff:a.b.c.d`, 6to4,
  64:ff9b::/96) is judged as that IPv4 address.
- The connection goes to the address that was checked — the name is never
  resolved again (no DNS rebinding). TLS verifies the certificate against the
  host name.
- Redirects are not followed automatically: each `Location` is re-checked as
  above, at most 5 hops.
- 5 MB cap on the body (declared, streamed, and after gzip/deflate
  decompression); 20 s for the whole fetch including redirects;
  User-Agent `Cookie/0.1 (+https://enkeon.com)`.

Files (`make_deck`):
- Writes only inside the folders given as `--root` (repeatable; none = no
  writes). The path must be absolute, end in `.pptx`, contain no `..`; its
  folder must exist and is resolved with `realpath`, so a symlinked folder
  cannot lead outside; the file itself may not be a symlink.
- An existing file is replaced only with `overwrite: true` (written to a
  temporary file and renamed over it). Without it the file is created with
  `O_EXCL | O_NOFOLLOW`, so a file that appears meanwhile is never clobbered.
- No shell, no `eval`, no subprocess.

## Tests

```sh
vendor/python/bin/python3 -I -B -m unittest discover -s cookie-py -v
COOKIE_LIVE=1 vendor/python/bin/python3 -I -B cookie-py/test_live.py -v   # touches the network
```

The offline suite uses a fake resolver and transport (no network): every
blocked range, redirects into private space, scheme and credential refusals,
the 5 MB cap (against a local server, plain and chunked), extraction, quote
normalisation, path confinement, deck round-trip through python-pptx, and an
MCP round-trip with `server.py` as a subprocess.

## Licences

Verified from the installed package metadata (`importlib.metadata`) and, for
the runtime, the upstream repository:

| Component | Version | Licence |
|---|---|---|
| CPython | 3.12.15 | PSF License (`lib/python3.12/LICENSE.txt`) |
| python-build-standalone | release 20261009 | MPL-2.0 (the build tooling; the archive also contains statically linked third-party libraries, e.g. OpenSSL 3.5.9, whose licences ship with the project's full archives — check before release) |
| scrapling | 0.4.15 | BSD-3-Clause |
| python-pptx | 1.0.2 | MIT |
| lxml | 6.1.3 | BSD-3-Clause (exceptions and statically linked libxml2/libxslt: see its `LICENSES.txt`) |
| cssselect | 1.6.0 | BSD-3-Clause |
| w3lib | 2.5.0 | BSD-3-Clause |
| orjson | 3.13.0 | MPL-2.0 AND (Apache-2.0 OR MIT) |
| tld | 0.13.2 | MPL-1.1 OR GPL-2.0-only OR LGPL-2.1-or-later |
| typing_extensions | 4.16.0 | PSF-2.0 |
| pillow | 12.3.0 | MIT-CMU (bundles libjpeg, libpng, freetype, … under their own licences) |
| xlsxwriter | 3.2.9 | BSD-2-Clause (python-pptx uses it to embed chart data) |

## Why not Scrapling's `Fetcher`

`scrapling.fetchers.Fetcher` (0.4.15) imports `curl_cffi`, `browserforge`,
`playwright` and `patchright` at module load
(`scrapling/engines/toolbelt/convertor.py`), so it cannot be used without
shipping the Playwright/Patchright drivers (a Node binary each). It also hands
DNS to libcurl, which would undo the resolve-once SSRF pin. Fetching is
therefore the standard library's `http.client`, and Scrapling is used for what
it is installed for here: parsing and selecting.
