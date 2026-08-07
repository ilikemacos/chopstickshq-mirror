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
const MODELS = (process.env.CHOPSTICKS_AI_MODEL ||
  "nvidia/nemotron-3-ultra-550b-a55b:free,nvidia/nemotron-3-super-120b-a12b:free,google/gemma-4-26b-a4b-it:free")
  .split(",").map((m) => m.trim()).filter(Boolean);
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
const MAX_REPLY_TOKENS = 400;
// The /chopailab agent generates files and code, which needs far more room than
// the sidebar widget. Callers may request more, within a hard ceiling.
const MAX_REPLY_TOKENS_CEILING = 2000;

const MAX_MESSAGES = 12;        // trailing turns kept from the client
const MAX_CHARS_PER_MSG = 2000;
const GROUNDING_INTENTS = 6;

// Free-tier budget: once TOKEN_BUDGET is spent the endpoint stops calling the
// model for COOLDOWN_MS, so a burst of traffic cannot burn the whole allowance
// and leave the assistant dead for everyone.
const TOKEN_BUDGET = Number(process.env.CHOPSTICKS_AI_TOKEN_BUDGET || 775000);
const COOLDOWN_MS = Number(process.env.CHOPSTICKS_AI_COOLDOWN_MS || 3 * 60 * 60 * 1000);
const budget = { used: 0, windowStart: Date.now(), cooldownUntil: 0 };

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
function fitContext(system, turns) {
  const budgetTokens = MAX_CONTEXT_TOKENS - MAX_REPLY_TOKENS - messageTokens(system);
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

function budgetState(now) {
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

function spend(tokens, now) {
  budget.used += tokens;
  if (budget.used >= TOKEN_BUDGET) budget.cooldownUntil = now + COOLDOWN_MS;
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

/** Same word-boundary scoring as the offline engine, used purely to pick
 *  which facts to hand the model. */
function retrieve(query, limit = GROUNDING_INTENTS) {
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
  return scored.slice(0, limit).map((s) => s.intent);
}

function systemPrompt(grounding, mode) {
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
    "REFERENCE MATERIAL:\n\n",
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
  const state = budgetState(now);
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

  const system = { role: "system", content: systemPrompt(retrieve(retrievalQuery(turns)), payload.mode) };
  const messages = fitContext(system, turns);

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

    for (const candidate of MODELS) {
      const budgetMs = draftBudgetMs(replyTokens, deadline - Date.now());
      if (budgetMs <= 0) break;
      const g = withTimeout(budgetMs);
      let r;
      try {
        r = await callModel({ model: candidate, messages, key, signal: g.signal, maxTokens: replyTokens });
      } catch (e) {
        r = { ok: false, status: 0, detail: String(e && e.name) };
      } finally {
        g.done();
      }
      if (r.ok && r.text) {
        draft = r;
        draftModel = candidate;
        break;
      }
      lastStatus = r.status || 0;
      lastDetail = r.detail || "";
    }

    if (!draft) {
      return json(200, {
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

    spend(spent, now);

    if (!reply) {
      return json(200, { reply: "I didn't get a usable answer back — try rephrasing?", mode: "empty" });
    }

    return json(200, {
      reply,
      mode: "live",
      model: "chopsticksAI v1.0",
      budget: { used: budget.used, limit: TOKEN_BUDGET },
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
  _budget: budget, MAX_CONTEXT_TOKENS, TOKEN_BUDGET, COOLDOWN_MS,
};
