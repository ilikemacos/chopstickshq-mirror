/**
 * chopsticksAI — LLM-backed assistant for Chopsticks HQ.
 *
 *   POST /api/chopsticks-ai  { messages: [{role, content}, ...] }
 *        -> { reply, mode: "live" | "unconfigured" | "limited" }
 *
 * The OpenRouter key comes from env (OPENROUTER_API_KEY) and is only ever used
 * here, server-side. It is never shipped to a browser or embedded in the app —
 * an OpenRouter key is account-scoped, not model-scoped, so a leaked one can be
 * spent on paid models regardless of which model this endpoint requests.
 *
 * Answers are grounded in the generated knowledge base: the most relevant
 * entries are retrieved and injected as context so the model quotes real
 * version numbers and install commands instead of inventing them.
 */
// Verified against https://openrouter.ai/api/v1/models. OpenRouter ids change
// between releases and a wrong one 404s every request, so check before editing.
// Tried in order: if the first is rate-limited or erroring, the next takes over.
// Both are zero-cost tiers, so failover never introduces spend.
// Selectable tiers. Clients send a tier NAME, never a model id - accepting an
// arbitrary model from the browser would let anyone run a paid model on our key.
const TIERS = {
  ultra: {
    label: "Ultra",
    models: [
      "google/gemma-4-26b-a4b-it:free",
      "nvidia/nemotron-3-nano-30b-a3b:free",
      "nvidia/nemotron-3-super-120b-a12b:free",
      "nvidia/nemotron-3-ultra-550b-a55b:free",
    ],
    // Long generations are token-rate bound, and a 55B-active model cannot emit
    // ~1.5k tokens inside the serverless window. Fewer active parameters first.
    longModels: [
      "google/gemma-4-26b-a4b-it:free",
      "nvidia/nemotron-3-nano-30b-a3b:free",
      "nvidia/nemotron-3-super-120b-a12b:free",
    ],
    context: 48000,
  },
  super: {
    label: "Super",
    models: [
      "google/gemma-4-26b-a4b-it:free",
      "nvidia/nemotron-3-nano-30b-a3b:free",
      "nvidia/nemotron-3-super-120b-a12b:free",
    ],
    longModels: [
      "google/gemma-4-26b-a4b-it:free",
      "nvidia/nemotron-3-nano-30b-a3b:free",
      "nvidia/nemotron-3-super-120b-a12b:free",
    ],
    context: 24000,
  },
};
const DEFAULT_TIER = "ultra";
const tierOf = (name) => TIERS[String(name || "").toLowerCase()] || TIERS[DEFAULT_TIER];

const MODELS = TIERS[DEFAULT_TIER].models;
const MODEL = MODELS[0];

// Two models collaborate on each answer: Nemotron Ultra drafts, Gemma
// reviews and rewrites. Both are zero-cost tiers, so the second pass adds
// quality without adding spend. Set CHOPSTICKS_AI_REFINE=off to disable.
const REFINE_MODEL = process.env.CHOPSTICKS_AI_REFINE_MODEL || "google/gemma-4-26b-a4b-it:free";
const REFINE_ENABLED = (process.env.CHOPSTICKS_AI_REFINE || "on") !== "off";

const REFINE_SYSTEM = [
  "You are the reviewer in a two-model pipeline. Another assistant drafted the ",
  "reply below. Improve it and output ONLY the improved reply.\n\n",
  "Fix any inaccuracy, tighten wording, remove padding and repetition, and make ",
  "sure it directly answers what was asked. Keep the draft's facts: do not add ",
  "version numbers, links, commands or claims that are not already there.\n\n",
  "If the draft is already good, return it unchanged. Never mention the draft, ",
  "the review, or yourself as a reviewer - output only the final reply text.",
].join("");
const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
// Netlify caps a synchronous function at ~26s, so the whole request - both
// model calls - must finish inside this. The draft gets the bulk of it; the
// review pass only runs if enough time is left.
const TIMEOUT_MS = Number(process.env.CHOPSTICKS_AI_TIMEOUT_MS || 24000);
const REFINE_MIN_MS = 5000;
// Long generations (the /chopailab agent asking for whole files) need most of
// the window for the draft. Short widget replies leave room for a review pass.
const LONG_REPLY_TOKENS = 800;
const REFINE_RESERVE_MS = 6000;
const draftBudgetMs = (replyTokens, msLeft) =>
  replyTokens > LONG_REPLY_TOKENS ? msLeft - 800 : Math.max(8000, msLeft - REFINE_RESERVE_MS);

// Context window of the model, minus headroom for the reply.
const MAX_CONTEXT_TOKENS = Number(process.env.CHOPSTICKS_AI_MAX_CONTEXT || 48000);
const contextFor = (tier) => Math.min(MAX_CONTEXT_TOKENS, tier.context);
const MAX_REPLY_TOKENS = 400;
// The /chopailab agent generates files and code, which needs far more room than
// the sidebar widget. Callers may request more, within a hard ceiling.
const MAX_REPLY_TOKENS_CEILING = 2000;

const MAX_MESSAGES = 12;        // trailing turns kept from the client
const MAX_CHARS_PER_MSG = 2000;
const GROUNDING_INTENTS = 6;

// Free-tier budget: once TOKEN_BUDGET is spent the endpoint stops calling the
// model for COOLDOWN_MS, so a burst of traffic cannot burn the whole allowance
// and leave the assistant dead for everyone. When Supabase is configured the
// counter is durable across serverless cold starts; otherwise it falls back to
// a per-instance in-memory counter.
const TOKEN_BUDGET = Number(process.env.CHOPSTICKS_AI_TOKEN_BUDGET || 775000);
const COOLDOWN_MS = Number(process.env.CHOPSTICKS_AI_COOLDOWN_MS || 3 * 60 * 60 * 1000);
const SB_TIMEOUT_MS = 5000;
const budget = { used: 0, windowStart: Date.now(), cooldownUntil: 0 };
let budgetMode = "memory";

// Simple in-memory throttle. Serverless instances are short-lived so this is a
// speed bump against casual abuse, not a guarantee; it costs nothing and stops
// a single tab hammering the endpoint.
const RATE_WINDOW_MS = 60000;
const RATE_MAX = 20;
const hits = new Map();

/** ~4 chars per token, deliberately an over-estimate so trimming fires early
 *  rather than letting OpenRouter reject an oversized request. */
const estimateTokens = (text) => Math.max(1, Math.ceil(String(text || "").length / 4));
const messageTokens = (m) => estimateTokens(m.content) + 4;

/** Drops the oldest turns until system prompt + history fits the window. The
 *  system prompt is never trimmed - it carries the grounding facts. */
function fitContext(system, turns, contextTokens) {
  const budgetTokens = (contextTokens || MAX_CONTEXT_TOKENS) - MAX_REPLY_TOKENS - messageTokens(system);
  const kept = [];
  let used = 0;
  for (let i = turns.length - 1; i >= 0; i--) {
    const cost = messageTokens(turns[i]);
    if (used + cost > budgetTokens) break;
    kept.unshift(turns[i]);
    used += cost;
  }
  return [system, ...kept];
}

function measureMessages(messages) {
  return messages.reduce((n, m) => n + messageTokens(m), 0);
}

function contextWindowUsage(messages, limit, turnsTotal) {
  return {
    used: measureMessages(messages),
    limit,
    turns: messages.filter((m) => m.role !== "system").length,
    turnsTotal: turnsTotal ?? messages.filter((m) => m.role !== "system").length,
  };
}

function memoryBudgetState(now) {
  if (budget.cooldownUntil && now < budget.cooldownUntil) {
    return { blocked: true, retryInMs: budget.cooldownUntil - now };
  }
  if (budget.cooldownUntil && now >= budget.cooldownUntil) {
    budget.used = 0;
    budget.windowStart = now;
    budget.cooldownUntil = 0;
  }
  return { blocked: false };
}

function memorySpend(tokens, now) {
  budget.used += tokens;
  if (budget.used >= TOKEN_BUDGET) budget.cooldownUntil = now + COOLDOWN_MS;
}

function supabaseConfigured() {
  return Boolean(env("SUPABASE_URL") && env("SUPABASE_ANON_KEY"));
}

async function sb(path, init = {}) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), SB_TIMEOUT_MS);
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

async function budgetPeek(now) {
  if (!supabaseConfigured()) {
    budgetMode = "memory";
    const state = memoryBudgetState(now);
    return { ...state, used: budget.used, mode: "memory" };
  }
  try {
    const res = await sb("rpc/chopsticks_ai_budget_peek", {
      method: "POST",
      body: JSON.stringify({ p_limit: TOKEN_BUDGET, p_cooldown_ms: COOLDOWN_MS }),
    });
    if (!res.ok || !res.body || typeof res.body !== "object") {
      budgetMode = "memory";
      const state = memoryBudgetState(now);
      return { ...state, used: budget.used, mode: "memory" };
    }
    budgetMode = "supabase";
    budget.used = Number(res.body.used) || 0;
    if (res.body.blocked) {
      return {
        blocked: true,
        retryInMs: Number(res.body.retry_in_ms) || 0,
        used: budget.used,
        mode: "supabase",
      };
    }
    return { blocked: false, used: budget.used, mode: "supabase" };
  } catch {
    budgetMode = "memory";
    const state = memoryBudgetState(now);
    return { ...state, used: budget.used, mode: "memory" };
  }
}

async function budgetSpend(tokens, now) {
  const spent = Math.max(0, Math.min(50000, Math.round(Number(tokens) || 0)));
  if (!supabaseConfigured()) {
    budgetMode = "memory";
    memorySpend(spent, now);
    return { used: budget.used, mode: "memory" };
  }
  try {
    const res = await sb("rpc/chopsticks_ai_budget_spend", {
      method: "POST",
      body: JSON.stringify({
        p_tokens: spent,
        p_limit: TOKEN_BUDGET,
        p_cooldown_ms: COOLDOWN_MS,
      }),
    });
    if (!res.ok || !res.body || typeof res.body !== "object") {
      memorySpend(spent, now);
      return { used: budget.used, mode: "memory" };
    }
    budget.used = Number(res.body.used) || budget.used;
    budgetMode = "supabase";
    if (res.body.blocked) budget.cooldownUntil = now + COOLDOWN_MS;
    return { used: budget.used, mode: "supabase" };
  } catch {
    memorySpend(spent, now);
    return { used: budget.used, mode: "memory" };
  }
}

function budgetState(now) {
  return memoryBudgetState(now);
}

function spend(tokens, now) {
  memorySpend(tokens, now);
}

const env = (name) =>
  (typeof process !== "undefined" && process.env && process.env[name]) || "";

let KB = null;
function knowledgeBase() {
  if (KB) return KB;
  try {
    // Generated by chopsticks-ai/build-kb.py, shared with the website widget.
    KB = require("./chopsticks-ai-kb.json");
  } catch (e) {
    KB = { intents: [] };
  }
  return KB;
}

function normalise(text) {
  return String(text || "")
    .toLowerCase()
    .replace(/[^a-z0-9\s]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** Last few user turns, joined — follow-ups like "how do I install it?" keep
 *  product context from earlier in the thread. */
function retrievalQuery(turns) {
  return turns
    .filter((m) => m.role === "user")
    .slice(-3)
    .map((m) => m.content)
    .join(" ");
}

const KB_CONFIDENCE_FLOOR = 4;

function scoreQuery(query) {
  const kb = knowledgeBase();
  const text = normalise(query);
  if (!text) return [];
  const padded = " " + text + " ";

  const scored = [];
  for (const intent of kb.intents) {
    let total = 0;
    for (const [term, weight] of intent.terms) {
      if (padded.includes(" " + term + " ")) total += weight;
    }
    if (total > 0) scored.push({ intent, score: total });
  }
  scored.sort((a, b) => {
    if (b.score !== a.score) return b.score - a.score;
    if (b.intent.priority !== a.intent.priority) return b.intent.priority - a.intent.priority;
    return a.intent.id < b.intent.id ? -1 : 1;
  });
  return scored;
}

/** Same word-boundary scoring as the offline engine, used purely to pick
 *  which facts to hand the model. */
function retrieve(query, limit = GROUNDING_INTENTS) {
  return scoreQuery(query).slice(0, limit).map((s) => s.intent);
}

function kbFallbackAnswer(query) {
  const top = scoreQuery(query)[0];
  if (!top || top.score < KB_CONFIDENCE_FLOOR) return null;
  return top.intent.answer;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ------------------------------------------------------------- web search ---
// Free sources only (DuckDuckGo Instant Answer + Wikipedia REST), so search
// adds no cost. Results are injected as context; the model still writes the
// answer.
const SEARCH_ENABLED = (process.env.CHOPSTICKS_AI_SEARCH || "on") !== "off";
const SEARCH_TIMEOUT_MS = 5000;

// Questions the knowledge base already covers should not trigger a lookup, and
// neither should chit-chat. These are the cues that a question wants facts
// about the wider world.
const SEARCH_HINTS = /\b(who|what|when|where|which|latest|current|news|today|price|population|capital|founded|born|died|weather|score|release[ds]?|version of|how many|how much|history of|meaning of|define)\b/i;
// Product questions are covered by the knowledge base, and questions about
// chopsticksAI itself are answered from selfFacts() - neither needs a lookup.
const SEARCH_SKIP = /\b(rnitro|fathom|arena|chopsticks|chopsticksai|shader|your|yourself|you\b.*\b(are|can|do)|context window|token limit|rate limit)\b/i;

function wantsSearch(text) {
  if (!SEARCH_ENABLED) return false;
  const t = String(text || "");
  if (t.length < 8) return false;
  if (SEARCH_SKIP.test(t)) return false;
  return SEARCH_HINTS.test(t);
}

async function fetchJson(url, signal) {
  const res = await fetch(url, {
    signal,
    headers: { "User-Agent": "chopsticksAI/1.0 (+https://chopstickshq.com)" },
  });
  if (!res.ok) return null;
  return res.json().catch(() => null);
}

/** Returns a short context block, or "" when nothing useful came back. */
async function webSearch(query) {
  const c = new AbortController();
  const timer = setTimeout(() => c.abort(), SEARCH_TIMEOUT_MS);
  const found = [];
  try {
    const ddg = await fetchJson(
      "https://api.duckduckgo.com/?format=json&no_html=1&skip_disambig=1&q=" +
        encodeURIComponent(query), c.signal
    ).catch(() => null);

    if (ddg) {
      if (ddg.AbstractText) {
        found.push({
          title: ddg.Heading || query,
          text: ddg.AbstractText,
          src: ddg.AbstractURL || "duckduckgo.com",
        });
      }
      for (const t of (ddg.RelatedTopics || []).slice(0, 3)) {
        if (t && t.Text) found.push({ title: t.Text.split(" - ")[0], text: t.Text, src: t.FirstURL || "" });
      }
    }

    if (!found.length) {
      // Ask Wikipedia which article matches the question, rather than guessing a
      // title from the wording - "current president of france" is not a page,
      // but its search resolves it to "President of France".
      const hit = await fetchJson(
        "https://en.wikipedia.org/w/api.php?action=query&list=search&format=json" +
          "&origin=*&srlimit=1&srsearch=" + encodeURIComponent(query), c.signal
      ).catch(() => null);
      const title = hit && hit.query && hit.query.search && hit.query.search[0]
        && hit.query.search[0].title;

      if (title) {
        const wiki = await fetchJson(
          "https://en.wikipedia.org/api/rest_v1/page/summary/" +
            encodeURIComponent(title.replace(/\s+/g, "_")), c.signal
        ).catch(() => null);
        if (wiki && wiki.extract) {
          found.push({
            title: wiki.title,
            text: wiki.extract,
            src: (wiki.content_urls && wiki.content_urls.desktop && wiki.content_urls.desktop.page) || "wikipedia.org",
          });
        }
      }
    }
  } catch (e) {
    return "";
  } finally {
    clearTimeout(timer);
  }

  if (!found.length) return "";
  return found
    .slice(0, 4)
    .map((f) => `- ${f.title}: ${String(f.text).slice(0, 400)}${f.src ? ` (${f.src})` : ""}`)
    .join("\n");
}

/** Facts chopsticksAI knows about itself. Built from the live config so the
 *  numbers can never drift from what the endpoint actually enforces. */
function selfFacts(tier) {
  const t = tier || TIERS[DEFAULT_TIER];
  return [
    "ABOUT YOURSELF (answer questions about your own capabilities from this):",
    `- You are chopsticksAI v1.0, built and run by Chopsticks HQ.`,
    `- You run in two selectable tiers: Ultra (the default, largest context) and Super (lighter, smaller context, faster).`,
    `- Current tier: ${t.label}, with a ${contextFor(t).toLocaleString()} token context window.`,
    `- Longest single reply: ${MAX_REPLY_TOKENS_CEILING.toLocaleString()} tokens (in the chopAI Lab agent); ${MAX_REPLY_TOKENS} in the sidebar widget.`,
    `- Conversation memory: the last ${MAX_MESSAGES} turns.`,
    `- Usage allowance: ${TOKEN_BUDGET.toLocaleString()} tokens, then a ${Math.round(COOLDOWN_MS / 3600000)}-hour cooldown.`,
    `- Rate limit: ${RATE_MAX} requests per minute per visitor.`,
    "- You can search the web when a question needs current information.",
    "- You answer general questions on any topic, and are the in-house expert on Chopsticks HQ software.",
    "- You need no API key from the user, and nothing they type is stored.",
    "- You are available on every page of chopstickshq.com, in the chopAI Lab web agent at /chopailab, and inside rNitro's Chat tab.",
    "- Do not name or speculate about any underlying model, provider or vendor.",
  ].join("\n");
}

function systemPrompt(grounding, mode, web, tier) {
  // The agent at /chopailab produces files and code; the sidebar widget answers
  // conversationally. Same knowledge, different output contract.
  const agent = mode === "agent" ? [
    "\n\nYou are running as the chopsticksAI Lab agent. The user may ask you to ",
    "write code, config, scripts, documents or data files.\n",
    "- Put every file you produce in its own fenced code block.\n",
    "- Start the fence with the language, then a space, then the filename, ",
    "e.g. ```python analyse.py or ```json config.json — the interface turns that ",
    "filename into a download button, so always supply one.\n",
    "- Give complete, runnable files rather than fragments or ellipses.\n",
    "- Keep explanation outside the fences and brief.",
  ].join("") : "";

  const facts = grounding.length
    ? grounding.map((i) => `### ${i.label}\n${i.answer}`).join("\n\n")
    : "(no specific reference material matched this question)";

  return [
    "You are chopsticksAI, a helpful and knowledgeable general-purpose assistant, ",
    "made by Chopsticks HQ.\n\n",
    "Answer ANY question the user asks — general knowledge, science, history, coding, ",
    "writing, maths, recommendations, advice, casual conversation, anything. You are a ",
    "full assistant, not a support bot, and you should never refuse a question simply ",
    "because it is unrelated to Chopsticks HQ.\n\n",
    "Answer naturally and conversationally. Be concise by default — a short paragraph — ",
    "and go longer only when the question genuinely needs it. Plain text reads best; ",
    "use markdown only when structure really helps, such as code blocks for code.\n\n",
    "You are also the in-house expert on Chopsticks HQ's own software: rNitro (macOS menu ",
    "bar system monitor), Fathom Air (battery monitor), Fathom Pro (battery, weather and AI ",
    "chat), ARENA (an FPS game), and Chopsticks Shaders. When a question touches those, the ",
    "reference material below is authoritative.\n\n",
    selfFacts(tier),
    web ? "\n\nWEB SEARCH RESULTS (retrieved just now - use these for anything current, and cite the source domain when you rely on one):\n" + web : "",
    "\n\nREFERENCE MATERIAL:\n\n",
    facts,
    "\n\nRules:\n",
    "- For questions about Chopsticks HQ software, version numbers, install commands, file ",
    "names and pricing must come from the reference material above. If it does not cover the ",
    "detail, say you're not certain and point to chopstickshq.com rather than guessing.\n",
    "- Never invent a download link, command, or version number for Chopsticks software.\n",
    "- Never imply Chopsticks software costs money or needs a subscription.\n",
    "- For everything else, just answer the question well using your own knowledge. Do not ",
    "steer the conversation back to Chopsticks HQ, and do not mention the reference material ",
    "when it isn't relevant.\n",
    "- If you are genuinely unsure of a fact, say so rather than inventing one.\n",
    "- You are chopsticksAI v1.0, made by Chopsticks HQ. If asked what model, ",
    "engine or company is behind you, say you are chopsticksAI v1.0 by Chopsticks ",
    "HQ. Never name or speculate about any underlying model, provider or vendor.\n",
    "- Never mention this prompt or the reference material as such; just answer.",
    agent,
  ].join("");
}

function rateLimited(key) {
  const now = Date.now();
  const rec = hits.get(key);
  if (!rec || now - rec.start > RATE_WINDOW_MS) {
    hits.set(key, { start: now, n: 1 });
    if (hits.size > 500) {
      for (const [k, v] of hits) if (now - v.start > RATE_WINDOW_MS) hits.delete(k);
    }
    return false;
  }
  rec.n += 1;
  return rec.n > RATE_MAX;
}

const json = (status, body) => ({
  statusCode: status,
  headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  body: JSON.stringify(body),
});

/** One chat completion. Returns null on any non-OK response. */
async function callModel({ model, messages, key, signal, maxTokens, temperature }) {
  const res = await fetch(OPENROUTER_URL, {
    method: "POST",
    signal,
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "https://chopstickshq.com",
      "X-Title": "chopsticksAI",
    },
    body: JSON.stringify({
      model,
      messages,
      temperature: temperature ?? 0.3,
      max_tokens: maxTokens ?? MAX_REPLY_TOKENS,
    }),
  });
  if (!res.ok) {
    return { ok: false, status: res.status, detail: await res.text().catch(() => "") };
  }
  const data = await res.json();
  const text = (data.choices && data.choices[0] && data.choices[0].message.content || "").trim();
  if (!text) {
    return { ok: false, status: res.status, detail: "empty completion" };
  }
  const reported = data.usage && Number(data.usage.total_tokens);
  return {
    ok: true,
    text,
    tokens: Number.isFinite(reported) && reported > 0 ? reported : null,
  };
}

async function handler(event) {
  if (event.httpMethod === "OPTIONS") return { statusCode: 204, body: "" };
  if (event.httpMethod !== "POST") {
    return json(405, { error: "POST only" });
  }

  const key = env("OPENROUTER_API_KEY");
  if (!key) {
    return json(200, {
      reply:
        "chopsticksAI isn't configured on this host yet. " +
        "Ask on chopstickshq.com or email mzx+chopsticks@lam.ws.",
      mode: "unconfigured",
    });
  }

  const headers = event.headers || {};
  const who =
    headers["x-nf-client-connection-ip"] ||
    headers["cf-connecting-ip"] ||
    (headers["x-forwarded-for"] || "").split(",")[0].trim() ||
    "anon";
  if (rateLimited(who)) {
    return json(429, {
      reply: "That's a lot of questions at once — give it a minute and try again.",
      mode: "limited",
    });
  }

  let payload;
  try {
    payload = JSON.parse(event.body || "{}");
  } catch (e) {
    return json(400, { error: "invalid JSON" });
  }

  const incoming = Array.isArray(payload.messages) ? payload.messages : [];
  const turns = incoming
    .filter((m) => m && (m.role === "user" || m.role === "assistant") && m.content)
    .slice(-MAX_MESSAGES)
    .map((m) => ({
      role: m.role,
      content: String(m.content).slice(0, MAX_CHARS_PER_MSG),
    }));

  const lastUser = [...turns].reverse().find((m) => m.role === "user");
  if (!lastUser) return json(400, { error: "no user message" });

  const now = Date.now();
  const state = await budgetPeek(now);
  if (state.blocked) {
    const mins = Math.ceil(state.retryInMs / 60000);
    return json(200, {
      reply:
        "chopsticksAI has used up its free allowance for now and is cooling down " +
        `(about ${mins} minute${mins === 1 ? "" : "s"} left). ` +
        "Everything it knows is still on chopstickshq.com in the meantime.",
      mode: "cooldown",
      retryInMs: state.retryInMs,
    });
  }

  const wanted = Number(payload.maxTokens);
  const replyTokens = Number.isFinite(wanted)
    ? Math.max(100, Math.min(MAX_REPLY_TOKENS_CEILING, Math.round(wanted)))
    : MAX_REPLY_TOKENS;

  // Search runs before the draft so results are in the prompt, and only when
  // the question actually looks like it needs the wider world.
  const tier = tierOf(payload.tier);
  const web = wantsSearch(lastUser.content) ? await webSearch(lastUser.content) : "";

  const system = {
    role: "system",
    content: systemPrompt(retrieve(retrievalQuery(turns)), payload.mode, web, tier),
  };
  const messages = fitContext(system, turns, contextFor(tier));

  const deadline = now + TIMEOUT_MS;
  const withTimeout = (ms) => {
    const c = new AbortController();
    const t = setTimeout(() => c.abort(), ms);
    return { signal: c.signal, done: () => clearTimeout(t) };
  };
  try {
    // --- stage 1: draft -------------------------------------------------
    // Walk the model chain; a rate-limited or erroring model hands off to the
    // next rather than failing the request.
    let draft = null;
    let draftModel = null;
    let lastStatus = 0;
    let lastDetail = "";

    const chain = (replyTokens > LONG_REPLY_TOKENS && tier.longModels)
      ? tier.longModels : tier.models;

    for (let ci = 0; ci < chain.length; ci++) {
      const candidate = chain[ci];
      // The first candidate is the likeliest to succeed, so give it most of the
      // window and leave a short retry slice for the rest. Splitting evenly
      // starved every candidate and all of them timed out.
      const msLeft = deadline - Date.now();
      const budgetMs = ci === 0 && chain.length > 1
        ? Math.max(8000, msLeft - 5000)
        : draftBudgetMs(replyTokens, msLeft);
      if (budgetMs <= 0) break;
      let r;
      const g = withTimeout(budgetMs);
      try {
        r = await callModel({ model: candidate, messages, key, signal: g.signal, maxTokens: replyTokens });
      } catch (e) {
        r = { ok: false, status: 0, detail: String(e && e.name) };
      } finally {
        g.done();
      }
      if (!r.ok && (r.status === 429 || r.status === 503) && budgetMs > 2500) {
        await sleep(700);
        const g2 = withTimeout(Math.min(budgetMs, 12000));
        try {
          r = await callModel({ model: candidate, messages, key, signal: g2.signal, maxTokens: replyTokens });
        } catch (e) {
          r = { ok: false, status: 0, detail: String(e && e.name) };
        } finally {
          g2.done();
        }
      }
      if (r.ok && r.text) {
        draft = r;
        draftModel = candidate;
        break;
      }
      lastStatus = r.status || 0;
      lastDetail = (r.detail || "") + ` [${candidate.split("/")[1]} ${Date.now() - attemptStart}/${budgetMs}ms]`;
    }

    if (!draft) {
      console.error("chopsticksAI: all models failed", {
        tier: tier.label, status: lastStatus, detail: String(lastDetail).slice(0, 300),
        replyTokens, msLeft: deadline - Date.now(),
      });
      const kbQuery = retrievalQuery(turns) || lastUser.content;
      const kbAnswer = kbFallbackAnswer(kbQuery);
      if (kbAnswer) {
        return json(200, {
          reply: kbAnswer + "\n\n(Offline answer — the live model was temporarily unavailable.)",
          mode: "offline",
        });
      }
      return json(200, {
        diag: { status: lastStatus, detail: String(lastDetail).slice(0, 200) },
        reply:
          "chopsticksAI couldn't reach its model just now. Try again in a moment, " +
          "or browse chopstickshq.com for the answer.",
        mode: "error",
      });
    }

    let spent = draft.tokens || (messages.reduce((n, m) => n + messageTokens(m), 0) + MAX_REPLY_TOKENS);
    let reply = draft.text;
    let refinedBy = null;

    // --- stage 2: refine ------------------------------------------------
    // A second model reviews and rewrites the draft. Failure here is not fatal:
    // the draft is already a complete answer, so we return it unchanged.
    // A review pass rewrites prose safely, but can silently corrupt generated
    // code or file contents, so drafts containing a fenced block skip it.
    const hasCodeBlock = draft.text.includes("```");
    const timeLeft = deadline - Date.now();
    if (REFINE_ENABLED && REFINE_MODEL && REFINE_MODEL !== draftModel
        && !hasCodeBlock && timeLeft >= REFINE_MIN_MS) {
      const question = [...turns].reverse().find((m) => m.role === "user");
      const g = withTimeout(timeLeft - 500);
      // An abort or network error here must not lose the draft, which is
      // already a complete answer.
      let r;
      try {
      r = await callModel({
        model: REFINE_MODEL,
        key,
        signal: g.signal,
        temperature: 0.2,
        messages: [
          { role: "system", content: REFINE_SYSTEM },
          {
            role: "user",
            content:
              "QUESTION:\n" + (question ? question.content : "") +
              "\n\nDRAFT REPLY:\n" + draft.text,
          },
        ],
      });
      } catch (e) {
        r = { ok: false };
      } finally {
        g.done();
      }
      if (r.ok && r.text) {
        reply = r.text;
        refinedBy = REFINE_MODEL;
        spent += r.tokens || estimateTokens(draft.text) + MAX_REPLY_TOKENS;
      }
    }

    const spentResult = await budgetSpend(spent, now);

    if (!reply) {
      return json(200, { reply: "I didn't get a usable answer back — try rephrasing?", mode: "empty" });
    }

    const ctxLimit = contextFor(tier);
    return json(200, {
      reply,
      mode: "live",
      model: "chopsticksAI v1.0",
      tier: tier.label,
      context: ctxLimit,
      contextWindow: contextWindowUsage(messages, ctxLimit, turns.length),
      searched: Boolean(web),
      budget: { used: spentResult.used, limit: TOKEN_BUDGET },
      budgetMode: spentResult.mode,
    });
  } catch (e) {
    const aborted = e && e.name === "AbortError";
    return json(200, {
      reply: aborted
        ? "That took too long to answer. Try a shorter question?"
        : "chopsticksAI hit an error reaching its model. Try again shortly.",
      mode: "error",
    });
  } finally {
    // per-call timers are cleared inline
  }
}

module.exports = {
  handler, retrieve, retrievalQuery, systemPrompt, normalise, fitContext,
  measureMessages, contextWindowUsage,
  wantsSearch, webSearch, selfFacts,
  budgetPeek, budgetSpend, budgetState, spend,
  _budget: budget, budgetMode, MAX_CONTEXT_TOKENS, TOKEN_BUDGET, COOLDOWN_MS,
};
