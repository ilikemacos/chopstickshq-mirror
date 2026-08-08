import { handler } from "../../api/_lib/chopsticks-ai.js";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

export async function onRequest(context) {
  const { request, env } = context;

  if (typeof process !== "undefined" && process.env) {
    if (env.OPENROUTER_API_KEY) process.env.OPENROUTER_API_KEY = env.OPENROUTER_API_KEY;
    if (env.CHOPSTICKS_AI_MODEL) process.env.CHOPSTICKS_AI_MODEL = env.CHOPSTICKS_AI_MODEL;
    if (env.SUPABASE_URL) process.env.SUPABASE_URL = env.SUPABASE_URL;
    if (env.SUPABASE_ANON_KEY) process.env.SUPABASE_ANON_KEY = env.SUPABASE_ANON_KEY;
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
