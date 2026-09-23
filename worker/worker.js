function parseRange(header, size) {
  if (!header) return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match || (!match[1] && !match[2])) return false;
  let start;
  let end;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix < 1) return false;
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] ? Number(match[2]) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end)) return false;
    end = Math.min(end, size - 1);
  }
  if (start < 0 || start >= size || end < start) return false;
  return { start, end };
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", { status: 405, headers: { Allow: "GET, HEAD" } });
    }

    const filename = new URL(request.url).pathname.slice(1);
    if (!filename || filename.includes("/") || !/\.(mp3|wav|m4a)$/i.test(filename)) {
      return new Response("Not Found", { status: 404 });
    }

    let rangeHeader = request.headers.get("Range");
    const ifNoneMatch = request.headers.get("If-None-Match");
    const ifModifiedSince = request.headers.get("If-Modified-Since");
    const ifRange = request.headers.get("If-Range");
    const metadata = rangeHeader || request.method === "HEAD" || ifNoneMatch || ifModifiedSince
      ? await env.AUDIO_BUCKET.head(filename)
      : null;
    if ((rangeHeader || request.method === "HEAD" || ifNoneMatch || ifModifiedSince) && !metadata) {
      return new Response("Not Found", { status: 404 });
    }
    if (metadata && ifNoneMatch && (ifNoneMatch.trim() === "*" || ifNoneMatch.split(",").some((tag) => tag.trim() === metadata.httpEtag))) {
      return new Response(null, { status: 304, headers: { ETag: metadata.httpEtag } });
    }
    if (metadata && !ifNoneMatch && ifModifiedSince && metadata.uploaded &&
        metadata.uploaded.getTime() <= new Date(ifModifiedSince).getTime()) {
      return new Response(null, { status: 304, headers: { ETag: metadata.httpEtag } });
    }
    if (rangeHeader && ifRange && metadata) {
      const matchesTag = ifRange === metadata.httpEtag;
      const matchesDate = metadata.uploaded && metadata.uploaded.getTime() <= new Date(ifRange).getTime();
      if (!matchesTag && !matchesDate) rangeHeader = null;
    }
    const range = rangeHeader ? parseRange(rangeHeader, metadata.size) : null;
    if (range === false) {
      return new Response(null, { status: 416, headers: { "Content-Range": `bytes */${metadata.size}` } });
    }

    const object = request.method === "HEAD"
      ? metadata
      : await env.AUDIO_BUCKET.get(filename, range ? { range: { offset: range.start, length: range.end - range.start + 1 } } : undefined);
    if (!object) return new Response("Not Found", { status: 404 });

    const headers = new Headers();
    object.writeHttpMetadata(headers);
    headers.set("ETag", object.httpEtag);
    if (object.uploaded) headers.set("Last-Modified", object.uploaded.toUTCString());
    headers.set("Accept-Ranges", "bytes");
    headers.set("Cache-Control", "public, max-age=31536000, immutable");
    if (range) {
      headers.set("Content-Range", `bytes ${range.start}-${range.end}/${object.size}`);
      headers.set("Content-Length", String(range.end - range.start + 1));
    } else {
      headers.set("Content-Length", String(object.size));
    }

    const record = (delivered) => {
      if (!env.ANALYTICS_EVENTS || delivered < 1) return;
      const start = range?.start ?? 0;
      const event = {
        method: "GET",
        status: range ? 206 : 200,
        filename,
        size: object.size,
        start,
        end: Math.min(start + delivered - 1, object.size - 1),
        ip: request.headers.get("CF-Connecting-IP") ?? "",
        userAgent: request.headers.get("User-Agent") ?? "",
        timestamp: Math.floor(Date.now() / 1000),
      };
      const key = `events/${new Date().toISOString().slice(0, 10)}/${Date.now()}-${crypto.randomUUID()}.json`;
      ctx.waitUntil(env.ANALYTICS_EVENTS.put(key, JSON.stringify(event), {
        httpMetadata: { contentType: "application/json" },
      }).catch((error) => console.error("Analytics event write failed", error)));
    };

    let body = null;
    if (request.method === "GET") {
      const reader = object.body.getReader();
      let delivered = 0;
      let recorded = false;
      const finish = () => {
        if (recorded) return;
        recorded = true;
        record(delivered);
      };
      body = new ReadableStream({
        async pull(controller) {
          try {
            const chunk = await reader.read();
            if (chunk.done) {
              finish();
              controller.close();
            } else {
              delivered += chunk.value.byteLength;
              controller.enqueue(chunk.value);
            }
          } catch (error) {
            finish();
            controller.error(error);
          }
        },
        async cancel(reason) {
          await reader.cancel(reason);
          finish();
        },
      });
    }

    return new Response(body,
      { status: range ? 206 : 200, headers });
  },
};

export { parseRange };
