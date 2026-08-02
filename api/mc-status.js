// Vercel serverless entrypoint.
// Reuses the Netlify handler unchanged (api/_lib/mc-status.js) and adapts the
// signature, so the two hosts can't drift apart in behaviour.
const { handler } = require('./_lib/mc-status.js');

module.exports = async (req, res) => {
  let body = req.body;
  if (body && typeof body !== 'string') body = JSON.stringify(body);

  const result = await handler({
    httpMethod: req.method,
    queryStringParameters: req.query || {},
    headers: req.headers || {},
    body: body || '',
  });

  res.status(result.statusCode || 200);
  for (const [k, v] of Object.entries(result.headers || {})) res.setHeader(k, v);
  res.send(result.body);
};
