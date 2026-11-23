// Client for the relay's deployment admin API (/api/admin/v1, Buzz relay 0.3.0).
//
// This file has no DOM dependency so tests/test_admin_dashboard.mjs can run it
// under Node. Private keys never reach it: signing is delegated to a NIP-07
// browser extension through the injected `signer`.

export const PREFIX = "/api/admin/v1";
export const MAX_TIMEOUT_SECS = 365 * 24 * 60 * 60;

export class ApiError extends Error {
  constructor(status, code, message) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
  }
}

const toHex = (bytes) =>
  Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

async function sha256Hex(bytes) {
  return toHex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)));
}

function base64(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Builds the `Authorization` value for one request (NIP-98, kind 27235). */
export async function signRequest(signer, url, method, body) {
  // The nonce keeps two same-second requests from hashing to one event id,
  // which the relay's replay guard would reject.
  const nonce = toHex(crypto.getRandomValues(new Uint8Array(16)));
  const tags = [["u", url], ["method", method], ["nonce", nonce]];
  if (body !== undefined) tags.push(["payload", await sha256Hex(body)]);
  const event = await signer.signEvent({
    kind: 27235,
    created_at: Math.floor(Date.now() / 1000),
    tags,
    content: "",
  });
  return `Nostr ${base64(JSON.stringify(event))}`;
}

export function query(params) {
  const search = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null && value !== "") {
      search.set(key, String(value));
    }
  }
  const text = search.toString();
  return text ? `?${text}` : "";
}

export function createClient({ origin, signer = null, fetchImpl, uuid }) {
  const doFetch = fetchImpl ?? ((...args) => globalThis.fetch(...args));
  const newId = uuid ?? (() => crypto.randomUUID());

  async function send(path, method = "GET", payload) {
    const body =
      payload === undefined
        ? undefined
        : new TextEncoder().encode(JSON.stringify(payload));
    const attempt = async () => {
      const headers = { accept: "application/json" };
      if (body) headers["content-type"] = "application/json";
      if (signer) {
        headers.authorization = await signRequest(
          signer,
          `${origin}${PREFIX}${path}`,
          method,
          body,
        );
      }
      return doFetch(`${origin}${PREFIX}${path}`, {
        method,
        headers,
        body,
        credentials: "same-origin",
      });
    };

    let response = await attempt();
    // One re-sign covers clock skew at the edge of the relay's 60 second window.
    if (response.status === 401 && signer) response = await attempt();

    if (!response.ok) {
      const envelope = await response.json().catch(() => null);
      const error = envelope?.error ?? {};
      throw new ApiError(
        response.status,
        error.code ?? "request_failed",
        error.message ?? `Request failed (${response.status})`,
      );
    }
    if (response.status === 204) return null;
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }

  const member = (pubkey) => `/members/${encodeURIComponent(pubkey)}`;
  const direct = (path, communityHost, fields) =>
    send(`${path}${query({ communityHost })}`, "POST", {
      requestId: fields.requestId ?? newId(),
      ...(fields.reason ? { reason: fields.reason } : {}),
      ...(fields.expirationSecs
        ? { expirationSecs: fields.expirationSecs }
        : {}),
    });

  return {
    newId,
    probe: () => send("/probe"),

    communities: (params = {}) => send(`/communities${query(params)}`),

    reports: (params = {}) => send(`/reports${query(params)}`),
    report: (id) => send(`/reports/${id}`),
    resolveReport: (id, body) => send(`/reports/${id}/resolve`, "POST", body),
    reopenReport: (id, body) => send(`/reports/${id}/reopen`, "POST", body),
    cancelReport: (id, actionId) =>
      send(`/reports/${id}/cancel`, "POST", { actionId }),

    feedback: () => send("/feedback"),
    feedbackItem: (id) => send(`/feedback/${id}`),
    setFeedbackStatus: (id, status) =>
      send(`/feedback/${id}`, "PATCH", { status }),

    operators: () => send("/operators"),
    putOperator: (pubkey, role) =>
      send(`/operators/${encodeURIComponent(pubkey)}`, "PUT", { role }),
    deleteOperator: (pubkey) =>
      send(`/operators/${encodeURIComponent(pubkey)}`, "DELETE"),

    searchMembers: (communityHost, q) =>
      send(`/members/search${query({ communityHost, q })}`),
    member: (communityHost, pubkey) =>
      send(`${member(pubkey)}${query({ communityHost })}`),

    restrictions: (communityHost, cursor) =>
      send(`/members/restrictions${query({ communityHost, cursor })}`),
    ban: (communityHost, pubkey, fields) =>
      direct(`${member(pubkey)}/ban`, communityHost, fields),
    timeout: (communityHost, pubkey, fields) =>
      direct(`${member(pubkey)}/timeout`, communityHost, fields),
    unban: (communityHost, pubkey) =>
      send(`${member(pubkey)}/ban${query({ communityHost })}`, "DELETE"),
    untimeout: (communityHost, pubkey) =>
      send(`${member(pubkey)}/timeout${query({ communityHost })}`, "DELETE"),

    event: (communityHost, id) =>
      send(`/events/${encodeURIComponent(id)}${query({ communityHost })}`),
    deleteEvent: (communityHost, id, fields) =>
      direct(`/events/${encodeURIComponent(id)}/delete`, communityHost, fields),
  };
}

// ── Public keys ──────────────────────────────────────────────────────────────

const BECH32 = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

function polymod(values) {
  const generators = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let check = 1;
  for (const value of values) {
    const top = check >>> 25;
    check = ((check & 0x1ffffff) << 5) ^ value;
    generators.forEach((generator, bit) => {
      if ((top >>> bit) & 1) check ^= generator;
    });
  }
  return check >>> 0;
}

function decodeNpub(text) {
  const split = text.lastIndexOf("1");
  const hrp = text.slice(0, split);
  const data = [...text.slice(split + 1)].map((c) => BECH32.indexOf(c));
  if (hrp !== "npub" || data.length < 7 || data.includes(-1)) return null;
  const expanded = [
    ...[...hrp].map((c) => c.charCodeAt(0) >> 5),
    0,
    ...[...hrp].map((c) => c.charCodeAt(0) & 31),
    ...data,
  ];
  if (polymod(expanded) !== 1) return null;

  let accumulator = 0;
  let bits = 0;
  const bytes = [];
  for (const value of data.slice(0, -6)) {
    accumulator = (accumulator << 5) | value;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      bytes.push((accumulator >> bits) & 255);
    }
    accumulator &= (1 << bits) - 1;
  }
  if (bits >= 5 || accumulator !== 0 || bytes.length !== 32) return null;
  return toHex(bytes);
}

/** Returns lowercase hex. Refuses a private key rather than sending it anywhere. */
export function normalizePubkey(input) {
  const text = String(input ?? "").trim().toLowerCase();
  if (text.startsWith("nsec1")) {
    throw new Error(
      "That is a private key (nsec). Do not share it. Treat it as compromised and use the public npub.",
    );
  }
  if (/^[0-9a-f]{64}$/.test(text)) return text;
  if (text.startsWith("npub1")) {
    const hex = decodeNpub(text);
    if (hex) return hex;
  }
  throw new Error("Enter a valid npub or a 64-character hex public key.");
}

export function normalizeEventId(input) {
  const text = String(input ?? "").trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(text)) {
    throw new Error("Enter a 64-character hex event id.");
  }
  return text;
}

export function parseDuration(hours) {
  const seconds = Math.round(Number(hours) * 3600);
  if (!Number.isFinite(seconds) || seconds <= 0 || seconds > MAX_TIMEOUT_SECS) {
    throw new Error("Enter a duration between a few minutes and 8760 hours (365 days).");
  }
  return seconds;
}
