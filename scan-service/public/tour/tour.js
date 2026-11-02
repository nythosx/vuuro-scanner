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
    isEmbed: false,
    features: null,
    walkthroughMode: 'photos',
    standId: null,
    standPhotoIndex: 0,
    guidedTourActive: false,
    guidedTourTimer: null,
    guidedTourQueue: [],
    guidedTourIndex: 0
  };

  var els = {};

  function boot() {
    els.viewport = document.getElementById('tour-viewport');
    els.toolbar = document.getElementById('tour-toolbar');
    els.minimap = document.getElementById('tour-minimap');
    els.info = document.getElementById('tour-info');
    els.infoRoom = document.getElementById('tour-info-room');
    els.infoCounter = document.getElementById('tour-info-counter');
    els.roomNav = document.getElementById('tour-room-nav');
    els.roomSequence = document.getElementById('tour-room-sequence');
    els.roomPrev = document.getElementById('tour-room-prev');
    els.roomNext = document.getElementById('tour-room-next');
    els.hint = document.getElementById('tour-hint');

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
    els.toolbar.setAttribute('aria-label', window.TourStrings.t('tour_mode_aria'));
    var prevRoom = document.getElementById('tour-room-prev');
    var nextRoom = document.getElementById('tour-room-next');
    if (prevRoom) prevRoom.setAttribute('aria-label', window.TourStrings.t('prev_room_aria'));
    if (nextRoom) nextRoom.setAttribute('aria-label', window.TourStrings.t('next_room_aria'));

    window.TourRoute.onPop(function (parsed) {
      if (!state.data) {
        return;
      }
      stopGuidedTour();
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

  function readStartView() {
    var view = new URLSearchParams(window.location.search).get('view');
    return view === 'plan' || view === 'photos' || view === 'walkthrough' || view === 'dollhouse' ? view : 'all';
  }

  function applyStartView() {
    var view = readStartView();
    var needsStand = view === 'walkthrough' || (view === 'all' && state.isEmbed);
    var target = needsStand ? firstStandFromCurrent() : null;
    var flags = {
      walkthrough: state.features && state.features.walkthrough === true,
      hasStand: target !== null,
      hasDollhouse: state.hasDollhouse,
      hasPhotos: state.hasPhotos
    };
    var chosen = window.TourStartView.pick(view, state.isEmbed, flags);
    if (chosen === 'dollhouse') {
      state.mode = 'dollhouse';
      return;
    }
    if (chosen === 'walkthrough') {
      if (target) {
        state.mode = 'stand';
        state.walkthroughMode = 'stand';
        state.roomIndex = target.roomIndex;
        state.standId = target.standId;
      }
      return;
    }
    if (chosen === 'photos') {
      state.mode = 'photos';
      state.walkthroughMode = 'photos';
      state.roomIndex = state.roomsWithPhotos[0];
      state.roomSequenceIndex = 0;
      state.photoIndex = 0;
    }
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
    state.features = data.features && typeof data.features === 'object' ? data.features : null;
    state.walkthroughMode = readWalkthroughMode();
    state.roomsWithPhotos = computeRoomsWithPhotos(rawRooms);
    state.hasPhotos = state.roomsWithPhotos.length > 0;
    state.hasDollhouse = !!state.data.dollhouse_glb_url;
    state.mode = 'plan';
    state.roomIndex = 0;
    state.photoIndex = 0;
    state.roomSequenceIndex = 0;
    state.standPhotoIndex = 0;
    var parsedStart = window.TourRoute.parse(window.location.hash);
    applyParsedUrl(parsedStart);
    var startHash = window.location.hash;
    if (parsedStart.mode === window.TourRoute.MODES.PLAN && (startHash === '' || startHash === '#' || startHash === '#/')) {
      applyStartView();
    }
    window.TourRoute.replace(currentUrlState());
    render();
  }

  function readWalkthroughMode() {
    if (!(state.features && state.features.walkthrough === true)) {
      return 'photos';
    }
    try {
      var stored = localStorage.getItem('tour.walkthrough');
      if (stored === '0') return 'photos';
      if (stored === '1') return 'stand';
    } catch (err) {}
    return 'stand';
  }

  function persistWalkthroughMode(mode) {
    try {
      localStorage.setItem('tour.walkthrough', mode === 'stand' ? '1' : '0');
    } catch (err) {}
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
    if (parsed.mode === window.TourRoute.MODES.STAND && state.hasPhotos) {
      if (!(state.features && state.features.walkthrough === true)) {
        state.mode = 'plan';
        return;
      }
      for (var i = 0; i < state.data.rooms.length; i++) {
        var stands = state.data.rooms[i].stands || [];
        for (var j = 0; j < stands.length; j++) {
          if (stands[j].stand_id === parsed.standId) {
            state.mode = 'stand';
            state.roomIndex = i;
            state.standId = parsed.standId;
            state.walkthroughMode = 'stand';
            state.standPhotoIndex = parsed.photoIndex || 0;
            return;
          }
        }
      }
      state.mode = 'plan';
      return;
    }
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
    if (state.mode === 'stand') {
      return { mode: 'stand', standId: state.standId, photoIndex: state.standPhotoIndex || 0 };
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

  var GUIDED_TOUR_STEP_MS = 6000;

  function guidedTourPlaySvg() {
    return '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5v14l11-7z" fill="currentColor"/></svg>';
  }

  function guidedTourStopSvg() {
    return '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="6" y="6" width="12" height="12" rx="1" fill="currentColor"/></svg>';
  }

  function svgToolbarButton(svgHtml, label, active, onClick) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'tour-stand-tool' + (active ? ' is-active' : '');
    btn.innerHTML = svgHtml;
    btn.setAttribute('aria-label', label);
    btn.setAttribute('aria-pressed', active ? 'true' : 'false');
    btn.setAttribute('data-tip', label);
    btn.addEventListener('click', onClick);
    return btn;
  }

  function guidedTourOrder() {
    var out = [];
    if (!state.data) {
      return out;
    }
    for (var i = 0; i < state.data.rooms.length; i++) {
      var stands = state.data.rooms[i].stands || [];
      for (var j = 0; j < stands.length; j++) {
        if ((stands[j].photo_ids || []).length < 2) {
          continue;
        }
        out.push({ roomIndex: i, standId: stands[j].stand_id });
      }
    }
    return out;
  }

  function guidedTourIndexOf(standId) {
    for (var i = 0; i < state.guidedTourQueue.length; i++) {
      if (state.guidedTourQueue[i].standId === standId) {
        return i;
      }
    }
    return -1;
  }

  function scheduleNextGuidedStep() {
    if (state.guidedTourTimer) {
      clearTimeout(state.guidedTourTimer);
      state.guidedTourTimer = null;
    }
    state.guidedTourTimer = setTimeout(function () {
      state.guidedTourTimer = null;
      if (!state.guidedTourActive) {
        return;
      }
      state.guidedTourIndex += 1;
      if (state.guidedTourIndex >= state.guidedTourQueue.length) {
        stopGuidedTour();
        render();
        return;
      }
      var next = state.guidedTourQueue[state.guidedTourIndex];
      state.roomIndex = next.roomIndex;
      state.standId = next.standId;
      state.standPhotoIndex = 0;
      state.mode = 'stand';
      state.walkthroughMode = 'stand';
      syncUrl(false);
      render();
      scheduleNextGuidedStep();
    }, GUIDED_TOUR_STEP_MS);
  }

  function startGuidedTour() {
    var order = guidedTourOrder();
    if (order.length < 2) {
      return;
    }
    state.guidedTourActive = true;
    state.guidedTourQueue = order;
    var currentIndex = guidedTourIndexOf(state.standId);
    if (currentIndex < 0) {
      state.guidedTourIndex = 0;
      var first = order[0];
      state.roomIndex = first.roomIndex;
      state.standId = first.standId;
      state.standPhotoIndex = 0;
      state.mode = 'stand';
      state.walkthroughMode = 'stand';
      syncUrl(false);
      render();
      scheduleNextGuidedStep();
      return;
    }
    state.guidedTourIndex = currentIndex;
    scheduleNextGuidedStep();
    render();
  }

  function stopGuidedTour() {
    if (!state.guidedTourActive && !state.guidedTourTimer) {
      return;
    }
    state.guidedTourActive = false;
    if (state.guidedTourTimer) {
      clearTimeout(state.guidedTourTimer);
      state.guidedTourTimer = null;
    }
  }

  function toggleGuidedTour() {
    if (state.guidedTourActive) {
      stopGuidedTour();
      render();
      return;
    }
    startGuidedTour();
  }

  function renderMenu() {
    var toolbar = els.toolbar;
    clearNode(toolbar);
    toolbar.hidden = false;
    var walkthrough = state.hasPhotos && state.features && state.features.walkthrough === true;
    if (state.hasPhotos) {
      var single = document.createElement('div');
      single.className = 'tour-stand-pill';
      single.appendChild(toolbarButton('photos', window.TourStrings.t('menu_photos'), state.mode === 'photos', function () {
        if (walkthrough) {
          enterWalkthroughMode('photos');
        } else {
          switchMode('photos');
        }
      }));
      toolbar.appendChild(single);
    }
    var modes = document.createElement('div');
    modes.className = 'tour-stand-pill';
    if (state.hasDollhouse) {
      modes.appendChild(toolbarButton('dollhouse', window.TourStrings.t('menu_dollhouse'), state.mode === 'dollhouse', function () { switchMode('dollhouse'); }));
    }
    modes.appendChild(toolbarButton('plan', window.TourStrings.t('menu_plan'), state.mode === 'plan', function () { switchMode('plan'); }));
    if (walkthrough) {
      modes.appendChild(toolbarButton('walk', window.TourStandStrings.t('toggle_walkthrough'), state.mode === 'stand', function () { enterWalkthroughMode('stand'); }));
      var tourLabel = state.guidedTourActive ? window.TourStandStrings.t('tour_stop_label') : window.TourStandStrings.t('tour_play_label');
      var tourSvg = state.guidedTourActive ? guidedTourStopSvg() : guidedTourPlaySvg();
      modes.appendChild(svgToolbarButton(tourSvg, tourLabel, state.guidedTourActive, toggleGuidedTour));
    }
    toolbar.appendChild(modes);
  }

  function toolbarButton(icon, label, active, onClick) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'tour-stand-tool' + (active ? ' is-active' : '');
    btn.innerHTML = window.TourStands.icons[icon];
    btn.setAttribute('aria-label', label);
    btn.setAttribute('aria-pressed', active ? 'true' : 'false');
    btn.setAttribute('data-mode', icon);
    btn.setAttribute('data-tip', label);
    if (!active) btn.addEventListener('click', onClick);
    return btn;
  }

  function enterWalkthroughMode(mode) {
    stopGuidedTour();
    state.walkthroughMode = mode;
    persistWalkthroughMode(mode);
    if (mode === 'stand') {
      var target = firstStandFromCurrent();
      if (target) {
        state.mode = 'stand';
        state.roomIndex = target.roomIndex;
        state.standId = target.standId;
        syncUrl(false);
        render();
        return;
      }
      state.mode = 'plan';
      syncUrl(false);
      render();
      return;
    }
    if (state.roomsWithPhotos.length > 0) {
      state.mode = 'photos';
      state.roomIndex = state.roomsWithPhotos[0];
      state.roomSequenceIndex = 0;
      state.photoIndex = 0;
      syncUrl(false);
      render();
    }
  }

  function firstStandFromCurrent() {
    if (!state.data) return null;
    var fallback = null;
    var multi = null;
    for (var i = 0; i < state.roomsWithPhotos.length; i++) {
      var roomIndex = state.roomsWithPhotos[i];
      var room = state.data.rooms[roomIndex];
      var stands = room.stands || [];
      var posed = {};
      (room.photos || []).forEach(function (photo) {
        if (Array.isArray(photo.camera_transform) && photo.camera_transform.length === 16) posed[photo.photo_id] = true;
      });
      for (var j = 0; j < stands.length; j++) {
        var ids = stands[j].photo_ids || [];
        var candidate = { roomIndex: roomIndex, standId: stands[j].stand_id };
        if (ids.length > 1 && ids.some(function (id) { return posed[id]; })) {
          return candidate;
        }
        if (ids.length > 1 && !multi) {
          multi = candidate;
        }
        if (!fallback) {
          fallback = candidate;
        }
      }
    }
    return multi || fallback;
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
    if (mode === 'stand') {
      enterWalkthroughMode('stand');
      return;
    }
    if (mode === 'dollhouse' && !state.hasDollhouse) {
      return;
    }
    stopGuidedTour();
    state.mode = mode;
    syncUrl(false);
    render();
  }

  function renderViewport() {
    if (window.TourDollhouse && typeof window.TourDollhouse.stop === 'function') {
      window.TourDollhouse.stop();
    }
    if (window.TourStands && typeof window.TourStands.destroy === 'function') {
      window.TourStands.destroy();
    }
    clearNode(els.viewport);
    if (state.mode === 'plan') {
      renderPlan();
    } else if (state.mode === 'photos') {
      renderPhotoTour();
    } else if (state.mode === 'stand') {
      renderStandView();
    } else if (state.mode === 'dollhouse') {
      renderDollhouse();
    }
  }

  function renderStandView() {
    if (!window.TourStands || !state.data) {
      state.mode = 'plan';
      renderViewport();
      return;
    }
    var room = state.data.rooms[state.roomIndex];
    if (!room) {
      backToPlan();
      return;
    }
    var stands = room.stands || [];
    var currentStand = null;
    for (var i = 0; i < stands.length; i++) {
      if (stands[i].stand_id === state.standId) {
        currentStand = stands[i];
        break;
      }
    }
    if (!currentStand) {
      backToPlan();
      return;
    }
    var allStands = {};
    var allRooms = {};
    for (var k = 0; k < state.data.rooms.length; k++) {
      var r = state.data.rooms[k];
      allStands[r.room_id] = r.stands || [];
      allRooms[r.room_id] = r;
    }
    window.TourStands.render(els.viewport, currentStand, allStands, allRooms, {
      roomId: room.room_id,
      initialPhotoIndex: state.standPhotoIndex || 0,
      buildPhotoUrl: withToken,
      onDollhouse: state.hasDollhouse ? function () { switchMode('dollhouse'); } : null,
      onBackToPlan: backToPlan,
      onNavigate: function (nextStandId, nextRoomId) {
        state.standPhotoIndex = 0;
        stopGuidedTour();
        for (var m = 0; m < state.data.rooms.length; m++) {
          if (state.data.rooms[m].room_id === nextRoomId) {
            state.roomIndex = m;
            break;
          }
        }
        state.standId = nextStandId;
        state.mode = 'stand';
        syncUrl(false);
        render();
      }
    });
  }

  function renderChrome() {
    var app = document.getElementById('tour-app');
    if (app) {
      app.classList.toggle('is-stand', state.mode === 'stand');
    }
    if (els.hint && state.mode === 'stand') {
      els.hint.textContent = window.TourStandStrings.t('hint_stand');
      els.hint.hidden = false;
    } else if (els.hint) {
      var hintKey = state.mode === 'photos' ? 'hint_photos' : state.mode === 'dollhouse' ? 'hint_dollhouse' : 'hint_plan';
      els.hint.textContent = window.TourStrings.t(hintKey);
      els.hint.hidden = false;
    }
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
        window.TourPlan.renderMinimap(els.minimap, state.data.rooms, activeRoom.room_id, state.photoIndex);
      }
    } else if (els.minimap && state.mode !== 'stand') {
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
    if (state.walkthroughMode === 'stand' && state.features && state.features.walkthrough === true) {
      var stands = room.stands || [];
      if (stands.length > 0) {
        state.roomIndex = index;
        state.standId = stands[0].stand_id;
        state.standPhotoIndex = 0;
        state.mode = 'stand';
        syncUrl(false);
        render();
        return;
      }
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
    stopGuidedTour();
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
    } else if (state.mode === 'stand' && window.TourStands && window.TourStands.relayout) {
      window.TourStands.relayout();
    }
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
