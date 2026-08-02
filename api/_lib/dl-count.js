/**
 * rNitro download counter — aggregate only, backed by Supabase.
 *
 *   GET  /api/dl-count           -> { total, kinds, copies, mode }
 *   POST /api/dl-count {kind}    -> increments that kind, returns new totals
 *        kind: "zip" | "pkg" | "dmg" | "sh" | "copy"
 *
 * Counts every install route offered on /rnitro: App ZIP, PKG, DMG, the shell
 * installer (both the no-Xcode and compile-from-source paths), and "copy the
 * terminal command".
 *
 * Credentials come from Netlify env (SUPABASE_URL / SUPABASE_ANON_KEY), not
 * from this bundle, and are only ever used server-side — the key is never
 * shipped to a visitor's browser.
 *
 * Writes go through the bump_download() RPC rather than a table UPDATE, so the
 * anon role needs no write grant: it can read the counts and increment by
 * exactly one, and nothing else.
 *
 * Privacy: five integers. No IPs, user agents, cookies, or per-visitor rows,
 * and the browser only ever talks to chopstickshq.com — the site's
 * "no telemetry" claim stays accurate.
 */
const FILE_KINDS = ["zip", "pkg", "dmg", "sh"];   // real file downloads
const ALL_KINDS = [...FILE_KINDS, "copy"];        // + terminal-command copies
const TIMEOUT_MS = 5000;

const URL_BASE = process.env.SUPABASE_URL;
const ANON = process.env.SUPABASE_ANON_KEY;

async function sb(path, init = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${URL_BASE}/rest/v1/${path}`, {
      ...init,
      signal: ctrl.signal,
      headers: {
        apikey: ANON,
        authorization: `Bearer ${ANON}`,
        "content-type": "application/json",
        ...(init.headers || {}),
      },
    });
    const text = await res.text();
    let body = null;
    try {
      body = text ? JSON.parse(text) : null;
    } catch {
      body = text;
    }
    return { ok: res.ok, status: res.status, body };
  } finally {
    clearTimeout(t);
  }
}

function shape(rows) {
  const kinds = {};
  for (const k of ALL_KINDS) kinds[k] = 0;
  if (Array.isArray(rows)) {
    for (const r of rows) {
      if (r && ALL_KINDS.includes(r.kind)) kinds[r.kind] = Number(r.count) || 0;
    }
  }
  return {
    kinds,
    // Copying the terminal one-liner IS an install — it curls the app down and
    // installs it — so it counts toward the headline number alongside the
    // direct file downloads.
    total: ALL_KINDS.reduce((n, k) => n + kinds[k], 0),
    copies: kinds.copy,
  };
}

const empty = () => ({ kinds: {}, total: 0, copies: 0 });

const json = (body, status = 200) => ({
  statusCode: status,
  headers: {
    "content-type": "application/json",
    "cache-control": "no-store",
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    "access-control-allow-headers": "content-type",
  },
  body: JSON.stringify(body),
});

exports.handler = async (event) => {
  if (event.httpMethod === "OPTIONS") return json({ ok: true });
  if (!URL_BASE || !ANON) return json({ ...empty(), mode: "unconfigured" });

  try {
    if (event.httpMethod === "POST") {
      let kind = "zip";
      try {
        kind = String(JSON.parse(event.body || "{}").kind || "zip").toLowerCase();
      } catch {
        /* keep default */
      }
      if (!ALL_KINDS.includes(kind)) kind = "zip";

      const bump = await sb("rpc/bump_download", {
        method: "POST",
        body: JSON.stringify({ p_kind: kind }),
      });
      if (!bump.ok) {
        return json({ ...empty(), mode: "setup-needed", detail: bump.body }, 200);
      }
    }

    const read = await sb("download_counts?select=kind,count");
    if (!read.ok) {
      return json({ ...empty(), mode: "setup-needed", detail: read.body }, 200);
    }
    return json({ ...shape(read.body), mode: "live" });
  } catch (err) {
    // a counter must never break the page
    return json({ ...empty(), mode: "error", error: String(err.message || err) }, 200);
  }
};
