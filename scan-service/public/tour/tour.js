(function () {
  'use strict';

  var statusEl = document.getElementById('tour-status');
  var appEl = document.getElementById('tour-app');

  function setStatus(text, isError) {
    if (!statusEl) {
      statusEl = document.createElement('p');
      statusEl.id = 'tour-status';
      appEl.appendChild(statusEl);
    }
    statusEl.textContent = text;
    statusEl.className = isError ? 'status error' : 'status';
  }

  function readSessionId() {
    var m = window.location.pathname.match(/^\/tour\/([^/?#]+)/);
    return m ? decodeURIComponent(m[1]) : '';
  }

  function readToken() {
    return new URLSearchParams(window.location.search).get('token') || '';
  }

  var sessionId = readSessionId();
  var token = readToken();

  if (!sessionId) { setStatus('Invalid tour URL — no session id.', true); return; }
  if (!token) { setStatus('Missing token in the URL. Add ?token=… to the link.', true); return; }

  setStatus('Loading tour…');

  fetch('/scan-sessions/' + encodeURIComponent(sessionId) + '/tour.json', {
    headers: { 'X-Scan-Access-Token': token },
  })
    .then(function (response) {
      if (response.status === 401) { throw new Error('This link is no longer valid.'); }
      if (!response.ok) { throw new Error('Server returned HTTP ' + response.status + '.'); }
      return response.json();
    })
    .then(render)
    .catch(function (err) {
      setStatus(err && err.message ? err.message : 'Could not load the tour.', true);
    });

  function render(data) {
    appEl.innerHTML = '';
    var rooms = Array.isArray(data.rooms) ? data.rooms : [];

    var summary = document.createElement('p');
    summary.className = 'summary';
    var roomCount = rooms.length;
    var photoCount = rooms.reduce(function (n, r) {
      return n + (Array.isArray(r.photos) ? r.photos.length : 0);
    }, 0);
    summary.textContent = roomCount + ' room' + (roomCount === 1 ? '' : 's')
      + ' · ' + photoCount + ' tour photo' + (photoCount === 1 ? '' : 's');
    appEl.appendChild(summary);

    if (data.plan_image_url) {
      var plan = document.createElement('img');
      plan.className = 'plan';
      plan.alt = 'Floor plan';
      var joinChar = data.plan_image_url.indexOf('?') === -1 ? '?' : '&';
      plan.src = data.plan_image_url + joinChar + 'token=' + encodeURIComponent(token);
      appEl.appendChild(plan);
    }

    if (roomCount === 0) {
      var empty = document.createElement('p');
      empty.className = 'summary';
      empty.textContent = 'No rooms captured in this scan yet.';
      appEl.appendChild(empty);
      return;
    }

    var list = document.createElement('ul');
    list.className = 'rooms';
    rooms.forEach(function (room) {
      var li = document.createElement('li');
      var name = document.createElement('strong');
      name.textContent = room.label || room.room_id;
      var meta = document.createElement('span');
      var count = Array.isArray(room.photos) ? room.photos.length : 0;
      meta.textContent = count + ' tour photo' + (count === 1 ? '' : 's');
      if (room.floor) { meta.textContent = room.floor + ' · ' + meta.textContent; }
      li.appendChild(name);
      li.appendChild(meta);
      list.appendChild(li);
    });
    appEl.appendChild(list);
  }
})();
