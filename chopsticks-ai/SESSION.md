# cs.AI session notes (through 3.6.7)

This is what landed in this Cursor session for Chopsticks HQ / cs.AI, ending at **v3.6.7** on 18 Aug 2026.

## Product

cs.AI (chopsticksAI) is the Mac + web assistant on chopstickshq.com. Live answers go through Netlify (`/api/chopsticks-ai`). ChopCode is the multi-agent coding plate.

## Problems we hit

1. **“The live model didn’t return an answer.”**  
   ChopCode ran 10 models inside Netlify’s ~26s window, so fallbacks never ran. The Mac client also cut ChopCode off at **22 seconds**. The API returned `mode: "error"` with that exact sentence whenever live-only chat missed.

2. **Chat felt frozen and Send did nothing.**  
   `busy` stayed true across long retries (Tamago then Rice, 90s each). Return in the tall composer inserted a newline. Every send drew an 11-bubble agent animation (even on Rice/Tamago), including a loop that always ticked 11 times. Replies were typed out character-by-character on the web.

## What we shipped

### 3.6.4
- ChopCode ensemble capped so a live fallback still had time.
- Mac wait raised to 90s (later shortened again for snappiness).
- Instant Agent 1–10 talk lines while Lead finished.

### 3.6.5
- Fast model (Groq 8B / Nemotron Nano) starts **in parallel** with the fancy plate.
- Tools only when the user asked for a file.
- ChopCode only hits **3** specialists on the network; the room still shows Agent labels.
- API **stopped returning** the blank live-miss error string. Last resort is product help or a real next step with `mode: "live"`.
- Mac retries Tamago → Rice → local KB; ChopCode Pro 403 is shown as Pro, not a fake live miss.

### 3.6.6
- **Return sends** (Shift+Return = newline).
- `defer { busy = false }` so Send cannot stick.
- Non-ChopCode thinking is a small ProgressView, not 11 bubbles.
- One API call + short Rice retry; 22s client timeout.
- Cloud sync no longer blocks the send path.
- Web replies appear at once (no stream reveal).

### 3.6.7 — More models
- New **More models** rail tab (Mac) and modal (web).
- Paste **Groq** (`gsk_`), **OpenRouter** (`sk-or-v1-`), or **Claude** (`sk-ant-`) keys.
- Mac stores keys in **Keychain**; web uses **localStorage**. Keys are sent only on that chat/list request.
- Catalogs:
  - **OpenRouter** — every public model from `GET /api/v1/models`
  - **Groq** — every model your Groq key can list (plus a small built-in set)
  - **Claude** — Anthropic `/v1/models` when a key is present, plus a current Claude 4.x / 3.x catalog
- Pick a model to use it instead of a plate. “Use plates instead” clears the pick.
- Custom OpenRouter models require **your** OpenRouter key (HQ key is not used to run arbitrary paid models). Claude requires your Anthropic key. Groq uses your key, or the server Groq key if you have none.

## Files that matter

| Area | Path |
| --- | --- |
| API | `chopstickshq-site/api/_lib/chopsticks-ai.js` |
| ChopCode room | `chopstickshq-site/api/_lib/chopcode-ensemble.js` |
| Web app | `chopstickshq-site/chopsticks-ai/web/index.html` |
| Mac app | `chopsticksAI/macos-app/` (`ChopsticksAIApp.swift`, `MoreModelsStore.swift`, `MoreModelsView.swift`) |
| Manifest | `chopsticks-ai/version.json`, `changelog.json` |

## How to run 3.6.7

1. Quit cs.AI.
2. Open `~/Applications/chopsticksAI.app` (this session installed it) or download `chopsticksAI-v3.6.7.zip`.
3. Rail → **More models** → paste keys → **Load catalogs** → click a model.
4. Agents chat then uses that model. Composer shows a sparkle chip with the name.

Web: [chopstickshq.com/chopsticks-ai/web/](https://chopstickshq.com/chopsticks-ai/web/) → star button in the rail.
