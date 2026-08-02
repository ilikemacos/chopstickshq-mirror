# Chopsticks HQ — domain / DNS setup

| Hostname | Serves |
|----------|--------|
| `www.chopstickshq.com` | Chopsticks HQ homepage |
| `chopstickshq.com` | HQ site |
| **`chopstickshq.com/rnitro`** | **rNitro product site (canonical)** |
| **`chopstickshq.com/fathom`** | **Fathom Air (canonical)** |
| **`chopstickshq.com/fathom-pro`** | **Fathom Pro (canonical)** |
| **`chopstickshq.com/minecraft`** | **Minecraft portfolio (imik2261_) + live CatboiGens telemetry** |
| `minecraft.chopstickshq.com` | Redirects → `/minecraft/` (add CNAME → Netlify) |
| **`chopstickshq.com/vault`** | **Password-gated vault** |
| `macbar.chopstickshq.com` | Redirects → /rnitro (temporary after rebrand revert) |
| `rnitro.chopstickshq.com` | Optional → /rnitro |
| **`fathom.chopstickshq.com`** | **→ /fathom/** (Fathom Air) — add CNAME → Netlify |
| **`air.chopstickshq.com`** | **→ /fathom/** (alias) — add CNAME → Netlify |
| **`fathompro.chopstickshq.com`** | **→ /fathom-pro/** — add CNAME → Netlify |
| **`fathom-pro.chopstickshq.com`** | **→ /fathom-pro/** — add CNAME → Netlify |
| `getrnitro.netlify.app` | Legacy product CDN |

## DNS records (Cloudflare / registrar)

For each product subdomain, add a **CNAME** (or ALIAS) to your Netlify site hostname, e.g. `chopstickshq-com.netlify.app` (check Netlify → Domain management).

| Type | Name | Target |
|------|------|--------|
| CNAME | `fathom` | `chopstickshq-com.netlify.app` |
| CNAME | `air` | `chopstickshq-com.netlify.app` |
| CNAME | `fathompro` | `chopstickshq-com.netlify.app` |
| CNAME | `fathom-pro` | `chopstickshq-com.netlify.app` |

Then in Netlify → Domain management → **Add domain alias** for each hostname (or wait for auto-detect). SSL is automatic.

Redirects are already in `netlify.toml` (same pattern as `rnitro.chopstickshq.com`).

## GitHub
- Repo may be named MacBar on GitHub; product brand is **rNitro**.
- Homepage: https://chopstickshq.com/rnitro
