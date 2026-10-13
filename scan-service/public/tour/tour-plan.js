(function () {
  'use strict';

  var NS = 'http://www.w3.org/2000/svg';
  var GAP_M = 0.4;
  var MIN_VIEWPORT = 240;
  var VIEWPORT_PADDING = 40;
  var PADDING = 20;
  var MARKER_RADIUS_PX = 7;

  function placedRooms(rooms) {
    var placed = [];
    var cursorX = 0;
    var allHaveOrigin = rooms.every(function (room) {
      var outline = Array.isArray(room.outline_m) ? room.outline_m : [];
      if (outline.length < 3) {
        return true;
      }
      var origin = room.structure_origin_m;
      return Array.isArray(origin)
        && origin.length === 2
        && isFinite(Number(origin[0]))
        && isFinite(Number(origin[1]));
    });
    for (var i = 0; i < rooms.length; i++) {
      var room = rooms[i];
      var outline = Array.isArray(room.outline_m) ? room.outline_m : [];
      if (outline.length < 3) {
        continue;
      }
      var xs = outline.map(function (p) { return Number(p[0]) || 0; });
      var minLocalX = Math.min.apply(null, xs);
      var width = Math.max.apply(null, xs) - minLocalX;
      var ox, oz;
      if (allHaveOrigin) {
        ox = Number(room.structure_origin_m[0]) || 0;
        oz = Number(room.structure_origin_m[1]) || 0;
      } else {
        ox = cursorX;
        oz = 0;
        cursorX += width + GAP_M;
      }
      var points = outline.map(function (p) {
        return [Number(p[0]) + ox, Number(p[1]) + oz];
      });
      placed.push({ index: i, room: room, points: points, ox: ox, oz: oz });
    }
    return placed;
  }

  function boundsOf(placed) {
    var minX = Infinity;
    var minZ = Infinity;
    var maxX = -Infinity;
    var maxZ = -Infinity;
    placed.forEach(function (item) {
      item.points.forEach(function (p) {
        if (p[0] < minX) minX = p[0];
        if (p[0] > maxX) maxX = p[0];
        if (p[1] < minZ) minZ = p[1];
        if (p[1] > maxZ) maxZ = p[1];
      });
    });
    return { minX: minX, minZ: minZ, maxX: maxX, maxZ: maxZ };
  }

  function renderPlan(viewport, rooms, onRoomTap, onPhotoTap) {
    var placed = placedRooms(rooms);
    if (placed.length === 0) {
      return false;
    }

    var svg = document.createElementNS(NS, 'svg');
    svg.classList.add('tour-plan-svg');
    svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', window.TourStrings.t('plan_aria'));
    viewport.appendChild(svg);

    var rect = viewport.getBoundingClientRect();
    var availableW = Math.max(MIN_VIEWPORT, rect.width - VIEWPORT_PADDING);
    var availableH = Math.max(MIN_VIEWPORT, rect.height - VIEWPORT_PADDING);

    var bounds = boundsOf(placed);
    var planW = Math.max(bounds.maxX - bounds.minX, 0.1);
    var planH = Math.max(bounds.maxZ - bounds.minZ, 0.1);
    var scale = Math.min((availableW - PADDING * 2) / planW, (availableH - PADDING * 2) / planH);
    var canvasW = planW * scale + PADDING * 2;
    var canvasH = planH * scale + PADDING * 2;

    svg.setAttribute('width', canvasW);
    svg.setAttribute('height', canvasH);
    svg.setAttribute('viewBox', '0 0 ' + canvasW + ' ' + canvasH);

    function toPx(point) {
      return [
        (point[0] - bounds.minX) * scale + PADDING,
        (point[1] - bounds.minZ) * scale + PADDING
      ];
    }

    placed.forEach(function (item) {
      var points = item.points.map(function (p) {
        var q = toPx(p);
        return q[0].toFixed(1) + ',' + q[1].toFixed(1);
      }).join(' ');

      var poly = document.createElementNS(NS, 'polygon');
      poly.setAttribute('points', points);
      poly.classList.add('tour-plan-room');
      if (item.room.overlap === true) {
        poly.classList.add('tour-plan-room-overlap');
      }
      poly.setAttribute('tabindex', '0');
      poly.setAttribute('role', 'button');
      poly.setAttribute('aria-label', item.room.label || '');

      (function (roomIndex) {
        poly.addEventListener('click', function () {
          onRoomTap(roomIndex);
        });
        poly.addEventListener('keydown', function (event) {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            onRoomTap(roomIndex);
          }
        });
      })(item.index);

      svg.appendChild(poly);

      var cx = 0;
      var cy = 0;
      item.points.forEach(function (p) {
        cx += p[0];
        cy += p[1];
      });
      var centroid = toPx([cx / item.points.length, cy / item.points.length]);

      var text = document.createElementNS(NS, 'text');
      text.setAttribute('x', centroid[0].toFixed(1));
      text.setAttribute('y', centroid[1].toFixed(1));
      text.setAttribute('text-anchor', 'middle');
      text.setAttribute('dominant-baseline', 'middle');
      text.classList.add('tour-plan-label');
      text.textContent = item.room.label || '';
      svg.appendChild(text);
    });

    if (typeof onPhotoTap === 'function') {
      renderPhotoMarkers(svg, placed, toPx, onPhotoTap);
    }

    return true;
  }

  function renderMinimap(container, rooms, activeRoomId) {
    while (container.firstChild) {
      container.removeChild(container.firstChild);
    }
    var placed = placedRooms(rooms);
    if (placed.length === 0) {
      return false;
    }
    var svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', window.TourStrings.t('minimap_aria'));
    var rect = container.getBoundingClientRect();
    var w = Math.max(rect.width || 130, 60);
    var h = Math.max(rect.height || 96, 60);
    var bounds = boundsOf(placed);
    var planW = Math.max(bounds.maxX - bounds.minX, 0.1);
    var planH = Math.max(bounds.maxZ - bounds.minZ, 0.1);
    var scale = Math.min((w - 8) / planW, (h - 8) / planH);
    function toPx(point) {
      return [
        (point[0] - bounds.minX) * scale + 4,
        (point[1] - bounds.minZ) * scale + 4
      ];
    }
    svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
    placed.forEach(function (item) {
      var pts = item.points.map(function (p) {
        var q = toPx(p);
        return q[0].toFixed(1) + ',' + q[1].toFixed(1);
      }).join(' ');
      var poly = document.createElementNS(NS, 'polygon');
      poly.setAttribute('points', pts);
      poly.classList.add('tour-minimap-room');
      if (item.room.room_id === activeRoomId) {
        poly.classList.add('is-active');
      }
      svg.appendChild(poly);
    });
    var active = placed.filter(function (item) {
      return item.room.room_id === activeRoomId;
    })[0];
    if (active) {
      var cx = 0, cz = 0;
      active.points.forEach(function (p) { cx += p[0]; cz += p[1]; });
      cx /= active.points.length;
      cz /= active.points.length;
      var dot = toPx([cx, cz]);
      var circle = document.createElementNS(NS, 'circle');
      circle.setAttribute('cx', dot[0].toFixed(1));
      circle.setAttribute('cy', dot[1].toFixed(1));
      circle.setAttribute('r', '2.5');
      circle.classList.add('tour-minimap-dot');
      svg.appendChild(circle);
    }
    container.appendChild(svg);
    return true;
  }

  function renderPhotoMarkers(svg, placed, toPx, onPhotoTap) {
    var group = document.createElementNS(NS, 'g');
    group.classList.add('tour-plan-photo-markers');
    var added = false;
    placed.forEach(function (item) {
      var photos = Array.isArray(item.room.photos) ? item.room.photos : [];
      photos.forEach(function (photo, photoIndex) {
        var pos = Array.isArray(photo.position_m) ? photo.position_m : null;
        if (!pos || pos.length < 2) {
          return;
        }
        var wx = Number(pos[0]) + item.ox;
        var wz = Number(pos[1]) + item.oz;
        if (!isFinite(wx) || !isFinite(wz)) {
          return;
        }
        var px = toPx([wx, wz]);
        var marker = document.createElementNS(NS, 'circle');
        marker.setAttribute('cx', px[0].toFixed(1));
        marker.setAttribute('cy', px[1].toFixed(1));
        marker.setAttribute('r', String(MARKER_RADIUS_PX));
        marker.classList.add('tour-plan-photo-marker');
        marker.setAttribute('tabindex', '0');
        marker.setAttribute('role', 'button');
        marker.setAttribute('aria-label', (item.room.label || '') + ' photo ' + (photoIndex + 1));
        marker.setAttribute('data-room-index', String(item.index));
        marker.setAttribute('data-photo-index', String(photoIndex));
        (function (roomIndex, photoIdx) {
          marker.addEventListener('click', function (event) {
            event.stopPropagation();
            onPhotoTap(roomIndex, photoIdx);
          });
          marker.addEventListener('keydown', function (event) {
            if (event.key === 'Enter' || event.key === ' ') {
              event.preventDefault();
              event.stopPropagation();
              onPhotoTap(roomIndex, photoIdx);
            }
          });
        })(item.index, photoIndex);
        group.appendChild(marker);
        added = true;
      });
    });
    if (added) {
      svg.appendChild(group);
    }
  }

  window.TourPlan = {
    renderPlan: renderPlan,
    placedRooms: placedRooms,
    boundsOf: boundsOf,
    renderMinimap: renderMinimap
  };
})();
