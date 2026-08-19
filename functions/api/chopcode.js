import { handleChopCode } from "../../api/_lib/chopcode.js";

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
    Vary: "Origin",
  };
}

function copyEnv(env) {
  if (typeof process === "undefined" || !process.env || !env) return;
  const keys = [
    "OPENROUTER_API_KEY",
    "SUPABASE_URL",
    "SUPABASE_ANON_KEY",
    "SUPABASE_SERVICE_ROLE_KEY",
    "FATHOM_PRO_HMAC_SECRET",
    "CHOPSTICKS_AI_BUCKET_SALT",
  ];
  for (const k of keys) {
    if (env[k]) process.env[k] = env[k];
  }
}

export async function onRequest(context) {
  const { request, env } = context;
  const CORS = corsHeaders(request);
  copyEnv(env);

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS });
  }

  const body = request.method === "POST" ? await request.text() : "";
  const result = await handleChopCode({
    httpMethod: request.method,
    headers: Object.fromEntries(request.headers),
    body,
  });

  if (result.webStream) {
    return new Response(result.webStream, {
      status: result.statusCode || 200,
      headers: { ...CORS, ...(result.headers || {}) },
    });
  }

  return new Response(result.body || "", {
    status: result.statusCode,
    headers: { ...CORS, ...(result.headers || {}) },
  });
}
