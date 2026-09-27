# file-to-s3

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

Example:

```sh
AUTH_TOKEN=replace-with-a-long-random-token
```

## Run

```sh
bin/rackup -s webrick
```

The service listens on http://localhost:33333

The local `bin/rackup` wrapper defaults to port `33333`. You can still override it with `PORT=4567 bin/rackup -s webrick` or `bin/rackup -p 4567 -s webrick`.

If `bin/rackup` is missing, regenerate the local Bundler binstub once:

```sh
bundle binstub rackup --force
bin/rackup -s webrick
```

## Notes

- The app exposes `POST /upload`, `POST /receive`, and `GET /files/:name`.
- Uploads larger than 25 MB are rejected by the app.
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

The `file-to-s3` MCP in `agents-configs` logs in with a Slack OTP and then
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
