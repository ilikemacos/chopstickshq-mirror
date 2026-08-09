import { handler } from "../../api/_lib/chopsticks-ai.js";

const ALLOWED_ORIGIN = /^https:\/\/chopstickshq\.com$/;
const PREVIEW_ORIGIN = /^https:\/\/([a-z0-9-]+\.)?netlify\.app$/;
const LOCAL_ORIGIN = /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

function corsOrigin(request) {
  const origin = request.headers.get("Origin") || "";
  if (!origin) return "https://chopstickshq.com";
  if (ALLOWED_ORIGIN.test(origin) || PREVIEW_ORIGIN.test(origin) || LOCAL_ORIGIN.test(origin)) {
    return origin;
  }
  return "https://chopstickshq.com";
}

function corsHeaders(request) {
  return {
    "Access-Control-Allow-Origin": corsOrigin(request),
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Vary": "Origin",
  };
}

export async function onRequest(context) {
  const { request, env } = context;
  const CORS = corsHeaders(request);

  if (typeof process !== "undefined" && process.env) {
    if (env.OPENROUTER_API_KEY) process.env.OPENROUTER_API_KEY = env.OPENROUTER_API_KEY;
    if (env.CHOPSTICKS_AI_MODEL) process.env.CHOPSTICKS_AI_MODEL = env.CHOPSTICKS_AI_MODEL;
    if (env.SUPABASE_URL) process.env.SUPABASE_URL = env.SUPABASE_URL;
    if (env.SUPABASE_ANON_KEY) process.env.SUPABASE_ANON_KEY = env.SUPABASE_ANON_KEY;
    if (env.SUPABASE_SERVICE_ROLE_KEY) process.env.SUPABASE_SERVICE_ROLE_KEY = env.SUPABASE_SERVICE_ROLE_KEY;
    if (env.FATHOM_PRO_HMAC_SECRET) process.env.FATHOM_PRO_HMAC_SECRET = env.FATHOM_PRO_HMAC_SECRET;
    if (env.FATHOM_VAULT_PASSWORD) process.env.FATHOM_VAULT_PASSWORD = env.FATHOM_VAULT_PASSWORD;
    if (env.CHOPSTICKS_AI_BUCKET_SALT) process.env.CHOPSTICKS_AI_BUCKET_SALT = env.CHOPSTICKS_AI_BUCKET_SALT;
    if (env.RESEND_API_KEY) process.env.RESEND_API_KEY = env.RESEND_API_KEY;
    if (env.CHOPSTICKS_AI_FROM_EMAIL) process.env.CHOPSTICKS_AI_FROM_EMAIL = env.CHOPSTICKS_AI_FROM_EMAIL;
    if (env.CHOPSTICKS_AI_USAGE_EMAIL) process.env.CHOPSTICKS_AI_USAGE_EMAIL = env.CHOPSTICKS_AI_USAGE_EMAIL;
    if (env.SERPER_API_KEY) process.env.SERPER_API_KEY = env.SERPER_API_KEY;
    if (env.GOOGLE_CSE_API_KEY) process.env.GOOGLE_CSE_API_KEY = env.GOOGLE_CSE_API_KEY;
    if (env.GOOGLE_CSE_CX) process.env.GOOGLE_CSE_CX = env.GOOGLE_CSE_CX;
    if (env.BRAVE_SEARCH_API_KEY) process.env.BRAVE_SEARCH_API_KEY = env.BRAVE_SEARCH_API_KEY;
  }

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS });
  }

  const body = request.method === "POST" ? await request.text() : "";

  const result = await handler({
    httpMethod: request.method,
    headers: Object.fromEntries(request.headers),
    body,
  });

  return new Response(result.body, {
    status: result.statusCode,
    headers: { ...CORS, ...(result.headers || {}) },
  });
}
