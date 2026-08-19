# Chopsticks HQ — domain / DNS setup

| Hostname | Serves |
|----------|--------|
| `www.chopstickshq.com` | Chopsticks HQ homepage |
| `chopstickshq.com` | HQ site |
| **`chopstickshq.com/macbar`** | **MacBar product site (canonical)** |
| **`chopstickshq.com/fathom`** | **Fathom Air (canonical)** |
| **`chopstickshq.com/fathom-pro`** | **Fathom Pro (canonical)** |
| **`chopstickshq.com/minecraft`** | **Minecraft portfolio (imik2261_) + live CatboiGens telemetry** |
| `minecraft.chopstickshq.com` | Redirects → `/minecraft/` (add CNAME → Netlify) |
| **`chopstickshq.com/vault`** | **Password-gated vault** |
| `macbar.chopstickshq.com` | Redirects → /macbar (temporary after rebrand revert) |
| `macbar.chopstickshq.com` | Optional → /macbar |
| **`fathom.chopstickshq.com`** | **→ /fathom/** (Fathom Air) — add CNAME → Netlify |
| **`air.chopstickshq.com`** | **→ /fathom/** (alias) — add CNAME → Netlify |
| **`fathompro.chopstickshq.com`** | **→ /fathom-pro/** — add CNAME → Netlify |
| **`fathom-pro.chopstickshq.com`** | **→ /fathom-pro/** — add CNAME → Netlify |
| `chopstickshq.com/macbar` | Legacy product CDN (redirect → `/macbar/`) |
| **`chopstickshq-mirror.pages.dev`** | **Cloudflare Pages backup** (repo `ilikemacos/chopstickshq-mirror`) |
| **`ilikemacos.github.io/chopstickshq-mirror/`** | **GitHub Pages backup** |
| **`ilikemacos.github.io/chopstickshq-backup/`** | **GitHub Pages second backup** |

## Backup hosts (Cloudflare + GitHub)

Primary production: **Netlify** → `chopstickshq.com`.

| Host | Provider | Source repo |
|------|----------|-------------|
| https://chopstickshq-mirror.pages.dev | Cloudflare Pages | [ilikemacos/chopstickshq-mirror](https://github.com/ilikemacos/chopstickshq-mirror) |
| https://ilikemacos.github.io/chopstickshq-mirror/ | GitHub Pages | same |
| https://ilikemacos.github.io/chopstickshq-backup/ | GitHub Pages | [ilikemacos/chopstickshq-backup](https://github.com/ilikemacos/chopstickshq-backup) |

Sync: push the static site tree to both GitHub repos (`main`). Cloudflare Pages rebuilds from the mirror repo when connected. GitHub Pages builds from `main` `/`.

Note: GitHub project Pages use a subpath (`/chopstickshq-mirror/`), so root-absolute links (`/js/…`) prefer **Cloudflare** or **Netlify** as full-fidelity backups.

## DNS records (Cloudflare / registrar)

For each product subdomain, add a **CNAME** (or ALIAS) to your Netlify site hostname, e.g. `chopstickshq-com.netlify.app` (check Netlify → Domain management).

| Type | Name | Target |
|------|------|--------|
| CNAME | `fathom` | `chopstickshq-com.netlify.app` |
| CNAME | `air` | `chopstickshq-com.netlify.app` |
| CNAME | `fathompro` | `chopstickshq-com.netlify.app` |
| CNAME | `fathom-pro` | `chopstickshq-com.netlify.app` |

Then in Netlify → Domain management → **Add domain alias** for each hostname (or wait for auto-detect). SSL is automatic.

Redirects are already in `netlify.toml` (same pattern as `macbar.chopstickshq.com`).

## GitHub
- Repo may be named MacBar on GitHub; product brand is **MacBar**.
- Homepage: https://chopstickshq.com/macbar
