'use strict';

/**
 * Minimal toast notification system. No framework needed — a fixed
 * region in the DOM, appended to by JS, auto-dismissed after a delay.
 */

function ensureToastRegion() {
  let region = document.getElementById('toast-region');
  if (!region) {
    region = document.createElement('div');
    region.id = 'toast-region';
    region.setAttribute('role', 'status');
    region.setAttribute('aria-live', 'polite');
    document.body.appendChild(region);
  }
  return region;
}

const ICONS = {
  success: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none"><path d="M13.5 4.5 6.5 11.5 3 8" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
  error: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="6.2" stroke="currentColor" stroke-width="1.6"/><path d="M8 5v3.6M8 11h.01" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>',
  info: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none"><circle cx="8" cy="8" r="6.2" stroke="currentColor" stroke-width="1.6"/><path d="M8 7.2v3.6M8 5h.01" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>',
};

function showToast({ type = 'info', title, detail, duration = 4200 }) {
  const region = ensureToastRegion();
  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.innerHTML = `
    <span class="toast-icon">${ICONS[type] || ICONS.info}</span>
    <div class="toast-body">
      <div class="toast-title"></div>
      ${detail ? '<div class="toast-detail"></div>' : ''}
    </div>
    <button class="toast-close" aria-label="Dismiss notification">
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none"><path d="M1 1l12 12M13 1 1 13" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>
    </button>
  `;
  el.querySelector('.toast-title').textContent = title;
  if (detail) el.querySelector('.toast-detail').textContent = detail;

  const remove = () => {
    el.classList.add('leaving');
    setTimeout(() => el.remove(), 160);
  };
  el.querySelector('.toast-close').addEventListener('click', remove);
  region.appendChild(el);

  if (duration > 0) setTimeout(remove, duration);
  return el;
}
