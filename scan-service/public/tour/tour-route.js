(function () {
  'use strict';

  var MODES = { PLAN: 'plan', PHOTOS: 'photos', DOLLHOUSE: 'dollhouse', STAND: 'stand' };

  function parse(hash) {
    var raw = String(hash || '').replace(/^#/, '').replace(/^\//, '');
    if (raw === '' || raw === 'plan') {
      return { mode: MODES.PLAN };
    }
    var parts = raw.split('/');
    if (parts[0] === 'photos') {
      var r = parseInt(parts[1], 10);
      var p = parseInt(parts[2], 10);
      return {
        mode: MODES.PHOTOS,
        roomIndex: isFinite(r) && r >= 0 ? r : 0,
        photoIndex: isFinite(p) && p >= 0 ? p : 0
      };
    }
    if (parts[0] === 'dollhouse') {
      return { mode: MODES.DOLLHOUSE };
    }
    if (parts[0] === 'stand') {
      var sid = parts[1] ? decodeURIComponent(parts[1]) : '';
      var pi = parseInt(parts[2], 10);
      return {
        mode: MODES.STAND,
        standId: sid,
        photoIndex: isFinite(pi) && pi >= 0 ? pi : 0
      };
    }
    return { mode: MODES.PLAN };
  }

  function format(s) {
    if (s.mode === MODES.PHOTOS) {
      return '#/photos/' + (s.roomIndex || 0) + '/' + (s.photoIndex || 0);
    }
    if (s.mode === MODES.DOLLHOUSE) {
      return '#/dollhouse';
    }
    if (s.mode === MODES.STAND) {
      return '#/stand/' + encodeURIComponent(s.standId || '') + '/' + (s.photoIndex || 0);
    }
    return '#/plan';
  }

  function push(s) {
    var url = format(s);
    if (window.location.hash === url) {
      history.replaceState({ mode: s.mode }, '', url);
    } else {
      history.pushState({ mode: s.mode }, '', url);
    }
  }

  function replace(s) {
    history.replaceState({ mode: s.mode }, '', format(s));
  }

  function onPop(callback) {
    window.addEventListener('popstate', function () {
      callback(parse(window.location.hash));
    });
  }

  window.TourRoute = {
    MODES: MODES,
    parse: parse,
    format: format,
    push: push,
    replace: replace,
    onPop: onPop
  };
})();
