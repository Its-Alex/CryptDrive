# CryptDrive on the web

The web version is the same app, built for the browser, with rclone compiled
to WebAssembly. Files are encrypted and decrypted **in your browser**: the
server hosting the app only serves static files and never sees a key, a token
or a file. The browser talks to Google Drive directly.

```
Browser tab
  ├─ Flutter UI
  └─ Web Worker: cryptdrive.wasm (rclone: drive + crypt + memory + alias)
        └─ fetch ──▶ www.googleapis.com (Drive API)
Host (nginx, static files only)
```

## Run it

### Local development

```sh
cd app
mise exec -- flutter build web --profile --no-web-resources-cdn
python3 -m http.server 8080 --bind 127.0.0.1 --directory build/web
```

Then open **<http://localhost:8080>**, and nothing else.

- The port and the hostname are not free: the Web OAuth client has
  `http://localhost:8080` as its authorized JavaScript origin and
  `http://localhost:8080/oauth_callback.html` as its redirect URI. Google
  refuses the consent popup from any other origin, so `:8091`,
  `127.0.0.1:8080` and `localhost:8081` all fail at sign-in.
- `flutter run -d web-server` can't serve this app: the CSP meta tag in
  [`app/web/index.html`](../app/web/index.html) blocks CanvasKit fetched from
  the CDN and the inline script dwds injects. Build as above, or delete that
  one line for the session and restore it afterwards.
- `--no-web-resources-cdn` is required — without it the build loads CanvasKit
  from `gstatic.com`, which the same CSP blocks.

### Container image

Each release publishes `ghcr.io/its-alex/cryptdrive-web`:

```sh
docker run -d --name cryptdrive-web -p 8080:8080 ghcr.io/its-alex/cryptdrive-web:latest
```

It listens on port 8080, as a non-root user, and answers `/healthz`. Put it
behind a reverse proxy that terminates **HTTPS** (Caddy, Traefik, nginx…):
browsers only allow some of what the app uses on secure origins, and Google
only accepts `https://` redirect URIs (except `http://localhost`).

### GitHub Pages

Each release is published at **https://its-alex.github.io/CryptDrive/**.

For a fork, at `https://<owner>.github.io/<repository>/`:

1. GitHub Pages needs a **public** repository on GitHub Free (private
   repositories need a paid plan, and the site is public either way).
2. **Settings → Pages → Build and deployment → Source: GitHub Actions.**
3. **Settings → Secrets and variables → Actions → Variables**: add
   `DEPLOY_PAGES` = `true`.
4. **Settings → Environments → github-pages**: allow deployments from tags
   matching `v*` (by default only the default branch may deploy).
5. Push a `v*` tag: the `GitHub Pages` job deploys that release.

Pages can't send custom headers, so the Content Security Policy also sits in
a `<meta>` tag in `index.html`. Register `https://its-alex.github.io` as
JavaScript origin and `https://its-alex.github.io/CryptDrive/oauth_callback.html`
as redirect URI of your Web application OAuth client.

### Any static host

The release also ships `CryptDrive-web.tar.gz`. Serve its contents as-is
from any static host (a folder on a web server, an object-storage bucket
behind a CDN…). Requirements:

- `.wasm` files served as `application/wasm`;
- if you add a Content Security Policy, it must allow `'wasm-unsafe-eval'`
  for scripts, `blob:` workers and connections to `https://www.googleapis.com`,
  `https://oauth2.googleapis.com` and `https://*.googleusercontent.com`
  (see [`deploy/web/nginx.conf`](../deploy/web/nginx.conf)).

To serve it under a sub-path (e.g. `https://example.com/cryptdrive/`),
build with `flutter build web --base-href /cryptdrive/`.

## Google OAuth client for the web

The desktop and mobile apps use a **Desktop app** client. The web app needs
a **Web application** client, in the same Google Cloud project:

1. [Google Auth Platform → Clients](https://console.cloud.google.com/auth/clients) → **Create client** → type **Web application**.
2. **Authorized JavaScript origins**: the origin of your deployment, e.g. `https://drive.example.com`,
   plus `http://localhost:8080` to run it locally (see [Local development](#local-development)).
3. **Authorized redirect URIs**: `https://drive.example.com/oauth_callback.html`
   and `http://localhost:8080/oauth_callback.html`
   (the app shows the exact value next to the client ID field).
4. Copy the client ID and secret into the app and click **Sign in with Google**.

The consent screen, test users and `drive` scope are the same as in
[google-oauth-client.md](google-oauth-client.md). Alternatively, paste a
token from `rclone authorize` made with a Desktop client (its ID and secret
go in the same fields).

## How your secrets are kept

- On first use, the app asks for a **browser password**. The rclone config
  (Drive token, vault passwords) is stored in the browser's `localStorage`
  **encrypted with it**, using rclone's own config encryption.
- The password itself is never stored with the config. It is kept in
  `sessionStorage` so a reload of the same tab doesn't ask again; closing
  the tab forgets it. **Settings → Lock** forgets it right away.
- **Forget this browser** (Settings, or on the unlock screen) deletes the
  stored config. The vault in Drive is untouched and can be reopened with
  its vault password.
- The vault format is plain rclone crypt: what the web app writes, the
  desktop app, the rclone CLI, RSAF and Round Sync can read, and vice versa.

The host still serves the code your browser runs, as with any web app: use
an instance you trust, ideally your own.

## Limits of the web version

- **Memory**: an upload is read into memory before it is encrypted, and a
  download is decrypted into memory before the browser saves it. A 300 MB
  file encrypts in about 4 s and decrypts in about 2.5 s (plus the Drive
  transfer); multi-GB files can exhaust the tab's memory, use the desktop app.
- **Backends**: only Google Drive, crypt, alias and memory are built in. An
  imported `rclone.conf` with other remote types (S3, OneDrive…) loads, but
  those remotes can't be opened in the browser.
- **"This tab only" storage** (for trying the app without a Google account)
  lives in the tab's memory: everything is gone on reload, and empty folders
  are not kept.
- No share sheet: **Open** shows images, videos, audio, PDF and text in a
  new tab when the browser allows it, and downloads anything else.
