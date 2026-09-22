'use strict';

/**
 * Shared API client + session storage, used by both login.js and app.js.
 *
 * Session persistence: the backend API itself is unchanged — it still
 * returns the access token and refresh token in the JSON response body
 * (this is required for the existing curl/API-testing workflows and the
 * AWS deployment to keep working identically). Storing them in
 * sessionStorage here is a frontend-only decision so navigation between
 * /login and / doesn't lose the session on a full page load. This is a
 * demo-appropriate tradeoff, not a production recommendation — a real
 * product would use an httpOnly, Secure, SameSite cookie set by the
 * server so the token is never reachable from JS at all. That would
 * require the backend to issue Set-Cookie headers and add CSRF
 * protection, which is a real backend change outside this UI redesign's
 * scope, so it's called out here instead of silently glossed over.
 * sessionStorage (not localStorage) is used deliberately: it clears when
 * the tab closes, limiting how long a token sits in browser storage.
 */

const SESSION_KEY = 'secure_cicd_demo_session';

const Session = {
  get() {
    try {
      const raw = sessionStorage.getItem(SESSION_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch {
      return null;
    }
  },
  set(session) {
    try {
      sessionStorage.setItem(SESSION_KEY, JSON.stringify(session));
    } catch {
      /* sessionStorage unavailable (private mode etc.) — session just
         won't survive navigation; the rest of the UI still works. */
    }
  },
  clear() {
    try {
      sessionStorage.removeItem(SESSION_KEY);
    } catch {
      /* noop */
    }
  },
};

// Decodes a JWT's payload WITHOUT verifying its signature — purely to
// read already-public claims (like `exp`) for display. This is not a
// trust decision; the server independently re-verifies the signature on
// every request via jwt.verify(), so a tampered token still can't do
// anything even though its payload is readable here.
function decodeJwtPayload(token) {
  try {
    const payload = token.split('.')[1];
    const json = atob(payload.replace(/-/g, '+').replace(/_/g, '/'));
    return JSON.parse(json);
  } catch {
    return null;
  }
}

function formatExpiry(exp) {
  if (!exp) return null;
  const secondsLeft = exp - Math.floor(Date.now() / 1000);
  if (secondsLeft <= 0) return 'expired';
  const mins = Math.floor(secondsLeft / 60);
  if (mins < 1) return `${secondsLeft}s`;
  if (mins < 60) return `${mins}m`;
  return `${Math.floor(mins / 60)}h ${mins % 60}m`;
}

let lastRateLimit = null;

function recordRateLimitFromResponse(res) {
  const limit = res.headers.get('ratelimit-limit');
  const remaining = res.headers.get('ratelimit-remaining');
  const reset = res.headers.get('ratelimit-reset');
  if (limit === null || remaining === null) return;
  lastRateLimit = { limit: parseInt(limit, 10), remaining: parseInt(remaining, 10), reset: reset ? parseInt(reset, 10) : null };
  window.dispatchEvent(new CustomEvent('ratelimit', { detail: lastRateLimit }));
}

function getLastRateLimit() {
  return lastRateLimit;
}

// Thin fetch wrapper: same-origin only (this page and the API are served
// from the same Vercel deployment, so no base URL/CORS handling is
// needed), tracks rate-limit headers, and normalizes JSON parsing.
async function apiFetch(path, options = {}) {
  const res = await fetch(path, {
    ...options,
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
  });
  recordRateLimitFromResponse(res);
  let body = null;
  try {
    body = await res.json();
  } catch {
    body = null;
  }
  return { ok: res.ok, status: res.status, body };
}

function apiPost(path, data) {
  return apiFetch(path, { method: 'POST', body: JSON.stringify(data) });
}

function apiGet(path, token) {
  return apiFetch(path, { headers: token ? { Authorization: `Bearer ${token}` } : {} });
}

// Redirects to /login if there's no session — call at the top of any
// page that requires authentication.
function requireSession() {
  const session = Session.get();
  if (!session) {
    window.location.href = '/login';
    return null;
  }
  return session;
}
