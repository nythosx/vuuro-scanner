(function () {
  'use strict';

  var TEXELS_PER_M = 80;
  var TEXEL_BUDGET_DESKTOP = 16000000;
  var TEXEL_BUDGET_SMALL = 6000000;
  var density = TEXELS_PER_M;
  var MAX_TEXTURE_EDGE = 1024;
  var SAMPLE_EDGE_PX = 640;
  var EYE_HEIGHT_M = 1.4;
  var MIN_EYE_M = 0.6;
  var MAX_EYE_M = 2.4;
  var SLICE_MS = 8;
  var DEFAULT_HEIGHT_M = 2.4;
  var EXTERIOR_INSET_M = 0.077;
  var INTERIOR_INSET_M = 0.032;
  var FLOOR_LIFT_M = 0.004;
  var SHARED_EDGE_M = 0.4;
  var SHARED_SAMPLES = 5;
  var SAME_FLOOR_M = 0.5;
  var EDGE_FEATHER = 0.12;
  var WEIGHT_POWER = 4;
  var WALL_RGB = [242, 240, 235];
  var FLOOR_RGB = [230, 219, 199];

  function poseFor(roomPoses, roomId) {
    if (!Array.isArray(roomPoses)) return null;
    for (var i = 0; i < roomPoses.length; i++) {
      var p = roomPoses[i];
      if (p && p.room_id === roomId && isFinite(Number(p.origin_x)) && isFinite(Number(p.origin_z))) {
        return {
          ox: Number(p.origin_x),
          oz: Number(p.origin_z),
          cos: Math.cos(Number(p.rotation_rad) || 0),
          sin: Math.sin(Number(p.rotation_rad) || 0),
          y: Number(p.base_y) || 0
        };
      }
    }
    return null;
  }

  function toWorld(pose, x, z) {
    return [x * pose.cos - z * pose.sin + pose.ox, x * pose.sin + z * pose.cos + pose.oz];
  }

  function outlineOf(room) {
    if (!room || !Array.isArray(room.outline_m) || room.outline_m.length < 3) return null;
    var pts = room.outline_m.map(function (p) { return [Number(p[0]) || 0, Number(p[1]) || 0]; });
    return pts;
  }

  function signedArea(pts) {
    var a = 0;
    for (var i = 0; i < pts.length; i++) {
      var p = pts[i];
      var q = pts[(i + 1) % pts.length];
      a += p[0] * q[1] - q[0] * p[1];
    }
    return a / 2;
  }

  function segmentDistance(px, pz, ax, az, bx, bz) {
    var dx = bx - ax;
    var dz = bz - az;
    var len2 = dx * dx + dz * dz;
    var t = len2 > 0 ? Math.max(0, Math.min(1, ((px - ax) * dx + (pz - az) * dz) / len2)) : 0;
    var ex = ax + dx * t - px;
    var ez = az + dz * t - pz;
    return Math.sqrt(ex * ex + ez * ez);
  }

  function wallEdges(rooms, roomPoses) {
    var edges = [];
    rooms.forEach(function (room, roomIndex) {
      var pose = poseFor(roomPoses, room.room_id);
      var pts = outlineOf(room);
      if (!pose || !pts) return;
      var inward = signedArea(pts) >= 0 ? 1 : -1;
      var open = Array.isArray(room.open_edges) ? room.open_edges : [];
      for (var i = 0; i < pts.length; i++) {
        if (open.indexOf(i) !== -1) continue;
        var a = pts[i];
        var b = pts[(i + 1) % pts.length];
        var dx = b[0] - a[0];
        var dz = b[1] - a[1];
        var len = Math.sqrt(dx * dx + dz * dz);
        if (len < 1e-6) continue;
        var nx = -dz / len * inward;
        var nz = dx / len * inward;
        var wa = toWorld(pose, a[0], a[1]);
        var wb = toWorld(pose, b[0], b[1]);
        edges.push({
          roomIndex: roomIndex,
          index: i,
          a: a,
          b: b,
          len: len,
          nx: nx,
          nz: nz,
          ax: wa[0],
          az: wa[1],
          bx: wb[0],
          bz: wb[1],
          wnx: nx * pose.cos - nz * pose.sin,
          wnz: nx * pose.sin + nz * pose.cos,
          y: pose.y,
          exterior: true
        });
      }
    });
    edges.forEach(function (edge) {
      var shared = 0;
      for (var s = 0; s < SHARED_SAMPLES; s++) {
        var t = (s + 0.5) / SHARED_SAMPLES;
        var px = edge.ax + (edge.bx - edge.ax) * t;
        var pz = edge.az + (edge.bz - edge.az) * t;
        for (var k = 0; k < edges.length; k++) {
          var other = edges[k];
          if (other.roomIndex === edge.roomIndex || Math.abs(other.y - edge.y) > SAME_FLOOR_M) continue;
          if (segmentDistance(px, pz, other.ax, other.az, other.bx, other.bz) < SHARED_EDGE_M) {
            shared++;
            break;
          }
        }
      }
      edge.exterior = shared * 2 < SHARED_SAMPLES;
    });
    return edges;
  }

  function nearestEdge(edges, x, z, maxDistance) {
    var best = null;
    var bestDistance = maxDistance;
    for (var i = 0; i < edges.length; i++) {
      var e = edges[i];
      var d = segmentDistance(x, z, e.ax, e.az, e.bx, e.bz);
      if (d < bestDistance) {
        bestDistance = d;
        best = e;
      }
    }
    return best;
  }

  function normalize(v) {
    var l = Math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) || 1;
    return [v[0] / l, v[1] / l, v[2] / l];
  }

  function cameraFor(photo) {
    var m = photo.camera_transform;
    var k = photo.intrinsics;
    if (!Array.isArray(m) || m.length !== 16 || !Array.isArray(k) || k.length !== 4) return null;
    for (var i = 0; i < 16; i++) {
      if (typeof m[i] !== 'number' || !isFinite(m[i])) return null;
    }
    if (!(k[0] > 0 && k[1] > 0 && k[2] > 0 && k[3] > 0)) return null;
    var c0 = normalize([m[0], m[1], m[2]]);
    var c1 = normalize([m[4], m[5], m[6]]);
    var b = normalize([m[8], m[9], m[10]]);
    var fwd = [-b[0], -b[1], -b[2]];
    var right;
    var up;
    if (Math.abs(m[5]) > Math.abs(m[1])) {
      right = m[5] >= 0 ? c0 : [-c0[0], -c0[1], -c0[2]];
      up = m[5] >= 0 ? c1 : [-c1[0], -c1[1], -c1[2]];
    } else if (m[1] <= 0) {
      right = c1;
      up = [-c0[0], -c0[1], -c0[2]];
    } else {
      right = [-c1[0], -c1[1], -c1[2]];
      up = c0;
    }
    var y = m[13] >= MIN_EYE_M && m[13] <= MAX_EYE_M ? m[13] : EYE_HEIGHT_M;
    return { x: m[12], y: y, z: m[14], fwd: fwd, right: right, up: up, k: k };
  }

  function loadSample(url) {
    return new Promise(function (resolve) {
      var img = new Image();
      img.decoding = 'async';
      img.onload = function () {
        var w = img.naturalWidth;
        var h = img.naturalHeight;
        if (!w || !h) {
          resolve(null);
          return;
        }
        var scale = Math.min(1, SAMPLE_EDGE_PX / Math.max(w, h));
        var cw = Math.max(1, Math.round(w * scale));
        var ch = Math.max(1, Math.round(h * scale));
        var canvas = document.createElement('canvas');
        canvas.width = cw;
        canvas.height = ch;
        var ctx = canvas.getContext('2d', { willReadFrequently: true });
        if (!ctx) {
          resolve(null);
          return;
        }
        ctx.drawImage(img, 0, 0, cw, ch);
        try {
          resolve({ data: ctx.getImageData(0, 0, cw, ch).data, w: cw, h: ch, naturalW: w });
        } catch (err) {
          resolve(null);
        }
      };
      img.onerror = function () { resolve(null); };
      img.src = url;
    });
  }

  function prepareCamera(cam, sample) {
    var k = cam.k;
    var fx = k[0];
    var fy = k[1];
    var cx = k[2];
    var cy = k[3];
    var ref = sample.naturalW / (2 * cx);
    if (Math.abs(ref - 1) > 0.2) {
      fx *= ref;
      fy *= ref;
      cx *= ref;
      cy *= ref;
    }
    var s = sample.w / sample.naturalW;
    cam.fx = fx * s;
    cam.fy = fy * s;
    cam.cx = cx * s;
    cam.cy = cy * s;
    cam.sample = sample;
    return cam;
  }

  function crosses(ax, az, bx, bz, cx, cz, dx, dz) {
    var rx = bx - ax;
    var rz = bz - az;
    var sx = dx - cx;
    var sz = dz - cz;
    var den = rx * sz - rz * sx;
    if (Math.abs(den) < 1e-12) return false;
    var t = ((cx - ax) * sz - (cz - az) * sx) / den;
    var u = ((cx - ax) * rz - (cz - az) * rx) / den;
    return t > 1e-3 && t < 0.985 && u >= 0 && u <= 1;
  }

  function visible(outline, skipEdge, cam, x, z) {
    for (var i = 0; i < outline.length; i++) {
      if (i === skipEdge) continue;
      var a = outline[i];
      var b = outline[(i + 1) % outline.length];
      if (crosses(cam.x, cam.z, x, z, a[0], a[1], b[0], b[1])) return false;
    }
    return true;
  }

  function samplePoint(cams, outline, skipEdge, px, py, pz, n, out) {
    var r = 0;
    var g = 0;
    var bl = 0;
    var total = 0;
    for (var i = 0; i < cams.length; i++) {
      var cam = cams[i];
      var vx = px - cam.x;
      var vy = py - cam.y;
      var vz = pz - cam.z;
      var depth = vx * cam.fwd[0] + vy * cam.fwd[1] + vz * cam.fwd[2];
      if (depth < 0.05) continue;
      var ix = cam.cx + cam.fx * (vx * cam.right[0] + vy * cam.right[1] + vz * cam.right[2]) / depth;
      var iy = cam.cy - cam.fy * (vx * cam.up[0] + vy * cam.up[1] + vz * cam.up[2]) / depth;
      var s = cam.sample;
      if (ix < 0 || iy < 0 || ix > s.w - 1 || iy > s.h - 1) continue;
      var edge = Math.min(ix / s.w, 1 - ix / s.w, iy / s.h, 1 - iy / s.h);
      var feather = Math.min(1, edge / EDGE_FEATHER);
      var dist = Math.sqrt(vx * vx + vy * vy + vz * vz);
      var facing = -(vx * n[0] + vy * n[1] + vz * n[2]) / dist;
      if (facing <= 0.05) continue;
      var w = Math.pow(feather * facing / (1 + dist * 0.15), WEIGHT_POWER);
      if (w < 1e-6) continue;
      if (!visible(outline, skipEdge, cam, px, pz)) continue;
      var x0 = Math.floor(ix);
      var y0 = Math.floor(iy);
      var fx = ix - x0;
      var fy = iy - y0;
      var x1 = Math.min(s.w - 1, x0 + 1);
      var y1 = Math.min(s.h - 1, y0 + 1);
      var d = s.data;
      var i00 = (y0 * s.w + x0) * 4;
      var i10 = (y0 * s.w + x1) * 4;
      var i01 = (y1 * s.w + x0) * 4;
      var i11 = (y1 * s.w + x1) * 4;
      var w00 = (1 - fx) * (1 - fy);
      var w10 = fx * (1 - fy);
      var w01 = (1 - fx) * fy;
      var w11 = fx * fy;
      r += w * (d[i00] * w00 + d[i10] * w10 + d[i01] * w01 + d[i11] * w11);
      g += w * (d[i00 + 1] * w00 + d[i10 + 1] * w10 + d[i01 + 1] * w01 + d[i11 + 1] * w11);
      bl += w * (d[i00 + 2] * w00 + d[i10 + 2] * w10 + d[i01 + 2] * w01 + d[i11 + 2] * w11);
      total += w;
    }
    if (total <= 0) return false;
    out[0] = r / total;
    out[1] = g / total;
    out[2] = bl / total;
    return true;
  }

  function pointInPolygon(pts, x, z) {
    var inside = false;
    for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      var a = pts[i];
      var b = pts[j];
      if ((a[1] > z) !== (b[1] > z) && x < (b[0] - a[0]) * (z - a[1]) / (b[1] - a[1]) + a[0]) {
        inside = !inside;
      }
    }
    return inside;
  }

  function textureSize(meters) {
    return Math.max(4, Math.min(MAX_TEXTURE_EDGE, Math.round(meters * density)));
  }

  function sliceTask(tw, th, paintRow, toPart) {
    var canvas = document.createElement('canvas');
    canvas.width = tw;
    canvas.height = th;
    var ctx = canvas.getContext('2d');
    var image = ctx.createImageData(tw, th);
    var stats = { painted: 0 };
    var row = 0;
    return function () {
      var started = Date.now();
      do {
        paintRow(image.data, row, stats);
        row++;
      } while (row < th && Date.now() - started < SLICE_MS);
      if (row < th) return null;
      if (stats.painted === 0) return { part: null };
      ctx.putImageData(image, 0, 0);
      return { part: toPart(canvas) };
    };
  }

  function wallTask(edge, height, outline, cams, toPart) {
    var tw = textureSize(edge.len);
    var th = textureSize(height);
    var ux = (edge.b[0] - edge.a[0]) / edge.len;
    var uz = (edge.b[1] - edge.a[1]) / edge.len;
    var n = [edge.nx, 0, edge.nz];
    var out = [0, 0, 0];
    return sliceTask(tw, th, function (px, row, stats) {
      var y = height * (1 - (row + 0.5) / th);
      for (var col = 0; col < tw; col++) {
        var t = edge.len * (col + 0.5) / tw;
        var x = edge.a[0] + ux * t + edge.nx * 0.01;
        var z = edge.a[1] + uz * t + edge.nz * 0.01;
        var o = (row * tw + col) * 4;
        if (samplePoint(cams, outline, edge.index, x, y, z, n, out)) {
          px[o] = out[0];
          px[o + 1] = out[1];
          px[o + 2] = out[2];
          stats.painted++;
        } else {
          px[o] = WALL_RGB[0];
          px[o + 1] = WALL_RGB[1];
          px[o + 2] = WALL_RGB[2];
        }
        px[o + 3] = 255;
      }
    }, toPart);
  }

  function floorTask(outline, cams, bounds, toPart) {
    var w = bounds.maxX - bounds.minX;
    var d = bounds.maxZ - bounds.minZ;
    var scale = Math.min(density, MAX_TEXTURE_EDGE / Math.max(w, d));
    var tw = Math.max(4, Math.round(w * scale));
    var th = Math.max(4, Math.round(d * scale));
    var n = [0, 1, 0];
    var out = [0, 0, 0];
    return sliceTask(tw, th, function (px, row, stats) {
      var z = bounds.minZ + d * (row + 0.5) / th;
      for (var col = 0; col < tw; col++) {
        var x = bounds.minX + w * (col + 0.5) / tw;
        var o = (row * tw + col) * 4;
        if (!pointInPolygon(outline, x, z)) {
          px[o + 3] = 0;
          continue;
        }
        if (samplePoint(cams, outline, -1, x, 0, z, n, out)) {
          px[o] = out[0];
          px[o + 1] = out[1];
          px[o + 2] = out[2];
          stats.painted++;
        } else {
          px[o] = FLOOR_RGB[0];
          px[o + 1] = FLOOR_RGB[1];
          px[o + 2] = FLOOR_RGB[2];
        }
        px[o + 3] = 255;
      }
    }, toPart);
  }

  function quadPart(pose, corners, normal, fade, canvas) {
    var positions = new Float32Array(12);
    var normals = new Float32Array(12);
    var fades = new Float32Array(12);
    var wn = [normal[0] * pose.cos - normal[2] * pose.sin, normal[1], normal[0] * pose.sin + normal[2] * pose.cos];
    for (var i = 0; i < 4; i++) {
      var w = toWorld(pose, corners[i][0], corners[i][2]);
      positions[i * 3] = w[0];
      positions[i * 3 + 1] = corners[i][1] + pose.y;
      positions[i * 3 + 2] = w[1];
      normals[i * 3] = wn[0];
      normals[i * 3 + 1] = wn[1];
      normals[i * 3 + 2] = wn[2];
      fades[i * 3] = fade[0];
      fades[i * 3 + 1] = fade[1];
      fades[i * 3 + 2] = fade[2];
    }
    return {
      positions: positions,
      normals: normals,
      uvs: new Float32Array([0, 1, 1, 1, 1, 0, 0, 0]),
      fades: fades,
      indices: new Uint16Array([0, 1, 2, 0, 2, 3]),
      canvas: canvas,
      painted: true
    };
  }

  function roomJobs(room, roomIndex, pose, edges, buildUrl) {
    var outline = outlineOf(room);
    var photos = (Array.isArray(room.photos) ? room.photos : []).filter(function (p) {
      return typeof p.url === 'string' && p.url !== '' && cameraFor(p) !== null;
    });
    if (!outline || photos.length === 0) return null;
    var height = Number(room.height_m);
    if (!isFinite(height) || height <= 0) height = DEFAULT_HEIGHT_M;
    var roomEdges = edges.filter(function (e) { return e.roomIndex === roomIndex; });
    return Promise.all(photos.map(function (photo) {
      return loadSample(buildUrl(photo.url)).then(function (sample) {
        return sample ? prepareCamera(cameraFor(photo), sample) : null;
      });
    })).then(function (cams) {
      cams = cams.filter(Boolean);
      if (cams.length === 0) return [];
      var jobs = [];
      var bounds = { minX: Infinity, maxX: -Infinity, minZ: Infinity, maxZ: -Infinity };
      outline.forEach(function (p) {
        bounds.minX = Math.min(bounds.minX, p[0]);
        bounds.maxX = Math.max(bounds.maxX, p[0]);
        bounds.minZ = Math.min(bounds.minZ, p[1]);
        bounds.maxZ = Math.max(bounds.maxZ, p[1]);
      });
      jobs.push(floorTask(outline, cams, bounds, function (canvas) {
        var y = FLOOR_LIFT_M;
        return quadPart(pose, [
          [bounds.minX, y, bounds.maxZ],
          [bounds.maxX, y, bounds.maxZ],
          [bounds.maxX, y, bounds.minZ],
          [bounds.minX, y, bounds.minZ]
        ], [0, 1, 0], [0, 0, 0], canvas);
      }));
      roomEdges.forEach(function (edge) {
        jobs.push(wallTask(edge, height, outline, cams, function (canvas) {
          var inset = edge.exterior ? EXTERIOR_INSET_M : INTERIOR_INSET_M;
          var ax = edge.a[0] + edge.nx * inset;
          var az = edge.a[1] + edge.nz * inset;
          var bx = edge.b[0] + edge.nx * inset;
          var bz = edge.b[1] + edge.nz * inset;
          return quadPart(pose, [
            [ax, 0, az],
            [bx, 0, bz],
            [bx, height, bz],
            [ax, height, az]
          ], [edge.nx, 0, edge.nz], [edge.wnx, edge.wnz, edge.exterior ? 1 : 0], canvas);
        }));
      });
      return jobs;
    });
  }

  function texelBudget() {
    var memory = Number(navigator.deviceMemory);
    var coarse = window.matchMedia && window.matchMedia('(pointer: coarse)').matches;
    return coarse || (isFinite(memory) && memory > 0 && memory <= 4) ? TEXEL_BUDGET_SMALL : TEXEL_BUDGET_DESKTOP;
  }

  function paintedArea(rooms) {
    var area = 0;
    rooms.forEach(function (room) {
      var outline = outlineOf(room);
      if (!outline) return;
      var height = Number(room.height_m);
      if (!isFinite(height) || height <= 0) height = DEFAULT_HEIGHT_M;
      var minX = Infinity, maxX = -Infinity, minZ = Infinity, maxZ = -Infinity, perimeter = 0;
      for (var i = 0; i < outline.length; i++) {
        var a = outline[i];
        var b = outline[(i + 1) % outline.length];
        minX = Math.min(minX, a[0]);
        maxX = Math.max(maxX, a[0]);
        minZ = Math.min(minZ, a[1]);
        maxZ = Math.max(maxZ, a[1]);
        perimeter += Math.hypot(b[0] - a[0], b[1] - a[1]);
      }
      area += (maxX - minX) * (maxZ - minZ) + perimeter * height;
    });
    return area;
  }

  function densityFor(rooms) {
    var area = paintedArea(rooms);
    if (!(area > 0)) return TEXELS_PER_M;
    return Math.max(8, Math.min(TEXELS_PER_M, Math.sqrt(texelBudget() / area)));
  }

  function paint(rooms, roomPoses, buildUrl, onPart) {
    var cancelled = false;
    density = densityFor(rooms);
    var edges = wallEdges(rooms, roomPoses);
    var pending = [];
    rooms.forEach(function (room, roomIndex) {
      var pose = poseFor(roomPoses, room.room_id);
      if (!pose) return;
      var jobs = roomJobs(room, roomIndex, pose, edges, buildUrl);
      if (jobs) pending.push(jobs);
    });
    Promise.all(pending).then(function (lists) {
      var queue = [].concat.apply([], lists);
      var step = function () {
        if (cancelled || queue.length === 0) return;
        var result = queue[0]();
        if (result) {
          queue.shift();
          if (result.part && !cancelled) onPart(result.part);
        }
        setTimeout(step, 0);
      };
      step();
    });
    return function () { cancelled = true; };
  }

  window.TourDollhousePaint = {
    paint: paint,
    wallEdges: wallEdges,
    nearestEdge: nearestEdge,
    densityFor: densityFor
  };
})();
