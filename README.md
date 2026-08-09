# Chopsticks HQ (chopstickshq.com)

Static site, Lab, and published API sources for [Chopsticks HQ](https://chopstickshq.com/) — **fully open source** under the [MIT License](LICENSE).

Live site: **https://chopstickshq.com** (Netlify). This repo is the public GitHub Pages mirror.

## Open-source projects

| Project | Repo | License |
|---------|------|---------|
| **cs.AI / chopsticksAI** (macOS app + API + Lab) | [ilikemacos/ChopsticksAI](https://github.com/ilikemacos/ChopsticksAI) | MIT |
| **rNitro** (menu bar monitor) | [ilikemacos/rNitro](https://github.com/ilikemacos/rNitro) | MIT |
| **Fathom** (battery drain) | [ilikemacos/Fathom](https://github.com/ilikemacos/Fathom) | MIT |
| **Fathom Pro** | [ilikemacos/Fathom-Pro](https://github.com/ilikemacos/Fathom-Pro) | MIT |
| **Homebrew tap** | [ilikemacos/homebrew-rnitro](https://github.com/ilikemacos/homebrew-rnitro) | MIT |

## What's in this tree

- **`chopsticks-ai/`** — product pages, changelog, macOS zip, installer script, mirrored server JS
- **`chopailab/`** — web agent (Lab)
- **`api/_lib/`** — cs.AI API implementation (`chopsticks-ai.js`)
- **`rnitro/`**, **`fathom/`**, **`arena-fps/`** — other HQ products (pages + downloads)

## cs.AI source layout

The macOS Agents app, offline KB engine, and Netlify API live in **[ChopsticksAI](https://github.com/ilikemacos/ChopsticksAI)**. This mirror also includes:

- `api/_lib/chopsticks-ai.js` — server handler (same logic as production)
- `chopsticks-ai/files/chopsticks-ai.server.js` — published mirror for inspection
- `chopailab/index.html` — Lab client

No API keys are in the repo. Deploy your own instance with `OPENROUTER_API_KEY` (or compatible) in the host environment.

## Mirror deploy

Primary hosting is Netlify. GitHub Pages mirrors:

- https://ilikemacos.github.io/chopstickshq-mirror/
- https://ilikemacos.github.io/chopstickshq-backup/

## Contributing

Issues and PRs welcome on the relevant repo. For cs.AI bugs, use [ChopsticksAI issues](https://github.com/ilikemacos/ChopsticksAI/issues).
