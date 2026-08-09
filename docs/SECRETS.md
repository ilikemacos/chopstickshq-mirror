# Secret rotation checklist (cs.AI)

Run these in the **Netlify dashboard** (Site → Environment variables) after any exposure or quarterly.

| Variable | Purpose | Action |
|----------|---------|--------|
| `OPENROUTER_API_KEY` | LLM provider | **Rotate** at openrouter.ai → revoke old key |
| `FATHOM_PRO_HMAC_SECRET` | Signs `oi-pl2-…` unlock keys | Generate new 32+ byte random string; old keys stop working |
| `FATHOM_VAULT_PASSWORD` | Server-only vault mint gate | Change password; update vault UI users |
| `CHOPSTICKS_AI_BUCKET_SALT` | Per-client budget bucket hashing | Rotate only if buckets should reset |
| `SUPABASE_SERVICE_ROLE_KEY` | Budget RPC + profile entitlements (server only) | Supabase → Settings → API → service_role → reset |
| `SUPABASE_ANON_KEY` | Client auth (public in apps) | Reset if compromised; update apps |
| `RESEND_API_KEY` | Sends usage-limit emails from `chopstickshq@lam.ws` | Resend dashboard → create API key; verify `lam.ws` domain |
| `CHOPSTICKS_AI_FROM_EMAIL` | From header (optional) | Default: `cs.AI <chopstickshq@lam.ws>` |
| `CHOPSTICKS_AI_USAGE_EMAIL` | Toggle usage alerts | Set to `off` to disable; default on when `RESEND_API_KEY` is set |

Never commit these to git. Never log request bodies containing tokens or unlock keys.

After rotation: redeploy Netlify production and verify `/api/chopsticks-ai` health + one chat turn.
