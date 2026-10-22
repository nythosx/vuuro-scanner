(function () {
  'use strict';

  var state = {
    sessionId: '',
    token: '',
    data: null,
    mode: 'plan',
    roomIndex: 0,
    photoIndex: 0,
    hasPhotos: false,
    hasDollhouse: false,
    roomsWithPhotos: [],
    roomSequenceIndex: 0,
    isEmbed: false
  };

  var els = {};

  function boot() {
    els.viewport = document.getElementById('tour-viewport');
    els.menu = document.getElementById('tour-menu');
    els.minimap = document.getElementById('tour-minimap');
    els.info = document.getElementById('tour-info');
    els.infoRoom = document.getElementById('tour-info-room');
    els.infoCounter = document.getElementById('tour-info-counter');
    els.roomNav = document.getElementById('tour-room-nav');
    els.roomSequence = document.getElementById('tour-room-sequence');
    els.roomPrev = document.getElementById('tour-room-prev');
    els.roomNext = document.getElementById('tour-room-next');

    if (els.roomPrev) {
      els.roomPrev.addEventListener('click', function () { stepRoom(-1); });
    }
    if (els.roomNext) {
      els.roomNext.addEventListener('click', function () { stepRoom(1); });
    }

    state.isEmbed = readEmbed();
    if (state.isEmbed) {
      installEmbedChrome();
    }

    state.sessionId = readSessionId();
    state.token = readToken();

    if (!state.sessionId) {
      setStatus(window.TourStrings.t('invalid_url'), true);
      return;
    }
    if (!state.token) {
      setStatus(window.TourStrings.t('missing_token'), true);
      return;
    }
    document.getElementById('tour-menu').setAttribute('aria-label', window.TourStrings.t('tour_mode_aria'));
    var prevRoom = document.getElementById('tour-room-prev');
    var nextRoom = document.getElementById('tour-room-next');
    if (prevRoom) prevRoom.setAttribute('aria-label', window.TourStrings.t('prev_room_aria'));
    if (nextRoom) nextRoom.setAttribute('aria-label', window.TourStrings.t('next_room_aria'));

    window.TourRoute.onPop(function (parsed) {
      if (!state.data) {
        return;
      }
      applyParsedUrl(parsed);
      render();
    });

    setStatus(window.TourStrings.t('loading_tour'), false);
    fetchTour();
  }

  function readSessionId() {
    var m = window.location.pathname.match(/^\/tour\/([^/?#]+)/);
    return m ? decodeURIComponent(m[1]) : '';
  }

  function readToken() {
    return new URLSearchParams(window.location.search).get('token') || '';
  }

  function readEmbed() {
    return new URLSearchParams(window.location.search).get('embed') === '1';
  }

  function installEmbedChrome() {
    var brand = document.querySelector('.tour-brand');
    if (!brand || !brand.parentNode) return;
    var url = new URL(window.location.href);
    url.searchParams.delete('embed');
    var link = document.createElement('a');
    link.className = 'tour-popout';
    link.href = url.toString();
    link.target = '_blank';
    link.rel = 'noopener';
    link.setAttribute('aria-label', window.TourStrings.t('popout_full_tour'));
    link.textContent = window.TourStrings.t('popout_full_tour') + ' \u2197';
    brand.parentNode.replaceChild(link, brand);
  }

  function withToken(url) {
    var join = url.indexOf('?') === -1 ? '?' : '&';
    return url + join + 'token=' + encodeURIComponent(state.token);
  }

  function setStatus(text, isError) {
    clearNode(els.viewport);
    var p = document.createElement('p');
    p.className = 'tour-status' + (isError ? ' is-error' : '');
    p.textContent = text;
    els.viewport.appendChild(p);
  }

  function clearNode(node) {
    while (node.firstChild) {
      node.removeChild(node.firstChild);
    }
  }

  function fetchTour() {
    fetch('/scan-sessions/' + encodeURIComponent(state.sessionId) + '/tour.json?lang=' + encodeURIComponent(window.TourStrings.lang), {
      headers: { 'X-Scan-Access-Token': state.token }
    })
      .then(function (response) {
        if (response.status === 401) {
          throw new Error(window.TourStrings.t('link_expired'));
        }
        if (!response.ok) {
          throw new Error(window.TourStrings.t('server_http', { status: response.status }));
        }
        return response.json();
      })
      .then(onLoaded)
      .catch(function (err) {
        setStatus(err && err.message ? err.message : window.TourStrings.t('load_failed'), true);
      });
  }

  function onLoaded(data) {
    var rawRooms = Array.isArray(data.rooms) ? data.rooms : [];
    state.data = {
      rooms: rawRooms,
      dollhouse_glb_url: data.dollhouse_glb_url || null
    };
    state.roomsWithPhotos = computeRoomsWithPhotos(rawRooms);
    state.hasPhotos = state.roomsWithPhotos.length > 0;
    state.hasDollhouse = !!state.data.dollhouse_glb_url;
    state.mode = 'plan';
    state.roomIndex = 0;
    state.photoIndex = 0;
    state.roomSequenceIndex = 0;
    applyParsedUrl(window.TourRoute.parse(window.location.hash));
    window.TourRoute.replace(currentUrlState());
    render();
  }

  function computeRoomsWithPhotos(rooms) {
    var out = [];
    for (var i = 0; i < rooms.length; i++) {
      if (Array.isArray(rooms[i].photos) && rooms[i].photos.length > 0) {
        out.push(i);
      }
    }
    return out;
  }

  function applyParsedUrl(parsed) {
    if (parsed.mode === window.TourRoute.MODES.PHOTOS && state.hasPhotos) {
      var roomIdx = parsed.roomIndex;
      if (state.roomsWithPhotos.indexOf(roomIdx) === -1) {
        roomIdx = state.roomsWithPhotos[0];
      }
      state.mode = 'photos';
      state.roomIndex = roomIdx;
      state.photoIndex = clampPhotoIndex(roomIdx, parsed.photoIndex);
      state.roomSequenceIndex = Math.max(0, state.roomsWithPhotos.indexOf(roomIdx));
      return;
    }
    if (parsed.mode === window.TourRoute.MODES.DOLLHOUSE && state.hasDollhouse) {
      state.mode = 'dollhouse';
      return;
    }
    state.mode = 'plan';
  }

  function clampPhotoIndex(roomIdx, idx) {
    var room = state.data.rooms[roomIdx];
    var len = room && Array.isArray(room.photos) ? room.photos.length : 0;
    if (len === 0) {
      return 0;
    }
    if (idx < 0) {
      return 0;
    }
    if (idx >= len) {
      return len - 1;
    }
    return idx;
  }

  function currentUrlState() {
    if (state.mode === 'photos') {
      return { mode: 'photos', roomIndex: state.roomIndex, photoIndex: state.photoIndex };
    }
    if (state.mode === 'dollhouse') {
      return { mode: 'dollhouse' };
    }
    return { mode: 'plan' };
  }

  function syncUrl(replace) {
    var s = currentUrlState();
    if (replace) {
      window.TourRoute.replace(s);
    } else {
      window.TourRoute.push(s);
    }
  }

  function render() {
    if (!state.data) {
      return;
    }
    renderMenu();
    renderViewport();
    renderChrome();
  }

  function renderMenu() {
    var menu = els.menu;
    clearNode(menu);
    menu.hidden = false;
    appendMenuButton('plan', window.TourStrings.t('menu_plan'));
    if (state.hasPhotos) {
      appendMenuButton('photos', window.TourStrings.t('menu_photos'));
    }
    if (state.hasDollhouse) {
      appendMenuButton('dollhouse', window.TourStrings.t('menu_dollhouse'));
    }
  }

  function appendMenuButton(mode, label) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'tour-menu-btn' + (state.mode === mode ? ' is-active' : '');
    btn.textContent = label;
    btn.setAttribute('data-mode', mode);
    btn.addEventListener('click', function () {
      switchMode(mode);
    });
    els.menu.appendChild(btn);
  }

  function switchMode(mode) {
    if (mode === 'photos' && state.mode !== 'photos') {
      if (!state.hasPhotos) {
        return;
      }
      state.roomIndex = state.roomsWithPhotos[0];
      state.roomSequenceIndex = 0;
      state.photoIndex = 0;
    }
    if (mode === 'dollhouse' && !state.hasDollhouse) {
      return;
    }
    state.mode = mode;
    syncUrl(false);
    render();
  }

  function renderViewport() {
    if (window.TourDollhouse && typeof window.TourDollhouse.stop === 'function') {
      window.TourDollhouse.stop();
    }
    clearNode(els.viewport);
    if (state.mode === 'plan') {
      renderPlan();
    } else if (state.mode === 'photos') {
      renderPhotoTour();
    } else if (state.mode === 'dollhouse') {
      renderDollhouse();
    }
  }

  function renderChrome() {
    els.minimap.hidden = state.mode !== 'photos';
    els.info.hidden = state.mode !== 'photos';
    var showRoomNav = state.mode === 'photos' && state.roomsWithPhotos.length > 1;
    if (els.roomNav) {
      els.roomNav.hidden = !showRoomNav;
    }
    if (state.mode === 'photos') {
      var activeRoom = state.data.rooms[state.roomIndex];
      if (activeRoom && els.minimap) {
        els.minimap.hidden = false;
        window.TourPlan.renderMinimap(els.minimap, state.data.rooms, activeRoom.room_id);
      }
    } else if (els.minimap) {
      els.minimap.hidden = true;
    }
    if (state.mode !== 'photos') {
      return;
    }
    var room = state.data.rooms[state.roomIndex];
    if (!room) {
      return;
    }
    els.infoRoom.textContent = room.label || '';
    var photos = Array.isArray(room.photos) ? room.photos : [];
    els.infoCounter.textContent = photos.length === 0
      ? '0 / 0'
      : (state.photoIndex + 1) + ' / ' + photos.length;
    if (showRoomNav && els.roomSequence) {
      els.roomSequence.textContent = (state.roomSequenceIndex + 1) + ' / ' + state.roomsWithPhotos.length;
    }
  }

  function renderPlan() {
    var drew = window.TourPlan.renderPlan(els.viewport, state.data.rooms, openRoom, openPhoto);
    if (!drew) {
      setStatus(window.TourStrings.t('no_rooms'), false);
    }
  }

  function openRoom(index) {
    var room = state.data.rooms[index];
    if (!room) {
      return;
    }
    if (!Array.isArray(room.photos) || room.photos.length === 0) {
      return;
    }
    state.roomIndex = index;
    state.roomSequenceIndex = Math.max(0, state.roomsWithPhotos.indexOf(index));
    state.photoIndex = 0;
    state.mode = 'photos';
    syncUrl(false);
    render();
  }

  function openPhoto(roomIndex, photoIndex) {
    var room = state.data.rooms[roomIndex];
    if (!room) {
      return;
    }
    var photos = Array.isArray(room.photos) ? room.photos : [];
    if (photos.length === 0) {
      return;
    }
    state.roomIndex = roomIndex;
    state.roomSequenceIndex = Math.max(0, state.roomsWithPhotos.indexOf(roomIndex));
    state.photoIndex = clampPhotoIndex(roomIndex, photoIndex);
    state.mode = 'photos';
    syncUrl(false);
    render();
  }

  function renderPhotoTour() {
    var room = state.data.rooms[state.roomIndex];
    if (!room) {
      backToPlan();
      return;
    }
    window.TourPhoto.render(els.viewport, room, state.photoIndex, {
      buildPhotoUrl: withToken,
      onPrev: function () { stepPhoto(-1); },
      onNext: function () { stepPhoto(1); },
      onClose: backToPlan,
      onBackToPlan: backToPlan
    });
  }

  function stepPhoto(delta) {
    var room = state.data.rooms[state.roomIndex];
    if (!room) {
      return;
    }
    var photos = Array.isArray(room.photos) ? room.photos : [];
    if (photos.length === 0) {
      return;
    }
    state.photoIndex = (state.photoIndex + delta + photos.length) % photos.length;
    syncUrl(true);
    render();
  }

  function stepRoom(delta) {
    if (state.roomsWithPhotos.length < 2) {
      return;
    }
    var len = state.roomsWithPhotos.length;
    var next = (state.roomSequenceIndex + delta + len) % len;
    state.roomSequenceIndex = next;
    state.roomIndex = state.roomsWithPhotos[next];
    state.photoIndex = 0;
    state.mode = 'photos';
    syncUrl(false);
    render();
  }

  function backToPlan() {
    state.mode = 'plan';
    syncUrl(false);
    render();
  }

  function renderDollhouse() {
    window.TourDollhouse.render(els.viewport, state.data.dollhouse_glb_url, state.data.rooms, backToPlan, openPhoto, withToken);
  }

  document.addEventListener('keydown', function (event) {
    if (state.mode !== 'photos') {
      return;
    }
    if (event.key === 'ArrowLeft') {
      stepPhoto(-1);
    } else if (event.key === 'ArrowRight') {
      stepPhoto(1);
    } else if (event.key === 'ArrowUp') {
      stepRoom(-1);
    } else if (event.key === 'ArrowDown') {
      stepRoom(1);
    } else if (event.key === 'Escape') {
      backToPlan();
    }
  });

  window.addEventListener('resize', function () {
    if (state.mode === 'plan' && state.data) {
      renderViewport();
    }
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
