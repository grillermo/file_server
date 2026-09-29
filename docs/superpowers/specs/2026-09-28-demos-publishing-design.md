# demos.grillermo.com publishing — design

## Goal

`files.chiq.me` serves every stored file. `demos.grillermo.com` is a public
Cloudflare tunnel hostname that must serve **only files explicitly chosen** for
it. Publishing is rare, so simplicity and hard separation beat convenience.

## Decisions

- **Separate copy directory.** Publishing copies a file from `files/` into
  `demos/` (repo root, gitignored, `DEMOS_DIR` overrides). A real copy — no
  symlink or hardlink — so nothing in `demos/` points back into `files/`.
  "Published" means "a copy exists in `demos/`"; there is no manifest.
- The copy keeps the stored name (1:1 mapping). Later overwrites of the
  original (pinned uploads) do **not** propagate; republish to refresh.
  Deleting the original leaves the copy.
- **Separate process and port.** `demos.ru` runs `DemoApp` on port 33334
  (`DEMO_PORT`). It requires nothing from `app.rb`, OTP, tokens or upload code.
  The demos.grillermo.com tunnel route points at `http://localhost:33334`.
- **Choosing files** happens through a toggle on `files.chiq.me/index`,
  protected by a browser session obtained through the existing Slack OTP.
- `./serve` starts both processes as panes of one tmux session.

## Components

### `lib/file_body.rb`
`FileBody` (streams from disk) moves out of `app.rb` so both apps share it,
plus a helper building `content-type` / `content-length` headers for a path.

### `lib/demo_app.rb` + `demos.ru`
- `GET`/`HEAD /<name>` → serves `demos/<File.basename(name)>` when it is a
  regular file; responses carry `cache-control: no-cache` (unpublish takes
  effect through Cloudflare) and `x-content-type-options: nosniff`.
- Everything else — `/`, other methods, missing files, traversal attempts —
  is a plain `404 Not found`. No listing, no health endpoint.

### Session (main app)
- `SESSION_SECRET` (new, required for login) signs a cookie
  `fs_session=<expires_at>.<hmac>`; HttpOnly, Secure, SameSite=Strict, 30 days.
  Verification: constant-time HMAC compare and `expires_at > now`.
- `GET /login` — HTML form: "Send code" (POSTs `/auth/otp`) and a code field
  that POSTs `/auth/session`.
- `POST /auth/session` (`code`) — `Otp#verify`; on success sets the cookie and
  redirects (303) to `/index`; otherwise 401.
- `POST /logout` — clears the cookie, redirects to `/index`.

### Publishing (main app)
- `POST /publish` (`name`) — requires session cookie **or** bearer token.
  Copies `files/<basename>` to `demos/<basename>` (via temp file + rename).
  404 if the source is missing; 422 for reserved names (`mcp.html`).
- `POST /unpublish` (`name`) — same auth; deletes `demos/<basename>` if present.
- Both redirect (303) to `/index` for browser forms, which is fine for curl too.

### `/index` listing
- Logged in: each row gets a Public on/off form button and, when published,
  the demos URL (`DEMOS_URL`, default `https://demos.grillermo.com`).
- Logged out: unchanged, plus a "Log in" link.

### `./serve`
Bash, modelled on `../comunidad-antesis/serve` minus deploy/blue-green steps.
One detached tmux session `file_server`, panes titled `files`
(`rackup config.ru -p $PORT`, default 33333) and `demos`
(`rackup demos.ru -p $DEMO_PORT`, default 33334). Each pane command re-sources
`.env` and carries `PATH`; `remain-on-exit` keeps crashed panes readable.
Re-running restarts both panes in place after freeing their ports.
Checks: `files` answers `/health` with `chiq-file-server`; `demos` pane alive and
port listening. On failure, dump the pane and exit non-zero. Attach at the end
(`switch-client` inside tmux, skip without a TTY). Must pass `shellcheck`.

## Testing
- `DemoApp`: serves a published file (GET and HEAD); 404 for `/`, `/index`,
  `/upload`, `/health`, `/files/x`, traversal, files only in `files/`.
- Publish: copies content; overwriting the original leaves the copy; unpublish
  removes it; unauthenticated / tampered / expired cookie → 401; bearer works.
- Session: login flow sets a cookie that authorizes publish; logout clears it.
- Listing: toggle only shown with a session.

## Manual steps
- Cloudflare dashboard: route demos.grillermo.com → `http://localhost:33334`.
- Add `SESSION_SECRET` to `.env` (`ruby -rsecurerandom -e 'puts SecureRandom.hex(32)'`).
- Restart with `./serve`.
