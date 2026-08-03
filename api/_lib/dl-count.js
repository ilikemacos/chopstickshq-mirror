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

const PRODUCTS = {
  rnitro: { prefix: "", kinds: ALL_KINDS },
  arena: { prefix: "arena_", kinds: ["zip", "sh", "copy"] },
};

const productOf = (name) =>
  PRODUCTS[String(name || "rnitro").toLowerCase()] || PRODUCTS.rnitro;

const rowKey = (product, kind) => product.prefix + kind;

const env = (name) =>
  (typeof process !== "undefined" && process.env && process.env[name]) || "";

async function sb(path, init = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const res = await fetch(`${env("SUPABASE_URL")}/rest/v1/${path}`, {
      ...init,
      signal: ctrl.signal,
      headers: {
        apikey: env("SUPABASE_ANON_KEY"),
        authorization: `Bearer ${env("SUPABASE_ANON_KEY")}`,
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

function shape(rows, product) {
  const kinds = {};
  for (const k of product.kinds) kinds[k] = 0;
  if (Array.isArray(rows)) {
    for (const r of rows) {
      if (!r) continue;
      for (const k of product.kinds) {
        if (r.kind === rowKey(product, k)) kinds[k] = Number(r.count) || 0;
      }
    }
  }
  return {
    kinds,
    // Copying the terminal one-liner IS an install — it curls the app down and
    // installs it — so it counts toward the headline number alongside the
    // direct file downloads.
    total: product.kinds.reduce((n, k) => n + (kinds[k] || 0), 0),
    copies: kinds.copy || 0,
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
  if (!env("SUPABASE_URL") || !env("SUPABASE_ANON_KEY"))
    return json({ ...empty(), mode: "unconfigured" });

  const q = event.queryStringParameters || {};

  try {
    let product = productOf(q.product);

    if (event.httpMethod === "POST") {
      let kind = "zip";
      let body = {};
      try {
        body = JSON.parse(event.body || "{}");
      } catch {
        body = {};
      }
      if (body.product) product = productOf(body.product);
      kind = String(body.kind || "zip").toLowerCase();
      if (!product.kinds.includes(kind)) kind = "zip";

      const bump = await sb("rpc/bump_download", {
        method: "POST",
        body: JSON.stringify({ p_kind: rowKey(product, kind) }),
      });
      if (!bump.ok) {
        return json({ ...empty(), mode: "setup-needed", detail: bump.body }, 200);
      }
    }

    const read = await sb("download_counts?select=kind,count");
    if (!read.ok) {
      return json({ ...empty(), mode: "setup-needed", detail: read.body }, 200);
    }
    return json({ ...shape(read.body, product), mode: "live" });
  } catch (err) {
    // a counter must never break the page
    return json({ ...empty(), mode: "error", error: String(err.message || err) }, 200);
  }
};
