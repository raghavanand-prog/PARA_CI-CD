'use strict';

// All requests are same-origin (this page and the API are served from the
// same Vercel deployment), so no base URL or CORS handling is needed.

let currentToken = null;

async function checkHealth() {
  const dot = document.querySelector('#status-body .dot');
  const text = document.getElementById('status-text');
  try {
    const res = await fetch('/health');
    recordRateLimit(res);
    const body = await res.json();
    if (res.ok && body.status === 'ok') {
      dot.className = 'dot dot-ok';
      text.textContent = `ok — uptime ${body.uptimeSeconds}s — ${body.timestamp}`;
    } else {
      dot.className = 'dot dot-down';
      text.textContent = `unexpected response (HTTP ${res.status})`;
    }
  } catch (err) {
    dot.className = 'dot dot-down';
    text.textContent = `unreachable — ${err.message}`;
  }
}

// Reads the API's real express-rate-limit response headers (not a UI-only
// simulation) and reflects the current quota. Every fetch() call in this
// page routes through here so the indicator always shows the latest state.
function recordRateLimit(res) {
  const limit = res.headers.get('ratelimit-limit');
  const remaining = res.headers.get('ratelimit-remaining');
  const reset = res.headers.get('ratelimit-reset');
  if (limit === null || remaining === null) return;

  const body = document.getElementById('ratelimit-body');
  const dot = document.getElementById('ratelimit-dot');
  const text = document.getElementById('ratelimit-text');
  body.hidden = false;

  const remainingNum = parseInt(remaining, 10);
  const limitNum = parseInt(limit, 10);
  const ratio = limitNum > 0 ? remainingNum / limitNum : 1;
  dot.className = 'dot ' + (ratio <= 0 ? 'dot-down' : ratio < 0.2 ? 'dot-pending' : 'dot-ok');

  const resetText = reset !== null ? `, resets in ${reset}s` : '';
  text.textContent = `Rate limit: ${remaining}/${limit} requests remaining${resetText}`;
}

function showOutput(el, data, isError) {
  el.hidden = false;
  el.textContent = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
  el.className = 'output ' + (isError ? 'error' : 'success');
}

function formToJSON(form) {
  const data = {};
  new FormData(form).forEach((value, key) => { data[key] = value; });
  return data;
}

function setButtonsDisabled(form, disabled) {
  form.querySelectorAll('button').forEach((b) => { b.disabled = disabled; });
}

function wireAuthForm(formId, outputId, path) {
  const form = document.getElementById(formId);
  const output = document.getElementById(outputId);

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    setButtonsDisabled(form, true);
    try {
      const res = await fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(formToJSON(form)),
      });
      recordRateLimit(res);
      const body = await res.json();
      if (!res.ok) {
        showOutput(output, body, true);
        return;
      }
      showOutput(output, body, false);
      if (body.token) {
        currentToken = body.token;
        document.getElementById('profile-button').disabled = false;
      }
    } catch (err) {
      showOutput(output, { error: err.message }, true);
    } finally {
      setButtonsDisabled(form, false);
    }
  });
}

// Deliberately submits a password that fails the API's server-side
// validation (min length 10, upper/lower/digit) so the real rejection
// response — not a client-side guess at what it might say — is visible.
function wireWeakPasswordDemo() {
  const button = document.getElementById('register-weak-btn');
  const form = document.getElementById('register-form');

  button.addEventListener('click', () => {
    if (!form.name.value) form.name.value = 'Weak Password Demo';
    if (!form.email.value) form.email.value = `weak-demo-${Date.now()}@example.com`;
    form.password.value = 'short1';
    form.requestSubmit();
  });
}

// Deliberately sends a malformed/invalid JWT — bypassing whatever token is
// currently held — so the API's real 401 AuthenticationError is visible
// without needing a prior successful register/login.
function wireInvalidTokenDemo() {
  const button = document.getElementById('profile-invalid-btn');
  const output = document.getElementById('profile-output');

  button.addEventListener('click', async () => {
    button.disabled = true;
    try {
      const res = await fetch('/api/users/profile', {
        headers: { Authorization: 'Bearer not-a-real-jwt.tampered.token' },
      });
      recordRateLimit(res);
      const body = await res.json();
      showOutput(output, body, !res.ok);
    } catch (err) {
      showOutput(output, { error: err.message }, true);
    } finally {
      button.disabled = false;
    }
  });
}

function wireProfileButton() {
  const button = document.getElementById('profile-button');
  const output = document.getElementById('profile-output');

  button.addEventListener('click', async () => {
    if (!currentToken) return;
    button.disabled = true;
    try {
      const res = await fetch('/api/users/profile', {
        headers: { Authorization: `Bearer ${currentToken}` },
      });
      recordRateLimit(res);
      const body = await res.json();
      showOutput(output, body, !res.ok);
    } catch (err) {
      showOutput(output, { error: err.message }, true);
    } finally {
      button.disabled = false;
    }
  });
}

checkHealth();
wireAuthForm('register-form', 'register-output', '/api/auth/register');
wireAuthForm('login-form', 'login-output', '/api/auth/login');
wireWeakPasswordDemo();
wireProfileButton();
wireInvalidTokenDemo();
