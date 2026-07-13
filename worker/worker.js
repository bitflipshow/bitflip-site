export default {
  async fetch(request, env, ctx) {
    // Only allow GET and HEAD
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const url = new URL(request.url);
    const filename = url.pathname.slice(1); // strip leading /

    if (!filename) {
      return new Response("Not Found", { status: 404 });
    }

    // Parse Range header if present
    // e.g. "bytes=1024-2047" or "bytes=1024-"
    const rangeHeader = request.headers.get("Range");
    let range;
    if (rangeHeader) {
      const match = rangeHeader.match(/^bytes=(\d+)-(\d*)$/);
      if (match) {
        range = {
          offset: parseInt(match[1], 10),
          // If no end specified, R2 will return to end of object
          ...(match[2] !== "" && { length: parseInt(match[2], 10) - parseInt(match[1], 10) + 1 }),
        };
      }
    }

    // Fetch from R2
    const object = await env.AUDIO_BUCKET.get(filename, {
      ...(range && { range }),
    });

    if (!object) {
      return new Response("Not Found", { status: 404 });
    }

    // Build response headers
    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set("etag", object.httpEtag);
    headers.set("accept-ranges", "bytes");
    headers.set("cache-control", "public, max-age=31536000, immutable");

    // Set content-range header for partial responses.
    // R2's object.range is { offset?, length? } — compute the inclusive end
    // byte ourselves (open-ended ranges run to the end of the object).
    if (range && object.range) {
      const offset = object.range.offset ?? 0;
      const end =
        object.range.length != null
          ? offset + object.range.length - 1
          : object.size - 1;
      headers.set("content-range", `bytes ${offset}-${end}/${object.size}`);
      headers.set("content-length", String(end - offset + 1));
    } else {
      headers.set("content-length", String(object.size));
    }

    const status = range ? 206 : 200;

    // Fire analytics async — non-blocking, does not delay the response
    if (request.method === "GET") {
      const episode = filename.match(/e0*(\d+)/i)?.[1] ?? "unknown";
      ctx.waitUntil(
        fetch(`${env.UMAMI_HOST}/api/send`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "User-Agent": "Mozilla/5.0 (compatible; BitFlipWorker/1.0)",
          },
          body: JSON.stringify({
            type: "event",
            payload: {
              website: env.UMAMI_WEBSITE_ID,
              url: url.pathname,
              name: "episode_download",
              data: {
                episode,
                filename,
                ua: request.headers.get("user-agent") ?? "unknown",
              },
            },
          }),
        }).catch(() => {
          // Silently swallow analytics failures — never block audio delivery
        })
      );
    }

    return new Response(object.body, { status, headers });
  },
};