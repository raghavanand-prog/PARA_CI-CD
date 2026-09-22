'use strict';

const session = requireSession();
if (session) {
  init();
}

function init() {
  document.getElementById('header-user-name').textContent = session.name || session.email;
  document.getElementById('identity-name').textContent = session.name || '—';
  document.getElementById('identity-email').textContent = session.email;
  renderAccessToken();

  checkApiStatus();
  loadProfile();
  wireLogout();
  wireRefreshButton();
  wireCopyToken();
  wireDeveloperTests();
  wireModal();

  window.addEventListener('ratelimit', (e) => renderRateLimit(e.detail));
}

/* ---------- API status (header + status strip) ---------- */
async function checkApiStatus() {
  const dots = [document.getElementById('header-api-dot'), document.getElementById('tile-api-dot')];
  const texts = [document.getElementById('header-api-text'), document.getElementById('tile-api-text')];
  try {
    const { ok, body } = await apiGet('/health');
    if (ok && body?.status === 'ok') {
      dots.forEach((d) => { d.className = d.id === 'tile-api-dot' ? 'dot dot-ok' : 'dot-live'; });
      texts[0].textContent = 'API Operational';
      texts[1].textContent = 'Operational';
    } else {
      throw new Error('unexpected');
    }
  } catch {
    dots.forEach((d) => { d.className = d.id === 'tile-api-dot' ? 'dot dot-down' : 'dot-live'; d.style.background = 'var(--danger)'; });
    texts[0].textContent = 'API Unreachable';
    texts[1].textContent = 'Unreachable';
  }
  const rl = getLastRateLimit();
  if (rl) renderRateLimit(rl);
}

function renderRateLimit(rl) {
  const text = `${rl.remaining} / ${rl.limit} requests`;
  document.getElementById('header-rate-text').textContent = text;
  document.getElementById('tile-rate-text').textContent = `${rl.remaining} / ${rl.limit}`;
}

/* ---------- Identity (profile) ---------- */
async function loadProfile() {
  const { ok, status, body } = await apiGet('/api/users/profile', session.token);
  if (!ok) {
    if (status === 401) {
      // Access token expired/invalid and wasn't refreshed in time.
      showToast({ type: 'error', title: 'Session expired', detail: 'Please sign in again.' });
      Session.clear();
      setTimeout(() => { window.location.href = '/login'; }, 900);
    }
    return;
  }
  document.getElementById('identity-id').textContent = body.user.id;
  document.getElementById('identity-created').textContent = new Date(body.user.createdAt).toLocaleString(undefined, {
    year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit',
  });
}

/* ---------- Access token display ---------- */
function renderAccessToken() {
  const token = session.token;
  const truncated = token.length > 16 ? `${token.slice(0, 10)}…${token.slice(-6)}` : token;
  document.getElementById('access-token-display').textContent = truncated;

  const payload = decodeJwtPayload(token);
  const expiryEl = document.getElementById('access-expiry');
  const expiry = payload ? formatExpiry(payload.exp) : null;
  if (expiry) {
    expiryEl.textContent = expiry === 'expired' ? 'Expired' : `Expires in ${expiry}`;
    expiryEl.classList.toggle('expiring-soon', expiry !== 'expired' && payload.exp - Date.now() / 1000 < 300);
  } else {
    expiryEl.textContent = '';
  }
}

function wireCopyToken() {
  document.getElementById('copy-access-token').addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(session.token);
      showToast({ type: 'success', title: 'Access token copied', duration: 2000 });
    } catch {
      showToast({ type: 'error', title: 'Could not copy — clipboard unavailable', duration: 2500 });
    }
  });
}

/* ---------- Logout ---------- */
function wireLogout() {
  document.getElementById('logout-button').addEventListener('click', async () => {
    const button = document.getElementById('logout-button');
    setBtnLoading(button, true);
    try {
      await apiPost('/api/auth/logout', { refreshToken: session.refreshToken });
    } catch {
      /* Revocation is best-effort from the client's perspective — the
         session is cleared locally either way. */
    }
    Session.clear();
    window.location.href = '/login';
  });
}

/* ---------- Refresh access token ---------- */
function wireRefreshButton() {
  document.getElementById('refresh-token-button').addEventListener('click', async () => {
    const button = document.getElementById('refresh-token-button');
    setBtnLoading(button, true);
    try {
      const { ok, status, body } = await apiPost('/api/auth/refresh', { refreshToken: session.refreshToken });
      if (!ok) {
        showToast({ type: 'error', title: 'Refresh failed', detail: `HTTP ${status} — ${body?.error?.message || 'session may be invalid'}` });
        return;
      }
      session.token = body.token;
      session.refreshToken = body.refreshToken;
      Session.set(session);
      renderAccessToken();
      showToast({ type: 'success', title: 'Access token refreshed', detail: 'Refresh token rotated — the previous one is now revoked.' });
    } catch {
      showToast({ type: 'error', title: 'Refresh failed', detail: 'Network error.' });
    } finally {
      setBtnLoading(button, false);
    }
  });
}

function setBtnLoading(button, loading) {
  button.disabled = loading;
  button.dataset.originalText = button.dataset.originalText || button.textContent;
  button.textContent = loading ? '…' : button.dataset.originalText;
}

/* ---------- Developer / API testing ---------- */
function wireDeveloperTests() {
  document.getElementById('test-weak-password').addEventListener('click', async () => {
    const { ok, status, body } = await apiPost('/api/auth/register', {
      name: 'Weak Password Test',
      email: `weak-test-${Date.now()}@example.com`,
      password: 'short1',
    });
    if (!ok && status === 400) {
      showToast({ type: 'success', title: 'Server rejected weak password', detail: `${status} Bad Request` });
    } else {
      showToast({ type: 'error', title: 'Unexpected result', detail: `HTTP ${status}` });
    }
    openResponseModal(status, body);
  });

  document.getElementById('test-invalid-token').addEventListener('click', async () => {
    const { ok, status, body } = await apiGet('/api/users/profile', 'tampered.invalid.token');
    if (!ok && status === 401) {
      showToast({ type: 'success', title: 'Invalid token rejected', detail: `${status} Unauthorized` });
    } else {
      showToast({ type: 'error', title: 'Unexpected result', detail: `HTTP ${status}` });
    }
    openResponseModal(status, body);
  });
}

/* ---------- API response modal ---------- */
function syntaxHighlight(json) {
  const str = JSON.stringify(json, null, 2);
  return str
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\"])*"(\s*:)?|\b(true|false|null)\b|-?\d+(?:\.\d*)?(?:[eE][+-]?\d+)?)/g, (match) => {
      let cls = 'n';
      if (/^"/.test(match)) cls = /:$/.test(match) ? 'k' : 's';
      return `<span class="${cls}">${match}</span>`;
    });
}

function openResponseModal(status, body) {
  const overlay = document.getElementById('response-modal');
  const pill = document.getElementById('response-status-pill');
  const isOk = status >= 200 && status < 300;
  pill.className = `status-pill ${isOk ? 'ok' : 'err'}`;
  pill.textContent = `${status} ${statusText(status)}`;
  document.getElementById('response-json').innerHTML = syntaxHighlight(body ?? {});
  overlay.hidden = false;
  document.getElementById('response-modal-close').focus();
}

function statusText(status) {
  const map = { 200: 'OK', 201: 'Created', 204: 'No Content', 400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 409: 'Conflict', 429: 'Too Many Requests', 500: 'Server Error' };
  return map[status] || '';
}

function wireModal() {
  const overlay = document.getElementById('response-modal');
  const close = () => { overlay.hidden = true; };
  document.getElementById('response-modal-close').addEventListener('click', close);
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !overlay.hidden) close(); });
}
