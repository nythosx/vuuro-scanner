'use strict';

const STORAGE_KEY = 'vuuro.scan.admin.key';

const state = {
  adminKey: '',
  currentSessionId: null,
  returnTo: null,
  planStyle: 'auto',
};

const PLAN_STYLES = [
  { value: 'auto', label: 'Automatic (per purpose)' },
  { value: 'funda', label: 'Listing plan' },
  { value: 'default', label: 'Full report' },
];

function planStyleQuery() {
  if (state.planStyle === 'funda') return '?style=funda';
  if (state.planStyle === 'auto') return '?style=auto';
  return '';
}

const VIEWS = ['loading', 'login', 'search', 'detail', 'imports', 'settings'];

const RETENTION_PURPOSES = [
  { value: 'listing', label: 'Listing' },
  { value: 'check_in', label: 'Check-in' },
  { value: 'check_out', label: 'Check-out' },
  { value: 'renovation', label: 'Renovation' },
  { value: 'other', label: 'Other' },
];

const $ = (sel) => document.querySelector(sel);

const API_TIMEOUT_MS = 60000;
const activeBlobUrls = new Set();

function trackBlobUrl(url) {
  activeBlobUrls.add(url);
  return url;
}

function revokeBlobUrl(url) {
  if (url && activeBlobUrls.has(url)) {
    URL.revokeObjectURL(url);
    activeBlobUrls.delete(url);
  }
}

function revokeAllBlobUrls() {
  activeBlobUrls.forEach((url) => URL.revokeObjectURL(url));
  activeBlobUrls.clear();
}

function formatTimestamp(value) {
  if (!value) return '';
  const d = new Date(value);
  if (isNaN(d.getTime())) return String(value);
  return d.toLocaleString(undefined, {
    year: 'numeric',
    month: 'short',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });
}

function friendlyApiError(err) {
  const raw = err && err.message ? String(err.message) : 'Request failed.';
  const m = raw.match(/^HTTP (\d+):\s*([\s\S]*)$/);
  if (!m) return raw;
  const status = m[1];
  const body = m[2];
  try {
    const parsed = JSON.parse(body);
    if (parsed && typeof parsed.message === 'string' && parsed.message.length > 0) {
      return parsed.message;
    }
    if (parsed && typeof parsed.error === 'string' && parsed.error.length > 0) {
      return parsed.error.replace(/_/g, ' ');
    }
  } catch (e) {}
  return 'HTTP ' + status + ' - ' + (body || 'no details');
}

function escapeHtml(s) {
  if (s === null || s === undefined) return '';
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function networkError(err) {
  const error = new Error('Could not reach the Scan Service. Check that it is running and try again.');
  error.isNetwork = true;
  error.cause = err;
  return error;
}

function loadingHtml(text) {
  return '<div class="state"><span class="spinner" aria-hidden="true"></span><p>' + escapeHtml(text) + '</p></div>';
}

function emptyHtml(text) {
  return '<div class="state state-empty"><p>' + escapeHtml(text) + '</p></div>';
}

function renderError(container, message, retry) {
  if (!container) return;
  container.innerHTML = '<div class="state state-error" role="alert"><p>' + escapeHtml(message) + '</p>' +
    (retry ? '<button type="button" class="small retry-btn">Try again</button>' : '') + '</div>';
  if (retry) {
    container.querySelector('.retry-btn').addEventListener('click', retry);
  }
}

function wrapTable(html) {
  return '<div class="table-wrap">' + html + '</div>';
}

async function api(path, options) {
  const opts = options || {};
  const headers = Object.assign({}, opts.headers || {});
  headers['X-Admin-Api-Key'] = state.adminKey;

  const controller = new AbortController();
  const timeoutMs = opts.timeoutMs || API_TIMEOUT_MS;
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);

  let response;
  try {
    response = await fetch(path, Object.assign({}, opts, {
      headers,
      signal: controller.signal,
    }));
  } catch (err) {
    clearTimeout(timeoutId);
    if (err && err.name === 'AbortError') {
      const timeoutError = new Error(
        'Request timed out after ' + Math.round(timeoutMs / 1000) +
        ' seconds. The Scan Service may be busy or unreachable.'
      );
      timeoutError.isTimeout = true;
      throw timeoutError;
    }
    throw networkError(err);
  }
  clearTimeout(timeoutId);

  if (response.status === 401) {
    handleAuthFailure();
    throw new Error('Not authorized - admin key rejected');
  }
  if (!response.ok && !opts.allowNonOk) {
    const text = await response.text().catch(() => '');
    throw new Error('HTTP ' + response.status + ': ' + (text || response.statusText));
  }
  return response;
}

async function apiJson(path) {
  const response = await api(path);
  return response.json();
}

async function apiBlob(path) {
  const response = await api(path);
  return response.blob();
}

function handleAuthFailure() {
  sessionStorage.removeItem(STORAGE_KEY);
  state.adminKey = '';
  state.currentSessionId = null;
  recentIdentitiesLoaded = false;
  showLogin('Your admin key is no longer accepted. Please sign in again.');
}

function showView(name) {
  VIEWS.forEach((view) => {
    $('#view-' + view).classList.toggle('hidden', view !== name);
  });
  const signedIn = name !== 'login' && name !== 'loading';
  $('#topnav').classList.toggle('hidden', !signedIn);
  $('#signOutBtn').classList.toggle('hidden', !signedIn);
  if (signedIn) $('#keyStatus').textContent = 'Signed in';
  window.scrollTo(0, 0);
}

function showLogin(errorMessage) {
  showView('login');
  $('#keyStatus').textContent = 'Signed out';
  const errEl = $('#loginError');
  if (errorMessage) {
    errEl.textContent = errorMessage;
    errEl.classList.remove('hidden');
  } else {
    errEl.textContent = '';
    errEl.classList.add('hidden');
  }
}

function setTopnav(active) {
  document.querySelectorAll('.nav-btn').forEach((b) => {
    b.classList.toggle('active', b.getAttribute('data-nav') === active);
  });
}

function setUrl(query, push) {
  const url = '/admin' + (query ? '?' + query : '');
  if (location.pathname + location.search === url) return;
  if (push) history.pushState({}, '', url);
  else history.replaceState({}, '', url);
}

function showSearch(options) {
  const opts = options || {};
  showView('search');
  setTopnav('search');
  if (!opts.fromHistory) setUrl('', opts.push !== false);
}

let recentIdentitiesLoaded = false;

async function loadRecentIdentities() {
  if (recentIdentitiesLoaded) return;
  recentIdentitiesLoaded = true;
  try {
    const data = await apiJson('/admin/recent-identities');
    fillDatalist('recentPropertyIds', data.property_ids || []);
    fillDatalist('recentUnitIds', data.unit_ids || []);
    fillDatalist('recentOrganisationIds', data.organisation_ids || []);
  } catch (err) {
    recentIdentitiesLoaded = false;
  }
}

function fillDatalist(id, values) {
  const list = document.getElementById(id);
  if (!list) return;
  list.innerHTML = '';
  values.forEach((value) => {
    const opt = document.createElement('option');
    opt.value = value;
    list.appendChild(opt);
  });
}

function showDetail(returnTo) {
  state.returnTo = returnTo;
  showView('detail');
  setTopnav(returnTo);
  $('#backBtn').innerHTML = '&larr; ' + (returnTo === 'imports' ? 'Back to imports' : 'Back to search');
}

function showImports(options) {
  const opts = options || {};
  showView('imports');
  setTopnav('imports');
  if (!opts.fromHistory) setUrl('view=imports', opts.push !== false);
  loadImportsList();
}

function showSettings(options) {
  const opts = options || {};
  showView('settings');
  setTopnav('settings');
  if (!opts.fromHistory) setUrl('view=settings', opts.push !== false);
  loadSettings();
}

async function loadSettings() {
  const container = $('#settingsContent');
  container.innerHTML = loadingHtml('Loading settings…');
  try {
    renderSettings(await apiJson('/admin/settings'));
  } catch (err) {
    container.innerHTML = '<p class="error">Could not load settings: ' + escapeHtml(friendlyApiError(err)) + '</p>';
  }
}

let settingsLimits = { retention_days: { min: 1, max: 3650 }, tenant_grace_days: { min: 1, max: 90 } };

function settingsSourceNote(rule) {
  if (rule.source === 'env') return 'Set by the server config';
  if (rule.source === 'default') return 'Suggested default';
  return 'Set here';
}

function renderSettings(data) {
  const container = $('#settingsContent');
  if (data.limits) settingsLimits = data.limits;
  const dayLimits = settingsLimits.retention_days;
  const graceLimits = settingsLimits.tenant_grace_days;
  const rows = RETENTION_PURPOSES.map((p) => {
    const rule = data.retention[p.value];
    const reset = rule.source === 'admin'
      ? ' <button type="button" class="small ghost" data-retention-reset="' + p.value + '">' + (rule.server_config_days ? 'Use server config (' + escapeHtml(String(rule.server_config_days)) + ' days)' : 'Reset') + '</button>'
      : '';
    return '<tr>' +
      '<td>' + escapeHtml(p.label) + '</td>' +
      '<td><label class="switch"><input type="checkbox" data-retention-enabled="' + p.value + '"' + (rule.enabled ? ' checked' : '') + '> <span>' + (rule.enabled ? 'On' : 'Off') + '</span></label></td>' +
      '<td><input type="number" min="' + dayLimits.min + '" max="' + dayLimits.max + '" step="1" class="days-input" data-retention-days="' + p.value + '" value="' + escapeHtml(String(rule.days)) + '"> days</td>' +
      '<td class="muted">' + escapeHtml(settingsSourceNote(rule)) + reset + '</td>' +
    '</tr>';
  }).join('');
  const tenant = data.tenant_deletion;
  const planRows = RETENTION_PURPOSES.map((p) => {
    const current = (data.plan_style || {})[p.value] || 'listing';
    return '<tr>' +
      '<td>' + escapeHtml(p.label) + '</td>' +
      '<td><select data-plan-style="' + p.value + '">' +
        '<option value="listing"' + (current === 'listing' ? ' selected' : '') + '>Listing plan</option>' +
        '<option value="full"' + (current === 'full' ? ' selected' : '') + '>Full report</option>' +
      '</select></td>' +
    '</tr>';
  }).join('');
  container.innerHTML =
    '<h2>Default floor plan</h2>' +
    '<p class="muted">Used when the app is set to Automatic, and for Automatic in this dashboard. Listing plan is the clean Funda-style plan; Full report adds measurements, notes and missing items.</p>' +
    wrapTable('<table class="data-table settings-table"><thead><tr><th>Purpose</th><th>Plan</th></tr></thead><tbody>' + planRows + '</tbody></table>') +
    '<h2>Delete scans automatically</h2>' +
    '<p class="muted">When a purpose is on, scans of that purpose are deleted once they are older than the number of days set. Off means they are kept until the access link expires.</p>' +
    wrapTable('<table class="data-table settings-table"><thead><tr><th>Purpose</th><th>Auto-delete</th><th>After</th><th></th></tr></thead><tbody>' + rows + '</tbody></table>') +
    '<h2>Tenant deletion requests</h2>' +
    '<div class="settings-row"><label class="switch"><input type="checkbox" id="tenantDeletionEnabled"' + (tenant.enabled ? ' checked' : '') + '> <span>Tenants can ask for a scan to be deleted from the app</span></label></div>' +
    '<div class="settings-row"><label>Delete after <input type="number" min="' + graceLimits.min + '" max="' + graceLimits.max + '" step="1" class="days-input" id="tenantGraceDays" value="' + escapeHtml(String(tenant.grace_days)) + '"> days, unless the request is cancelled first</label></div>' +
    '<div class="actions">' +
      '<button id="saveSettingsBtn" class="primary" type="button">Save settings</button>' +
      '<button id="runRetentionBtn" class="ghost" type="button">Run clean-up now</button>' +
    '</div>' +
    '<p id="settingsMessage" class="hidden"></p>';

  container.querySelectorAll('input[type="checkbox"][data-retention-enabled]').forEach((box) => {
    box.addEventListener('change', () => {
      box.nextElementSibling.textContent = box.checked ? 'On' : 'Off';
    });
  });
  container.querySelectorAll('[data-retention-reset]').forEach((btn) => {
    btn.addEventListener('click', () => resetRetention(btn.getAttribute('data-retention-reset')));
  });
  $('#saveSettingsBtn').addEventListener('click', saveSettings);
  $('#runRetentionBtn').addEventListener('click', runRetentionNow);
}

function settingsMessage(text, isError) {
  const el = $('#settingsMessage');
  if (!el) return;
  el.textContent = text;
  el.className = isError ? 'error' : 'muted';
}

function readWholeNumber(input, min, max, label) {
  const value = Number(input.value);
  if (!Number.isInteger(value) || value < min || value > max) {
    input.focus();
    throw new Error(label + ' must be a whole number from ' + min + ' to ' + max + '.');
  }
  return value;
}

async function postSettings(payload) {
  const response = await api('/admin/settings', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  return response.json();
}

async function resetRetention(purpose) {
  const retention = {};
  retention[purpose] = null;
  try {
    renderSettings(await postSettings({ retention }));
    settingsMessage('Back to the server config for that purpose.', false);
  } catch (err) {
    settingsMessage('Could not reset: ' + friendlyApiError(err), true);
  }
}

async function saveSettings() {
  const btn = $('#saveSettingsBtn');
  let payload;
  try {
    const retention = {};
    RETENTION_PURPOSES.forEach((p) => {
      retention[p.value] = {
        enabled: document.querySelector('[data-retention-enabled="' + p.value + '"]').checked,
        days: readWholeNumber(document.querySelector('[data-retention-days="' + p.value + '"]'), settingsLimits.retention_days.min, settingsLimits.retention_days.max, p.label + ' days'),
      };
    });
    const planStyle = {};
    RETENTION_PURPOSES.forEach((p) => {
      planStyle[p.value] = document.querySelector('[data-plan-style="' + p.value + '"]').value;
    });
    payload = {
      plan_style: planStyle,
      retention,
      tenant_deletion: {
        enabled: $('#tenantDeletionEnabled').checked,
        grace_days: readWholeNumber($('#tenantGraceDays'), settingsLimits.tenant_grace_days.min, settingsLimits.tenant_grace_days.max, 'Tenant deletion days'),
      },
    };
  } catch (err) {
    settingsMessage(err.message, true);
    return;
  }
  btn.disabled = true;
  try {
    renderSettings(await postSettings(payload));
    settingsMessage('Settings saved.', false);
    showToast('Settings saved');
  } catch (err) {
    settingsMessage('Could not save settings: ' + friendlyApiError(err), true);
    btn.disabled = false;
  }
}

async function runRetentionNow() {
  if (!window.confirm('Delete every scan that is past its auto-delete date or tenant deletion date now? This cannot be undone.')) return;
  const btn = $('#runRetentionBtn');
  btn.disabled = true;
  try {
    const response = await api('/admin/run-retention', { method: 'POST' });
    const data = await response.json();
    settingsMessage('Clean-up finished: ' + data.purged + ' scan' + (data.purged === 1 ? '' : 's') + ' deleted.', false);
  } catch (err) {
    settingsMessage('Clean-up failed: ' + friendlyApiError(err), true);
  } finally {
    btn.disabled = false;
  }
}

function showLoading(message, retry) {
  showView('loading');
  const container = $('#loadingState');
  if (retry) {
    container.className = 'state state-error';
    container.setAttribute('role', 'alert');
    container.innerHTML = '<p>' + escapeHtml(message) + '</p><button type="button" class="small retry-btn">Try again</button>';
    container.querySelector('.retry-btn').addEventListener('click', retry);
  } else {
    container.className = 'state';
    container.removeAttribute('role');
    container.innerHTML = '<span class="spinner" aria-hidden="true"></span><p>' + escapeHtml(message) + '</p>';
  }
}

function routeFromUrl(fromHistory) {
  const params = new URLSearchParams(location.search);
  const sessionId = params.get('session');
  const importId = params.get('import');
  if (sessionId) openSession(sessionId, { fromHistory });
  else if (importId) openImport(importId, { fromHistory });
  else if (params.get('view') === 'imports') showImports({ fromHistory, push: false });
  else if (params.get('view') === 'settings') showSettings({ fromHistory, push: false });
  else showSearch({ fromHistory, push: false });
}

async function testKey() {
  await api('/scan-sessions?property_id=___probe___');
}

async function login() {
  const input = $('#adminKeyInput');
  const button = $('#loginBtn');
  const key = input.value.trim();
  if (!key) {
    showLogin('Please enter the admin key.');
    input.focus();
    return;
  }
  state.adminKey = key;
  button.disabled = true;
  button.textContent = 'Signing in…';
  try {
    await testKey();
    sessionStorage.setItem(STORAGE_KEY, key);
    input.value = '';
    loadRecentIdentities();
    routeFromUrl(true);
  } catch (err) {
    state.adminKey = '';
    showLogin(err.isNetwork ? err.message : 'That admin key was not accepted.');
  } finally {
    button.disabled = false;
    button.textContent = 'Sign in';
  }
}

function signOut() {
  if (!confirm('Sign out of admin?')) return;
  sessionStorage.removeItem(STORAGE_KEY);
  state.adminKey = '';
  state.currentSessionId = null;
  recentIdentitiesLoaded = false;
  $('#searchResults').innerHTML = '';
  $('#detailContent').innerHTML = '';
  setUrl('', false);
  showLogin();
}

function renderSearchResults(sessions) {
  const container = $('#searchResults');
  if (!sessions || sessions.length === 0) {
    container.innerHTML = emptyHtml('No scans match these filters. Check the IDs for typos, or search with fewer fields.');
    return;
  }
  const rows = sessions.map((s) => {
    return '<tr data-session-id="' + escapeHtml(s.id) + '">' +
      '<td><code>' + escapeHtml(s.property_id) + '</code></td>' +
      '<td><code>' + escapeHtml(s.unit_id) + '</code></td>' +
      '<td><code>' + escapeHtml(s.organisation_id) + '</code></td>' +
      '<td>' + escapeHtml(s.purpose) + '</td>' +
      '<td>' + escapeHtml(s.status) + '</td>' +
      '<td>' + escapeHtml(formatTimestamp(s.created_at)) + '</td>' +
      '<td>' + (s.occupied ? 'Yes' : 'No') + '</td>' +
      '<td><button class="open-btn primary small">Open</button></td>' +
      '</tr>';
  }).join('');
  container.innerHTML =
    '<p class="result-count">' + sessions.length + ' scan' + (sessions.length === 1 ? '' : 's') + ' found' +
      (sessions.length >= 100 ? ' (showing first 100 - narrow your search for the rest)' : '') + '</p>' +
    wrapTable('<table class="data-table"><thead><tr>' +
    '<th>Property</th><th>Unit</th><th>Organisation</th><th>Purpose</th>' +
    '<th>Status</th><th>Created</th><th>Occupied</th><th></th>' +
    '</tr></thead><tbody>' + rows + '</tbody></table>');
  container.querySelectorAll('.open-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = btn.closest('tr').getAttribute('data-session-id');
      openSession(id);
    });
  });
}

async function search(event) {
  if (event) event.preventDefault();
  const form = new FormData($('#searchForm'));
  const params = new URLSearchParams();
  for (const pair of form.entries()) {
    const value = String(pair[1]).trim();
    if (value) params.set(pair[0], value);
  }
  const container = $('#searchResults');
  if (params.toString() === '') {
    renderError(container, 'Fill in at least one of Property ID, Unit ID or Organisation ID.');
    $('#searchForm input').focus();
    return;
  }
  const button = $('#searchBtn');
  button.disabled = true;
  container.innerHTML = loadingHtml('Searching…');
  try {
    const data = await apiJson('/scan-sessions?' + params.toString());
    renderSearchResults(data.sessions || []);
  } catch (err) {
    renderError(container, 'Search failed: ' + err.message, () => search());
  } finally {
    button.disabled = false;
  }
}

async function openSession(sessionId, options) {
  const opts = options || {};
  revokeAllBlobUrls();
  state.currentSessionId = sessionId;
  showDetail('search');
  if (!opts.fromHistory) setUrl('session=' + encodeURIComponent(sessionId), true);
  const container = $('#detailContent');
  container.innerHTML = loadingHtml('Loading scan…');
  try {
    const data = await apiJson('/scan-sessions/' + encodeURIComponent(sessionId));
    if (state.currentSessionId !== sessionId) return;
    renderDetail(data, sessionId);
  } catch (err) {
    if (state.currentSessionId !== sessionId) return;
    const message = err.message.startsWith('HTTP 404')
      ? 'This scan no longer exists. It may have been deleted.'
      : 'Failed to load this scan: ' + err.message;
    renderError(container, message, () => openSession(sessionId, { fromHistory: true }));
  }
}

function renderDetail(data, sessionId) {
  const container = $('#detailContent');

  if (!data.rooms) {
    container.innerHTML = '<h1>Session ' + escapeHtml(sessionId) + '</h1>' +
      '<p class="muted">This session has no captured rooms yet (status: ' + escapeHtml(data.status || 'unknown') + ').</p>';
    return;
  }
  if (!Array.isArray(data.rooms)) {
    container.innerHTML = '<h1>Session ' + escapeHtml(sessionId) + '</h1>' +
      '<p class="error">This session\'s data looks malformed (rooms is not a list).</p>';
    return;
  }

  const rooms = data.rooms || [];
  const photos = data.photos || [];
  const notes = data.notes || [];
  const totalArea = rooms.reduce((sum, r) => sum + (Number(r.floor_area_m2) || 0), 0);

  const roomRows = rooms.map((r) => {
    const roomType = roomTypeLabel(r.room_type ? (r.room_type.confirmed || r.room_type.guess || '') : '');
    const height = r.height_m !== null && r.height_m !== undefined ? Number(r.height_m).toFixed(2) : '-';
    const coverage = r.coverage ? r.coverage.score : '';
    return '<tr>' +
      '<td>' + escapeHtml(r.label) + '</td>' +
      '<td>' + escapeHtml(roomType) + '</td>' +
      '<td>' + (Number(r.floor_area_m2) || 0).toFixed(2) + '</td>' +
      '<td>' + (Number(r.perimeter_m) || 0).toFixed(2) + '</td>' +
      '<td>' + height + '</td>' +
      '<td>' + escapeHtml(r.confidence) + '</td>' +
      '<td>' + escapeHtml(coverage) + '</td>' +
      '</tr>';
  }).join('');

  const noteItems = notes.map((n) => {
    const scope = n.room_id ? 'Room ' + escapeHtml(n.room_id) : 'Unit-level';
    return '<li><div class="note-text">' + escapeHtml(n.text) + '</div>' +
      '<div class="note-meta">' + scope + ' · ' + escapeHtml(n.created_at) + '</div></li>';
  }).join('');

  container.innerHTML =
    '<div class="detail-header">' +
      '<h1>' + escapeHtml(data.property_id) + ' — ' + escapeHtml(data.unit_id) + '</h1>' +
      '<p class="meta">' +
        '<span>Org: <code>' + escapeHtml(data.organisation_id) + '</code></span>' +
        '<span>Purpose: ' + escapeHtml(data.purpose) + '</span>' +
        '<span>Captured: ' + escapeHtml(formatTimestamp(data.captured_at)) + '</span>' +
      '</p>' +
      '<p class="meta">' +
        '<span>' + rooms.length + ' room' + (rooms.length === 1 ? '' : 's') + '</span>' +
        '<span>' + totalArea.toFixed(1) + ' m² total</span>' +
      '</p>' +
    '</div>' +

    '<div class="floor-plan">' +
      '<label class="plan-style">Plan style ' +
        '<select id="planStyleSelect">' +
          PLAN_STYLES.map((s) => '<option value="' + s.value + '"' + (s.value === state.planStyle ? ' selected' : '') + '>' + s.label + '</option>').join('') +
        '</select>' +
      '</label>' +
      '<img id="floorPlanImage" alt="Floor plan">' +
      '<p id="floorPlanError" class="error hidden"></p>' +
    '</div>' +

    '<div class="actions">' +
      '<button data-export="png" class="primary">Download PNG</button>' +
      '<button data-export="pdf" class="primary">Download PDF</button>' +
      '<button data-export="svg" class="primary">Download SVG</button>' +
    '</div>' +
    '<div class="actions secondary">' +
      '<button id="btnShareUrl" class="ghost">Copy share URL</button>' +
      '<button id="btnApiUrl" class="ghost">Copy API URL</button>' +
      '<button id="btnExportJson" class="ghost">Export JSON</button>' +
      '<button id="btnExportVuuroscan" class="ghost">Download .vuuroscan</button>' +
      '<button id="btnPublish" class="ghost">Push to platform</button>' +
    '</div>' +
    '<div id="publishResult" class="hidden"></div>' +

    '<h2>Rooms</h2>' +
    wrapTable('<table class="data-table"><thead><tr>' +
      '<th>Room</th><th>Type</th><th>Area (m²)</th><th>Perimeter (m)</th>' +
      '<th>Height (m)</th><th>Confidence</th><th>Coverage</th>' +
    '</tr></thead><tbody>' + roomRows + '</tbody></table>') +

    '<h2>Photos (' + photos.length + ')</h2>' +
    (photos.length === 0 ? emptyHtml('No photos attached.') : '<div id="photosGrid" class="photos-grid"></div>') +

    '<h2>Notes (' + notes.length + ')</h2>' +
    (noteItems ? '<ul class="notes-list">' + noteItems + '</ul>' : emptyHtml('No notes attached.')) +

    '<h2>Access log</h2>' +
    '<div id="accessLog">' + loadingHtml('Loading access log…') + '</div>';

  loadFloorPlanImage(sessionId);
  const styleSelect = $('#planStyleSelect');
  if (styleSelect) {
    styleSelect.addEventListener('change', () => {
      state.planStyle = PLAN_STYLES.some((s) => s.value === styleSelect.value) ? styleSelect.value : 'auto';
      loadFloorPlanImage(sessionId);
    });
  }
  photos.forEach((p) => loadPhotoThumb(p));
  loadAccessLog(sessionId);

  container.querySelectorAll('[data-export]').forEach((btn) => {
    btn.addEventListener('click', () => downloadExport(sessionId, btn.getAttribute('data-export'), data));
  });

  const btnShare = container.querySelector('#btnShareUrl');
  if (btnShare) btnShare.addEventListener('click', () => copyShareUrl(sessionId));
  const btnApi = container.querySelector('#btnApiUrl');
  if (btnApi) btnApi.addEventListener('click', () => copyApiUrl(sessionId));
  const btnJson = container.querySelector('#btnExportJson');
  if (btnJson) btnJson.addEventListener('click', () => exportJson(sessionId, data));
  const btnPub = container.querySelector('#btnPublish');
  if (btnPub) btnPub.addEventListener('click', () => publishToPlatform(sessionId));
  const btnVuuroscan = container.querySelector('#btnExportVuuroscan');
  if (btnVuuroscan) btnVuuroscan.addEventListener('click', () => downloadVuuroscanFile(sessionId, data));
}

async function downloadVuuroscanFile(sessionId, fp) {
  const path = '/scan-sessions/' + encodeURIComponent(sessionId) + '/export/vuuroscan';
  const base = (fp && fp.property_id ? fp.property_id : sessionId);
  const unit = (fp && fp.unit_id ? fp.unit_id : '');
  const filename = 'scan-' + base + (unit ? '-' + unit : '') + '.vuuroscan';
  try {
    const blob = await apiBlob(path);
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (err) {
    showToast('Download failed: ' + err.message);
  }
}

function copyShareUrl(sessionId) {
  const url = location.origin + '/admin?session=' + encodeURIComponent(sessionId);
  copyToClipboard(url, 'Share URL');
}

function copyApiUrl(sessionId) {
  const url = location.origin + '/scan-sessions/' + encodeURIComponent(sessionId);
  const hint = 'GET ' + url + '\nHeader: X-Admin-Api-Key: <your-admin-key>';
  copyToClipboard(hint, 'API endpoint');
}

function showToast(message) {
  let toast = document.getElementById('adminToast');
  if (!toast) {
    toast = document.createElement('div');
    toast.id = 'adminToast';
    toast.style.cssText = 'position:fixed;bottom:24px;left:50%;transform:translateX(-50%);' +
      'background:#222;color:#fff;padding:10px 16px;border-radius:6px;font-size:14px;' +
      'z-index:9999;opacity:0;transition:opacity 0.2s;pointer-events:none;max-width:80vw;' +
      'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
    document.body.appendChild(toast);
  }
  toast.textContent = message;
  toast.style.opacity = '1';
  clearTimeout(toast._hideTimer);
  toast._hideTimer = setTimeout(() => { toast.style.opacity = '0'; }, 2000);
}

function copyToClipboard(text, label) {
  const legacyFallback = () => {
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.position = 'fixed';
      ta.style.top = '-1000px';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      ta.setSelectionRange(0, text.length);
      const ok = document.execCommand && document.execCommand('copy');
      document.body.removeChild(ta);
      if (ok) {
        showToast(label + ' copied to clipboard');
        return;
      }
    } catch (e) {}
    prompt(label, text);
  };

  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(() => {
      showToast(label + ' copied to clipboard');
    }).catch(legacyFallback);
  } else {
    legacyFallback();
  }
}

function exportJson(sessionId, data) {
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = exportFileName(data, sessionId, 'scan', 'json');
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function publishToPlatform(sessionId) {
  if (!confirm('Push this scan to the platform?')) return;
  const resultEl = document.querySelector('#publishResult');
  if (!resultEl) return;
  resultEl.classList.remove('hidden');
  resultEl.className = 'publish-result';
  resultEl.textContent = 'Pushing to platform...';
  try {
    const response = await api('/scan-sessions/' + encodeURIComponent(sessionId) + '/publish-to-platform', {
      method: 'POST',
      allowNonOk: true,
    });
    let body = {};
    try { body = await response.json(); } catch (e) {}
    if (response.ok) {
      resultEl.className = 'publish-result ok';
      resultEl.textContent = 'Published. Platform returned HTTP ' + (body.platform_status || '') + '.';
    } else if (response.status === 503) {
      resultEl.className = 'publish-result warn';
      resultEl.textContent = 'Push is not configured on the server. Set SCAN_SERVICE_PLATFORM_WEBHOOK_URL and restart the server to enable it.';
    } else {
      resultEl.className = 'publish-result error';
      resultEl.textContent = 'Push failed: ' + (body.message || response.statusText);
    }
  } catch (err) {
    resultEl.className = 'publish-result error';
    resultEl.textContent = 'Push failed: ' + friendlyApiError(err);
  }
}

function serverHostedPath(url) {
  try {
    const u = new URL(url, location.href);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    if (!/^\/scan-sessions\/[^/]+\/photo-uploads\/[^/]+$/.test(u.pathname)) return null;
    return u.pathname;
  } catch (e) {
    return null;
  }
}

async function loadFloorPlanImage(sessionId) {
  const img = $('#floorPlanImage');
  const errEl = $('#floorPlanError');
  if (!img) return;
  const style = state.planStyle;
  try {
    const blob = await apiBlob('/scan-sessions/' + encodeURIComponent(sessionId) + '/export/floorplan.png' + planStyleQuery());
    if (state.currentSessionId !== sessionId || state.planStyle !== style) return;
    img.style.display = '';
    if (errEl) errEl.classList.add('hidden');
    if (img.dataset.blobUrl) revokeBlobUrl(img.dataset.blobUrl);
    const url = trackBlobUrl(URL.createObjectURL(blob));
    img.dataset.blobUrl = url;
    img.src = url;
  } catch (err) {
    if (state.currentSessionId !== sessionId || state.planStyle !== style) return;
    img.style.display = 'none';
    if (errEl) {
      errEl.textContent = 'Could not load floor plan: ' + friendlyApiError(err);
      errEl.classList.remove('hidden');
    }
  }
}

function loadPhotoThumb(photo) {
  const grid = $('#photosGrid');
  if (!grid) return;
  const wrapper = document.createElement('div');
  wrapper.className = 'photo-thumb photo-loading';
  const img = document.createElement('img');
  img.alt = photo.caption || 'photo';
  wrapper.appendChild(img);
  if (photo.caption) {
    const caption = document.createElement('div');
    caption.className = 'photo-caption';
    caption.textContent = photo.caption;
    wrapper.appendChild(caption);
  }
  grid.appendChild(wrapper);

  const clearLoading = () => wrapper.classList.remove('photo-loading');

  const showPlaceholder = (text) => {
    wrapper.classList.add('photo-failed');
    if (img.parentNode) img.remove();
    const placeholder = document.createElement('div');
    placeholder.className = 'photo-thumb-placeholder';
    placeholder.textContent = text;
    wrapper.insertBefore(placeholder, wrapper.firstChild);
  };

  const hostedPath = serverHostedPath(photo.url);
  if (hostedPath) {
    apiBlob(hostedPath).then((blob) => {
      const url = trackBlobUrl(URL.createObjectURL(blob));
      img.dataset.blobUrl = url;
      img.onload = clearLoading;
      img.onerror = () => {
        clearLoading();
        showPlaceholder('Failed to load');
      };
      img.src = url;
    }).catch(() => {
      clearLoading();
      showPlaceholder('Failed to load');
    });
  } else {
    clearLoading();
    showPlaceholder('External photo - not rendered');
  }
}

async function loadAccessLog(sessionId) {
  const container = $('#accessLog');
  if (!container) return;
  try {
    const data = await apiJson('/scan-sessions/' + encodeURIComponent(sessionId) + '/access-log');
    const entries = data.access_log || [];
    if (entries.length === 0) {
      container.innerHTML = emptyHtml('No access attempts recorded.');
      return;
    }
    const rows = entries.map((e) =>
      '<tr><td>' + escapeHtml(formatTimestamp(e.occurred_at)) + '</td>' +
      '<td>' + escapeHtml(e.action) + '</td>' +
      '<td>' + escapeHtml(e.outcome) + '</td></tr>'
    ).join('');
    container.innerHTML = wrapTable('<table class="data-table small"><thead><tr>' +
      '<th>Time</th><th>Action</th><th>Outcome</th>' +
      '</tr></thead><tbody>' + rows + '</tbody></table>');
  } catch (err) {
    renderError(container, 'Failed to load the access log: ' + friendlyApiError(err), () => {
      container.innerHTML = loadingHtml('Loading access log…');
      loadAccessLog(sessionId);
    });
  }
}

function roomTypeLabel(value) {
  const text = String(value || '').replace(/_/g, ' ').trim();
  return text ? text.charAt(0).toUpperCase() + text.slice(1) : '';
}

function fileSlug(value) {
  const slug = String(value || '').replace(/[^A-Za-z0-9_-]+/g, '_').replace(/_+/g, '_').replace(/^_|_$/g, '');
  return slug || 'Untitled';
}

function exportFileName(fp, sessionId, suffix, kind) {
  const parts = [fileSlug(fp && fp.property_id ? fp.property_id : sessionId)];
  if (fp && fp.unit_id) parts.push(fileSlug(fp.unit_id));
  const captured = fp && typeof fp.captured_at === 'string' ? fp.captured_at.slice(0, 10) : '';
  if (/^\d{4}-\d{2}-\d{2}$/.test(captured)) parts.push(captured);
  parts.push(suffix);
  return parts.join('_') + '.' + kind;
}

async function downloadExport(sessionId, kind, fp) {
  const path = '/scan-sessions/' + encodeURIComponent(sessionId) + '/export/floorplan.' + kind + planStyleQuery();
  const filename = exportFileName(fp, sessionId, 'floorplan', kind);
  try {
    const blob = await apiBlob(path);
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (err) {
    showToast('Download failed: ' + err.message);
  }
}

function setupImportDropZone() {
  const zone = $('#importDropZone');
  const input = $('#importFileInput');
  if (!zone || !input) return;

  zone.addEventListener('click', () => input.click());

  zone.addEventListener('dragover', (e) => {
    e.preventDefault();
    zone.classList.add('dragover');
  });
  zone.addEventListener('dragleave', () => {
    zone.classList.remove('dragover');
  });
  zone.addEventListener('drop', (e) => {
    e.preventDefault();
    zone.classList.remove('dragover');
    const files = e.dataTransfer && e.dataTransfer.files;
    if (files && files.length > 0) {
      handleImportFile(files[0]);
    }
  });

  input.addEventListener('change', () => {
    if (input.files && input.files.length > 0) {
      handleImportFile(input.files[0]);
      input.value = '';
    }
  });
}

async function handleImportFile(file) {
  const resultEl = $('#importResult');
  if (!resultEl) return;
  resultEl.classList.remove('hidden');
  resultEl.className = 'warn';
  resultEl.textContent = 'Uploading ' + file.name + '…';

  const formData = new FormData();
  formData.append('file', file, file.name);

  try {
    const response = await fetch('/imported-scans', {
      method: 'POST',
      headers: { 'X-Admin-Api-Key': state.adminKey },
      body: formData,
    });
    let body = {};
    try { body = await response.json(); } catch (e) {}
    if (response.status === 201 && body.import_id) {
      const sig = body.signature_status || 'unsigned';
      resultEl.className = 'ok';
      resultEl.innerHTML =
        'Imported ' + escapeHtml(body.property_id) + ' / ' + escapeHtml(body.unit_id) +
        ' (' + escapeHtml(body.session_id) + '). ' +
        'Signature: <span class="badge badge-' + escapeHtml(sig) + '">' + escapeHtml(sig) + '</span>';
      loadImportsList();
    } else if (response.status === 401) {
      handleAuthFailure();
    } else {
      resultEl.className = 'error';
      resultEl.textContent = 'Import failed: ' + (body.message || response.statusText);
    }
  } catch (err) {
    resultEl.className = 'error';
    resultEl.textContent = 'Import failed: ' + err.message;
  }
}

async function loadImportsList() {
  const container = $('#importsList');
  if (!container) return;
  container.innerHTML = loadingHtml('Loading imported scans…');
  try {
    const data = await apiJson('/imported-scans');
    renderImportsList(data.imports || []);
  } catch (err) {
    renderError(container, 'Failed to load imported scans: ' + err.message, loadImportsList);
  }
}

function renderImportsList(imports) {
  const container = $('#importsList');
  if (!container) return;
  if (imports.length === 0) {
    container.innerHTML = emptyHtml('No imported scans yet. Upload a .vuuroscan file above to add one.');
    return;
  }
  const rows = imports.map((i) => {
    const sig = i.signature_status || 'unsigned';
    return '<tr data-import-id="' + escapeHtml(i.import_id) + '">' +
      '<td><code>' + escapeHtml(i.property_id) + '</code></td>' +
      '<td><code>' + escapeHtml(i.unit_id) + '</code></td>' +
      '<td><code>' + escapeHtml(i.organisation_id) + '</code></td>' +
      '<td>' + escapeHtml(i.purpose) + '</td>' +
      '<td><span class="badge badge-' + escapeHtml(sig) + '">' + escapeHtml(sig) + '</span></td>' +
      '<td>' + escapeHtml(formatTimestamp(i.imported_at)) + '</td>' +
      '<td><button class="open-import-btn primary small">Open</button></td>' +
      '</tr>';
  }).join('');
  container.innerHTML = wrapTable(
    '<table class="data-table"><thead><tr>' +
    '<th>Property</th><th>Unit</th><th>Organisation</th><th>Purpose</th>' +
    '<th>Signature</th><th>Imported</th><th></th>' +
    '</tr></thead><tbody>' + rows + '</tbody></table>');
  container.querySelectorAll('.open-import-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = btn.closest('tr').getAttribute('data-import-id');
      openImport(id);
    });
  });
}

async function openImport(importId, options) {
  const opts = options || {};
  revokeAllBlobUrls();
  state.currentSessionId = null;
  showDetail('imports');
  if (!opts.fromHistory) setUrl('import=' + encodeURIComponent(importId), true);
  const container = $('#detailContent');
  container.innerHTML = loadingHtml('Loading imported scan…');
  try {
    const data = await apiJson('/imported-scans/' + encodeURIComponent(importId));
    renderImportDetail(data);
  } catch (err) {
    renderError(container, 'Failed to load the imported scan: ' + err.message, () => openImport(importId, { fromHistory: true }));
  }
}

function renderImportDetail(data) {
  const container = $('#detailContent');
  const payload = data.payload || {};
  const session = payload.session || {};
  const fp = payload.floor_plan || {};
  const exportsBlock = payload.exports || {};

  const rooms = fp.rooms || [];
  const notes = fp.notes || [];
  const photos = fp.photos || [];
  const totalArea = rooms.reduce((sum, r) => sum + (Number(r.floor_area_m2) || 0), 0);

  const roomRows = rooms.map((r) => {
    const roomType = roomTypeLabel(r.room_type ? (r.room_type.confirmed || r.room_type.guess || '') : '');
    const height = r.height_m !== null && r.height_m !== undefined ? Number(r.height_m).toFixed(2) : '-';
    const coverage = r.coverage ? r.coverage.score : '';
    return '<tr>' +
      '<td>' + escapeHtml(r.label) + '</td>' +
      '<td>' + escapeHtml(roomType) + '</td>' +
      '<td>' + (Number(r.floor_area_m2) || 0).toFixed(2) + '</td>' +
      '<td>' + (Number(r.perimeter_m) || 0).toFixed(2) + '</td>' +
      '<td>' + height + '</td>' +
      '<td>' + escapeHtml(r.confidence) + '</td>' +
      '<td>' + escapeHtml(coverage) + '</td>' +
      '</tr>';
  }).join('');

  const noteItems = notes.map((n) => {
    const scope = n.room_id ? 'Room ' + escapeHtml(n.room_id) : 'Unit-level';
    return '<li><div class="note-text">' + escapeHtml(n.text) + '</div>' +
      '<div class="note-meta">' + scope + ' · ' + escapeHtml(n.created_at) + '</div></li>';
  }).join('');

  const sig = data.signature_status || 'unsigned';
  const sigBadge = '<span class="badge badge-' + escapeHtml(sig) + '">' + escapeHtml(sig) + '</span>';
  const exportedFrom = data.scan_service_base_url || '(unknown origin)';

  const pngBase64 = exportsBlock.png_base64 || '';
  const pngHtml = pngBase64
    ? '<img id="importedFloorPlanImage" alt="Floor plan">'
    : '<p class="muted">No PNG drawing embedded in this bundle.</p>';

  container.innerHTML =
    '<div class="detail-header">' +
      '<h1>' + escapeHtml(data.property_id) + ' — ' + escapeHtml(data.unit_id) + '</h1>' +
      '<p class="meta">' +
        '<span>Org: <code>' + escapeHtml(data.organisation_id) + '</code></span>' +
        '<span>Purpose: ' + escapeHtml(data.purpose) + '</span>' +
        '<span>Exported: ' + escapeHtml(formatTimestamp(data.exported_at)) + '</span>' +
        '<span>Imported: ' + escapeHtml(formatTimestamp(data.imported_at)) + '</span>' +
      '</p>' +
      '<p class="meta">' +
        '<span>Origin: <code>' + escapeHtml(exportedFrom) + '</code></span>' +
        '<span>Origin session: <code>' + escapeHtml(data.session_id) + '</code></span>' +
        '<span>Signature: ' + sigBadge + '</span>' +
      '</p>' +
      '<p class="meta">' +
        '<span>' + rooms.length + ' room' + (rooms.length === 1 ? '' : 's') + '</span>' +
        '<span>' + totalArea.toFixed(1) + ' m² total</span>' +
      '</p>' +
    '</div>' +

    '<div class="floor-plan">' + pngHtml + '</div>' +

    (pngBase64
      ? '<div class="actions"><button id="btnDownloadImportPng" class="primary">Download PNG</button>' +
        (exportsBlock.pdf_base64 ? '<button id="btnDownloadImportPdf" class="primary">Download PDF</button>' : '') +
        '</div>'
      : '') +

    '<h2>Rooms</h2>' +
    (rooms.length === 0
      ? '<p class="muted">No rooms in this imported scan.</p>'
      : wrapTable('<table class="data-table"><thead><tr>' +
        '<th>Room</th><th>Type</th><th>Area (m²)</th><th>Perimeter (m)</th>' +
        '<th>Height (m)</th><th>Confidence</th><th>Coverage</th>' +
        '</tr></thead><tbody>' + roomRows + '</tbody></table>')) +

    '<h2>Photos (' + photos.length + ')</h2>' +
    (photos.length === 0
      ? '<p class="muted">None.</p>'
      : '<p class="muted">Photos are stored on the originating Scan Service and cannot be fetched from here.</p>') +

    '<h2>Notes (' + notes.length + ')</h2>' +
    '<ul class="notes-list">' + (noteItems || '<li class="muted">None.</li>') + '</ul>';

  if (pngBase64) {
    const img = document.getElementById('importedFloorPlanImage');
    if (img) img.src = 'data:image/png;base64,' + pngBase64;
  }

  const btnPng = document.getElementById('btnDownloadImportPng');
  if (btnPng) {
    btnPng.addEventListener('click', () => {
      downloadBase64Blob(pngBase64, 'image/png', 'floorplan-' + data.session_id + '.png');
    });
  }
  const btnPdf = document.getElementById('btnDownloadImportPdf');
  if (btnPdf && exportsBlock.pdf_base64) {
    btnPdf.addEventListener('click', () => {
      downloadBase64Blob(exportsBlock.pdf_base64, 'application/pdf', 'floorplan-' + data.session_id + '.pdf');
    });
  }
}

function downloadBase64Blob(base64, mime, filename) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  const blob = new Blob([bytes], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function init() {
  $('#loginBtn').addEventListener('click', login);
  $('#adminKeyInput').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') login();
  });
  $('#signOutBtn').addEventListener('click', signOut);
  $('#searchForm').addEventListener('submit', search);
  document.querySelectorAll('.nav-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const target = btn.getAttribute('data-nav');
      if (target === 'search') showSearch();
      else if (target === 'imports') showImports();
      else if (target === 'settings') showSettings();
    });
  });
  setupImportDropZone();
  $('#backBtn').addEventListener('click', () => {
    state.currentSessionId = null;
    const target = state.returnTo || 'search';
    state.returnTo = null;
    if (target === 'imports') showImports();
    else showSearch();
  });
  window.addEventListener('popstate', () => {
    if (!state.adminKey) return;
    routeFromUrl(true);
  });

  const params = new URLSearchParams(location.search);
  const deepLink = params.get('session') || params.get('import');
  const signInPrompt = deepLink ? 'Sign in to open the shared scan.' : null;

  const stored = sessionStorage.getItem(STORAGE_KEY);
  if (!stored) {
    showLogin(signInPrompt);
    return;
  }
  const checkStoredKey = () => {
    showLoading('Checking your session…');
    state.adminKey = stored;
    testKey().then(() => {
      loadRecentIdentities();
      routeFromUrl(true);
    }).catch((err) => {
      if (err.isNetwork) {
        showLoading(err.message, checkStoredKey);
        return;
      }
      state.adminKey = '';
      sessionStorage.removeItem(STORAGE_KEY);
      showLogin(signInPrompt);
    });
  };
  checkStoredKey();
}

document.addEventListener('DOMContentLoaded', init);
