# file_to_s3 MCP with Slack OTP login — design

Date: 2026-09-26

## Goal

Let any Claude Code session, on any of my machines (including over SSH), upload a
local file to `https://files.chiq.me` through an MCP tool and get back its URL.
Log in once per machine with a one-time code posted to Slack `#otp`; the resulting
token never expires, so that machine can upload forever (until revoked).

## Decisions (from brainstorming)

- **Local stdio MCP, not a remote one.** A remote MCP cannot read local files; the
  local MCP reads the file from disk and POSTs it to the existing `/upload`, so file
  bytes never pass through Claude's context. Size limit stays the app's 25 MB.
- **In-chat OTP, not browser OAuth.** No browser or localhost callback, so it works
  over SSH. Flow is rulinky-style: request code → code posted to Slack → I tell
  Claude the code → Claude exchanges it for a token.
- **Ruby 3 stdlib only, no gems** for the MCP. Ruby 3 is on every machine I use.
- **Single user.** Passing the OTP is the whole identity check; no accounts.
- **Never-expiring tokens, revocable** on the server.

Out of scope: OAuth discovery/Doorkeeper, browser flow, multi-user, raising the
25 MB limit.

## Part 1 — server (`file_to_s3`)

### New endpoints

**`POST /auth/otp`** — unauthenticated. Params: `label` (optional; the client sends
its hostname).

- Generates a 6-digit code (`format("%06d", SecureRandom.random_number(1_000_000))`),
  valid 10 minutes. Only one code is live at a time; a new one replaces the old.
- Posts `{"text": "file_to_s3 OTP: 123456 (for <label>)"}` to
  `ENV["SLACK_OTP_WEBHOOK_URL"]` via `Net::HTTP.post` — same shape as rulinky's
  `SlackOtpNotifier`.
- Rate limit: if the previous code was issued less than 30 s ago → `429`.
- If `SLACK_OTP_WEBHOOK_URL` is unset → `503 "OTP delivery not configured"`
  (never issue a code nobody can receive).
- Success → `202 "OTP sent to Slack #otp"`.

**`POST /auth/verify`** — unauthenticated. Params: `code`, `label`.

- Compares with `Rack::Utils.secure_compare`. Each wrong attempt increments a
  counter; on the 5th wrong attempt the code is discarded. Expired or missing
  code → `401`.
- Success → consumes the code, issues token `fts_` + `SecureRandom.hex(32)`,
  returns `200 application/json {"token": "fts_..."}`.

OTP state is held in memory (single WEBrick process); a restart simply invalidates
a pending code.

### Token store

`lib/token_store.rb` — persists to `ENV.fetch("TOKENS_FILE") { <app>/tokens.json }`
(gitignored). Each entry: `{ "digest": sha256(token), "label", "created_at" }`.
Raw tokens are never written. Writes go to a temp file then `File.rename`, under a
`Mutex`. Tokens have no expiry.

`lib/otp.rb` — the in-memory code, its expiry, attempt count and last-issued time,
plus the Slack sender (injectable so tests stub it).

### Auth change

`authenticated?(req)` accepts **either** `ENV["AUTH_TOKEN"]` (unchanged — Shortcuts
and curl keep working) **or** a bearer whose SHA-256 matches a stored token.

### Revocation CLI

`bin/tokens list` — prints label, created_at, digest prefix.
`bin/tokens revoke <label|digest-prefix>` — removes matching entries.

### Install page — `files/mcp.html`

A static HTML page served at `https://files.chiq.me/files/mcp.html` with the
copy-pasteable install instructions (same content as the "Install" section below),
each command block with a copy button, light/dark styling matching `/index`.
`files/` is gitignored, so `.gitignore` gets a `!files/mcp.html` exception to keep
the page in the repo. Note: an upload with `?name=mcp.html` would overwrite it;
the server rejects that pinned name.

## Part 2 — local MCP (`agents-configs`)

`mcp/file-to-s3/server.rb` — single executable Ruby file, stdlib only
(`json`, `net/http`, `securerandom`, `socket`, `fileutils`, `uri`).

Transport: newline-delimited JSON-RPC 2.0 over stdio. Handles `initialize`
(protocol version echoed, `capabilities: { tools: {} }`), `notifications/initialized`,
`ping`, `tools/list`, `tools/call`; unknown methods → `-32601`. Logs go to stderr only.

Config: `FILE_TO_S3_URL` (default `https://files.chiq.me`);
token file `~/.config/file-to-s3/token` (override `FILE_TO_S3_TOKEN_FILE`).

Tools:

| Tool | Args | Behavior |
|---|---|---|
| `file_to_s3_login` | — | `POST /auth/otp` with `label=Socket.gethostname`. Returns text telling Claude to ask the user for the 6-digit code from Slack #otp. |
| `file_to_s3_verify` | `code` (string) | `POST /auth/verify`; writes token to the token file (dir `0700`, file `0600`). Returns "Logged in". |
| `upload_file` | `path` (string), `name` (optional string) | Expands `path`, checks it's a readable regular file, multipart POSTs to `/upload` (`?name=` when given) with `Authorization: Bearer <token>`. Returns the URL. |

Errors are returned as tool results with `isError: true` and actionable text:
no token file or `401` → "Not logged in — call file_to_s3_login"; file missing;
`422`/`429`/network errors → server message verbatim.

### install.sh

New `register_mcp` step: if `claude` is on PATH and `claude mcp get file-to-s3`
fails, run
`claude mcp add --scope user file-to-s3 -- ruby "$repo_root/mcp/file-to-s3/server.rb"`.
Otherwise print `mcp: already registered` / `mcp: skipped (claude not installed)`.

## Install (copy-pasteable; also on files/mcp.html)

New machine:

```sh
git clone git@github.com:grillermo/agents-configs.git ~/c/agents-configs
~/c/agents-configs/install.sh
```

Already have the repo:

```sh
cd ~/c/agents-configs && git pull && ./install.sh
```

Without `install.sh`:

```sh
claude mcp add --scope user file-to-s3 -- ruby ~/c/agents-configs/mcp/file-to-s3/server.rb
```

Then, in Claude Code: "log in to file_to_s3" → paste the code from Slack #otp →
"upload ./path/to/file".

Server side, once: set `SLACK_OTP_WEBHOOK_URL` in `file_to_s3/.env`.
Revoke a machine: `bin/tokens revoke <hostname>`.

## Testing

- `file_to_s3/test/auth_test.rb` (Minitest, `Rack::MockRequest`, stubbed Slack
  sender, temp `TOKENS_FILE`/`FILES_DIR`): OTP issue, 30 s rate limit, 503 without
  webhook, verify right/wrong/expired, 5-attempt lockout, upload with issued token,
  upload with `AUTH_TOKEN`, 401 after revoke, `mcp.html` pinned name rejected.
- `agents-configs/tests/file-to-s3-mcp.test.rb`: spawns `server.rb` as a subprocess
  against a tiny `TCPServer` fake HTTP server (WEBrick isn't stdlib in Ruby 3); covers initialize, tools/list, login, verify
  (token file written with 0600), upload success, upload without token.
- `agents-configs/tests/install.test.sh`: add cases with a fake `claude` on PATH
  (registers once; second run is a no-op) and without `claude` (skipped).
