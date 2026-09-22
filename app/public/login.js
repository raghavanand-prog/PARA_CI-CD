'use strict';

// If already signed in, skip the login page entirely.
if (Session.get()) {
  window.location.href = '/';
}

/* ---------- Tab switching ---------- */
const tabSignin = document.getElementById('tab-signin');
const tabRegister = document.getElementById('tab-register');
const viewSignin = document.getElementById('view-signin');
const viewRegister = document.getElementById('view-register');

function setMode(mode) {
  const isSignin = mode === 'signin';
  tabSignin.classList.toggle('active', isSignin);
  tabRegister.classList.toggle('active', !isSignin);
  tabSignin.setAttribute('aria-selected', String(isSignin));
  tabRegister.setAttribute('aria-selected', String(!isSignin));
  viewSignin.classList.toggle('active', isSignin);
  viewRegister.classList.toggle('active', !isSignin);
  (isSignin ? document.getElementById('signin-email') : document.getElementById('register-name')).focus();
}

tabSignin.addEventListener('click', () => setMode('signin'));
tabRegister.addEventListener('click', () => setMode('register'));
document.getElementById('go-to-register').addEventListener('click', (e) => { e.preventDefault(); setMode('register'); });
document.getElementById('go-to-signin').addEventListener('click', (e) => { e.preventDefault(); setMode('signin'); });

// Support ?mode=register deep link (used by the "Create account" link
// on the dashboard).
if (new URLSearchParams(window.location.search).get('mode') === 'register') {
  setMode('register');
}

/* ---------- Password show/hide ---------- */
document.querySelectorAll('.input-toggle').forEach((btn) => {
  btn.addEventListener('click', () => {
    const input = document.getElementById(btn.dataset.toggleFor);
    const showing = input.type === 'text';
    input.type = showing ? 'password' : 'text';
    btn.setAttribute('aria-label', showing ? 'Show password' : 'Hide password');
    btn.setAttribute('aria-pressed', String(!showing));
  });
});

/* ---------- Live password requirement checklist ---------- */
const passwordInput = document.getElementById('register-password');
const requirements = {
  length: (v) => v.length >= 10,
  upper: (v) => /[A-Z]/.test(v),
  lower: (v) => /[a-z]/.test(v),
  digit: (v) => /\d/.test(v),
};
passwordInput.addEventListener('input', () => {
  const value = passwordInput.value;
  document.querySelectorAll('#password-requirements li').forEach((li) => {
    const key = li.dataset.req;
    li.classList.toggle('met', requirements[key](value));
  });
});

/* ---------- Shared form helpers ---------- */
function setFieldError(inputId, message) {
  const errorEl = document.getElementById(`${inputId}-error`);
  const inputEl = document.getElementById(inputId);
  if (message) {
    errorEl.textContent = message;
    errorEl.hidden = false;
    inputEl.setAttribute('aria-invalid', 'true');
  } else {
    errorEl.hidden = true;
    inputEl.removeAttribute('aria-invalid');
  }
}

function clearErrors(...ids) {
  ids.forEach((id) => setFieldError(id, null));
}

function setLoading(button, loading) {
  button.classList.toggle('is-loading', loading);
  button.disabled = loading;
}

// Maps the API's field-level validation-error array (from
// express-validator, unchanged on the backend) onto the matching input.
function applyServerFieldErrors(prefix, details) {
  if (!Array.isArray(details)) return false;
  let applied = false;
  details.forEach((d) => {
    const inputId = `${prefix}-${d.field}`;
    if (document.getElementById(inputId)) {
      setFieldError(inputId, d.message);
      applied = true;
    }
  });
  return applied;
}

function friendlyAuthError(status, body) {
  if (status === 429) return 'Too many attempts. Please wait a moment and try again.';
  if (status === 0 || status === undefined) return 'Network error — could not reach the server.';
  if (status >= 500) return 'Server error. Please try again shortly.';
  return body?.error?.message || 'Something went wrong. Please try again.';
}

/* ---------- Sign in ---------- */
let signinInFlight = false;
document.getElementById('signin-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  if (signinInFlight) return;

  clearErrors('signin-email', 'signin-password');
  const email = document.getElementById('signin-email').value.trim();
  const password = document.getElementById('signin-password').value;

  if (!email) { setFieldError('signin-email', 'Email is required'); return; }
  if (!password) { setFieldError('signin-password', 'Password is required'); return; }

  signinInFlight = true;
  const button = document.getElementById('signin-submit');
  setLoading(button, true);

  try {
    const { ok, status, body } = await apiPost('/api/auth/login', { email, password });
    if (!ok) {
      if (!applyServerFieldErrors('signin', body?.error?.details)) {
        showToast({ type: 'error', title: 'Sign in failed', detail: friendlyAuthError(status, body) });
      }
      return;
    }

    Session.set({ email: body.user.email, name: body.user.name, token: body.token, refreshToken: body.refreshToken });
    showToast({ type: 'success', title: 'Signed in', detail: `Welcome back, ${body.user.name}` });
    setTimeout(() => { window.location.href = '/'; }, 320);
  } catch {
    showToast({ type: 'error', title: 'Sign in failed', detail: 'Network error — could not reach the server.' });
  } finally {
    signinInFlight = false;
    setLoading(button, false);
  }
});

/* ---------- Create account ---------- */
let registerInFlight = false;
document.getElementById('register-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  if (registerInFlight) return;

  clearErrors('register-name', 'register-email', 'register-password');
  const name = document.getElementById('register-name').value.trim();
  const email = document.getElementById('register-email').value.trim();
  const password = document.getElementById('register-password').value;

  if (!name) { setFieldError('register-name', 'Name is required'); return; }
  if (!email) { setFieldError('register-email', 'Email is required'); return; }
  if (!password) { setFieldError('register-password', 'Password is required'); return; }

  registerInFlight = true;
  const button = document.getElementById('register-submit');
  setLoading(button, true);

  try {
    const { ok, status, body } = await apiPost('/api/auth/register', { name, email, password });
    if (!ok) {
      if (!applyServerFieldErrors('register', body?.error?.details)) {
        showToast({ type: 'error', title: 'Registration failed', detail: friendlyAuthError(status, body) });
      }
      return;
    }

    Session.set({ email: body.user.email, name: body.user.name, token: body.token, refreshToken: body.refreshToken });
    showToast({ type: 'success', title: 'Account created', detail: `Welcome, ${body.user.name}` });
    setTimeout(() => { window.location.href = '/'; }, 320);
  } catch {
    showToast({ type: 'error', title: 'Registration failed', detail: 'Network error — could not reach the server.' });
  } finally {
    registerInFlight = false;
    setLoading(button, false);
  }
});
