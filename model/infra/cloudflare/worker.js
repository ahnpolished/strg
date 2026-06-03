// Cloudflare Worker — proxies requests to the current RunPod serverless endpoint.
//
// Deploy once, update the SERVERLESS_URL env var when the endpoint changes.
// Your app always hits https://strg-api.yourdomain.com — the Worker
// forwards to whatever RunPod endpoint is currently active.

export default {
  async fetch(request, env, ctx) {
    const serverlessUrl = env.SERVERLESS_URL;
    if (!serverlessUrl) {
      return new Response(JSON.stringify({ error: "SERVERLESS_URL not configured" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    const url = new URL(request.url);
    const targetUrl = `${serverlessUrl}${url.pathname}${url.search}`;

    // Forward the request to RunPod
    const modified = new Request(targetUrl, {
      method: request.method,
      headers: request.headers,
      body: request.method !== "GET" && request.method !== "HEAD" ? request.body : undefined,
      redirect: "follow",
    });

    try {
      const response = await fetch(modified);
      const responseBody = await response.text();

      return new Response(responseBody, {
        status: response.status,
        headers: {
          "Content-Type": response.headers.get("Content-Type") || "application/json",
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
          "Access-Control-Allow-Headers": "*",
        },
      });
    } catch (e) {
      return new Response(JSON.stringify({ error: `Proxy failed: ${e.message}` }), {
        status: 502,
        headers: { "Content-Type": "application/json" },
      });
    }
  },

  async scheduled(event, env, ctx) {
    // No-op: worker has no scheduled tasks
  },
};
