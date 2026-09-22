'use strict';

const STORAGE_KEY = 'vuuro.scan.admin.key';

const state = {
  adminKey: '',
  currentSessionId: null,
};

const $ = (sel) => document.querySelector(sel);

function escapeHtml(s) {
  if (s === null || s === undefined) return '';
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

async function api(path, options) {
  const opts = options || {};
  const headers = Object.assign({}, opts.headers || {});
  headers['X-Admin-Api-Key'] = state.adminKey;
  const response = await fetch(path, Object.assign({}, opts, { headers }));
  if (response.status === 401) {
    handleAuthFailure();
    throw new Error('Not authorized - admin key rejected');
  }
  if (!response.ok) {
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
  localStorage.removeItem(STORAGE_KEY);
  state.adminKey = '';
  state.currentSessionId = null;
  showLogin('Your admin key is no longer accepted. Please sign in again.');
}

function showLogin(errorMessage) {
  $('#view-login').classList.remove('hidden');
  $('#view-search').classList.add('hidden');
  $('#view-detail').classList.add('hidden');
  $('#view-imports').classList.add('hidden');
  $('#topnav').classList.add('hidden');
  $('#keyStatus').textContent = 'Signed out';
  $('#signOutBtn').classList.add('hidden');
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

function showSearch() {
  $('#view-login').classList.add('hidden');
  $('#view-search').classList.remove('hidden');
  $('#view-detail').classList.add('hidden');
  $('#view-imports').classList.add('hidden');
  $('#keyStatus').textContent = 'Signed in';
  $('#signOutBtn').classList.remove('hidden');
  $('#topnav').classList.remove('hidden');
  setTopnav('search');
}

function showDetail() {
  $('#view-login').classList.add('hidden');
  $('#view-search').classList.add('hidden');
  $('#view-detail').classList.remove('hidden');
  $('#view-imports').classList.add('hidden');
  $('#keyStatus').textContent = 'Signed in';
  $('#signOutBtn').classList.remove('hidden');
  $('#topnav').classList.remove('hidden');
}

function showImports() {
  $('#view-login').classList.add('hidden');
  $('#view-search').classList.add('hidden');
  $('#view-detail').classList.add('hidden');
  $('#view-imports').classList.remove('hidden');
  $('#keyStatus').textContent = 'Signed in';
  $('#signOutBtn').classList.remove('hidden');
  $('#topnav').classList.remove('hidden');
  setTopnav('imports');
  loadImportsList();
}

async function testKey() {
  await api('/scan-sessions?property_id=___probe___');
}

async function login() {
  const input = $('#adminKeyInput');
  const key = input.value.trim();
  if (!key) {
    showLogin('Please enter the admin key.');
    return;
  }
  state.adminKey = key;
  try {
    await testKey();
    localStorage.setItem(STORAGE_KEY, key);
    input.value = '';
    if (state.pendingSession) {
      const sid = state.pendingSession;
      state.pendingSession = null;
      history.replaceState({}, '', '/admin?session=' + encodeURIComponent(sid));
      openSession(sid);
    } else {
      showSearch();
    }
  } catch (err) {
    state.adminKey = '';
    showLogin('That admin key was not accepted.');
  }
}

function signOut() {
  if (!confirm('Sign out of admin?')) return;
  localStorage.removeItem(STORAGE_KEY);
  state.adminKey = '';
  state.currentSessionId = null;
  showLogin();
}

function renderSearchResults(sessions) {
  const container = $('#searchResults');
  if (!sessions || sessions.length === 0) {
    container.innerHTML = '<p class="muted">No matching sessions.</p>';
    return;
  }
  const rows = sessions.map((s) => {
    return '<tr data-session-id="' + escapeHtml(s.id) + '">' +
      '<td><code>' + escapeHtml(s.property_id) + '</code></td>' +
      '<td><code>' + escapeHtml(s.unit_id) + '</code></td>' +
      '<td><code>' + escapeHtml(s.organisation_id) + '</code></td>' +
      '<td>' + escapeHtml(s.purpose) + '</td>' +
      '<td>' + escapeHtml(s.status) + '</td>' +
      '<td>' + escapeHtml(s.created_at) + '</td>' +
      '<td>' + (s.occupied ? 'Yes' : 'No') + '</td>' +
      '<td><button class="open-btn primary small">Open</button></td>' +
      '</tr>';
  }).join('');
  container.innerHTML =
    '<table class="data-table"><thead><tr>' +
    '<th>Property</th><th>Unit</th><th>Organisation</th><th>Purpose</th>' +
    '<th>Status</th><th>Created</th><th>Occupied</th><th></th>' +
    '</tr></thead><tbody>' + rows + '</tbody></table>';
  container.querySelectorAll('.open-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = btn.closest('tr').getAttribute('data-session-id');
      openSession(id);
    });
  });
}

async function search(event) {
  event.preventDefault();
  const form = new FormData(event.target);
  const params = new URLSearchParams();
  for (const pair of form.entries()) {
    const value = String(pair[1]).trim();
    if (value) params.set(pair[0], value);
  }
  if (params.toString() === '') {
    alert('Provide at least one filter.');
    return;
  }
  const container = $('#searchResults');
  container.innerHTML = '<p class="muted">Searching…</p>';
  try {
    const data = await apiJson('/scan-sessions?' + params.toString());
    renderSearchResults(data.sessions || []);
  } catch (err) {
    container.innerHTML = '<p class="error">Search failed: ' + escapeHtml(err.message) + '</p>';
  }
}

async function openSession(sessionId) {
  state.currentSessionId = sessionId;
  showDetail();
  const container = $('#detailContent');
  container.innerHTML = '<p class="muted">Loading session…</p>';
  try {
    const data = await apiJson('/scan-sessions/' + encodeURIComponent(sessionId));
    renderDetail(data, sessionId);
  } catch (err) {
    container.innerHTML = '<p class="error">Failed to load session: ' + escapeHtml(err.message) + '</p>';
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
    const roomType = r.room_type ? (r.room_type.confirmed || r.room_type.guess || '') : '';
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
        '<span>Captured: ' + escapeHtml(data.captured_at) + '</span>' +
      '</p>' +
      '<p class="meta">' +
        '<span>' + rooms.length + ' room' + (rooms.length === 1 ? '' : 's') + '</span>' +
        '<span>' + totalArea.toFixed(1) + ' m² total</span>' +
      '</p>' +
    '</div>' +

    '<div class="floor-plan">' +
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
    '<table class="data-table"><thead><tr>' +
      '<th>Room</th><th>Type</th><th>Area (m²)</th><th>Perimeter (m)</th>' +
      '<th>Height (m)</th><th>Confidence</th><th>Coverage</th>' +
    '</tr></thead><tbody>' + roomRows + '</tbody></table>' +

    '<h2>Photos (' + photos.length + ')</h2>' +
    '<div id="photosGrid" class="photos-grid"></div>' +

    '<h2>Notes (' + notes.length + ')</h2>' +
    '<ul class="notes-list">' + (noteItems || '<li class="muted">None.</li>') + '</ul>' +

    '<h2>Access log</h2>' +
    '<div id="accessLog"><p class="muted">Loading…</p></div>';

  loadFloorPlanImage(sessionId);
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
    alert('Download failed: ' + err.message);
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
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(() => {
      showToast(label + ' copied to clipboard');
    }).catch(() => {
      prompt(label, text);
    });
  } else {
    prompt(label, text);
  }
}

function exportJson(sessionId, data) {
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'scan-' + sessionId + '.json';
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
    const response = await fetch('/scan-sessions/' + encodeURIComponent(sessionId) + '/publish-to-platform', {
      method: 'POST',
      headers: { 'X-Admin-Api-Key': state.adminKey },
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
    resultEl.textContent = 'Push failed: ' + err.message;
  }
}

function isServerHosted(url) {
  try {
    const u = new URL(url, location.href);
    return u.host === location.host && u.pathname.indexOf('/scan-sessions/') === 0;
  } catch (e) {
    return false;
  }
}

async function loadFloorPlanImage(sessionId) {
  const img = $('#floorPlanImage');
  const errEl = $('#floorPlanError');
  if (!img) return;
  try {
    const blob = await apiBlob('/scan-sessions/' + encodeURIComponent(sessionId) + '/export/floorplan.png');
    img.src = URL.createObjectURL(blob);
  } catch (err) {
    img.style.display = 'none';
    if (errEl) {
      errEl.textContent = 'Could not load floor plan: ' + err.message;
      errEl.classList.remove('hidden');
    }
  }
}

function loadPhotoThumb(photo) {
  const grid = $('#photosGrid');
  if (!grid) return;
  const wrapper = document.createElement('div');
  wrapper.className = 'photo-thumb';
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

  if (isServerHosted(photo.url)) {
    apiBlob(photo.url).then((blob) => {
      img.src = URL.createObjectURL(blob);
    }).catch(() => {
      wrapper.classList.add('photo-failed');
      img.alt = 'Failed to load';
    });
  } else {
    img.src = photo.url;
  }
}

async function loadAccessLog(sessionId) {
  const container = $('#accessLog');
  if (!container) return;
  try {
    const data = await apiJson('/scan-sessions/' + encodeURIComponent(sessionId) + '/access-log');
    const entries = data.access_log || [];
    if (entries.length === 0) {
      container.innerHTML = '<p class="muted">No access attempts recorded.</p>';
      return;
    }
    const rows = entries.map((e) =>
      '<tr><td>' + escapeHtml(e.occurred_at) + '</td>' +
      '<td>' + escapeHtml(e.action) + '</td>' +
      '<td>' + escapeHtml(e.outcome) + '</td></tr>'
    ).join('');
    container.innerHTML = '<table class="data-table small"><thead><tr>' +
      '<th>Time</th><th>Action</th><th>Outcome</th>' +
      '</tr></thead><tbody>' + rows + '</tbody></table>';
  } catch (err) {
    container.innerHTML = '<p class="error">Failed to load access log: ' + escapeHtml(err.message) + '</p>';
  }
}

async function downloadExport(sessionId, kind, fp) {
  const path = '/scan-sessions/' + encodeURIComponent(sessionId) + '/export/floorplan.' + kind;
  const base = (fp && fp.property_id ? fp.property_id : sessionId);
  const filename = 'floorplan-' + base + '.' + kind;
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
    alert('Download failed: ' + err.message);
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
  container.innerHTML = '<p class="muted">Loading…</p>';
  try {
    const data = await apiJson('/imported-scans');
    renderImportsList(data.imports || []);
  } catch (err) {
    container.innerHTML = '<p class="error">Failed to load imports: ' + escapeHtml(err.message) + '</p>';
  }
}

function renderImportsList(imports) {
  const container = $('#importsList');
  if (!container) return;
  if (imports.length === 0) {
    container.innerHTML = '<p class="muted">No imported scans yet. Upload a .vuuroscan file above to add one.</p>';
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
      '<td>' + escapeHtml(i.imported_at) + '</td>' +
      '<td><button class="open-import-btn primary small">Open</button></td>' +
      '</tr>';
  }).join('');
  container.innerHTML =
    '<table class="data-table"><thead><tr>' +
    '<th>Property</th><th>Unit</th><th>Organisation</th><th>Purpose</th>' +
    '<th>Signature</th><th>Imported</th><th></th>' +
    '</tr></thead><tbody>' + rows + '</tbody></table>';
  container.querySelectorAll('.open-import-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = btn.closest('tr').getAttribute('data-import-id');
      openImport(id);
    });
  });
}

async function openImport(importId) {
  state.returnTo = 'imports';
  showDetail();
  const container = $('#detailContent');
  container.innerHTML = '<p class="muted">Loading imported scan…</p>';
  try {
    const data = await apiJson('/imported-scans/' + encodeURIComponent(importId));
    renderImportDetail(data);
  } catch (err) {
    container.innerHTML = '<p class="error">Failed to load import: ' + escapeHtml(err.message) + '</p>';
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
    const roomType = r.room_type ? (r.room_type.confirmed || r.room_type.guess || '') : '';
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
        '<span>Exported: ' + escapeHtml(data.exported_at) + '</span>' +
        '<span>Imported: ' + escapeHtml(data.imported_at) + '</span>' +
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
      : '<table class="data-table"><thead><tr>' +
        '<th>Room</th><th>Type</th><th>Area (m²)</th><th>Perimeter (m)</th>' +
        '<th>Height (m)</th><th>Confidence</th><th>Coverage</th>' +
        '</tr></thead><tbody>' + roomRows + '</tbody></table>') +

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

  const urlSession = new URLSearchParams(location.search).get('session');
  state.pendingSession = urlSession || null;

  const stored = localStorage.getItem(STORAGE_KEY);
  if (stored) {
    state.adminKey = stored;
    testKey().then(() => {
      if (state.pendingSession) {
        const sid = state.pendingSession;
        state.pendingSession = null;
        openSession(sid);
      } else {
        showSearch();
      }
    }).catch(() => {
      state.adminKey = '';
      localStorage.removeItem(STORAGE_KEY);
      showLogin(state.pendingSession ? 'Sign in to open the shared scan.' : null);
    });
  } else {
    showLogin(state.pendingSession ? 'Sign in to open the shared scan.' : null);
  }
}

document.addEventListener('DOMContentLoaded', init);
