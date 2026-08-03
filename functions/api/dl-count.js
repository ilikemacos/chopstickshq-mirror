import { handler } from "../../api/_lib/dl-count.js";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

export async function onRequest(context) {
  const { request, env } = context;

  if (typeof process !== "undefined" && process.env) {
    if (env.SUPABASE_URL) process.env.SUPABASE_URL = env.SUPABASE_URL;
    if (env.SUPABASE_ANON_KEY) process.env.SUPABASE_ANON_KEY = env.SUPABASE_ANON_KEY;
  }

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS });
  }

  const url = new URL(request.url);
  const body = request.method === "POST" ? await request.text() : "";

  const result = await handler({
    httpMethod: request.method,
    queryStringParameters: Object.fromEntries(url.searchParams),
    headers: Object.fromEntries(request.headers),
    body,
  });

  return new Response(result.body, {
    status: result.statusCode || 200,
    headers: { ...(result.headers || {}), ...CORS },
  });
}
