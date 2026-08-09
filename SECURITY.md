# Security

cs.AI and Chopsticks HQ are open source. Treat every control in this repo as public knowledge.

## Reporting vulnerabilities

Email **mzx+security@lam.ws** with:

- What you found and where (file, endpoint, or flow)
- Steps to reproduce
- Impact (data exposure, spend abuse, privilege escalation, etc.)

Please do not open public GitHub issues for undisclosed security bugs.

## Secrets — never commit

| Variable | Where it lives |
|----------|----------------|
| `OPENROUTER_API_KEY` | Netlify env only |
| `SUPABASE_SERVICE_ROLE_KEY` | Netlify env only |
| `FATHOM_PRO_HMAC_SECRET` | Netlify env — signs `oi-pl2-…` keys |
| `FATHOM_VAULT_PASSWORD` | Netlify env — vault mint gate |
| `CHOPSTICKS_AI_BUCKET_SALT` | Netlify env — per-visitor budget buckets |

See [docs/SECRETS.md](docs/SECRETS.md) for rotation steps.

## Deployment checklist

1. Set all env vars from `.env.example` in Netlify production.
2. Run `netlify/functions/chopsticks-ai-security.sql` in Supabase SQL editor (after backup).
3. Rotate `OPENROUTER_API_KEY` if it was ever exposed in logs or chat.
4. Set `FATHOM_PRO_HMAC_SECRET` (32+ random bytes) — old `oi-pl-…` keys stop working.
5. Set `FATHOM_VAULT_PASSWORD` and update vault users.
6. Redeploy Netlify; verify `GET /api/chopsticks-ai` returns 200.

## Architecture controls

- **Unlock keys:** HMAC-SHA256 server-side (`oi-pl2-…`); no client signing.
- **Profiles:** entitlement columns blocked for authenticated self-updates (SQL trigger).
- **Budget RPCs:** `service_role` execute only; per-IP buckets for anonymous traffic.
- **API abuse:** 8 req/min + 120/day per IP; premium tiers require sign-in.
- **CORS:** `chopstickshq.com`, Netlify previews, localhost only.
- **macOS:** Supabase session + unlock keys in Keychain; privacy mode skips cloud API/sync.
- **Usage emails:** Signed-in users get alerts from `chopstickshq@lam.ws` at 80% / 95% / cooldown (requires `RESEND_API_KEY`).

## Monitoring

Configure in Netlify dashboard:

- **Function alerts:** 5xx spike on `chopsticks-ai` function.
- **OpenRouter:** watch for 429 rate-limit responses in function logs.
- **Spend:** compare daily OpenRouter usage vs budget RPC totals.

Log hygiene: never log full request bodies, `Authorization` headers, or unlock keys.

## CI

GitHub Actions workflow `.github/workflows/security.yml` runs on push/PR:

- `node --check` on API modules
- grep for common secret patterns (`sk-or-`, hardcoded HMAC secrets)
