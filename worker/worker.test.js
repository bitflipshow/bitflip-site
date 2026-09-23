import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { parseRange } from "./worker.js";

test("range parsing", () => {
  assert.deepEqual(parseRange("bytes=0-1", 100), { start: 0, end: 1 });
  assert.deepEqual(parseRange("bytes=10-", 100), { start: 10, end: 99 });
  assert.deepEqual(parseRange("bytes=-10", 100), { start: 90, end: 99 });
  assert.equal(parseRange("bytes=100-", 100), false);
  assert.equal(parseRange("bytes=0-1,5-6", 100), false);
});

test("worker preserves range, HEAD, and event payload", async () => {
  const events = [];
  const object = { size: 100, httpEtag: '"etag"',
    body: new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(20)); controller.close(); } }),
    writeHttpMetadata(headers) { headers.set("Content-Type", "audio/mpeg"); } };
  const env = {
    AUDIO_BUCKET: { async head() { return object; }, async get(_name, options) {
      assert.deepEqual(options, { range: { offset: 10, length: 20 } });
      return object;
    } },
    ANALYTICS_EVENTS: { async put(key, body) { events.push({ key, body: JSON.parse(body) }); } },
  };
  {
    const waits = [];
    const ctx = { waitUntil(promise) { waits.push(promise); } };
    const url = "https://audio.bitflip.show/episode.mp3";
    const response = await worker.fetch(new Request(url, { headers: { Range: "bytes=10-29", "CF-Connecting-IP": "198.51.100.1", "User-Agent": "PodcastApp/1" } }), env, ctx);
    await response.arrayBuffer();
    await Promise.all(waits);
    assert.equal(response.status, 206);
    assert.equal(response.headers.get("Content-Range"), "bytes 10-29/100");
    assert.equal(events.length, 1);
    assert.deepEqual([events[0].body.start, events[0].body.end, events[0].body.status], [10, 29, 206]);
    const head = await worker.fetch(new Request(url, { method: "HEAD" }), env, ctx);
    assert.equal(head.status, 200);
    assert.equal(head.headers.get("Content-Length"), "100");
    assert.equal(events.length, 1);
    const invalid = await worker.fetch(new Request(url, { headers: { Range: "bytes=100-" } }), env, ctx);
    assert.equal(invalid.status, 416);
    const cached = await worker.fetch(new Request(url, { headers: { "If-None-Match": '"etag"' } }), env, ctx);
    assert.equal(cached.status, 304);
    assert.equal(events.length, 1);
  }
});

test("early disconnect records only streamed bytes", async () => {
  const events = [];
  const object = { size: 100, httpEtag: '"etag"',
    body: new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(20)); controller.close(); } }),
    writeHttpMetadata() {} };
  const env = { AUDIO_BUCKET: { async get() { return object; } },
    ANALYTICS_EVENTS: { async put(_key, body) { events.push(JSON.parse(body)); } } };
  const waits = [];
  const response = await worker.fetch(new Request("https://audio.bitflip.show/episode.mp3", {
    headers: { "CF-Connecting-IP": "8.8.8.8", "User-Agent": "PodcastApp/1" },
  }), env, { waitUntil(promise) { waits.push(promise); } });
  await response.arrayBuffer();
  await Promise.all(waits);
  assert.equal(events[0].status, 200);
  assert.equal(events[0].start, 0);
  assert.equal(events[0].end, 19);
});
