# Demos publishing — design

## Goal

`files.chiq.me` serves every stored file. `demos.grillermo.com` (a second
hostname on the same Cloudflare tunnel) must serve **only** files explicitly
chosen for the public, with hard separation: the process behind demos cannot
reach `files/`, upload, log in, or list anything.

Publishing is rare, so a published file is a frozen copy.

## Storage

- `demos/` at the repo root (sibling of `files/`, gitignored). Override with
  `DEMOS_DIR`.
- Publishing copies `files/<name>` to `demos/<name>` with `IO.copy_stream` —
  a real copy, never a link.
- "Published" means the copy exists. No manifest.
- The copy keeps the stored name (UUID prefix included): the mapping is 1:1 and
  unpublishing is a delete.
- Later overwrites or deletion of the original do not touch the copy. To refresh
  it, unpublish and publish again.

## Demos server

- `demos.ru` runs `DemoApp` (`lib/demo_app.rb`) on port 33334 (`DEMO_PORT`).
- It requires only `lib/file_body.rb` — never `app.rb`, OTP, tokens, Slack or
  upload code.
- `GET`/`HEAD /<name>` serves `demos/<File.basename(name)>` when it is a regular
  file. Everything else — `/`, other methods, missing files — is a plain 404.
  No listing.
- Response headers: `content-type`, `content-length`,
  `x-content-type-options: nosniff`, `cache-control: no-cache` (so an unpublish
  is not outlived by a Cloudflare cache).

## Shared code

`FileBody` and the file-response helper (MIME type, content-length, HEAD
handling) move from `app.rb` to `lib/file_body.rb`. It is the only code both
apps load.

## Toggle on files.chiq.me

Main app, same process as today.

### Browser session (Slack OTP)

- `GET /login`: page that requests a code through the existing `POST /auth/otp`,
  then submits it to `POST /auth/session`.
- `POST /auth/session` (`code`): checks with `Otp#verify`; on success sets a
  cookie `fs_session` = `<expiry>.<HMAC-SHA256(SESSION_SECRET, expiry)>`,
  `HttpOnly; Secure; SameSite=Strict; Path=/`, 30-day expiry. Stateless.
- `POST /logout` clears it.
- `SESSION_SECRET` is required in `.env` for sessions; without it login answers
  503 and the toggle is hidden.

### Publish endpoints

- `POST /publish` and `POST /unpublish` with `name`.
- Authorized by a valid session cookie **or** the existing bearer auth
  (`AUTH_TOKEN` / `fts_` tokens), so curl and the MCP can publish too.
- `name` goes through `File.basename`; reserved names (`mcp.html`) cannot be
  published; publishing a missing file is 404.
- From the browser they redirect back to `/index` (303); with a bearer token they
  answer `text/plain` with the demos URL (`DEMOS_URL`, default
  `https://demos.grillermo.com`).
- CSRF: POST-only plus `SameSite=Strict`.

### Listing

- Logged in: each `/index` row gets a Public switch (a small POST form) and,
  when published, the demos URL.
- Logged out: identical to today plus a "log in" link. Who can view
  files.chiq.me is unchanged.

## ./serve

Rewritten in Ruby (macOS `/bin/bash` 3.2 lacks `wait -n`):

- Spawns `bundle exec rackup -p 33333` and
  `bundle exec rackup demos.ru -p 33334`, `RACK_ENV` defaulting to `deployment`.
- Forwards `INT`/`TERM` to both children.
- `Process.wait2(-1)` for the first child to exit, terminates the other, exits
  with the first one's status — so whatever supervises `./serve` restarts both.

## Tests (Rack::Test, existing style)

- `DemoApp`: serves a file in `demos/`; 404 for `/`, `/index`, `/upload`,
  `/health`, `/auth/otp`, `../` traversal, and a file present only in `files/`;
  HEAD matches GET without a body; headers include `nosniff`.
- Publish copies; overwriting the original leaves the copy unchanged; unpublish
  deletes it.
- Publish/unpublish reject no auth, a tampered cookie, and an expired cookie;
  accept a session cookie and a bearer token; refuse `mcp.html`.
- Session: correct code sets the cookie; wrong code does not.

## Manual steps

- Cloudflare dashboard: route demos.grillermo.com → `http://localhost:33334`.
- Add `SESSION_SECRET` (and optionally `DEMOS_URL`) to `.env`.
- Restart `./serve`.

## Out of scope

Renaming files on publish, a public index of demos, auto-refreshing copies.
