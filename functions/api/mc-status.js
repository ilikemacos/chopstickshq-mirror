import { handler } from "../../api/_lib/mc-status.js";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
};

export async function onRequest(context) {
  const { request, env } = context;

  if (typeof process !== "undefined" && process.env) {
    for (const [k, v] of Object.entries(env)) {
      if (typeof v === "string") process.env[k] = v;
    }
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
