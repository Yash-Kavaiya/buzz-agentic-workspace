// Checks the admin dashboard's API client against the relay 0.3.0 contract:
// NIP-98 signing inputs, routes, and refusal of private keys.

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  createClient,
  normalizeEventId,
  normalizePubkey,
  parseDuration,
} from "../helm/buzz-gke/files/admin-dashboard/api.js";

const ORIGIN = "https://buzz-admin.example.com";
const HOST = "community.example.com";
const SAMPLE_PK = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e";
const NPUB = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg";

function harness(respond = () => new Response("{}", { status: 200 })) {
  const calls = [];
  const signed = [];
  const signer = {
    signEvent: async (event) => {
      signed.push(event);
      return { ...event, id: "id", pubkey: SAMPLE_PK, sig: "sig" };
    },
  };
  const fetchImpl = async (url, init) => {
    calls.push({ url, ...init });
    return respond(calls.length);
  };
  const client = createClient({ origin: ORIGIN, signer, fetchImpl, uuid: () => "request-id" });
  return { calls, signed, client };
}

const tag = (event, name) => event.tags.find(([key]) => key === name)?.[1];

test("signs the full URL including the query string", async () => {
  const { client, signed, calls } = harness();
  await client.reports({ status: "open", limit: 50 });
  const url = `${ORIGIN}/api/admin/v1/reports?status=open&limit=50`;
  assert.equal(calls[0].url, url);
  assert.equal(signed[0].kind, 27235);
  assert.equal(tag(signed[0], "u"), url);
  assert.equal(tag(signed[0], "method"), "GET");
  assert.equal(tag(signed[0], "payload"), undefined);
  assert.match(calls[0].headers.authorization, /^Nostr /);
});

test("the payload tag hashes the exact bytes sent", async () => {
  const { client, signed, calls } = harness();
  await client.putOperator(SAMPLE_PK, "moderator");
  assert.equal(calls[0].method, "PUT");
  assert.equal(
    tag(signed[0], "payload"),
    createHash("sha256").update(calls[0].body).digest("hex"),
  );
  assert.deepEqual(JSON.parse(new TextDecoder().decode(calls[0].body)), { role: "moderator" });
});

test("every request gets a unique nonce", async () => {
  const { client, signed } = harness();
  await client.probe();
  await client.probe();
  assert.notEqual(tag(signed[0], "nonce"), tag(signed[1], "nonce"));
});

test("a 401 re-signs and retries exactly once", async () => {
  const { client, calls, signed } = harness(() => new Response("{}", { status: 401 }));
  await assert.rejects(client.probe(), { status: 401 });
  assert.equal(calls.length, 2);
  assert.equal(signed.length, 2);
});

test("direct actions send the relay's camelCase body", async () => {
  const { client, calls } = harness();
  await client.timeout(HOST, SAMPLE_PK, { reason: "spam", expirationSecs: 3600 });
  assert.equal(
    calls[0].url,
    `${ORIGIN}/api/admin/v1/members/${SAMPLE_PK}/timeout?communityHost=${HOST}`,
  );
  assert.deepEqual(JSON.parse(new TextDecoder().decode(calls[0].body)), {
    requestId: "request-id",
    reason: "spam",
    expirationSecs: 3600,
  });
});

test("a ban sends no expiry, which the relay would reject", async () => {
  const { client, calls } = harness();
  await client.ban(HOST, SAMPLE_PK, { requestId: "fixed" });
  assert.deepEqual(JSON.parse(new TextDecoder().decode(calls[0].body)), { requestId: "fixed" });
});

test("lifting a restriction handles the relay's 204", async () => {
  const { client, calls } = harness(() => new Response(null, { status: 204 }));
  assert.equal(await client.unban(HOST, SAMPLE_PK), null);
  assert.equal(calls[0].method, "DELETE");
  assert.equal(calls[0].body, undefined);
});

test("API errors surface the relay's code and message", async () => {
  const { client } = harness(() =>
    Response.json({ error: { code: "target_is_staff", message: "target is staff" } }, { status: 409 }),
  );
  await assert.rejects(client.ban(HOST, SAMPLE_PK, {}), { status: 409, code: "target_is_staff" });
});

test("public keys normalize from hex and npub", () => {
  assert.equal(normalizePubkey(SAMPLE_PK.toUpperCase()), SAMPLE_PK);
  assert.equal(normalizePubkey(NPUB), SAMPLE_PK);
});

test("a private key or corrupted npub is refused", () => {
  assert.throws(() => normalizePubkey(`nsec1${"q".repeat(58)}`), /private key/);
  assert.throws(() => normalizePubkey(`${NPUB.slice(0, -1)}q`), /valid npub/);
  assert.throws(() => normalizePubkey("not-a-key"), /valid npub/);
});

test("event ids and durations are validated", () => {
  assert.equal(normalizeEventId(SAMPLE_PK.toUpperCase()), SAMPLE_PK);
  assert.throws(() => normalizeEventId("abc"));
  assert.equal(parseDuration("1.5"), 5400);
  assert.throws(() => parseDuration("0"));
  assert.throws(() => parseDuration(String(366 * 24)));
});

test("the UI stays inside the relay's CSP and renders no raw HTML", () => {
  const dir = new URL("../helm/buzz-gke/files/admin-dashboard/", import.meta.url);
  const app = readFileSync(new URL("app.js", dir), "utf8");
  const html = readFileSync(new URL("index.html", dir), "utf8");
  assert.doesNotMatch(app, /innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(/);
  assert.doesNotMatch(html, /<style|style=|<script(?![^>]*src=)/);
  assert.match(html, /src="\/assets\/app\.js"/);
  assert.match(html, /href="\/assets\/app\.css"/);
});
