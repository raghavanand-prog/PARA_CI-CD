'use strict';

// All requests are same-origin (this page and the API are served from the
// same Vercel deployment), so no base URL or CORS handling is needed.

let currentToken = null;

async function checkHealth() {
  const dot = document.querySelector('#status-body .dot');
  const text = document.getElementById('status-text');
  try {
    const res = await fetch('/health');
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

function wireAuthForm(formId, outputId, path) {
  const form = document.getElementById(formId);
  const output = document.getElementById(outputId);

  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const button = form.querySelector('button');
    button.disabled = true;
    try {
      const res = await fetch(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(formToJSON(form)),
      });
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
wireProfileButton();
