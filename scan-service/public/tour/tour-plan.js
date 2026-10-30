(function () {
  'use strict';

  var NS = 'http://www.w3.org/2000/svg';
  var GAP_M = 0.4;
  var MIN_VIEWPORT = 240;
  var VIEWPORT_PADDING = 16;
  var PADDING = 24;
  var MARKER_RADIUS_PX = 7;
  var CLUSTER_RADIUS_PX = 11;
  var CLUSTER_DISTANCE_PX = 26;
  var HIT_RADIUS_PX = 22;
  var FLOOR_ROW_PX = 48;
  var selectedFloor = null;
  var ROTATE_GAIN = 1.2;
  var MIN_DIMENSION_EDGE_PX = 36;
  var DIMENSION_INSET_PX = 11;
  var COLLINEAR_DEG = 4;

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

    var floors = floorGroups(placed);
    var floorRow = null;
    if (floors.length > 1) {
      var keys = floors.map(function (group) { return group.key; });
      if (keys.indexOf(selectedFloor) === -1) {
        selectedFloor = defaultFloorKey(floors);
      }
      placed = placed.filter(function (item) { return floorKey(item.room) === selectedFloor; });
    }

    var svg = document.createElementNS(NS, 'svg');
    svg.classList.add('tour-plan-svg');
    svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', window.TourStrings.t('plan_aria'));
    viewport.appendChild(svg);

    if (floors.length > 1) {
      floorRow = buildFloorRow(floors, function (key) {
        selectedFloor = key;
        if (svg.parentNode) svg.parentNode.removeChild(svg);
        if (floorRow.parentNode) floorRow.parentNode.removeChild(floorRow);
        renderPlan(viewport, rooms, onRoomTap, onPhotoTap);
      });
      viewport.appendChild(floorRow);
    }

    var rect = viewport.getBoundingClientRect();
    var availableW = Math.max(MIN_VIEWPORT, rect.width - VIEWPORT_PADDING);
    var availableH = Math.max(MIN_VIEWPORT, rect.height - VIEWPORT_PADDING - (floorRow ? FLOOR_ROW_PX * 2 : 0));

    var bounds = boundsOf(placed);
    var planW = Math.max(bounds.maxX - bounds.minX, 0.1);
    var planH = Math.max(bounds.maxZ - bounds.minZ, 0.1);
    var fit = fitPlan(planW, planH, availableW - PADDING * 2, availableH - PADDING * 2);
    var scale = fit.scale;
    var canvasW = (fit.rotated ? planH : planW) * scale + PADDING * 2;
    var canvasH = (fit.rotated ? planW : planH) * scale + PADDING * 2;

    svg.setAttribute('width', canvasW);
    svg.setAttribute('height', canvasH);
    svg.setAttribute('viewBox', '0 0 ' + canvasW + ' ' + canvasH);

    function toPx(point) {
      if (fit.rotated) {
        return [
          (bounds.maxZ - point[1]) * scale + PADDING,
          (point[0] - bounds.minX) * scale + PADDING
        ];
      }
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
      renderDimensions(svg, item.points.map(toPx), item.points);

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

  function floorKey(room) {
    return typeof room.floor === 'string' ? room.floor.trim() : '';
  }

  function floorRank(name) {
    var n = name.toLowerCase();
    if (n === '') return 1000;
    if (/attic|zolder|roof|dak|loft/.test(n)) return 100;
    if (/basement|kelder|cellar|souterrain/.test(n)) return -10;
    if (/ground|begane|gelijkvloers/.test(n) || n === 'bg') return 0;
    var digits = n.match(/\d+/);
    if (digits) return parseInt(digits[0], 10);
    var ordinals = [['first', 1], ['eerste', 1], ['second', 2], ['tweede', 2], ['third', 3], ['derde', 3], ['fourth', 4], ['vierde', 4]];
    for (var i = 0; i < ordinals.length; i++) {
      if (n.indexOf(ordinals[i][0]) !== -1) return ordinals[i][1];
    }
    return 5;
  }

  function floorGroups(placed) {
    var groups = [];
    placed.forEach(function (item, order) {
      var key = floorKey(item.room);
      var existing = groups.filter(function (g) { return g.key === key; })[0];
      if (existing) {
        existing.rooms += 1;
        return;
      }
      groups.push({ key: key, rank: floorRank(key), order: order, rooms: 1 });
    });
    groups.sort(function (a, b) {
      return a.rank - b.rank || a.order - b.order;
    });
    return groups;
  }

  function defaultFloorKey(floors) {
    var best = floors[0];
    floors.forEach(function (group) {
      if (group.rank >= 0 && group.rank < 1000 && (best.rank < 0 || best.rank >= 1000 || group.rank < best.rank)) {
        best = group;
      }
    });
    return best.key;
  }

  function buildFloorRow(floors, onPick) {
    var row = document.createElement('div');
    row.className = 'tour-plan-floors';
    row.setAttribute('role', 'tablist');
    row.setAttribute('aria-label', window.TourStrings.t('plan_floors_aria'));
    floors.forEach(function (group) {
      var chip = document.createElement('button');
      chip.type = 'button';
      chip.className = 'tour-plan-floor-chip' + (group.key === selectedFloor ? ' is-active' : '');
      chip.setAttribute('role', 'tab');
      chip.setAttribute('aria-selected', group.key === selectedFloor ? 'true' : 'false');
      chip.textContent = group.key === '' ? window.TourStrings.t('plan_floor_other') : group.key;
      chip.addEventListener('click', function () {
        if (group.key !== selectedFloor) onPick(group.key);
      });
      row.appendChild(chip);
    });
    return row;
  }

  function fitPlan(planW, planH, innerW, innerH) {
    var straight = Math.min(innerW / planW, innerH / planH);
    var turned = Math.min(innerW / planH, innerH / planW);
    if (turned > straight * ROTATE_GAIN) {
      return { scale: turned, rotated: true };
    }
    return { scale: straight, rotated: false };
  }

  function formatMeters(value) {
    var text = value.toFixed(2);
    if (window.TourStrings.lang === 'nl') {
      text = text.replace('.', ',');
    }
    return text + ' m';
  }

  function wallRuns(pointsPx, pointsM) {
    var n = pointsPx.length;
    var runs = [];
    for (var i = 0; i < n; i++) {
      var a = pointsPx[i];
      var b = pointsPx[(i + 1) % n];
      var am = pointsM[i];
      var bm = pointsM[(i + 1) % n];
      var lengthM = Math.hypot(bm[0] - am[0], bm[1] - am[1]);
      if (lengthM < 1e-3) {
        continue;
      }
      var angle = Math.atan2(b[1] - a[1], b[0] - a[0]);
      var last = runs[runs.length - 1];
      if (last && Math.abs(angleDelta(last.angle, angle)) < COLLINEAR_DEG * Math.PI / 180) {
        last.b = b;
        last.lengthM += lengthM;
        continue;
      }
      runs.push({ a: a, b: b, angle: angle, lengthM: lengthM });
    }
    if (runs.length > 1) {
      var first = runs[0];
      var tail = runs[runs.length - 1];
      if (tail.b === first.a && Math.abs(angleDelta(tail.angle, first.angle)) < COLLINEAR_DEG * Math.PI / 180) {
        first.a = tail.a;
        first.lengthM += tail.lengthM;
        runs.pop();
      }
    }
    return runs;
  }

  function angleDelta(a, b) {
    var d = b - a;
    while (d > Math.PI) d -= 2 * Math.PI;
    while (d < -Math.PI) d += 2 * Math.PI;
    return d;
  }

  function renderDimensions(svg, pointsPx, pointsM) {
    var area = 0;
    for (var i = 0; i < pointsPx.length; i++) {
      var p = pointsPx[i];
      var q = pointsPx[(i + 1) % pointsPx.length];
      area += p[0] * q[1] - q[0] * p[1];
    }
    var inwardSign = area > 0 ? 1 : -1;
    wallRuns(pointsPx, pointsM).forEach(function (run) {
      var dx = run.b[0] - run.a[0];
      var dy = run.b[1] - run.a[1];
      var lengthPx = Math.hypot(dx, dy);
      if (lengthPx < MIN_DIMENSION_EDGE_PX) {
        return;
      }
      var nx = -dy / lengthPx * inwardSign;
      var ny = dx / lengthPx * inwardSign;
      var x = (run.a[0] + run.b[0]) / 2 + nx * DIMENSION_INSET_PX;
      var y = (run.a[1] + run.b[1]) / 2 + ny * DIMENSION_INSET_PX;
      var deg = run.angle * 180 / Math.PI;
      if (deg > 90) deg -= 180;
      if (deg <= -90) deg += 180;
      var text = document.createElementNS(NS, 'text');
      text.setAttribute('x', x.toFixed(1));
      text.setAttribute('y', y.toFixed(1));
      text.setAttribute('text-anchor', 'middle');
      text.setAttribute('dominant-baseline', 'middle');
      text.setAttribute('transform', 'rotate(' + deg.toFixed(1) + ' ' + x.toFixed(1) + ' ' + y.toFixed(1) + ')');
      text.classList.add('tour-plan-dim');
      text.textContent = formatMeters(run.lengthM);
      svg.appendChild(text);
    });
  }

  function clusterMarkers(markers) {
    var clusters = [];
    markers.forEach(function (marker) {
      var target = null;
      for (var i = 0; i < clusters.length; i++) {
        var c = clusters[i];
        if (c.roomIndex === marker.roomIndex && Math.hypot(c.seedX - marker.x, c.seedY - marker.y) <= CLUSTER_DISTANCE_PX) {
          target = c;
          break;
        }
      }
      if (!target) {
        clusters.push({ roomIndex: marker.roomIndex, label: marker.label, seedX: marker.x, seedY: marker.y, x: marker.x, y: marker.y, sumX: marker.x, sumY: marker.y, photoIndexes: [marker.photoIndex] });
        return;
      }
      target.photoIndexes.push(marker.photoIndex);
      target.sumX += marker.x;
      target.sumY += marker.y;
      target.x = target.sumX / target.photoIndexes.length;
      target.y = target.sumY / target.photoIndexes.length;
    });
    return clusters;
  }

  function renderMinimap(container, rooms, activeRoomId, activePhotoIndex) {
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
      var activePhotos = Array.isArray(active.room.photos) ? active.room.photos : [];
      var activePhoto = activePhotos[activePhotoIndex];
      var activePos = activePhoto && Array.isArray(activePhoto.position_m) ? activePhoto.position_m : null;
      if (activePos && activePos.length >= 2) {
        var px = Number(activePos[0]) + active.ox;
        var pz = Number(activePos[1]) + active.oz;
        if (isFinite(px) && isFinite(pz)) {
          cx = px;
          cz = pz;
        }
      }
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
    var markers = [];
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
        markers.push({ roomIndex: item.index, label: item.room.label || '', photoIndex: photoIndex, x: px[0], y: px[1] });
      });
    });
    if (markers.length === 0) {
      return;
    }
    clusterMarkers(markers).forEach(function (cluster) {
      var count = cluster.photoIndexes.length;
      var firstPhoto = Math.min.apply(null, cluster.photoIndexes);
      var node = document.createElementNS(NS, 'g');
      node.classList.add('tour-plan-photo-cluster');
      node.setAttribute('tabindex', '0');
      node.setAttribute('role', 'button');
      node.setAttribute('aria-label', count > 1
        ? cluster.label + ' ' + window.TourStrings.t('plan_photo_cluster', { count: count })
        : cluster.label + ' photo ' + (firstPhoto + 1));
      node.setAttribute('data-room-index', String(cluster.roomIndex));
      node.setAttribute('data-photo-index', String(firstPhoto));
      node.setAttribute('data-photo-count', String(count));
      var hit = document.createElementNS(NS, 'circle');
      hit.setAttribute('cx', cluster.x.toFixed(1));
      hit.setAttribute('cy', cluster.y.toFixed(1));
      hit.setAttribute('r', String(HIT_RADIUS_PX));
      hit.classList.add('tour-plan-photo-hit');
      node.appendChild(hit);
      var marker = document.createElementNS(NS, 'circle');
      marker.setAttribute('cx', cluster.x.toFixed(1));
      marker.setAttribute('cy', cluster.y.toFixed(1));
      marker.setAttribute('r', String(count > 1 ? CLUSTER_RADIUS_PX : MARKER_RADIUS_PX));
      marker.classList.add('tour-plan-photo-marker');
      node.appendChild(marker);
      if (count > 1) {
        var badge = document.createElementNS(NS, 'text');
        badge.setAttribute('x', cluster.x.toFixed(1));
        badge.setAttribute('y', cluster.y.toFixed(1));
        badge.setAttribute('text-anchor', 'middle');
        badge.setAttribute('dominant-baseline', 'central');
        badge.classList.add('tour-plan-photo-count');
        badge.textContent = String(count);
        node.appendChild(badge);
      }
      (function (roomIndex, photoIdx) {
        node.addEventListener('click', function (event) {
          event.stopPropagation();
          onPhotoTap(roomIndex, photoIdx);
        });
        node.addEventListener('keydown', function (event) {
          if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            event.stopPropagation();
            onPhotoTap(roomIndex, photoIdx);
          }
        });
      })(cluster.roomIndex, firstPhoto);
      group.appendChild(node);
    });
    svg.appendChild(group);
  }

  window.TourPlan = {
    renderPlan: renderPlan,
    placedRooms: placedRooms,
    boundsOf: boundsOf,
    fitPlan: fitPlan,
    floorGroups: floorGroups,
    wallRuns: wallRuns,
    clusterMarkers: clusterMarkers,
    renderMinimap: renderMinimap
  };
})();
