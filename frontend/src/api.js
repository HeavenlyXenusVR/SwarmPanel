const TOKEN_KEY = "swarm_panel_remote_token";
const USER_KEY = "swarm_panel_remote_username";
const CACHE_TTL = 12_000;
const CACHE_STALE_TTL = 90_000;
const CACHE_VERSION = "v5";
const API_FETCH_TIMEOUT_MS = 30_000;
const CACHE_STORE_PREFIX = "swarm_panel_api_cache:";
const MAX_STORED_CACHE_BYTES = 450_000;
const REMOTE_ORIGIN_KEY = "swarm_panel_remote_origin";
const REMOTE_ORIGIN_TTL = 60_000;
const REMOTE_ORIGIN_STALE_TTL = 15 * 60_000;

const cache = new Map();
const inFlightFetches = new Map();
let remoteOriginPromise = null;
let remoteOriginRefreshAfter = 0;
let remoteConfig = null;
let inMemoryToken = "";

function requestError(message, details = {}) {
  const error = new Error(message);
  Object.assign(error, details);
  return error;
}

function isAbortLike(error) {
  if (!error) return false;
  const name = String(error.name || "");
  const message = String(error.message || "");
  return name === "AbortError" || /abort/i.test(name) || /aborted|abort/i.test(message);
}

function isNetworkFailure(error) {
  if (!error) return false;
  const name = String(error.name || "");
  const message = String(error.message || "");
  return (
    name === "TypeError" ||
    /load failed|failed to fetch|networkerror|network request failed|fetch failed/i.test(message)
  );
}

function sleep(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function safeRemove(storage, key) {
  try {
    storage?.removeItem(key);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

export function readToken() {
  if (inMemoryToken) return inMemoryToken;
  try {
    const sessionToken = sessionStorage.getItem(TOKEN_KEY) || "";
    if (sessionToken) {
      inMemoryToken = sessionToken;
      return sessionToken;
    }
    // One-time migration: stop keeping bearer tokens in persistent localStorage.
    const legacyToken = localStorage.getItem(TOKEN_KEY) || "";
    if (legacyToken) {
      inMemoryToken = legacyToken;
      sessionStorage.setItem(TOKEN_KEY, legacyToken);
      localStorage.removeItem(TOKEN_KEY);
      return legacyToken;
    }
  } catch (_error) {
    // Some browser contexts block storage.
  }
  return "";
}

export function writeToken(token) {
  inMemoryToken = String(token || "");
  try {
    if (inMemoryToken) sessionStorage.setItem(TOKEN_KEY, inMemoryToken);
    else sessionStorage.removeItem(TOKEN_KEY);
  } catch (_error) {
    // Some browser contexts block storage.
  }
  // Never persist bearer tokens beyond the active tab/session.
  safeRemove(localStorage, TOKEN_KEY);
}

export function writeUsername(username) {
  try {
    if (username) sessionStorage.setItem(USER_KEY, username);
    else sessionStorage.removeItem(USER_KEY);
  } catch (_error) {
    // Some browser contexts block storage.
  }
  safeRemove(localStorage, USER_KEY);
}

export function clearCache(prefix = "") {
  for (const key of Array.from(cache.keys())) {
    if (!prefix || key.includes(`|${prefix}`)) cache.delete(key);
  }
  for (const storage of [safeStorage(sessionStorage), safeStorage(localStorage)]) {
    if (!storage) continue;
    for (let index = storage.length - 1; index >= 0; index -= 1) {
      const key = storage.key(index);
      if (!key?.startsWith(CACHE_STORE_PREFIX)) continue;
      if (!prefix || key.includes(`|${prefix}`)) storage.removeItem(key);
    }
  }
}

export function query(params) {
  const values = new URLSearchParams();
  Object.entries(params).forEach(([key, value]) => {
    if (value === undefined || value === null || value === "") return;
    values.set(key, String(value));
  });
  const text = values.toString();
  return text ? `?${text}` : "";
}

export async function apiFetch(path, options = {}) {
  const headers = new Headers(options.headers || {});
  const token = options.token ?? readToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (!headers.has("Accept")) headers.set("Accept", "application/json");
  if (options.body && !(options.body instanceof FormData) && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  const requestOptions = options.force ? { ...options, cache: "no-store" } : options;
  const response = await fetchWithRemoteRetry(path, requestOptions, headers);
  const contentType = response.headers.get("content-type") || "";
  const payload = contentType.includes("application/json")
    ? await response.json().catch(() => null)
    : await response.text();
  if (!response.ok) {
    const error = new Error(errorMessage(payload, response.status));
    error.status = response.status;
    error.payload = payload;
    throw error;
  }
  return payload;
}

function errorMessage(payload, status) {
  const raw = payload?.detail || payload?.message || payload;
  if (typeof raw === "string" && /<html[\s>]/i.test(raw) && /405\s+Not\s+Allowed/i.test(raw)) {
    return "Login request hit a static/proxy server instead of the SwarmPanel API. Refresh live-config.json or restart the live backend/tunnel.";
  }
  if (!raw) return `Request failed (${status})`;
  if (Array.isArray(raw)) {
    return raw.map((item) => item?.msg || item?.message || JSON.stringify(item)).join("; ");
  }
  if (typeof raw === "object") {
    return raw.msg || raw.message || JSON.stringify(raw);
  }
  return String(raw);
}

export async function cachedFetch(path, options = {}) {
  const method = String(options.method || "GET").toUpperCase();
  if (method !== "GET") return apiFetch(path, options);
  const ttl = options.ttl ?? CACHE_TTL;
  const staleTtl = options.staleTtl ?? CACHE_STALE_TTL;
  const token = options.token ?? readToken();
  const storage = options.storage === "local" ? safeStorage(localStorage) : safeStorage(sessionStorage);
  const key = `${CACHE_VERSION}|${path}|${token ? "auth" : "anon"}`;
  if (options.force) {
    cache.delete(key);
    safeRemove(storage, CACHE_STORE_PREFIX + key);
    return revalidateCache(key, path, options, ttl, staleTtl, storage);
  }
  const hit = cache.get(key);
  const now = Date.now();
  const stored = hit || readStoredCache(storage, key);
  if (stored) {
    cache.set(key, stored);
    if (stored.expires > now) return stored.value;
    if (stored.staleUntil > now && options.allowStale !== false) {
      revalidateCache(key, path, options, ttl, staleTtl, storage);
      return stored.value;
    }
  }
  return revalidateCache(key, path, options, ttl, staleTtl, storage);
}

export function prefetchFetch(path, options = {}) {
  cachedFetch(path, { ...options, allowStale: false }).catch(() => {});
}

export function apiUrl(path) {
  if (/^https?:\/\//i.test(path)) return path;
  const normalized = path.startsWith("/") ? path : `/${path}`;
  return `${currentApiOrigin()}${normalized}`;
}

export async function resolveApiUrl(path) {
  if (/^https?:\/\//i.test(path)) return path;
  await ensureRemoteOrigin();
  return apiUrl(path);
}

function currentApiOrigin() {
  return String(window.SWARM_PANEL_API_ORIGIN || "").replace(/\/+$/, "");
}

function isRemoteStaticHost() {
  return Boolean(window.SWARM_PANEL_REMOTE_MODE) || window.location.hostname.endsWith("github.io");
}

function remoteConfigUrl() {
  if (window.SWARM_PANEL_CONFIG_URL) return window.SWARM_PANEL_CONFIG_URL;
  const basename = String(window.SWARM_PANEL_BASENAME || "").replace(/\/+$/, "");
  if (basename) return `${basename}/live-config.json`;
  return "live-config.json";
}

async function ensureRemoteOrigin() {
  if (!isRemoteStaticHost()) return currentApiOrigin();
  if (currentApiOrigin() && remoteOriginRefreshAfter > Date.now()) return currentApiOrigin();
  if (!remoteOriginPromise) {
    remoteOriginPromise = loadRemoteOrigin().finally(() => {
      remoteOriginPromise = null;
    });
  }
  return remoteOriginPromise;
}

async function refreshRemoteOrigin() {
  if (!isRemoteStaticHost()) return currentApiOrigin();
  remoteOriginPromise = loadRemoteOrigin({ force: true }).finally(() => {
    remoteOriginPromise = null;
  });
  return remoteOriginPromise;
}

async function loadRemoteOrigin({ force = false } = {}) {
  const cached = readRemoteOriginCache();
  if (!force && cached?.origin && cached.updatedAt && Date.now() - cached.updatedAt < REMOTE_ORIGIN_TTL) {
    applyRemoteOrigin(cached);
    return cached.origin;
  }
  try {
    const response = await fetchWithTimeout(`${remoteConfigUrl()}?t=${Date.now()}`, {
      cache: "no-store",
      timeoutMs: 12_000,
      credentials: "omit",
    });
    if (!response.ok) throw new Error(`Remote config failed (${response.status})`);
    const config = await parseRemoteConfigResponse(response);
    const origin = normalizeApiOrigin(config.panel_url || config.api_url);
    if (origin) {
      const entry = { origin, localUrls: normalizeLocalUrls(config.local_urls), updatedAt: Date.now() };
      applyRemoteOrigin(entry);
      writeRemoteOriginCache(entry);
      return origin;
    }
    remoteConfig = config || null;
  } catch (_error) {
    if (cached?.origin && (!cached.updatedAt || Date.now() - cached.updatedAt < REMOTE_ORIGIN_STALE_TTL)) {
      applyRemoteOrigin(cached);
      return cached.origin;
    }
  }
  clearRemoteOriginCache();
  return "";
}

async function parseRemoteConfigResponse(response) {
  const text = await response.text();
  try {
    return JSON.parse(text);
  } catch (_error) {
    const recovered = parseFirstJsonObject(text);
    if (recovered) return recovered;
    throw _error;
  }
}

function parseFirstJsonObject(text) {
  const raw = String(text || "");
  const start = raw.indexOf("{");
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < raw.length; index += 1) {
    const char = raw[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (char === '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (char === "{") depth += 1;
    if (char === "}") {
      depth -= 1;
      if (depth === 0) {
        try {
          return JSON.parse(raw.slice(start, index + 1));
        } catch (_error) {
          return null;
        }
      }
    }
  }
  return null;
}

async function fetchWithRemoteRetry(path, options, headers) {
  if (shouldRefreshOriginBeforeRequest(options)) {
    await refreshRemoteOrigin();
  }
  const target = await resolveApiUrl(path);
  if (isRemoteStaticHost() && !originFromUrl(target)) {
    throw new Error("SwarmPanel live backend is not published yet. Restart the live backend/tunnel so live-config.json points at the FastAPI server.");
  }
  try {
    const response = await fetchWithTimeout(target, { ...options, headers });
    if (shouldRefreshRemoteAfterStatus(response.status, options)) {
      const retryTarget = await retryTargetFor(path, target, options);
      if (retryTarget && retryTarget !== target) {
        return fetchWithTimeout(retryTarget, { ...options, headers });
      }
    }
    return response;
  } catch (error) {
    if (error?.isAbort && !error?.retriable) throw error;
    if (error?.retriable && isNetworkFailure(error)) {
      await sleep(350);
    }
    const retryTarget = await retryTargetFor(path, target, options);
    if (retryTarget && retryTarget !== target) {
      return fetchWithTimeout(retryTarget, { ...options, headers });
    }
    if (error?.retriable && isNetworkFailure(error)) {
      return fetchWithTimeout(target, { ...options, headers });
    }
    throw error;
  }
}

function shouldRefreshOriginBeforeRequest(options) {
  if (!isRemoteStaticHost()) return false;
  const method = String(options.method || "GET").toUpperCase();
  return method !== "GET" && method !== "HEAD";
}

async function fetchWithTimeout(url, options = {}) {
  const controller = new AbortController();
  const merged = mergeAbortSignals(options.signal, controller.signal);
  const timeoutMs = Math.max(5_000, Number(options.timeoutMs) || API_FETCH_TIMEOUT_MS);
  let timedOut = false;
  const timer = window.setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  try {
    return await fetch(url, { ...options, signal: merged.signal });
  } catch (error) {
    if (timedOut) {
      throw requestError("SwarmPanel request timed out while waiting for the live backend.", {
        code: "TIMEOUT",
        status: 408,
        retriable: true,
      });
    }
    if (options.signal?.aborted && isAbortLike(error)) {
      throw requestError("Request cancelled.", { code: "ABORTED", isAbort: true, silent: true });
    }
    if (isAbortLike(error)) {
      throw requestError("The SwarmPanel request was interrupted before the backend replied.", {
        code: "ABORTED",
        isAbort: true,
      });
    }
    if (isNetworkFailure(error)) {
      throw requestError("SwarmPanel could not reach the live backend. Refresh the panel or restart the live backend/tunnel if this keeps happening.", {
        code: "NETWORK",
        status: 503,
        retriable: true,
      });
    }
    throw error;
  } finally {
    window.clearTimeout(timer);
    merged.cleanup();
  }
}

function mergeAbortSignals(...signals) {
  const activeSignals = signals.filter(Boolean);
  if (!activeSignals.length) {
    return { signal: undefined, cleanup() {} };
  }
  if (typeof AbortSignal !== "undefined" && typeof AbortSignal.any === "function") {
    return { signal: AbortSignal.any(activeSignals), cleanup() {} };
  }
  const controller = new AbortController();
  const listeners = [];
  const abortFrom = (signal) => {
    if (!controller.signal.aborted) controller.abort(signal?.reason);
  };
  for (const signal of activeSignals) {
    if (signal.aborted) {
      abortFrom(signal);
      break;
    }
    const listener = () => abortFrom(signal);
    signal.addEventListener("abort", listener, { once: true });
    listeners.push([signal, listener]);
  }
  return {
    signal: controller.signal,
    cleanup() {
      for (const [signal, listener] of listeners) {
        signal.removeEventListener("abort", listener);
      }
    },
  };
}

function normalizeApiOrigin(value) {
  const raw = String(value || "").trim().replace(/\/+$/, "");
  if (!raw) return "";
  try {
    const parsed = new URL(raw, window.location.href);
    if (!/^https?:$/.test(parsed.protocol)) return "";
    if (window.location.protocol === "https:" && parsed.protocol !== "https:" && !/^(localhost|127\.0\.0\.1|\[::1\])$/.test(parsed.hostname)) return "";
    return parsed.origin.replace(/\/+$/, "");
  } catch (_error) {
    return "";
  }
}

async function retryTargetFor(path, failedTarget, options) {
  if (!canRetryWithFreshRemote(options)) return "";
  const failedOrigin = originFromUrl(failedTarget) || currentApiOrigin();
  await refreshRemoteOrigin();
  const refreshed = apiUrl(path);
  if (refreshed && refreshed !== failedTarget) return refreshed;
  return fallbackApiUrl(path, failedOrigin);
}

function shouldRefreshRemoteAfterStatus(status, options) {
  return canRetryWithFreshRemote(options) && (
    status === 404 ||
    status === 405 ||
    status === 502 ||
    status === 503 ||
    status === 504 ||
    (status >= 520 && status <= 526)
  );
}

function canRetryWithFreshRemote(options) {
  const method = String(options.method || "GET").toUpperCase();
  if (!isRemoteStaticHost()) return false;
  if (method === "GET" || method === "HEAD") return true;
  return isReplayableRequestBody(options.body);
}

function isReplayableRequestBody(body) {
  if (!body) return true;
  if (typeof body === "string") return true;
  if (body instanceof URLSearchParams) return true;
  if (body instanceof FormData) return true;
  if (body instanceof Blob) return true;
  if (body instanceof ArrayBuffer) return true;
  return false;
}

function fallbackApiUrl(path, failedOrigin) {
  const origin = localOriginFallback(failedOrigin);
  if (!origin) return "";
  const normalized = path.startsWith("/") ? path : `/${path}`;
  return `${origin}${normalized}`;
}

function localOriginFallback(failedOrigin) {
  const localUrls = normalizeLocalUrls(remoteConfig?.local_urls);
  for (const origin of localUrls) {
    if (!origin || origin === failedOrigin) continue;
    if (window.location.protocol === "https:" && !/^http:\/\/(localhost|127\.0\.0\.1|\[::1\])(?::|$)/i.test(origin)) continue;
    return origin;
  }
  return "";
}

function applyRemoteOrigin(entry) {
  const origin = String(entry?.origin || "").replace(/\/+$/, "");
  const current = currentApiOrigin();
  window.SWARM_PANEL_API_ORIGIN = origin;
  remoteOriginRefreshAfter = Date.now() + REMOTE_ORIGIN_TTL;
  remoteConfig = { ...(remoteConfig || {}), local_urls: normalizeLocalUrls(entry?.localUrls || entry?.local_urls) };
  if (origin && current && current !== origin) clearCache();
}

function readRemoteOriginCache() {
  const raw = readStorageValue(REMOTE_ORIGIN_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    if (parsed?.origin) {
      return {
        origin: normalizeApiOrigin(parsed.origin),
        localUrls: normalizeLocalUrls(parsed.localUrls || parsed.local_urls),
        updatedAt: Number(parsed.updatedAt || 0),
      };
    }
  } catch (_error) {
    return { origin: normalizeApiOrigin(raw), localUrls: [], updatedAt: 0 };
  }
  return null;
}

function writeRemoteOriginCache(entry) {
  try {
    localStorage.setItem(REMOTE_ORIGIN_KEY, JSON.stringify(entry));
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

function clearRemoteOriginCache() {
  window.SWARM_PANEL_API_ORIGIN = "";
  remoteOriginRefreshAfter = 0;
  try {
    localStorage.removeItem(REMOTE_ORIGIN_KEY);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

function normalizeLocalUrls(urls) {
  if (!Array.isArray(urls)) return [];
  return urls
    .map((url) => normalizeApiOrigin(url))
    .filter(Boolean);
}

function originFromUrl(url) {
  try {
    return new URL(url, window.location.href).origin.replace(/\/+$/, "");
  } catch (_error) {
    return "";
  }
}

function revalidateCache(key, path, options, ttl, staleTtl, storage) {
  if (inFlightFetches.has(key)) return inFlightFetches.get(key);
  const promise = apiFetch(path, options)
    .then((value) => {
      if (ttl > 0) {
        const entry = {
          value,
          expires: Date.now() + ttl,
          staleUntil: Date.now() + ttl + Math.max(0, staleTtl),
        };
        cache.set(key, entry);
        writeStoredCache(storage, key, entry);
      }
      return value;
    })
    .finally(() => inFlightFetches.delete(key));
  inFlightFetches.set(key, promise);
  return promise;
}

function readStorageValue(key) {
  try {
    return localStorage.getItem(key) || "";
  } catch (_error) {
    return "";
  }
}

function writeStorageValue(key, value) {
  try {
    if (value) localStorage.setItem(key, value);
    else localStorage.removeItem(key);
  } catch (_error) {
    // Storage can be unavailable in hardened browser contexts.
  }
}

function safeStorage(storage) {
  try {
    const probe = "__swarm_panel_cache_probe__";
    storage.setItem(probe, "1");
    storage.removeItem(probe);
    return storage;
  } catch (_error) {
    return null;
  }
}

function readStoredCache(storage, key) {
  if (!storage) return null;
  try {
    const raw = storage.getItem(CACHE_STORE_PREFIX + key);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!parsed || parsed.staleUntil <= Date.now()) {
      storage.removeItem(CACHE_STORE_PREFIX + key);
      return null;
    }
    return parsed;
  } catch (_error) {
    return null;
  }
}

function writeStoredCache(storage, key, entry) {
  if (!storage) return;
  try {
    const raw = JSON.stringify(entry);
    if (raw.length > MAX_STORED_CACHE_BYTES) return;
    storage.setItem(CACHE_STORE_PREFIX + key, raw);
  } catch (_error) {
    pruneStoredCache(storage);
  }
}

function pruneStoredCache(storage) {
  try {
    const keys = [];
    for (let index = 0; index < storage.length; index += 1) {
      const key = storage.key(index);
      if (key?.startsWith(CACHE_STORE_PREFIX)) keys.push(key);
    }
    keys.slice(0, Math.ceil(keys.length / 3)).forEach((key) => storage.removeItem(key));
  } catch (_error) {
    // Storage cleanup is best-effort.
  }
}
