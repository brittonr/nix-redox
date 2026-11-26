# Hosting `nixredox.com` and redirecting `nixredox.org`

Canonical public site: **`https://nixredox.com/`**
Live browser lab: **`https://nixredox.com/live/`**
Redirected domains: **`nixredox.org`**, **`www.nixredox.org`**, **`www.nixredox.com`**, and legacy **`https://brittonr.github.io/nix-redox/`**.

## Why Cloudflare Pages (+ R2 overflow) instead of GitHub Pages

The threaded QEMU-WASM browser engine requires `SharedArrayBuffer`, which requires cross-origin isolation (`Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`).

- **GitHub Pages** ignores `site/_headers` and emits `Access-Control-Allow-Origin: *` without COOP/COEP, forcing first-time visitors onto the `site/coi-serviceworker.js` reload fallback.
- **Cloudflare Pages** honors `site/_headers` natively at the edge, so a fresh browser profile gets `window.crossOriginIsolated === true` on the very first response without waiting for a service worker.
- **25 MiB per-file limit:** Cloudflare Pages rejects static files larger than 25 MiB (`26,214,400` bytes). The complete `.#browser-site` tree currently contains files above 25 MiB that must **not** be dropped:
  - `assets/<sha256>/disk.img.gz` (~113 MiB)
  - `licenses/engine/source/qemu-wasm.tar.gz` (~37 MiB, plus its `revisions/<rev>/` copy)
  - `licenses/engine/source/emscripten.tar.gz` (~27 MiB, plus its `revisions/<rev>/` copy)

To publish the exact Nix-gated `.#browser-site` tree without dropping guest assets or corresponding source archives, `.github/workflows/pages.yml` runs `nix/browser/stage_cloudflare_pages.py`:

1. Files `<= 25 MiB` stay in the Cloudflare Pages static bundle (`cloudflare-staging/pages/`), served natively with `site/_headers`.
2. Files `> 25 MiB` are moved to `cloudflare-staging/r2-overflow/` and uploaded to a Cloudflare R2 bucket **before** the Pages deployment runs.
3. `_routes.json` routes **only** those exact overflow paths to `_worker.js`, which reads them from the `SITE_OVERFLOW` R2 bucket binding with the identical COOP/COEP/CORP, `X-Content-Type-Options: nosniff`, `Cache-Control`, and raw `Content-Type: application/gzip` (never `Content-Encoding: gzip`) headers.

> **Alternative:** If you later prefer to retain every historical `/revisions/<id>/` indefinitely across deploys, a single Cloudflare Worker serving 100% of `.#browser-site` from one R2 bucket (uploading `/assets/*` and `/revisions/*` before overwriting `channel.json`/`manifest.json`) removes the 25 MiB split altogether.

## Header and caching contract

`site/_headers` and `nix/browser/manifest.py` enforce:

| Path | Isolation headers | `Cache-Control` |
|---|---|---|
| `/*` (`/`, `/live/`, etc.) | COOP `same-origin`, COEP `require-corp`, CORP `same-origin`, `nosniff` | `no-store` |
| `/channel.json`, `/manifest.json` | inherited from `/*` | `! Cache-Control` -> `no-store` |
| `/revisions/*` | inherited from `/*` | `! Cache-Control` -> `public, max-age=31536000, immutable` |
| `/revisions/:revision/coi-serviceworker.js` | inherited from `/*` | `! Cache-Control` -> `no-store` |
| `/assets/<64-hex>/*` | inherited from `/*` | `! Cache-Control` -> `public, max-age=31536000, immutable` |

`! Cache-Control` is required on Cloudflare Pages overrides so Cloudflare replaces the `no-store` header from `/*` instead of concatenating both values.

Host and scheme redirects (`http://`, `www.`, `.org`) are configured as **Cloudflare Redirect Rules** at the zone level, not in `site/_redirects` (Cloudflare Pages `_redirects` only matches relative paths, not external hostnames or schemes).

## External setup checklist (Porkbun, Cloudflare, GitHub)

### 1. Porkbun (registrar hygiene)

Confirm for **both** `nixredox.com` and `nixredox.org`:

- [ ] **Registrar lock** remains enabled (`clientDeleteProhibited`, `clientTransferProhibited`).
- [ ] **Auto-renew** is enabled (not visible in RDAP; check Porkbun dashboard directly).
- [ ] **WHOIS privacy** remains enabled.
- [ ] **Nameservers** match the pair assigned by Cloudflare after adding both zones (currently delegated to `eric.ns.cloudflare.com` and `lucy.ns.cloudflare.com`; update in Porkbun if Cloudflare assigns a different pair).
- [ ] *(Optional, after zones are active)* Copy the Cloudflare **DS record** into Porkbun's DNSSEC settings for both domains.

### 2. Cloudflare zones and Pages + R2 setup

In the `brittonr` Cloudflare account:

1. **Add zones** (Free plan) for `nixredox.com` and `nixredox.org`. Wait until both show **Active** (resolving the lame delegation `SERVFAIL`).
2. **Create R2 bucket** (for example `nixredox-site-assets`) for `>25 MiB` overflow files.
3. **Create Cloudflare Pages project** (Direct Upload) named `nixredox`:
   - **Custom domains:** add `nixredox.com` (Cloudflare creates the proxied apex CNAME to `nixredox.pages.dev` and issues the edge TLS certificate).
   - **Settings -> Bindings -> Add -> R2 bucket** (Production and Preview):
     - Variable name: `SITE_OVERFLOW`
     - R2 bucket: `nixredox-site-assets` (the bucket created in step 2)

### 3. Cloudflare DNS records (both zones)

These domains do not send or receive mail. Publish null MX, SPF hard-fail, DMARC reject, and Cloudflare-only CAA records on **both** zones.

#### Zone: `nixredox.com`

| Type | Name | Content / Target | Proxy | Notes |
|---|---|---|---|---|
| `CNAME` | `@` | `nixredox.pages.dev` | Proxied | Created automatically by Pages custom domain |
| `AAAA` | `www` | `100::` | Proxied | Dummy origin so Cloudflare edge executes Redirect Rule |
| `MX` | `@` | `.` (priority `0`) | DNS only | RFC 7505 null MX |
| `TXT` | `@` | `v=spf1 -all` | DNS only | Reject all mail senders |
| `TXT` | `_dmarc` | `v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s;` | DNS only | Org-domain DMARC reject |
| `CAA` | `@` | `0 issue "pki.goog"` | DNS only | Cloudflare Universal SSL (Google Trust Services) |
| `CAA` | `@` | `0 issue "letsencrypt.org"` | DNS only | Cloudflare Universal SSL (Let's Encrypt) |
| `CAA` | `@` | `0 issue "ssl.com"` | DNS only | Cloudflare Universal SSL (SSL.com) |
| `CAA` | `@` | `0 issuewild ";"` | DNS only | Disallow wildcard certs unless needed (or match Cloudflare's managed Universal SSL CAA set) |

#### Zone: `nixredox.org`

| Type | Name | Content / Target | Proxy | Notes |
|---|---|---|---|---|
| `AAAA` | `@` | `100::` | Proxied | Dummy origin so Cloudflare edge serves TLS + Redirect Rule |
| `AAAA` | `www` | `100::` | Proxied | Dummy origin so Cloudflare edge serves TLS + Redirect Rule |
| `MX` | `@` | `.` (priority `0`) | DNS only | RFC 7505 null MX |
| `TXT` | `@` | `v=spf1 -all` | DNS only | Reject all mail senders |
| `TXT` | `_dmarc` | `v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s;` | DNS only | Org-domain DMARC reject |
| `CAA` | `@` | `0 issue "pki.goog"` | DNS only | Cloudflare Universal SSL |
| `CAA` | `@` | `0 issue "letsencrypt.org"` | DNS only | Cloudflare Universal SSL |
| `CAA` | `@` | `0 issue "ssl.com"` | DNS only | Cloudflare Universal SSL |
| `CAA` | `@` | `0 issuewild ";"` | DNS only | Disallow wildcard certs unless needed |

> Note: Cloudflare Universal SSL automatically manages CAA records when Universal SSL is active if no conflicting CAA blocks it. If Universal SSL uses DigiCert or another Cloudflare CA on your account, inspect **SSL/TLS -> Edge Certificates** and keep only the active CA(s) in CAA.

### 4. Cloudflare SSL/TLS and Redirect Rules

Apply on **both** `nixredox.com` and `nixredox.org`:

- **SSL/TLS -> Overview:** `Full (strict)`
- **SSL/TLS -> Edge Certificates:**
  - **Always Use HTTPS:** ON (handles `http://nixredox.com/*` -> `https://nixredox.com/*` with 301)
  - **Automatic HTTPS Rewrites:** ON
  - **Minimum TLS Version:** `TLS 1.2`

Configure **Rules -> Redirect Rules** (Single Redirects):

1. **Zone `nixredox.com` — `Redirect www to apex`:**
   - **When incoming requests match:** Custom filter expression
     ```text
     (http.host eq "www.nixredox.com")
     ```
   - **Type:** Dynamic
   - **Expression:**
     ```text
     concat("https://nixredox.com", http.request.uri.path)
     ```
   - **Status code:** `308` (or `301`)
   - **Preserve query string:** ON

2. **Zone `nixredox.org` — `Redirect nixredox.org to nixredox.com`:**
   - **When incoming requests match:** Custom filter expression
     ```text
     (http.host in {"nixredox.org" "www.nixredox.org"})
     ```
   - **Type:** Dynamic
   - **Expression:**
     ```text
     concat("https://nixredox.com", http.request.uri.path)
     ```
   - **Status code:** `308` (or `301`)
   - **Preserve query string:** ON

### 5. GitHub Actions secrets, variables, and cutover order

Create a scoped Cloudflare API token (`My Profile -> API Tokens -> Create Custom Token`) with:

- `Account -> Cloudflare Pages: Edit`
- `Account -> Workers R2 Storage: Edit`

Configure on `brittonr/nix-redox` (**Settings -> Secrets and variables -> Actions**):

- **Secrets:**
  - `CLOUDFLARE_API_TOKEN` — the scoped token above
  - `CLOUDFLARE_ACCOUNT_ID` — your Cloudflare Account ID
- **Variables:**
  - `CLOUDFLARE_R2_BUCKET` — `nixredox-site-assets` (required while `.#browser-site` contains files `>25 MiB`)
  - `CLOUDFLARE_PAGES_PROJECT` — `nixredox` *(optional; defaults to `nixredox`)*
  - `GITHUB_PAGES_REDIRECT_TO_CANONICAL` — leave unset until `https://nixredox.com/` is verified live

#### Cutover sequence

1. Trigger the **`Website`** workflow (`workflow_dispatch` on `main`) once secrets and `CLOUDFLARE_R2_BUCKET` are set. The `build` job runs the full Nix build, delivery tests, and Chromium smoke gate, then `deploy-cloudflare` uploads `>25 MiB` overflow files to R2 and publishes to Cloudflare Pages.
2. Verify `nixredox.com` and `nixredox.org` before switching GitHub Pages:
   ```bash
   ./scripts/verify-nixredox-domain.sh --skip-github-pages
   ```
   *(Pass `--doh` if your local network intercepts UDP/53.)*
3. Open `https://nixredox.com/live/` in a **fresh** browser profile and confirm in DevTools Console:
   - `window.crossOriginIsolated === true`
   - `typeof SharedArrayBuffer === "function"`
   - `navigator.serviceWorker.controller === null` (proves edge headers worked on the first visit)
   - Press **Boot** and verify the Redox guest reaches **Ready** (confirms R2 overflow delivery of `disk.img.gz`).
4. Set repository variable **`GITHUB_PAGES_REDIRECT_TO_CANONICAL=true`** and re-run **`Website`** (`workflow_dispatch` on `main`). GitHub Pages now publishes the lightweight redirect artifact generated by `nix/browser/build_pages_redirect.py` (`index.html`, `live/index.html`, and path-preserving `404.html`).
5. Update the GitHub repository homepage:
   ```bash
   gh repo edit brittonr/nix-redox --homepage https://nixredox.com/
   ```
6. Run the full verification script (including legacy GitHub Pages redirect checks):
   ```bash
   ./scripts/verify-nixredox-domain.sh
   ```
