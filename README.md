# file_server

Minimal headless Rack app that accepts a file upload, stores it locally, and serves it back over HTTP.

## Requirements

- Ruby 3.2.4
- Bundler

## Setup

```sh
bundle install
cp .env.example .env
```

The app loads `.env` automatically on boot. Set these variables in `.env` or export them in your shell:

- `AUTH_TOKEN` bearer token required for upload requests
- `PUBLIC_URL` base for returned file URLs (e.g. `https://files.chiq.me`). Without it
  the URL follows the request's host, so an upload sent to the LAN address would
  return a LAN-only link.
- `SESSION_SECRET` signs the browser login cookie for the publish toggle
- `DEMOS_URL` base of the demo links on `/index` (default `https://demos.grillermo.com`)
- `DEMO_PORT` port of the demos process (default `33334`)
- `DEMOS_DIR` where published copies live (default `./demos`). The main app and the
  demos process must resolve to the same directory, and it must differ from `FILES_DIR`.

Example:

```sh
AUTH_TOKEN=replace-with-a-long-random-token
```

## Run

```sh
./serve
```

`./serve` starts a tmux session named `file_server` with two panes: `files`
(the full app on http://localhost:33333, or `$PORT`) and `demos` (the demos
process on 127.0.0.1:33334, or `$DEMO_PORT`). Re-running it restarts both panes,
and first stops whatever is listening on those two ports. Use
`tmux attach -t file_server` to see them.

## demos.grillermo.com

A file is public on demos.grillermo.com only while a copy of it sits in `demos/`
(git-ignored). Everything else stays on files.chiq.me.

On `/index`, click "Log in" (a Slack OTP, same as the MCP login), then use
"Make public" beside a file; it turns into "Public — unpublish" with the demo link.
From a script:

```sh
curl -X POST https://files.chiq.me/publish -H "Authorization: Bearer $AUTH_TOKEN" -d name=<stored-name>
curl -X POST https://files.chiq.me/unpublish -H "Authorization: Bearer $AUTH_TOKEN" -d name=<stored-name>
```

- The copy does not follow later overwrites of the original; publish again to refresh it.
- The demos process (`demos.ru`) serves only `GET`/`HEAD /<name>` for files in
  `demos/` and answers 404 to everything else. It listens on 127.0.0.1 only, so
  the Cloudflare route for demos.grillermo.com must point at `http://localhost:33334`.
- The login cookie (`fs_session`, 30 days, signed with `SESSION_SECRET`) is `Secure`,
  so browser login only works over the HTTPS origin (files.chiq.me), not plain
  `http://<lan-ip>`. Without `SESSION_SECRET`, login returns 503.
- Sessions are stateless: logging out only clears the browser's cookie. Rotate
  `SESSION_SECRET` to revoke every session.
- A published file is served with full script power on the demos origin, so
  published HTML/JS can fetch other published files.
- `SameSite=Strict` keeps other sites from using the login cookie, including the
  demos domain as long as it stays a different registrable domain from files.chiq.me.
  But HTML you upload and open on files.chiq.me/files/* runs on the same origin as
  `/publish`, so a page opened there while logged in could POST to it. Only upload
  HTML you trust. Impact is limited: every stored file is already listed on the
  public `/index`, and publishing needs a valid session.

## Notes

- The app exposes `POST /upload`, `POST /receive`, `GET /files/:name`, `GET /health`,
  `GET /login`, `POST /auth/session`, `POST /logout`, `POST /publish`, and `POST /unpublish`.
- Files are streamed from disk, never read into memory.
- `GET /health?nonce=<hex>&token_id=<first 16 hex of sha256(token)>` answers
  `{"service":"chiq-file-server","proof":"..."}`, where the proof is
  HMAC-SHA256(key: sha256(token) hex, `"<nonce>\n<Host header>"`). The MCP uses it to
  confirm the LAN address really is this server before sending its token there.
  No proof is given through the tunnel (requests carrying `CF-Connecting-IP`).
- The app has no upload size limit. The Cloudflare tunnel in front of it caps
  requests at 25 MB, so larger files must be sent to the LAN address directly.
- Stored filenames use a UUID prefix to avoid collisions.

## API

Send a `multipart/form-data` request with a `file` field:

```sh
curl -X POST http://localhost:33333/upload \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -F "file=@/path/to/file.txt"
```

On success, the response is `200 text/plain` with the file's URL (served by this app under `/files/`) in the response body.

To store the file locally under `files/` without uploading it to S3:

```sh
curl -X POST http://file_to_s3.chiq.me/receive \
  -H "Authorization: Bearer 3f845ccfbb384a64b2e7976974128f912e875be90f0b4d6c" \
  -F "file=./dump"
```

On success, the response is `200 text/plain` after the local file has been written.

To store the file under a stable name that overwrites any previous upload —
so the URL never changes — pass `?name=`:

```sh
curl -X POST "https://files.chiq.me/upload?name=awh-manifest.plist" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -F "file=@ios/manifest.plist"
```

The response is always `https://files.chiq.me/files/awh-manifest.plist`, and
pinned responses carry `cache-control: no-cache` so caches in front of the
service revalidate instead of serving a stale copy. Without `?name=`, uploads
keep their UUID prefix and never overwrite anything.

## MCP login

The `file_server` MCP in `agents-configs` logs in with a Slack OTP and then
uploads with a token that never expires. Install instructions are served at
`/files/mcp.html`.

- `POST /auth/otp` (`label`) posts a 6-digit code to Slack `#otp`
  (needs `SLACK_OTP_WEBHOOK_URL` in `.env`). 202, or 429 within 30 s of the last code.
- `POST /auth/verify` (`code`, `label`) returns `{"token":"fts_..."}`. Five wrong
  codes void the current one.
- Tokens are stored as SHA-256 digests in `tokens.json` (`TOKENS_FILE` overrides).

```sh
bin/tokens list
bin/tokens revoke <label|digest-prefix>
```
