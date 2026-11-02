(function () {
  'use strict';

  var FOV_DEG = 90;
  var ZOOM_FOV_DEG = 50;
  var MIN_FOV_DEG = 40;
  var PHOTO_FOV_DEG = 60;
  var CURSOR_SIZE_M = 0.45;
  var WALK_PICK_RADIUS_M = 1.5;
  var CLICK_SLOP_PX = 6;
  var DEFAULT_WALL_DISTANCE_M = 3;
  var DEFAULT_PHOTO_VFOV_DEG = 62;
  var DEFAULT_CEILING_M = 2.5;
  var MAX_PITCH_DEG = 88;
  var POLE_SLACK_DEG = 12;
  var MAX_TEXTURE_PX = 4096;
  var NEAR_VIEW_COS = 0.34;
  var EYE_HEIGHT_M = 1.4;
  var MIN_EYE_M = 0.6;
  var MAX_EYE_M = 2.4;
  var MARKER_SIZE_M = 0.7;
  var TURN_MS = 320;
  var pendingRotation = null;
  var DRAG_SENSITIVITY = 0.4;
  var TRANSITION_MS = 400;
  var THUMB_YAW_DEG = 35;
  var THUMB_ELEVATION_DEG = 52;
  var THUMB_WALL_M = 1.1;
  var LOADING_FALLBACK_MS = 20000;
  var PRELOAD_COUNT = 3;
  var ICONS = {
    photos: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/></svg>',
    dollhouse: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M4 7.5l8 4.5 8-4.5M12 12v9"/></svg>',
    plan: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 4h9v6h5v10H5z"/><path d="M14 10H9v4"/></svg>',
    walk: '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="13" cy="4.5" r="1.8"/><path d="M10 21l2-6-2.5-2.5 1-5 3 2.5h3M9.5 8L7 12M14.5 15l1.5 6"/></svg>',
    fullscreen: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></svg>',
    measure: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 16l13-13 5 5-13 13z"/><path d="M7 12l2 2M10 9l2 2M13 6l2 2"/></svg>'
  };

  var state = {
    viewport: null,
    pano: null,
    world: null,
    arrowLayer: null,
    turnFrame: null,
    gl: null,
    drawFrame: null,
    coverage: { up: 0, down: 0 },
    colors: null,
    loading: null,
    loadingTimer: null,
    cursor: null,
    hit: null,
    fov: 90,
    viewPitch: 0,
    eyeHeight: EYE_HEIGHT_M,
    dragStartPitch: 0,
    dragStartY: 0,
    downX: 0,
    downY: 0,
    moved: false,
    stand: null,
    roomId: null,
    selectedFloor: null,
    photos: [],
    photoEls: [],
    neighbours: [],
    measureLayer: null,
    measuring: false,
    measurePoints: [],
    measureButton: null,
    allStands: {},
    allRooms: {},
    viewRotation: 0,
    dragging: false,
    dragStartX: 0,
    dragStartRotation: 0,
    animating: false,
    options: {}
  };

  function render(viewport, currentStand, allStands, allRooms, opts) {
    var startRotation = pendingRotation;
    pendingRotation = null;
    destroy();
    state.viewport = viewport;
    state.stand = currentStand;
    state.allStands = allStands || {};
    state.allRooms = allRooms || {};
    state.options = opts || {};
    state.roomId = state.options.roomId || null;
    var currentRoomForFloor = state.allRooms[state.roomId];
    state.selectedFloor = currentRoomForFloor && typeof currentRoomForFloor.floor === 'string'
      ? currentRoomForFloor.floor.trim()
      : '';

    state.photos = (currentStand.photo_ids || []).map(findPhoto).filter(Boolean);
    state.photos.sort(function (a, b) { return photoBearing(a) - photoBearing(b); });
    state.neighbours = (currentStand.neighbours || []).map(function (n) {
      var stand = findStand(n.room_id, n.stand_id);
      return stand ? { stand: stand, roomId: n.room_id } : null;
    }).filter(Boolean);

    if (state.photos.length === 0) {
      renderSinglePhotoFallback();
      return;
    }

    var initial = state.options.initialPhotoIndex;
    if (startRotation !== null) {
      state.viewRotation = startRotation;
    } else if (typeof initial === 'number' && initial >= 0 && initial < state.photos.length) {
      state.viewRotation = photoBearing(state.photos[initial]);
    } else {
      state.viewRotation = photoBearing(state.photos[0]);
    }
    state.fov = FOV_DEG;
    state.viewPitch = 0;
    state.eyeHeight = standEyeHeight(state.photos);
    state.coverage = computeCoverage();
    state.colors = { top: [0, 0, 0, 0], mid: [0, 0, 0, 0], bottom: [0, 0, 0, 0] };
    buildDom();
    updatePhotoPositions();
    bindDrag();
    bindKeyboard();
    watchLoading();
    preloadNeighbours();
  }

  function watchLoading() {
    var pending = [];
    var fwd = viewBasis().fwd;
    for (var i = 0; i < state.photoEls.length; i++) {
      var entry = state.photoEls[i];
      if (dot(entry.pose.fwd, fwd) > NEAR_VIEW_COS && !entry.el.complete) pending.push(entry.el);
    }
    if (pending.length === 0) {
      hideLoading();
      return;
    }
    var remaining = pending.length;
    var done = function () {
      remaining -= 1;
      if (remaining <= 0) hideLoading();
    };
    for (var j = 0; j < pending.length; j++) {
      pending[j].addEventListener('load', done, { once: true });
      pending[j].addEventListener('error', done, { once: true });
    }
    state.loadingTimer = setTimeout(hideLoading, LOADING_FALLBACK_MS);
  }

  function showLoading() {
    if (state.loading) state.loading.hidden = false;
  }

  function hideLoading() {
    if (state.loadingTimer) clearTimeout(state.loadingTimer);
    state.loadingTimer = null;
    if (state.loading) state.loading.hidden = true;
  }

  function preloadStand(n, bearing) {
    var photos = (n.stand.photo_ids || []).map(findPhoto).filter(Boolean);
    photos.sort(function (a, b) {
      return Math.abs(normalizeAngle(photoBearing(a) - bearing)) - Math.abs(normalizeAngle(photoBearing(b) - bearing));
    });
    for (var i = 0; i < Math.min(PRELOAD_COUNT, photos.length); i++) {
      var img = new Image();
      img.src = state.options.buildPhotoUrl ? state.options.buildPhotoUrl(photos[i].url) : photos[i].url;
    }
  }

  function preloadNeighbours() {
    for (var i = 0; i < state.neighbours.length && i < 2; i++) {
      var n = state.neighbours[i];
      preloadStand(n, bearingTo(n));
    }
  }

  function photoBearing(photo) {
    var m = photo.camera_transform;
    if (Array.isArray(m) && m.length === 16 && isFinite(m[8]) && isFinite(m[10]) && (m[8] !== 0 || m[10] !== 0)) {
      return normalizeAngle(Math.atan2(-m[8], m[10]) * 180 / Math.PI);
    }
    return normalizeAngle(Number(photo.heading_deg) || 0);
  }

  function findPhoto(photoId) {
    for (var roomId in state.allRooms) {
      var room = state.allRooms[roomId];
      for (var i = 0; i < (room.photos || []).length; i++) {
        if (room.photos[i].photo_id === photoId) return room.photos[i];
      }
    }
    return null;
  }

  function findStand(roomId, standId) {
    var stands = state.allStands[roomId] || [];
    for (var i = 0; i < stands.length; i++) {
      if (stands[i].stand_id === standId) return stands[i];
    }
    return null;
  }

  function renderSinglePhotoFallback() {
    if (!state.options.onBackToPlan) return;
    var t = window.TourStandStrings;
    var wrap = document.createElement('div');
    wrap.className = 'tour-empty-block';
    var p = document.createElement('p');
    p.textContent = t.t('stand_single_fallback');
    wrap.appendChild(p);
    var back = document.createElement('button');
    back.type = 'button';
    back.className = 'tour-btn tour-btn-primary';
    back.textContent = t.t('toggle_photos');
    back.addEventListener('click', state.options.onBackToPlan);
    wrap.appendChild(back);
    state.viewport.appendChild(wrap);
  }

  function buildDom() {
    clearNode(state.viewport);
    var shell = document.createElement('div');
    shell.className = 'tour-stand-shell';
    state.viewport.appendChild(shell);

    var pano = document.createElement('div');
    pano.className = 'tour-stand-pano';
    shell.appendChild(pano);
    state.pano = pano;

    var world = document.createElement('div');
    world.className = 'tour-stand-world';
    pano.appendChild(world);
    state.world = world;

    var canvas = document.createElement('canvas');
    canvas.className = 'tour-stand-canvas';
    canvas.setAttribute('aria-hidden', 'true');
    pano.insertBefore(canvas, world);
    state.gl = initGl(canvas);
    if (state.gl) {
      world.hidden = true;
      bindContextEvents(canvas);
    } else {
      pano.removeChild(canvas);
    }

    state.photoEls = [];
    for (var i = 0; i < state.photos.length; i++) {
      var photo = state.photos[i];
      var img = document.createElement('img');
      img.className = 'tour-stand-photo';
      img.alt = '';
      var entry = { el: img, photo: photo, pose: photoPose(photo), tex: null, buf: null };
      img.addEventListener('load', onPhotoLoaded(entry));
      img.src = state.options.buildPhotoUrl ? state.options.buildPhotoUrl(photo.url) : photo.url;
      world.appendChild(img);
      state.photoEls.push(entry);
    }

    if (state.options.onBackToPlan) {
      var close = document.createElement('button');
      close.type = 'button';
      close.className = 'tour-circle tour-stand-close';
      close.textContent = '×';
      close.setAttribute('aria-label', window.TourStrings.t('back_to_plan'));
      close.setAttribute('data-tip', window.TourStrings.t('back_to_plan'));
      close.addEventListener('click', state.options.onBackToPlan);
      shell.appendChild(close);
    }

    var cursor = document.createElement('div');
    cursor.className = 'tour-stand-cursor';
    cursor.hidden = true;
    pano.appendChild(cursor);
    state.cursor = cursor;

    var measureLayer = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    measureLayer.setAttribute('class', 'tour-stand-measure');
    measureLayer.setAttribute('aria-hidden', 'true');
    pano.appendChild(measureLayer);
    state.measureLayer = measureLayer;

    var arrowLayer = document.createElement('div');
    arrowLayer.className = 'tour-stand-arrows';
    pano.appendChild(arrowLayer);
    state.arrowLayer = arrowLayer;

    var loading = document.createElement('div');
    loading.className = 'tour-stand-loading';
    loading.setAttribute('role', 'status');
    var spinner = document.createElement('span');
    spinner.className = 'tour-stand-spinner';
    loading.appendChild(spinner);
    var loadingText = document.createElement('span');
    loadingText.className = 'tour-stand-loading-text';
    loadingText.textContent = window.TourStandStrings.t('loading_spot');
    loading.appendChild(loadingText);
    pano.appendChild(loading);
    state.loading = loading;

    var bottom = document.createElement('div');
    bottom.className = 'tour-stand-bottom';
    bottom.appendChild(buildToolbar());
    var stripEl = buildStrip();
    var floorsRow = buildFloorsRow(function (newFloor) {
      state.selectedFloor = newFloor;
      var newStrip = buildStrip();
      stripEl.parentNode.replaceChild(newStrip, stripEl);
      stripEl = newStrip;
    });
    if (floorsRow) {
      bottom.appendChild(floorsRow);
    }
    bottom.appendChild(stripEl);
    shell.appendChild(bottom);
  }

  function roomPolygons() {
    var polygons = [];
    for (var roomId in state.allRooms) {
      var room = state.allRooms[roomId];
      if (!room || !Array.isArray(room.outline_m) || room.outline_m.length < 3) continue;
      var o = Array.isArray(room.structure_origin_m) ? room.structure_origin_m : [0, 0];
      polygons.push(room.outline_m.map(function (p) { return [p[0] + (Number(o[0]) || 0), p[1] + (Number(o[1]) || 0)]; }));
    }
    return polygons;
  }

  function prepareThumbCanvas(canvas) {
    if (!canvas.isConnected) return null;
    var dpr = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = Math.round((canvas.clientWidth || 160) * dpr);
    canvas.height = Math.round((canvas.clientHeight || 90) * dpr);
    var ctx = canvas.getContext('2d');
    if (!ctx) return null;
    ctx.fillStyle = '#161616';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    return { ctx: ctx, dpr: dpr };
  }

  function drawPlanThumb(canvas) {
    var prepared = prepareThumbCanvas(canvas);
    var polygons = roomPolygons();
    if (!prepared || polygons.length === 0) return;
    var ctx = prepared.ctx;
    var dpr = prepared.dpr;
    var minX = Infinity;
    var maxX = -Infinity;
    var minZ = Infinity;
    var maxZ = -Infinity;
    polygons.forEach(function (poly) {
      poly.forEach(function (p) {
        minX = Math.min(minX, p[0]);
        maxX = Math.max(maxX, p[0]);
        minZ = Math.min(minZ, p[1]);
        maxZ = Math.max(maxZ, p[1]);
      });
    });
    var pad = 10 * dpr;
    var scale = Math.min((canvas.width - 2 * pad) / Math.max(0.01, maxX - minX), (canvas.height - 2 * pad - 8 * dpr) / Math.max(0.01, maxZ - minZ));
    var offX = (canvas.width - (maxX - minX) * scale) / 2 - minX * scale;
    var offY = (canvas.height - 8 * dpr - (maxZ - minZ) * scale) / 2 - minZ * scale;
    ctx.lineJoin = 'miter';
    polygons.forEach(function (poly) {
      ctx.beginPath();
      poly.forEach(function (p, i) {
        if (i === 0) ctx.moveTo(p[0] * scale + offX, p[1] * scale + offY);
        else ctx.lineTo(p[0] * scale + offX, p[1] * scale + offY);
      });
      ctx.closePath();
      ctx.fillStyle = '#cfcbc4';
      ctx.fill();
      ctx.lineWidth = 2.5 * dpr;
      ctx.strokeStyle = '#ffffff';
      ctx.stroke();
    });
  }

  function drawDollhouseThumb(canvas) {
    var prepared = prepareThumbCanvas(canvas);
    var polygons = roomPolygons();
    if (!prepared || polygons.length === 0) return;
    var ctx = prepared.ctx;
    var dpr = prepared.dpr;
    var yaw = THUMB_YAW_DEG * Math.PI / 180;
    var elev = THUMB_ELEVATION_DEG * Math.PI / 180;
    var cy = Math.cos(yaw);
    var sy = Math.sin(yaw);
    function view(x, y, z) {
      var rx = x * cy - z * sy;
      var rz = x * sy + z * cy;
      return [rx, rz * Math.sin(elev) - y * Math.cos(elev), rz];
    }
    var minX = Infinity;
    var maxX = -Infinity;
    var minY = Infinity;
    var maxY = -Infinity;
    var walls = [];
    for (var i = 0; i < polygons.length; i++) {
      var poly = polygons[i];
      for (var j = 0; j < poly.length; j++) {
        var a = poly[j];
        var b = poly[(j + 1) % poly.length];
        var pts = [view(a[0], 0, a[1]), view(b[0], 0, b[1]), view(b[0], THUMB_WALL_M, b[1]), view(a[0], THUMB_WALL_M, a[1])];
        for (var k = 0; k < 4; k++) {
          minX = Math.min(minX, pts[k][0]);
          maxX = Math.max(maxX, pts[k][0]);
          minY = Math.min(minY, pts[k][1]);
          maxY = Math.max(maxY, pts[k][1]);
        }
        var ex = b[0] - a[0];
        var ez = b[1] - a[1];
        var len = Math.sqrt(ex * ex + ez * ez) || 1;
        var light = 0.78 + 0.22 * Math.abs((-ez / len) * 0.6 + (ex / len) * 0.8);
        walls.push({ pts: pts, depth: (pts[0][2] + pts[1][2]) / 2, light: light });
      }
    }
    var pad = 8 * dpr;
    var scale = Math.min((canvas.width - 2 * pad) / Math.max(0.01, maxX - minX), (canvas.height - 2 * pad) / Math.max(0.01, maxY - minY));
    var offX = (canvas.width - (maxX - minX) * scale) / 2 - minX * scale;
    var offY = (canvas.height - (maxY - minY) * scale) / 2 - minY * scale;
    function path(points) {
      ctx.beginPath();
      for (var m = 0; m < points.length; m++) {
        var px = points[m][0] * scale + offX;
        var py = points[m][1] * scale + offY;
        if (m === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
      }
      ctx.closePath();
    }
    ctx.lineJoin = 'round';
    for (var f = 0; f < polygons.length; f++) {
      path(polygons[f].map(function (p) { return view(p[0], 0, p[1]); }));
      ctx.fillStyle = '#d9cfbf';
      ctx.fill();
    }
    walls.sort(function (p, q) { return p.depth - q.depth; });
    ctx.lineWidth = Math.max(1, dpr * 0.75);
    ctx.strokeStyle = 'rgba(0, 0, 0, 0.18)';
    for (var w = 0; w < walls.length; w++) {
      var c = Math.round(236 * walls[w].light);
      path(walls[w].pts);
      ctx.fillStyle = 'rgb(' + c + ',' + c + ',' + (c - 6) + ')';
      ctx.fill();
      ctx.stroke();
    }
  }

  function onPhotoLoaded(entry) {
    return function () {
      if (state.photoEls.indexOf(entry) === -1) return;
      if (state.gl) {
        uploadPhoto(entry);
      }
      updatePhotoPositions();
    };
  }

  function iconButton(icon, label, onClick, extraClass) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'tour-stand-tool' + (extraClass ? ' ' + extraClass : '');
    btn.innerHTML = ICONS[icon];
    btn.setAttribute('aria-label', label);
    btn.setAttribute('data-tip', label);
    if (onClick) btn.addEventListener('click', onClick);
    return btn;
  }

  function buildToolbar() {
    var t = window.TourStandStrings;
    var bar = document.createElement('div');
    bar.className = 'tour-stand-toolbar';

    var right = document.createElement('div');
    right.className = 'tour-stand-tools';
    var measure = iconButton('measure', t.t('measure_label'), toggleMeasure, 'is-round tour-stand-measure-btn');
    measure.setAttribute('aria-pressed', 'false');
    state.measureButton = measure;
    right.appendChild(measure);
    bar.appendChild(right);

    var app = document.getElementById('tour-app');
    if (app && app.requestFullscreen && document.fullscreenEnabled) {
      right.appendChild(iconButton('fullscreen', t.t('fullscreen_label'), function () {
        try {
          if (document.fullscreenElement) {
            document.exitFullscreen();
          } else {
            app.requestFullscreen();
          }
        } catch (err) {}
      }, 'is-round'));
    }
    return bar;
  }

  function buildStrip() {
    var t = window.TourStandStrings;
    var strip = document.createElement('div');
    strip.className = 'tour-stand-strip';
    strip.setAttribute('role', 'list');
    strip.setAttribute('aria-label', t.t('strip_aria'));

    if (state.options.onDollhouse) {
      var doll = document.createElement('button');
      doll.type = 'button';
      doll.className = 'tour-stand-tile is-mode';
      doll.setAttribute('role', 'listitem');
      var dollCanvas = document.createElement('canvas');
      dollCanvas.className = 'tour-stand-tile-preview';
      dollCanvas.setAttribute('aria-hidden', 'true');
      doll.appendChild(dollCanvas);
      setTimeout(function () { drawDollhouseThumb(dollCanvas); }, 0);
      var dollLabel = document.createElement('span');
      dollLabel.className = 'tour-stand-tile-label';
      dollLabel.textContent = t.t('embed_tab_dollhouse');
      doll.appendChild(dollLabel);
      doll.addEventListener('click', state.options.onDollhouse);
      strip.appendChild(doll);
    }

    if (state.options.onBackToPlan) {
      var plan = document.createElement('button');
      plan.type = 'button';
      plan.className = 'tour-stand-tile is-mode';
      plan.setAttribute('role', 'listitem');
      var planCanvas = document.createElement('canvas');
      planCanvas.className = 'tour-stand-tile-preview';
      planCanvas.setAttribute('aria-hidden', 'true');
      plan.appendChild(planCanvas);
      setTimeout(function () { drawPlanThumb(planCanvas); }, 0);
      var planLabel = document.createElement('span');
      planLabel.className = 'tour-stand-tile-label';
      planLabel.textContent = t.t('embed_tab_plan');
      plan.appendChild(planLabel);
      plan.addEventListener('click', state.options.onBackToPlan);
      strip.appendChild(plan);
    }

    var current = null;
    for (var roomId in state.allStands) {
      var stands = (state.allStands[roomId] || []).filter(function (s) { return (s.photo_ids || []).length > 1; });
      var room = state.allRooms[roomId] || {};
      var roomFloor = typeof room.floor === 'string' ? room.floor.trim() : '';
      if (state.selectedFloor && roomFloor && roomFloor !== state.selectedFloor) {
        continue;
      }
      for (var i = 0; i < stands.length; i++) {
        var stand = stands[i];
        var tile = document.createElement('button');
        tile.type = 'button';
        tile.className = 'tour-stand-tile';
        tile.setAttribute('role', 'listitem');
        var cover = findPhoto((stand.photo_ids || [])[0]);
        if (cover && cover.url) {
          var img = document.createElement('img');
          img.alt = '';
          img.loading = 'lazy';
          img.src = state.options.buildPhotoUrl ? state.options.buildPhotoUrl(cover.url) : cover.url;
          tile.appendChild(img);
        }
        var badge = document.createElement('span');
        badge.className = 'tour-stand-tile-badge';
        badge.innerHTML = ICONS.walk;
        tile.appendChild(badge);
        var label = document.createElement('span');
        label.className = 'tour-stand-tile-label';
        label.textContent = (room.label || '') + (stands.length > 1 ? ' \u00B7 ' + (i + 1) : '');
        tile.appendChild(label);
        if (stand.stand_id === state.stand.stand_id) {
          tile.className += ' is-current';
          tile.setAttribute('aria-current', 'true');
          current = tile;
        } else {
          (function (target, targetRoomId) {
            tile.addEventListener('click', function () {
              if (!state.options.onNavigate) return;
              showLoading();
              state.options.onNavigate(target.stand_id, targetRoomId);
            });
          })(stand, roomId);
        }
        strip.appendChild(tile);
      }
    }
    if (current) {
      setTimeout(function () {
        if (current.isConnected) {
          strip.scrollLeft = Math.max(0, current.offsetLeft - (strip.clientWidth - current.offsetWidth) / 2);
        }
      }, 0);
    }
    return strip;
  }

  function buildFloorsRow(onChange) {
    var floors = [];
    for (var roomId in state.allRooms) {
      var room = state.allRooms[roomId] || {};
      var name = typeof room.floor === 'string' ? room.floor.trim() : '';
      if (name && floors.indexOf(name) === -1) {
        floors.push(name);
      }
    }
    var appEl = document.getElementById('tour-app');
    if (floors.length < 2) {
      if (appEl) {
        appEl.classList.remove('has-stand-floors');
      }
      return null;
    }
    var row = document.createElement('div');
    row.className = 'tour-stand-floors';
    row.setAttribute('role', 'tablist');
    for (var i = 0; i < floors.length; i++) {
      (function (floorName) {
        var chip = document.createElement('button');
        chip.type = 'button';
        chip.className = 'tour-stand-floor-chip' + (floorName === state.selectedFloor ? ' is-active' : '');
        chip.setAttribute('role', 'tab');
        chip.setAttribute('aria-selected', floorName === state.selectedFloor ? 'true' : 'false');
        chip.textContent = floorName;
        chip.addEventListener('click', function () {
          if (state.selectedFloor === floorName) {
            return;
          }
          var chips = row.querySelectorAll('.tour-stand-floor-chip');
          for (var k = 0; k < chips.length; k++) {
            var active = chips[k].textContent === floorName;
            chips[k].classList.toggle('is-active', active);
            chips[k].setAttribute('aria-selected', active ? 'true' : 'false');
          }
          onChange(floorName);
        });
        row.appendChild(chip);
      })(floors[i]);
    }
    if (appEl) {
      appEl.classList.add('has-stand-floors');
    }
    return row;
  }

  function clearNode(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  function updatePhotoPositions() {
    if (!state.pano) return;
    clampPitch();
    if (state.gl) {
      requestDraw();
    } else {
      layoutCssPhotos();
    }
    renderArrows();
    drawMeasure();
  }

  function viewSize() {
    return [state.pano.clientWidth || 320, state.pano.clientHeight || 240];
  }

  function focalFor(width, height) {
    return Math.max(width, height) / 2 / Math.tan(state.fov * Math.PI / 360);
  }

  function viewBasis() {
    var t = state.viewRotation * Math.PI / 180;
    var p = state.viewPitch * Math.PI / 180;
    var st = Math.sin(t);
    var ct = Math.cos(t);
    var sp = Math.sin(p);
    var cp = Math.cos(p);
    return {
      fwd: [st * cp, -sp, -ct * cp],
      right: [ct, 0, st],
      up: [st * sp, cp, -ct * sp]
    };
  }

  function dot(a, b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  }

  function cross(a, b) {
    return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  }

  function normalize(v) {
    var len = Math.sqrt(dot(v, v)) || 1;
    return [v[0] / len, v[1] / len, v[2] / len];
  }

  function neg(v) {
    return [-v[0], -v[1], -v[2]];
  }

  function project(d, basis, width, height, focal) {
    var z = dot(d, basis.fwd);
    if (z <= 0.01) return null;
    return [width / 2 + focal * dot(d, basis.right) / z, height / 2 - focal * dot(d, basis.up) / z, z];
  }

  function unproject(x, y, basis, width, height, focal) {
    var a = x - width / 2;
    var b = y - height / 2;
    return normalize([
      basis.fwd[0] * focal + basis.right[0] * a - basis.up[0] * b,
      basis.fwd[1] * focal + basis.right[1] * a - basis.up[1] * b,
      basis.fwd[2] * focal + basis.right[2] * a - basis.up[2] * b
    ]);
  }

  function standEyeHeight(photos) {
    var heights = [];
    for (var i = 0; i < photos.length; i++) {
      var m = photos[i].camera_transform;
      var y = Array.isArray(m) && m.length === 16 ? Number(m[13]) : NaN;
      if (isFinite(y) && y >= MIN_EYE_M && y <= MAX_EYE_M) heights.push(y);
    }
    if (heights.length === 0) return EYE_HEIGHT_M;
    heights.sort(function (a, b) { return a - b; });
    return heights[Math.floor(heights.length / 2)];
  }

  function photoPose(photo) {
    var m = photo.camera_transform;
    var valid = Array.isArray(m) && m.length === 16;
    for (var i = 0; valid && i < 12; i++) {
      if (typeof m[i] !== 'number' || !isFinite(m[i])) valid = false;
    }
    if (valid && (m[8] !== 0 || m[9] !== 0 || m[10] !== 0)) {
      var c0 = normalize([m[0], m[1], m[2]]);
      var c1 = normalize([m[4], m[5], m[6]]);
      var fwd = neg(normalize([m[8], m[9], m[10]]));
      if (Math.abs(m[5]) > Math.abs(m[1])) {
        return m[5] >= 0 ? { fwd: fwd, right: c0, up: c1 } : { fwd: fwd, right: neg(c0), up: neg(c1) };
      }
      return m[1] <= 0 ? { fwd: fwd, right: c1, up: neg(c0) } : { fwd: fwd, right: neg(c1), up: c0 };
    }
    var b = photoBearing(photo) * Math.PI / 180;
    var p = (Number(photo.pitch_deg) || 0) * Math.PI / 180;
    var f = [Math.sin(b) * Math.cos(p), Math.sin(p), -Math.cos(b) * Math.cos(p)];
    var r = [Math.cos(b), 0, Math.sin(b)];
    return { fwd: f, right: r, up: cross(r, f) };
  }

  function photoFrame(entry) {
    var photo = entry.photo;
    var w = entry.el.naturalWidth || 0;
    var h = entry.el.naturalHeight || 0;
    var k = photo.intrinsics;
    if (Array.isArray(k) && k.length === 4 && k[0] > 0 && k[1] > 0 && k[2] > 0 && k[3] > 0) {
      var fx = k[0];
      var fy = k[1];
      var cx = k[2];
      var cy = k[3];
      if (w > 0 && h > 0) {
        var scale = w / (2 * cx);
        if (Math.abs(scale - 1) > 0.2) {
          fx *= scale;
          fy *= scale;
          cx *= scale;
          cy *= scale;
        }
      } else {
        w = 2 * cx;
        h = 2 * cy;
      }
      return { left: -cx / fx, right: (w - cx) / fx, top: cy / fy, bottom: -(h - cy) / fy };
    }
    var halfW = Math.tan(photoFovDeg(photo) * Math.PI / 360);
    var aspect = w > 0 && h > 0 ? h / w : 0.75;
    return { left: -halfW, right: halfW, top: halfW * aspect, bottom: -halfW * aspect };
  }

  function photoHalfVerticalDeg(photo) {
    var k = photo.intrinsics;
    if (Array.isArray(k) && k.length === 4 && k[1] > 0 && k[3] > 0) {
      return Math.atan(k[3] / k[1]) * 180 / Math.PI;
    }
    return DEFAULT_PHOTO_VFOV_DEG / 2;
  }

  function computeCoverage() {
    var up = 0;
    var down = 0;
    for (var i = 0; i < state.photos.length; i++) {
      var pose = photoPose(state.photos[i]);
      var elev = Math.asin(Math.max(-1, Math.min(1, pose.fwd[1]))) * 180 / Math.PI;
      var half = photoHalfVerticalDeg(state.photos[i]);
      up = Math.max(up, elev + half);
      down = Math.max(down, half - elev);
    }
    return { up: up, down: down };
  }

  function clampPitch() {
    var size = viewSize();
    var focal = focalFor(size[0], size[1]);
    var halfV = Math.atan((size[1] / 2) / focal) * 180 / Math.PI;
    var maxUp = Math.min(MAX_PITCH_DEG, Math.max(0, state.coverage.up - halfV + POLE_SLACK_DEG));
    var maxDown = Math.min(MAX_PITCH_DEG, Math.max(0, state.coverage.down - halfV + POLE_SLACK_DEG));
    state.viewPitch = Math.max(-maxUp, Math.min(maxDown, state.viewPitch));
  }

  function layoutCssPhotos() {
    var size = viewSize();
    var width = size[0];
    var height = size[1];
    var focal = focalFor(width, height);
    var basis = viewBasis();
    for (var i = 0; i < state.photoEls.length; i++) {
      var entry = state.photoEls[i];
      var pose = entry.pose;
      var p = project(pose.fwd, basis, width, height, focal);
      if (!p || p[2] < 0.35) {
        entry.el.style.display = 'none';
        continue;
      }
      var frame = photoFrame(entry);
      var pxW = (frame.right - frame.left) * focal / p[2];
      var pxH = (frame.top - frame.bottom) * focal / p[2];
      entry.el.style.display = 'block';
      entry.el.style.width = pxW + 'px';
      entry.el.style.height = pxH + 'px';
      entry.el.style.left = (p[0] - pxW / 2) + 'px';
      entry.el.style.top = (p[1] - pxH / 2) + 'px';
      entry.el.style.zIndex = String(Math.round(p[2] * 1000));
      var roll = Math.atan2(dot(pose.up, basis.right), dot(pose.up, basis.up)) * 180 / Math.PI;
      entry.el.style.transform = 'rotate(' + roll + 'deg)';
    }
  }

  var GAIN_SAMPLE_PX = 16;
  var GAIN_MIN = 0.75;
  var GAIN_MAX = 1.33;
  var PHOTO_VS = 'attribute vec3 a_dir;attribute vec2 a_uv;uniform vec3 u_right;uniform vec3 u_up;uniform vec3 u_fwd;uniform vec2 u_scale;varying vec2 v_uv;void main(){float z=dot(a_dir,u_fwd);gl_Position=vec4(dot(a_dir,u_right)*u_scale.x,dot(a_dir,u_up)*u_scale.y,z-0.02,z);v_uv=a_uv;}';
  var PHOTO_FS = 'precision mediump float;uniform sampler2D u_tex;uniform vec3 u_gain;varying vec2 v_uv;void main(){vec4 c=texture2D(u_tex,v_uv);c.rgb=min(c.rgb*u_gain,vec3(1.0));float e=0.1;float a=smoothstep(0.0,e,v_uv.x)*smoothstep(0.0,e,1.0-v_uv.x)*smoothstep(0.0,e,v_uv.y)*smoothstep(0.0,e,1.0-v_uv.y);gl_FragColor=vec4(c.rgb,a);}';
  var BG_VS = 'attribute vec2 a_pos;varying vec2 v_pos;void main(){v_pos=a_pos;gl_Position=vec4(a_pos,0.0,1.0);}';
  var BG_FS = 'precision mediump float;uniform vec3 u_right;uniform vec3 u_up;uniform vec3 u_fwd;uniform vec2 u_inv;uniform vec3 u_top;uniform vec3 u_mid;uniform vec3 u_bottom;varying vec2 v_pos;void main(){vec3 d=normalize(u_fwd+u_right*v_pos.x*u_inv.x+u_up*v_pos.y*u_inv.y);vec3 c=d.y>0.0?mix(u_mid,u_top,smoothstep(0.0,0.8,d.y)):mix(u_mid,u_bottom,smoothstep(0.0,0.8,-d.y));gl_FragColor=vec4(c,1.0);}';

  function compileProgram(gl, vsSource, fsSource) {
    function shader(type, source) {
      var s = gl.createShader(type);
      gl.shaderSource(s, source);
      gl.compileShader(s);
      return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
    }
    var vs = shader(gl.VERTEX_SHADER, vsSource);
    var fs = shader(gl.FRAGMENT_SHADER, fsSource);
    if (!vs || !fs) return null;
    var prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    return gl.getProgramParameter(prog, gl.LINK_STATUS) ? prog : null;
  }

  function initGl(canvas) {
    var gl = null;
    try {
      gl = canvas.getContext('webgl', { alpha: false, antialias: true, preserveDrawingBuffer: false });
    } catch (err) {
      gl = null;
    }
    if (!gl) return null;
    var photo = compileProgram(gl, PHOTO_VS, PHOTO_FS);
    var bg = compileProgram(gl, BG_VS, BG_FS);
    if (!photo || !bg) return null;
    var bgBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, bgBuf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    return {
      ctx: gl,
      canvas: canvas,
      maxTexture: Math.min(MAX_TEXTURE_PX, gl.getParameter(gl.MAX_TEXTURE_SIZE) || MAX_TEXTURE_PX),
      photo: {
        prog: photo,
        dir: gl.getAttribLocation(photo, 'a_dir'),
        uv: gl.getAttribLocation(photo, 'a_uv'),
        right: gl.getUniformLocation(photo, 'u_right'),
        up: gl.getUniformLocation(photo, 'u_up'),
        fwd: gl.getUniformLocation(photo, 'u_fwd'),
        scale: gl.getUniformLocation(photo, 'u_scale'),
        tex: gl.getUniformLocation(photo, 'u_tex'),
        gain: gl.getUniformLocation(photo, 'u_gain')
      },
      bg: {
        prog: bg,
        buf: bgBuf,
        pos: gl.getAttribLocation(bg, 'a_pos'),
        right: gl.getUniformLocation(bg, 'u_right'),
        up: gl.getUniformLocation(bg, 'u_up'),
        fwd: gl.getUniformLocation(bg, 'u_fwd'),
        inv: gl.getUniformLocation(bg, 'u_inv'),
        top: gl.getUniformLocation(bg, 'u_top'),
        mid: gl.getUniformLocation(bg, 'u_mid'),
        bottom: gl.getUniformLocation(bg, 'u_bottom')
      }
    };
  }

  function bindContextEvents(canvas) {
    canvas.addEventListener('webglcontextlost', function (e) {
      e.preventDefault();
      if (state.gl && state.gl.canvas === canvas) {
        state.gl = null;
        if (state.world) state.world.hidden = false;
        canvas.hidden = true;
        updatePhotoPositions();
      }
    });
    canvas.addEventListener('webglcontextrestored', function () {
      if (state.gl || !canvas.isConnected) return;
      var g = initGl(canvas);
      if (!g) return;
      state.gl = g;
      for (var i = 0; i < state.photoEls.length; i++) {
        state.photoEls[i].tex = null;
        state.photoEls[i].buf = null;
        uploadPhoto(state.photoEls[i]);
      }
      if (state.world) state.world.hidden = true;
      canvas.hidden = false;
      updatePhotoPositions();
    });
  }

  function photoMean(img) {
    try {
      var c = document.createElement('canvas');
      c.width = GAIN_SAMPLE_PX;
      c.height = GAIN_SAMPLE_PX;
      var ctx = c.getContext('2d');
      ctx.drawImage(img, 0, 0, GAIN_SAMPLE_PX, GAIN_SAMPLE_PX);
      var px = ctx.getImageData(0, 0, GAIN_SAMPLE_PX, GAIN_SAMPLE_PX).data;
      var sum = [0, 0, 0];
      for (var i = 0; i < px.length; i += 4) {
        sum[0] += px[i];
        sum[1] += px[i + 1];
        sum[2] += px[i + 2];
      }
      var n = px.length / 4;
      var mean = [sum[0] / n, sum[1] / n, sum[2] / n];
      return mean[0] + mean[1] + mean[2] > 3 ? mean : null;
    } catch (err) {
      return null;
    }
  }

  function median(values) {
    var sorted = values.slice().sort(function (a, b) { return a - b; });
    var mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  function photoGains(list) {
    var means = list.map(function (e) { return e.mean; }).filter(Boolean);
    if (means.length < 2) return null;
    var ref = [0, 1, 2].map(function (k) { return median(means.map(function (m) { return m[k]; })); });
    return function (entry) {
      if (!entry.mean) return [1, 1, 1];
      return [0, 1, 2].map(function (k) {
        var m = Math.max(1, entry.mean[k]);
        return Math.max(GAIN_MIN, Math.min(GAIN_MAX, ref[k] / m));
      });
    };
  }

  function uploadPhoto(entry) {
    var g = state.gl;
    var img = entry.el;
    if (!g || entry.tex || !img.naturalWidth) return;
    var gl = g.ctx;
    var source = img;
    var longest = Math.max(img.naturalWidth, img.naturalHeight);
    if (longest > g.maxTexture) {
      var s = g.maxTexture / longest;
      var c = document.createElement('canvas');
      c.width = Math.max(1, Math.floor(img.naturalWidth * s));
      c.height = Math.max(1, Math.floor(img.naturalHeight * s));
      c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
      source = c;
    }
    var tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    try {
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGB, gl.RGB, gl.UNSIGNED_BYTE, source);
    } catch (err) {
      gl.deleteTexture(tex);
      return;
    }
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    entry.mean = photoMean(img);
    var f = photoFrame(entry);
    var p = entry.pose;
    function corner(u, v, s, t) {
      return [
        p.fwd[0] + p.right[0] * u + p.up[0] * v,
        p.fwd[1] + p.right[1] * u + p.up[1] * v,
        p.fwd[2] + p.right[2] * u + p.up[2] * v,
        s, t
      ];
    }
    var data = [].concat(
      corner(f.left, f.top, 0, 0),
      corner(f.left, f.bottom, 0, 1),
      corner(f.right, f.top, 1, 0),
      corner(f.right, f.bottom, 1, 1)
    );
    var buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(data), gl.STATIC_DRAW);
    entry.tex = tex;
    entry.buf = buf;
    samplePhotoColors(entry, f);
  }

  function samplePhotoColors(entry, frame) {
    var bands;
    try {
      var c = document.createElement('canvas');
      c.width = 1;
      c.height = 3;
      var ctx = c.getContext('2d');
      ctx.drawImage(entry.el, 0, 0, 1, 3);
      bands = ctx.getImageData(0, 0, 1, 3).data;
    } catch (err) {
      return;
    }
    var p = entry.pose;
    var offsets = [frame.top * 0.66, 0, frame.bottom * 0.66];
    for (var i = 0; i < 3; i++) {
      var y = normalize([
        p.fwd[0] + p.up[0] * offsets[i],
        p.fwd[1] + p.up[1] * offsets[i],
        p.fwd[2] + p.up[2] * offsets[i]
      ])[1];
      var key = y > 0.35 ? 'top' : y < -0.35 ? 'bottom' : 'mid';
      var acc = state.colors[key];
      acc[0] += bands[i * 4];
      acc[1] += bands[i * 4 + 1];
      acc[2] += bands[i * 4 + 2];
      acc[3] += 1;
    }
  }

  function averageColor(key, fallback, shade) {
    var acc = state.colors[key];
    if (acc[3] > 0) return [acc[0] / acc[3] / 255, acc[1] / acc[3] / 255, acc[2] / acc[3] / 255];
    return [fallback[0] * shade, fallback[1] * shade, fallback[2] * shade];
  }

  function requestDraw() {
    if (state.drawFrame || !state.gl) return;
    state.drawFrame = requestAnimationFrame(drawGl);
  }

  function drawGl() {
    state.drawFrame = null;
    var g = state.gl;
    if (!g || !state.pano) return;
    var gl = g.ctx;
    var size = viewSize();
    var width = size[0];
    var height = size[1];
    var dpr = Math.min(2, window.devicePixelRatio || 1);
    var cw = Math.max(1, Math.round(width * dpr));
    var ch = Math.max(1, Math.round(height * dpr));
    if (g.canvas.width !== cw || g.canvas.height !== ch) {
      g.canvas.width = cw;
      g.canvas.height = ch;
    }
    gl.viewport(0, 0, cw, ch);
    var focal = focalFor(width, height);
    var basis = viewBasis();
    var neutral = [0.42, 0.41, 0.39];
    var mid = averageColor('mid', neutral, 1);
    var top = averageColor('top', mid, 1.15);
    var bottom = averageColor('bottom', mid, 0.75);

    gl.disable(gl.BLEND);
    gl.useProgram(g.bg.prog);
    gl.uniform3fv(g.bg.right, basis.right);
    gl.uniform3fv(g.bg.up, basis.up);
    gl.uniform3fv(g.bg.fwd, basis.fwd);
    gl.uniform2f(g.bg.inv, (width / 2) / focal, (height / 2) / focal);
    gl.uniform3fv(g.bg.top, top);
    gl.uniform3fv(g.bg.mid, mid);
    gl.uniform3fv(g.bg.bottom, bottom);
    gl.bindBuffer(gl.ARRAY_BUFFER, g.bg.buf);
    gl.enableVertexAttribArray(g.bg.pos);
    gl.vertexAttribPointer(g.bg.pos, 2, gl.FLOAT, false, 0, 0);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.disableVertexAttribArray(g.bg.pos);

    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.useProgram(g.photo.prog);
    gl.uniform3fv(g.photo.right, basis.right);
    gl.uniform3fv(g.photo.up, basis.up);
    gl.uniform3fv(g.photo.fwd, basis.fwd);
    gl.uniform2f(g.photo.scale, focal / (width / 2), focal / (height / 2));
    gl.uniform1i(g.photo.tex, 0);
    gl.activeTexture(gl.TEXTURE0);
    gl.enableVertexAttribArray(g.photo.dir);
    gl.enableVertexAttribArray(g.photo.uv);
    var list = state.photoEls.filter(function (e) { return e.tex; });
    list.sort(function (a, b) { return dot(a.pose.fwd, basis.fwd) - dot(b.pose.fwd, basis.fwd); });
    var gainFor = photoGains(list);
    for (var i = 0; i < list.length; i++) {
      var gain = gainFor ? gainFor(list[i]) : [1, 1, 1];
      gl.uniform3f(g.photo.gain, gain[0], gain[1], gain[2]);
      gl.bindBuffer(gl.ARRAY_BUFFER, list[i].buf);
      gl.vertexAttribPointer(g.photo.dir, 3, gl.FLOAT, false, 20, 0);
      gl.vertexAttribPointer(g.photo.uv, 2, gl.FLOAT, false, 20, 12);
      gl.bindTexture(gl.TEXTURE_2D, list[i].tex);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    }
    gl.disableVertexAttribArray(g.photo.dir);
    gl.disableVertexAttribArray(g.photo.uv);
  }

  function releaseGl() {
    var g = state.gl;
    state.gl = null;
    if (state.drawFrame) cancelAnimationFrame(state.drawFrame);
    state.drawFrame = null;
    if (!g) return;
    try {
      var lose = g.ctx.getExtension('WEBGL_lose_context');
      if (lose) lose.loseContext();
    } catch (err) {}
  }

  function surfaceEllipse(point, normal, basis, width, height, focal, sizeM) {
    var p = project(point, basis, width, height, focal);
    if (!p) return null;
    var q = project([point[0] + normal[0] * 0.1, point[1] + normal[1] * 0.1, point[2] + normal[2] * 0.1], basis, width, height, focal);
    var angle = q ? Math.atan2(q[1] - p[1], q[0] - p[0]) * 180 / Math.PI : 90;
    var squash = Math.max(0.18, Math.abs(dot(normalize(point), normal)));
    return { x: p[0], y: p[1], size: (sizeM / p[2]) * focal, angle: angle, squash: squash };
  }

  function ellipseTransform(e) {
    return 'rotate(' + e.angle + 'deg) scale(' + e.squash + ', 1) translate(-50%, -50%)';
  }

  function renderArrows() {
    if (!state.arrowLayer || !state.pano) return;
    clearNode(state.arrowLayer);
    var size = viewSize();
    var width = size[0];
    var height = size[1];
    var focal = focalFor(width, height);
    var basis = viewBasis();
    var halfH = Math.atan((width / 2) / focal) * 180 / Math.PI;
    var left = null;
    var right = null;
    for (var i = 0; i < state.neighbours.length; i++) {
      var n = state.neighbours[i];
      var delta = planDelta(n);
      var floorPoint = [delta[0], -state.eyeHeight, delta[1]];
      var e = surfaceEllipse(floorPoint, [0, 1, 0], basis, width, height, focal, MARKER_SIZE_M);
      if (e && e.x > 20 && e.x < width - 20 && e.y > 20 && e.y < height - 20) {
        addFloorMarker(n, e);
        continue;
      }
      var relative = normalizeAngle(bearingTo(n) - state.viewRotation);
      if (Math.abs(relative) <= halfH) continue;
      if (relative < 0) {
        if (!left || relative > left.relative) left = { n: n, relative: relative };
      } else if (!right || relative < right.relative) {
        right = { n: n, relative: relative };
      }
    }
    if (left) addTurnButton(left.n, 'left');
    if (right) addTurnButton(right.n, 'right');
  }

  function addFloorMarker(n, e) {
    var size = Math.max(30, Math.min(160, e.size));
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'tour-stand-floor-marker';
    btn.style.left = e.x + 'px';
    btn.style.top = e.y + 'px';
    btn.style.width = size + 'px';
    btn.style.height = size + 'px';
    btn.style.transform = ellipseTransform(e);
    var otherRoom = n.roomId !== state.roomId ? state.allRooms[n.roomId] : null;
    var label = window.TourStandStrings.t('arrow_label');
    if (otherRoom && otherRoom.label) {
      var chip = document.createElement('span');
      chip.className = 'tour-stand-marker-label';
      chip.textContent = otherRoom.label;
      chip.style.left = e.x + 'px';
      chip.style.top = (e.y - size * 0.5 * Math.max(e.squash, 0.4) - 10) + 'px';
      state.arrowLayer.appendChild(chip);
      label += ': ' + otherRoom.label;
    }
    btn.setAttribute('aria-label', label);
    btn.addEventListener('click', function () { navigateTo(n); });
    state.arrowLayer.appendChild(btn);
  }

  function addTurnButton(n, side) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'tour-stand-turn is-' + side;
    btn.textContent = side === 'left' ? '‹' : '›';
    var turnLabel = window.TourStandStrings.t(side === 'left' ? 'turn_left_label' : 'turn_right_label');
    btn.setAttribute('aria-label', turnLabel);
    btn.setAttribute('data-tip', turnLabel);
    btn.addEventListener('click', function () { turnTo(bearingTo(n)); });
    state.arrowLayer.appendChild(btn);
  }

  function turnTo(targetBearing) {
    animateView(targetBearing, state.fov, 0);
  }

  function animateView(targetBearing, targetFov, targetPitch) {
    if (state.turnFrame) cancelAnimationFrame(state.turnFrame);
    var start = state.viewRotation;
    var delta = normalizeAngle(targetBearing - start);
    var startFov = state.fov;
    var startPitch = state.viewPitch;
    var endPitch = typeof targetPitch === 'number' ? targetPitch : startPitch;
    var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduced) {
      state.viewRotation = start + delta;
      state.viewPitch = endPitch;
      setFov(targetFov);
      return;
    }
    var began = null;
    function step(now) {
      if (!state.pano) return;
      if (began === null) began = now;
      var p = Math.min(1, (now - began) / TURN_MS);
      var eased = p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2;
      state.viewRotation = start + delta * eased;
      state.viewPitch = startPitch + (endPitch - startPitch) * eased;
      setFov(startFov + (targetFov - startFov) * eased);
      state.turnFrame = p < 1 ? requestAnimationFrame(step) : null;
    }
    state.turnFrame = requestAnimationFrame(step);
  }

  function planDelta(neighbour) {
    var from = worldCenter(state.stand, state.roomId);
    var to = worldCenter(neighbour.stand, neighbour.roomId);
    return [to[0] - from[0], to[1] - from[1]];
  }

  function photoFovDeg(photo) {
    var k = photo.intrinsics;
    if (Array.isArray(k) && k.length === 4 && k[0] > 0 && k[2] > 0) {
      return 2 * Math.atan(k[2] / k[0]) * 180 / Math.PI;
    }
    var zoom = Number(photo.zoom) > 1 ? Number(photo.zoom) : 1;
    return 2 * Math.atan(Math.tan(PHOTO_FOV_DEG * Math.PI / 360) / zoom) * 180 / Math.PI;
  }

  function worldCenter(stand, roomId) {
    var room = roomId ? state.allRooms[roomId] : null;
    var origin = room && Array.isArray(room.structure_origin_m) ? room.structure_origin_m : null;
    var ox = origin ? Number(origin[0]) || 0 : 0;
    var oz = origin ? Number(origin[1]) || 0 : 0;
    return [stand.center_m[0] + ox, stand.center_m[1] + oz];
  }

  function bearingTo(neighbour) {
    var d = planDelta(neighbour);
    return Math.atan2(d[0], -d[1]) * 180 / Math.PI;
  }

  function bindDrag() {
    state.pano.addEventListener('pointerdown', function (e) {
      if (e.target.tagName === 'BUTTON' || e.target.tagName === 'SPAN') return;
      state.dragging = true;
      state.moved = false;
      state.downX = e.clientX;
      state.downY = e.clientY;
      state.dragStartX = e.clientX;
      state.dragStartY = e.clientY;
      state.dragStartRotation = state.viewRotation;
      state.dragStartPitch = state.viewPitch;
      state.pano.setPointerCapture(e.pointerId);
    });
    state.pano.addEventListener('pointermove', function (e) {
      if (state.dragging) {
        if (Math.abs(e.clientX - state.downX) > CLICK_SLOP_PX || Math.abs(e.clientY - state.downY) > CLICK_SLOP_PX) {
          state.moved = true;
        }
        if (state.moved) {
          var dx = e.clientX - state.dragStartX;
          var dy = e.clientY - state.dragStartY;
          state.viewRotation = state.dragStartRotation - dx * DRAG_SENSITIVITY * (state.fov / FOV_DEG);
          state.viewPitch = state.dragStartPitch - dy * DRAG_SENSITIVITY * (state.fov / FOV_DEG);
          updatePhotoPositions();
        }
      }
      if (e.pointerType === 'mouse' || e.pointerType === 'pen') {
        updateCursor(e.clientX, e.clientY);
      }
    });
    state.pano.addEventListener('pointerup', function (e) {
      var wasClick = state.dragging && !state.moved;
      state.dragging = false;
      try { state.pano.releasePointerCapture(e.pointerId); } catch (err) {}
      if (wasClick && e.target.tagName !== 'BUTTON' && e.target.tagName !== 'SPAN') {
        updateCursor(e.clientX, e.clientY);
        activateHit();
      }
    });
    state.pano.addEventListener('pointercancel', function () {
      state.dragging = false;
    });
    state.pano.addEventListener('pointerleave', function () {
      if (state.cursor) state.cursor.hidden = true;
    });
    state.pano.addEventListener('wheel', function (e) {
      e.preventDefault();
      setFov(state.fov + (e.deltaY > 0 ? 6 : -6));
    }, { passive: false });
  }

  function setFov(fov) {
    state.fov = Math.max(MIN_FOV_DEG, Math.min(FOV_DEG, fov));
    updatePhotoPositions();
  }

  function currentOutline() {
    var room = state.roomId ? state.allRooms[state.roomId] : null;
    return room && Array.isArray(room.outline_m) && room.outline_m.length >= 3 ? room.outline_m : null;
  }

  function ceilingHeight() {
    var room = state.roomId ? state.allRooms[state.roomId] : null;
    var h = room ? Number(room.height_m) : 0;
    return h > state.eyeHeight + 0.3 ? h : DEFAULT_CEILING_M;
  }

  function wallHit(origin, dir) {
    var outline = currentOutline();
    if (!outline) return null;
    var best = null;
    for (var i = 0; i < outline.length; i++) {
      var a = outline[i];
      var b = outline[(i + 1) % outline.length];
      var ex = b[0] - a[0];
      var ez = b[1] - a[1];
      var denom = dir[0] * ez - dir[1] * ex;
      if (Math.abs(denom) < 1e-9) continue;
      var ax = a[0] - origin[0];
      var az = a[1] - origin[1];
      var t = (ax * ez - az * ex) / denom;
      var u = (ax * dir[1] - az * dir[0]) / denom;
      if (t > 0.05 && u >= 0 && u <= 1 && (!best || t < best.t)) {
        var len = Math.sqrt(ex * ex + ez * ez) || 1;
        best = { t: t, normal: [-ez / len, ex / len] };
      }
    }
    return best;
  }

  function updateCursor(clientX, clientY) {
    if (!state.cursor || !state.pano) return;
    var rect = state.pano.getBoundingClientRect();
    var width = rect.width;
    var height = rect.height;
    var x = clientX - rect.left;
    var y = clientY - rect.top;
    var focal = focalFor(width, height);
    var basis = viewBasis();
    var d = unproject(x, y, basis, width, height, focal);
    var origin = state.stand.center_m;
    var hLen = Math.sqrt(d[0] * d[0] + d[2] * d[2]);
    var surface = null;
    if (hLen > 1e-4) {
      var dirH = [d[0] / hLen, d[2] / hLen];
      var wall = wallHit(origin, dirH);
      surface = {
        kind: 'wall',
        t: (wall ? wall.t : DEFAULT_WALL_DISTANCE_M) / hLen,
        normal: wall ? [wall.normal[0], 0, wall.normal[1]] : [-dirH[0], 0, -dirH[1]]
      };
    }
    if (d[1] < -1e-4) {
      var tf = state.eyeHeight / -d[1];
      if (!surface || tf < surface.t) surface = { kind: 'floor', t: tf, normal: [0, 1, 0] };
    } else if (d[1] > 1e-4) {
      var tc = (ceilingHeight() - state.eyeHeight) / d[1];
      if (!surface || tc < surface.t) surface = { kind: 'ceiling', t: tc, normal: [0, -1, 0] };
    }
    if (!surface) {
      state.cursor.hidden = true;
      state.hit = null;
      return;
    }
    var point = [d[0] * surface.t, d[1] * surface.t, d[2] * surface.t];
    var e = surfaceEllipse(point, surface.normal, basis, width, height, focal, CURSOR_SIZE_M);
    if (!e) {
      state.cursor.hidden = true;
      state.hit = null;
      return;
    }
    var size = Math.max(18, Math.min(160, e.size));
    state.cursor.hidden = false;
    state.cursor.classList.toggle('is-floor', surface.kind === 'floor');
    state.cursor.style.left = x + 'px';
    state.cursor.style.top = y + 'px';
    state.cursor.style.width = size + 'px';
    state.cursor.style.height = size + 'px';
    state.cursor.style.transform = ellipseTransform(e);
    state.hit = {
      kind: surface.kind,
      bearing: Math.atan2(d[0], -d[2]) * 180 / Math.PI,
      pitch: -Math.asin(Math.max(-1, Math.min(1, d[1]))) * 180 / Math.PI,
      point: [origin[0] + point[0], origin[1] + point[2]],
      point3: [point[0], point[1], point[2]]
    };
  }

  function activateHit() {
    var hit = state.hit;
    if (!hit) return;
    if (state.measuring) {
      if (state.measurePoints.length >= 2) state.measurePoints = [];
      state.measurePoints.push(hit.point3);
      drawMeasure();
      return;
    }
    if (hit.kind === 'floor') {
      var target = neighbourNear(hit.point);
      if (target) {
        navigateTo(target);
        return;
      }
    }
    if (state.fov < FOV_DEG - 1) {
      animateView(hit.bearing, FOV_DEG, hit.pitch);
    } else {
      animateView(hit.bearing, ZOOM_FOV_DEG, hit.pitch);
    }
  }

  function toggleMeasure() {
    state.measuring = !state.measuring;
    state.measurePoints = [];
    if (state.measureButton) {
      state.measureButton.classList.toggle('is-active', state.measuring);
      state.measureButton.setAttribute('aria-pressed', state.measuring ? 'true' : 'false');
    }
    if (state.pano) state.pano.classList.toggle('is-measuring', state.measuring);
    drawMeasure();
  }

  function formatMeters(m) {
    var text = m.toFixed(2);
    return (window.TourStandStrings.lang === 'nl' ? text.replace('.', ',') : text) + ' m';
  }

  function drawMeasure() {
    var layer = state.measureLayer;
    if (!layer || !state.pano) return;
    while (layer.firstChild) layer.removeChild(layer.firstChild);
    var pts = state.measuring ? state.measurePoints : [];
    if (pts.length === 0) return;
    var size = viewSize();
    var focal = focalFor(size[0], size[1]);
    var basis = viewBasis();
    var ns = 'http://www.w3.org/2000/svg';
    var screen = pts.map(function (p) { return project(p, basis, size[0], size[1], focal); });
    if (screen.length === 2 && screen[0] && screen[1]) {
      var line = document.createElementNS(ns, 'line');
      line.setAttribute('x1', screen[0][0]);
      line.setAttribute('y1', screen[0][1]);
      line.setAttribute('x2', screen[1][0]);
      line.setAttribute('y2', screen[1][1]);
      layer.appendChild(line);
    }
    screen.forEach(function (s) {
      if (!s) return;
      var dotEl = document.createElementNS(ns, 'circle');
      dotEl.setAttribute('cx', s[0]);
      dotEl.setAttribute('cy', s[1]);
      dotEl.setAttribute('r', 5);
      layer.appendChild(dotEl);
    });
    if (pts.length === 2) {
      var dx = pts[1][0] - pts[0][0];
      var dy = pts[1][1] - pts[0][1];
      var dz = pts[1][2] - pts[0][2];
      var mid = project([(pts[0][0] + pts[1][0]) / 2, (pts[0][1] + pts[1][1]) / 2, (pts[0][2] + pts[1][2]) / 2], basis, size[0], size[1], focal);
      if (mid) {
        var label = document.createElementNS(ns, 'text');
        label.setAttribute('x', mid[0]);
        label.setAttribute('y', mid[1] - 10);
        label.textContent = formatMeters(Math.sqrt(dx * dx + dy * dy + dz * dz));
        layer.appendChild(label);
      }
    }
  }

  function neighbourNear(localPoint) {
    var originRoom = state.roomId ? state.allRooms[state.roomId] : null;
    var o = originRoom && Array.isArray(originRoom.structure_origin_m) ? originRoom.structure_origin_m : [0, 0];
    var hitWorld = [localPoint[0] + (Number(o[0]) || 0), localPoint[1] + (Number(o[1]) || 0)];
    var best = null;
    var bestDistance = WALK_PICK_RADIUS_M;
    for (var i = 0; i < state.neighbours.length; i++) {
      var c = worldCenter(state.neighbours[i].stand, state.neighbours[i].roomId);
      var d = Math.sqrt((c[0] - hitWorld[0]) * (c[0] - hitWorld[0]) + (c[1] - hitWorld[1]) * (c[1] - hitWorld[1]));
      if (d <= bestDistance) {
        bestDistance = d;
        best = state.neighbours[i];
      }
    }
    return best;
  }

  function bindKeyboard() {
    document.addEventListener('keydown', handleKey);
  }

  function handleKey(e) {
    if (!state.stand || !state.pano) return;
    if (e.key === 'Escape' && state.options.onBackToPlan) {
      e.preventDefault();
      state.options.onBackToPlan();
      return;
    }
    var focused = document.activeElement;
    if (focused && focused !== document.body && /^(BUTTON|A|INPUT|SELECT|TEXTAREA)$/.test(focused.tagName)) return;
    if (e.key === 'ArrowLeft') {
      state.viewRotation -= 15;
      updatePhotoPositions();
      e.preventDefault();
    } else if (e.key === 'ArrowRight') {
      state.viewRotation += 15;
      updatePhotoPositions();
      e.preventDefault();
    } else if (e.key === 'ArrowUp' || e.key === 'Enter') {
      var target = nearestAhead();
      if (target) {
        navigateTo(target);
        e.preventDefault();
      }
    }
  }

  function nearestAhead() {
    var best = null;
    var bestAbs = 999;
    for (var i = 0; i < state.neighbours.length; i++) {
      var n = state.neighbours[i];
      var relative = Math.abs(normalizeAngle(bearingTo(n) - state.viewRotation));
      if (relative < bestAbs) {
        bestAbs = relative;
        best = n;
      }
    }
    return bestAbs <= 45 ? best : null;
  }

  function navigateTo(n) {
    if (state.animating || !state.options.onNavigate) return;
    pendingRotation = bearingTo(n);
    preloadStand(n, pendingRotation);
    showLoading();
    var reduced = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduced) {
      state.options.onNavigate(n.stand.stand_id, n.roomId);
      return;
    }
    if (!state.pano) {
      state.options.onNavigate(n.stand.stand_id, n.roomId);
      return;
    }
    state.animating = true;
    var targetBearing = normalizeAngle(bearingTo(n) - state.viewRotation);
    var shift = -targetBearing * 2;
    state.pano.style.transition = 'transform ' + TRANSITION_MS + 'ms ease-in-out, opacity ' + TRANSITION_MS + 'ms ease-in-out';
    state.pano.style.transform = 'scale(1.35) translateX(' + shift + 'px)';
    state.pano.style.opacity = '0.15';
    var pano = state.pano;
    setTimeout(function () {
      if (state.pano !== pano) return;
      state.pano.style.transition = '';
      state.pano.style.transform = '';
      state.pano.style.opacity = '1';
      state.animating = false;
      if (state.options.onNavigate) state.options.onNavigate(n.stand.stand_id, n.roomId);
    }, TRANSITION_MS);
  }

  function normalizeAngle(deg) {
    deg = deg % 360;
    if (deg > 180) deg -= 360;
    if (deg < -180) deg += 360;
    return deg;
  }

  function destroy() {
    if (state.turnFrame) cancelAnimationFrame(state.turnFrame);
    state.turnFrame = null;
    releaseGl();
    if (state.loadingTimer) clearTimeout(state.loadingTimer);
    state.loadingTimer = null;
    state.loading = null;
    document.removeEventListener('keydown', handleKey);
    state.dragging = false;
    state.animating = false;
    state.pano = null;
    state.world = null;
    state.arrowLayer = null;
    state.cursor = null;
    state.hit = null;
    state.measureLayer = null;
    state.measuring = false;
    state.measurePoints = [];
    state.measureButton = null;
    state.photoEls = [];
    state.neighbours = [];
    state.photos = [];
    state.stand = null;
    state.roomId = null;
  }

  function relayout() {
    updatePhotoPositions();
  }

  window.TourStands = { render: render, destroy: destroy, relayout: relayout, icons: ICONS };
})();
