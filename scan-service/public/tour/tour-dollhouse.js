(function () {
  'use strict';

  var HOTSPOT_PIXEL_SIZE = 14;
  var SPOT_RADIUS_M = 0.32;
  var SPOT_MIN_PX = 14;
  var SPOT_MAX_PX = 64;
  var SPOT_LIFT_M = 0.02;
  var FRAME_MARGIN = 0.98;
  var FLY_MS = 750;
  var FOV_Y = Math.PI / 3.5;
  var TAP_SLOP_PX = 6;
  var TAP_MAX_MS = 450;
  var TAP_FADE_CUTOFF = 0.2;
  var MAX_OCCLUSION_TRIANGLES = 8000;
  var OCCLUSION_CLEARANCE_M = 0.05;
  var FADE_EDGE_DISTANCE_M = 0.45;
  var FADE_START = 0.05;

  var activeViewer = null;

  function stop() {
    if (activeViewer) {
      activeViewer.stop();
      activeViewer = null;
    }
  }

  function render(viewport, url, rooms, onBackToPlan, onHotspotTap, buildUrl, options) {
    var opts = options || {};
    stop();
    if (!url) {
      renderFallback(viewport, onBackToPlan, window.TourStrings.t('dollhouse_unavailable'));
      return;
    }
    renderLoading(viewport, onBackToPlan);
    var fetchUrl = typeof buildUrl === 'function' ? buildUrl(url) : url;
    fetch(fetchUrl, { credentials: 'omit' })
      .then(function (res) {
        if (!res.ok) {
          throw new Error('HTTP ' + res.status);
        }
        return res.arrayBuffer();
      })
      .then(function (buffer) {
        var gltf = window.TourDollhouseGlb.parse(buffer);
        var hotspots = buildHotspots(rooms || [], gltf.roomPoses, !!opts.onStandTap);
        var stage = buildStage(viewport, onBackToPlan);
        var viewer = new Viewer(stage.canvas, gltf, hotspots, stage.hotspotLayer, onHotspotTap, rooms || []);
        viewer.onStandTap = opts.onStandTap || null;
        viewer.spawnRoomLabels(buildRoomLabels(rooms || [], gltf.roomPoses));
        activeViewer = viewer;
        viewer.start();
        if (window.TourDollhousePaint && typeof buildUrl === 'function') {
          viewer.cancelPaint = window.TourDollhousePaint.paint(rooms || [], gltf.roomPoses, buildUrl, function (part) {
            viewer.addPart(part);
          });
        }
      })
      .catch(function (err) {
        renderFallback(viewport, onBackToPlan, window.TourStrings.t('dollhouse_load_failed', { reason: err && err.message ? err.message : 'unknown error' }));
      });
  }

  function renderLoading(viewport, onBackToPlan) {
    clearNode(viewport);
    var stage = document.createElement('div');
    stage.className = 'tour-dollhouse';
    var p = document.createElement('p');
    p.className = 'tour-status';
    p.textContent = window.TourStrings.t('loading_3d');
    stage.appendChild(p);
    viewport.appendChild(stage);
  }

  function renderFallback(viewport, onBackToPlan, message) {
    clearNode(viewport);
    var stage = document.createElement('div');
    stage.className = 'tour-dollhouse';
    var p = document.createElement('p');
    p.className = 'tour-status';
    p.textContent = message;
    stage.appendChild(p);
    viewport.appendChild(stage);
  }

  function buildStage(viewport, onBackToPlan) {
    clearNode(viewport);
    var stage = document.createElement('div');
    stage.className = 'tour-dollhouse';

    var canvas = document.createElement('canvas');
    canvas.className = 'tour-dollhouse-canvas';
    stage.appendChild(canvas);

    var vignette = document.createElement('div');
    vignette.className = 'tour-dollhouse-vignette';
    vignette.setAttribute('aria-hidden', 'true');
    stage.appendChild(vignette);

    var hotspotLayer = document.createElement('div');
    hotspotLayer.className = 'tour-dollhouse-hotspots';
    stage.appendChild(hotspotLayer);

    viewport.appendChild(stage);

    return { stage: stage, canvas: canvas, hotspotLayer: hotspotLayer };
  }

  function clearNode(node) {
    while (node.firstChild) {
      node.removeChild(node.firstChild);
    }
  }

  function poseFor(roomPoses, room) {
    if (!Array.isArray(roomPoses) || !room || typeof room.room_id !== 'string') {
      return null;
    }
    for (var i = 0; i < roomPoses.length; i++) {
      var pose = roomPoses[i];
      if (pose && pose.room_id === room.room_id
        && isFinite(Number(pose.origin_x)) && isFinite(Number(pose.origin_z))) {
        return pose;
      }
    }
    return null;
  }

  function roomPlacements(rooms, roomPoses) {
    var allHaveOrigin = rooms.length > 0 && rooms.every(function (room) {
      var origin = room.structure_origin_m;
      return Array.isArray(origin) && origin.length === 2
        && isFinite(Number(origin[0])) && isFinite(Number(origin[1]));
    });
    var out = [];
    var cursorX = 0;
    for (var i = 0; i < rooms.length; i++) {
      var room = rooms[i];
      var outline = Array.isArray(room.outline_m) ? room.outline_m : [];
      var ox, oz;
      if (allHaveOrigin) {
        ox = Number(room.structure_origin_m[0]);
        oz = Number(room.structure_origin_m[1]);
      } else {
        var xs = outline.map(function (p) { return Number(p[0]) || 0; });
        var minX = xs.length ? Math.min.apply(null, xs) : 0;
        var maxX = xs.length ? Math.max.apply(null, xs) : minX;
        ox = cursorX;
        oz = 0;
        cursorX += (maxX - minX) + 0.4;
      }
      var height = Number(room.height_m);
      if (!isFinite(height) || height <= 0) {
        height = 2.4;
      }
      out.push(placement(room, outline, ox, oz, height, poseFor(roomPoses, room)));
    }
    return out;
  }

  function placement(room, outline, ox, oz, height, pose) {
    return {
      room: room,
      outline: outline,
      height: height,
      toWorld: function (px, pz, y) {
        if (pose) {
          var rotation = Number(pose.rotation_rad) || 0;
          var cos = Math.cos(rotation);
          var sin = Math.sin(rotation);
          return [
            px * cos - pz * sin + Number(pose.origin_x),
            (Number(pose.base_y) || 0) + y,
            px * sin + pz * cos + Number(pose.origin_z)
          ];
        }
        return [px + ox, y, pz + oz];
      }
    };
  }

  function polygonCentroid(outline) {
    var area = 0;
    var cx = 0;
    var cz = 0;
    for (var i = 0; i < outline.length; i++) {
      var a = outline[i];
      var b = outline[(i + 1) % outline.length];
      var ax = Number(a[0]) || 0;
      var az = Number(a[1]) || 0;
      var bx = Number(b[0]) || 0;
      var bz = Number(b[1]) || 0;
      var cross = ax * bz - bx * az;
      area += cross;
      cx += (ax + bx) * cross;
      cz += (az + bz) * cross;
    }
    if (Math.abs(area) < 1e-6) {
      var sx = 0;
      var sz = 0;
      outline.forEach(function (p) { sx += Number(p[0]) || 0; sz += Number(p[1]) || 0; });
      return [sx / outline.length, sz / outline.length];
    }
    return [cx / (3 * area), cz / (3 * area)];
  }

  function buildRoomLabels(rooms, roomPoses) {
    var labels = [];
    roomPlacements(rooms, roomPoses).forEach(function (item) {
      var text = typeof item.room.label === 'string' ? item.room.label.trim() : '';
      if (!text || item.outline.length < 3) {
        return;
      }
      var c = polygonCentroid(item.outline);
      if (window.TourDollhouseMath.distanceOutside(c, item.outline) > 0) {
        return;
      }
      labels.push({ text: text, world: item.toWorld(c[0], c[1], SPOT_LIFT_M) });
    });
    return labels;
  }

  function walkableStands(room) {
    if (!window.TourPlan || typeof window.TourPlan.capturedStands !== 'function') {
      return [];
    }
    return window.TourPlan.capturedStands(room).filter(function (stand) {
      return (stand.photo_ids || []).length > 1;
    });
  }

  function buildHotspots(rooms, roomPoses, withSpots) {
    var hotspots = [];
    var placements = roomPlacements(rooms, roomPoses);
    for (var i = 0; i < placements.length; i++) {
      var item = placements[i];
      var room = item.room;
      var outline = item.outline;
      var height = item.height;
      var covered = {};
      if (withSpots) {
        walkableStands(room).forEach(function (stand, standIndex) {
          (stand.photo_ids || []).forEach(function (id) { covered[String(id)] = true; });
          hotspots.push({
            kind: 'spot',
            roomIndex: i,
            standId: stand.stand_id,
            world: item.toWorld(Number(stand.center_m[0]), Number(stand.center_m[1]), SPOT_LIFT_M),
            roomHeight: height,
            label: window.TourStandStrings.t('spot_label', { room: room.label || '', number: standIndex + 1 })
          });
        });
      }
      var photos = Array.isArray(room.photos) ? room.photos : [];
      for (var p = 0; p < photos.length; p++) {
        if (photos[p].photo_id !== undefined && photos[p].photo_id !== null && covered[String(photos[p].photo_id)]) {
          continue;
        }
        var pos = photos[p].position_m;
        if (!Array.isArray(pos) || pos.length < 2) {
          continue;
        }
        var px = Number(pos[0]);
        var pz = Number(pos[1]);
        if (!isFinite(px) || !isFinite(pz)) {
          continue;
        }
        if (window.TourDollhouseMath.distanceOutside([px, pz], outline) > window.TourDollhouseMath.OUTSIDE_TOLERANCE_M) {
          continue;
        }
        var world = item.toWorld(px, pz, height / 2);
        hotspots.push({
          kind: 'photo',
          roomIndex: i,
          photoIndex: p,
          photoId: photos[p].photo_id !== undefined && photos[p].photo_id !== null ? String(photos[p].photo_id) : '',
          world: world,
          roomHeight: height,
          label: (room.label || '') + ' photo ' + (p + 1)
        });
      }
    }
    return hotspots;
  }

  function Viewer(canvas, mesh, hotspots, hotspotLayer, onHotspotTap, rooms) {
    this.canvas = canvas;
    var contextOptions = { antialias: true, alpha: false };
    this.roomLabelElements = [];
    this.onStandTap = null;
    this.hideBase = false;
    this.gl = canvas.getContext('webgl2', contextOptions) || canvas.getContext('webgl', contextOptions);
    if (!this.gl) {
      throw new Error(window.TourStrings.t('webgl_unavailable'));
    }
    this.uintIndices = (typeof WebGL2RenderingContext !== 'undefined' && this.gl instanceof WebGL2RenderingContext)
      || !!this.gl.getExtension('OES_element_index_uint');
    this.mesh = mesh;
    this.hotspots = hotspots;
    this.hotspotLayer = hotspotLayer;
    this.onHotspotTap = onHotspotTap || function () {};
    this.yaw = Math.PI * 0.25;
    this.pitch = Math.PI * 0.22;
    this.distance = 20;
    this.target = [0, 0, 0];
    this.mvp = null;
    this.running = false;
    this.destroyed = false;
    this.dragging = false;
    this.lastPointer = null;
    this.activePointers = {};
    this.pinchDistance = null;
    this.pinchMidpoint = null;
    this.hotspotElements = [];
    this.tapStart = null;
    this.photoTargets = {};
    for (var h = 0; h < hotspots.length; h++) {
      if (hotspots[h].photoId !== '' && !this.photoTargets[hotspots[h].photoId]) {
        this.photoTargets[hotspots[h].photoId] = { roomIndex: hotspots[h].roomIndex, photoIndex: hotspots[h].photoIndex };
      }
    }
    this.parts = [];
    this.imageTextures = {};
    this.paintedTextures = [];
    this.cancelPaint = null;
    this.edges = window.TourDollhousePaint ? window.TourDollhousePaint.wallEdges(rooms || [], mesh.roomPoses) : [];
    this.initGl();
    this.frameToBounds();
    this.bindControls();
    this.spawnHotspots();
  }

  Viewer.prototype.initGl = function () {
    var gl = this.gl;
    var vert = [
      'attribute vec3 aPos;',
      'attribute vec3 aNrm;',
      'attribute vec4 aCol;',
      'attribute vec2 aUV;',
      'attribute vec3 aFade;',
      'uniform mat4 uMvp;',
      'varying vec3 vNrm;',
      'varying vec4 vCol;',
      'varying vec2 vUV;',
      'varying vec3 vFade;',
      'varying vec3 vPos;',
      'void main() {',
      '  gl_Position = uMvp * vec4(aPos, 1.0);',
      '  vNrm = aNrm;',
      '  vCol = aCol;',
      '  vUV = aUV;',
      '  vFade = aFade;',
      '  vPos = aPos;',
      '}'
    ].join('\n');
    var frag = [
      'precision mediump float;',
      'varying vec3 vNrm;',
      'varying vec4 vCol;',
      'varying vec2 vUV;',
      'varying vec3 vFade;',
      'varying vec3 vPos;',
      'uniform sampler2D uSampler;',
      'uniform float uUseTexture;',
      'uniform float uPainted;',
      'uniform float uPass;',
      'uniform vec3 uEye;',
      'void main() {',
      '  vec3 n = normalize(vNrm);',
      '  if (uPainted > 0.5 && dot(n, uEye - vPos) < 0.0) discard;',
      '  vec3 light = normalize(vec3(0.35, 0.85, 0.4));',
      '  float diff = max(dot(n, light), 0.0);',
      '  float shade = uPainted > 0.5 ? 0.9 + diff * 0.12 : 0.55 + diff * 0.55;',
      '  vec4 base = uUseTexture > 0.5 ? texture2D(uSampler, vUV) : vCol;',
      '  if (base.a < 0.5) discard;',
      '  float alpha = 1.0;',
      '  if (vFade.z > 0.5) {',
      '    vec2 toEye = uEye.xz - vPos.xz;',
      '    float len = length(toEye);',
      '    float side = len > 0.0001 ? dot(vFade.xy, toEye / len) : 0.0;',
      '    alpha = mix(1.0, 0.1, smoothstep(' + FADE_START.toFixed(2) + ', 0.35, -side));',
      '  }',
      '  if (uPass < 0.5 && alpha < 0.999) discard;',
      '  if (uPass > 0.5 && alpha >= 0.999) discard;',
      '  gl_FragColor = vec4(base.rgb * shade, alpha);',
      '}'
    ].join('\n');
    var program = compile(gl, vert, frag);
    this.program = program;
    this.aPos = gl.getAttribLocation(program, 'aPos');
    this.aNrm = gl.getAttribLocation(program, 'aNrm');
    this.aCol = gl.getAttribLocation(program, 'aCol');
    this.aUV = gl.getAttribLocation(program, 'aUV');
    this.aFade = gl.getAttribLocation(program, 'aFade');
    this.uMvp = gl.getUniformLocation(program, 'uMvp');
    this.uSampler = gl.getUniformLocation(program, 'uSampler');
    this.uUseTexture = gl.getUniformLocation(program, 'uUseTexture');
    this.uPainted = gl.getUniformLocation(program, 'uPainted');
    this.uPass = gl.getUniformLocation(program, 'uPass');
    this.uEye = gl.getUniformLocation(program, 'uEye');

    gl.enable(gl.DEPTH_TEST);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.clearColor(0.13, 0.13, 0.135, 1.0);

    this.parts = this.mesh.parts.map(this.buildPart, this);
  };

  Viewer.prototype.buildPart = function (part) {
    var gl = this.gl;
    var vertexCount = part.positions.length / 3;

    var posBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, posBuf);
    gl.bufferData(gl.ARRAY_BUFFER, part.positions, gl.STATIC_DRAW);

    var nrmBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, nrmBuf);
    gl.bufferData(gl.ARRAY_BUFFER, part.normals || new Float32Array(part.positions.length), gl.STATIC_DRAW);

    var uvBuf = null;
    var colBuf = null;
    if (part.uvs) {
      uvBuf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, uvBuf);
      gl.bufferData(gl.ARRAY_BUFFER, part.uvs, gl.STATIC_DRAW);
    } else {
      var colors = part.colors;
      if (!colors) {
        colors = new Float32Array(vertexCount * 4);
        for (var i = 0; i < vertexCount; i++) {
          colors[i * 4 + 0] = 0.85;
          colors[i * 4 + 1] = 0.84;
          colors[i * 4 + 2] = 0.82;
          colors[i * 4 + 3] = 1.0;
        }
      }
      colBuf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, colBuf);
      gl.bufferData(gl.ARRAY_BUFFER, colors, gl.STATIC_DRAW);
    }

    var indices = part.indices;
    var indexType = gl.UNSIGNED_INT;
    if (indices instanceof Uint16Array) {
      indexType = gl.UNSIGNED_SHORT;
    } else if (indices instanceof Uint8Array) {
      indexType = gl.UNSIGNED_BYTE;
    } else if (!this.uintIndices) {
      if (vertexCount > 65535) {
        throw new Error(window.TourStrings.t('webgl_unavailable'));
      }
      indices = Uint16Array.from(indices);
      indexType = gl.UNSIGNED_SHORT;
    }
    var idxBuf = gl.createBuffer();
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, idxBuf);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, indices, gl.STATIC_DRAW);

    var fades = part.fades || this.fadesFor(part.positions, part.normals);
    part.fades = fades;
    var fadeBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, fadeBuf);
    gl.bufferData(gl.ARRAY_BUFFER, fades, gl.STATIC_DRAW);

    var texture = null;
    if (part.canvas) {
      texture = this.textureForCanvas(part.canvas);
    } else if (part.imageIndex !== null && part.imageIndex !== undefined) {
      texture = this.textureForImage(part.imageIndex);
    }

    return {
      posBuf: posBuf,
      nrmBuf: nrmBuf,
      uvBuf: uvBuf,
      colBuf: colBuf,
      idxBuf: idxBuf,
      fadeBuf: fadeBuf,
      indexCount: indices.length,
      indexType: indexType,
      texture: texture,
      painted: !!part.painted
    };
  };

  Viewer.prototype.fadesFor = function (positions, normals) {
    var count = positions.length / 3;
    var fades = new Float32Array(count * 3);
    if (!normals || this.edges.length === 0) return fades;
    for (var i = 0; i < count; i++) {
      if (Math.abs(normals[i * 3 + 1]) > 0.5) continue;
      var edge = window.TourDollhousePaint.nearestEdge(this.edges, positions[i * 3], positions[i * 3 + 2], FADE_EDGE_DISTANCE_M);
      if (!edge || !edge.exterior) continue;
      fades[i * 3] = edge.wnx;
      fades[i * 3 + 1] = edge.wnz;
      fades[i * 3 + 2] = 1;
    }
    return fades;
  };

  Viewer.prototype.addPart = function (part) {
    if (this.destroyed) return;
    var built = this.buildPart(part);
    if (built.painted) {
      this.hideBase = true;
    }
    this.parts.push(built);
  };

  Viewer.prototype.visibleParts = function () {
    if (!this.hideBase) {
      return this.parts;
    }
    return this.parts.filter(function (part) { return part.painted; });
  };

  Viewer.prototype.textureForCanvas = function (canvas) {
    var gl = this.gl;
    var texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, canvas);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    this.paintedTextures.push(texture);
    return texture;
  };

  Viewer.prototype.textureForImage = function (imageIndex) {
    if (this.imageTextures[imageIndex]) {
      return this.imageTextures[imageIndex];
    }
    var gl = this.gl;
    var texture = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([214, 214, 209, 255]));
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    this.imageTextures[imageIndex] = texture;

    var image = this.mesh.images[imageIndex];
    if (image) {
      var self = this;
      this.decodeImage(image).then(function (bitmap) {
        if (self.destroyed) {
          return;
        }
        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, bitmap);
        self.render();
      }).catch(function () {});
    }
    return texture;
  };

  Viewer.prototype.decodeImage = function (image) {
    var blob = new Blob([image.bytes], { type: image.mime });
    var viaImage = function () {
      return new Promise(function (resolve, reject) {
        var url = URL.createObjectURL(blob);
        var img = new Image();
        img.onload = function () {
          URL.revokeObjectURL(url);
          resolve(img);
        };
        img.onerror = function (err) {
          URL.revokeObjectURL(url);
          reject(err);
        };
        img.src = url;
      });
    };
    if (typeof createImageBitmap === 'function') {
      return createImageBitmap(blob).catch(viaImage);
    }
    return viaImage();
  };

  Viewer.prototype.frameToBounds = function () {
    var min = [Infinity, Infinity, Infinity];
    var max = [-Infinity, -Infinity, -Infinity];
    for (var pi = 0; pi < this.mesh.parts.length; pi++) {
      var p = this.mesh.parts[pi].positions;
      for (var i = 0; i < p.length; i += 3) {
        for (var k = 0; k < 3; k++) {
          var v = p[i + k];
          if (v < min[k]) min[k] = v;
          if (v > max[k]) max[k] = v;
        }
      }
    }
    if (!isFinite(min[0])) {
      return;
    }
    this.target = [
      (min[0] + max[0]) / 2,
      (min[1] + max[1]) / 2,
      (min[2] + max[2]) / 2
    ];
    var aspect = (this.canvas.clientWidth || 640) / Math.max(1, this.canvas.clientHeight || 480);
    var M = window.TourDollhouseMath;
    var proj = M.perspective(FOV_Y, aspect, 0.05, 2000);
    var corners = [];
    for (var c = 0; c < 8; c++) {
      corners.push([c & 1 ? max[0] : min[0], c & 2 ? max[1] : min[1], c & 4 ? max[2] : min[2]]);
    }
    var self = this;
    var fits = function (distance) {
      self.distance = distance;
      var mvp = M.multiply(proj, M.lookAt(self.eyePosition(), self.target, [0, 1, 0]));
      for (var i = 0; i < corners.length; i++) {
        var p = corners[i];
        var w = mvp[3] * p[0] + mvp[7] * p[1] + mvp[11] * p[2] + mvp[15];
        if (w <= 0.05) return false;
        var x = (mvp[0] * p[0] + mvp[4] * p[1] + mvp[8] * p[2] + mvp[12]) / w;
        var y = (mvp[1] * p[0] + mvp[5] * p[1] + mvp[9] * p[2] + mvp[13]) / w;
        if (Math.abs(x) > FRAME_MARGIN || Math.abs(y) > FRAME_MARGIN) return false;
      }
      return true;
    };
    var lo = 0.5;
    var hi = 400;
    for (var it = 0; it < 40; it++) {
      var mid = (lo + hi) / 2;
      if (fits(mid)) hi = mid; else lo = mid;
    }
    this.distance = hi;
  };

  Viewer.prototype.bindControls = function () {
    var self = this;
    var canvas = this.canvas;
    canvas.style.touchAction = 'none';
    canvas.addEventListener('pointerdown', function (event) {
      if (self.flying) {
        return;
      }
      self.activePointers[event.pointerId] = { x: event.clientX, y: event.clientY };
      var ids = Object.keys(self.activePointers);
      self.tapStart = ids.length === 1 && event.button === 0
        ? { id: event.pointerId, x: event.clientX, y: event.clientY, time: Date.now() }
        : null;
      if (ids.length === 2) {
        self.pinchDistance = self.pointerDistance();
        self.pinchMidpoint = self.pointerMidpoint();
        self.lastPointer = null;
      } else {
        self.dragging = true;
        self.lastPointer = { x: event.clientX, y: event.clientY, button: event.button };
      }
      canvas.setPointerCapture(event.pointerId);
    });
    canvas.addEventListener('pointermove', function (event) {
      if (self.activePointers[event.pointerId]) {
        self.activePointers[event.pointerId].x = event.clientX;
        self.activePointers[event.pointerId].y = event.clientY;
      }
      if (Object.keys(self.activePointers).length >= 2) {
        var d = self.pointerDistance();
        if (self.pinchDistance && d > 0) {
          self.distance *= self.pinchDistance / d;
          self.distance = Math.max(1, Math.min(500, self.distance));
        }
        self.pinchDistance = d;
        var mid = self.pointerMidpoint();
        if (self.pinchMidpoint && mid) {
          self.pan(mid.x - self.pinchMidpoint.x, mid.y - self.pinchMidpoint.y);
        }
        self.pinchMidpoint = mid;
        self.render();
        return;
      }
      if (!self.dragging || !self.lastPointer) {
        return;
      }
      var dx = event.clientX - self.lastPointer.x;
      var dy = event.clientY - self.lastPointer.y;
      self.lastPointer.x = event.clientX;
      self.lastPointer.y = event.clientY;
      if (self.lastPointer.button === 2 || event.shiftKey) {
        self.pan(dx, dy);
      } else {
        self.yaw += dx * 0.008;
        self.pitch += dy * 0.008;
        self.pitch = Math.max(0.05, Math.min(Math.PI / 2 - 0.05, self.pitch));
      }
      self.render();
    });
    canvas.addEventListener('pointerup', function (event) {
      var tap = self.tapStart;
      self.tapStart = null;
      if (tap && tap.id === event.pointerId
        && Math.hypot(event.clientX - tap.x, event.clientY - tap.y) <= TAP_SLOP_PX
        && Date.now() - tap.time <= TAP_MAX_MS) {
        var rect = canvas.getBoundingClientRect();
        var target = self.photoAt(event.clientX - rect.left, event.clientY - rect.top);
        if (target) {
          self.onHotspotTap(target.roomIndex, target.photoIndex);
        }
      }
      delete self.activePointers[event.pointerId];
      if (Object.keys(self.activePointers).length < 2) {
        self.pinchDistance = null;
        self.pinchMidpoint = null;
      }
      self.dragging = false;
      self.lastPointer = null;
      try { canvas.releasePointerCapture(event.pointerId); } catch (e) {}
    });
    canvas.addEventListener('pointercancel', function (event) {
      self.tapStart = null;
      delete self.activePointers[event.pointerId];
      self.pinchDistance = null;
      self.pinchMidpoint = null;
      self.dragging = false;
      self.lastPointer = null;
    });
    canvas.addEventListener('wheel', function (event) {
      event.preventDefault();
      var delta = event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? 400 : 1);
      if (event.ctrlKey) {
        delta *= 8;
      }
      delta = Math.max(-200, Math.min(200, delta));
      self.distance *= Math.pow(1.0015, delta);
      self.distance = Math.max(1, Math.min(500, self.distance));
      self.render();
    }, { passive: false });
    canvas.addEventListener('contextmenu', function (event) { event.preventDefault(); });
  };

  Viewer.prototype.pointerDistance = function () {
    var pts = Object.keys(this.activePointers).map(function (k) {
      return this.activePointers[k];
    }, this);
    if (pts.length < 2) {
      return 0;
    }
    var dx = pts[0].x - pts[1].x;
    var dy = pts[0].y - pts[1].y;
    return Math.sqrt(dx * dx + dy * dy);
  };

  Viewer.prototype.pointerMidpoint = function () {
    var pts = Object.keys(this.activePointers).map(function (k) {
      return this.activePointers[k];
    }, this);
    if (pts.length < 2) {
      return null;
    }
    return { x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2 };
  };

  Viewer.prototype.pan = function (dx, dy) {
    var scale = this.distance * 0.0015;
    var forward = [
      Math.sin(this.yaw) * Math.cos(this.pitch),
      Math.sin(this.pitch),
      Math.cos(this.yaw) * Math.cos(this.pitch)
    ];
    var right = [forward[2], 0, -forward[0]];
    var rlen = Math.hypot(right[0], right[2]) || 1;
    right = [right[0] / rlen, 0, right[2] / rlen];
    this.target[0] -= right[0] * dx * scale;
    this.target[1] += dy * scale;
    this.target[2] -= right[2] * dx * scale;
  };

  Viewer.prototype.spawnHotspots = function () {
    var self = this;
    for (var i = 0; i < this.hotspots.length; i++) {
      (function (hotspot) {
        var el = document.createElement('button');
        el.type = 'button';
        el.className = hotspot.kind === 'spot' ? 'tour-dollhouse-spot' : 'tour-dollhouse-hotspot';
        el.style.width = HOTSPOT_PIXEL_SIZE + 'px';
        el.style.height = HOTSPOT_PIXEL_SIZE + 'px';
        el.setAttribute('aria-label', hotspot.label);
        el.setAttribute('title', hotspot.label);
        el.addEventListener('click', function () {
          if (hotspot.kind === 'spot') {
            if (!self.onStandTap) return;
            self.flyTo(hotspot.world, function () {
              self.onStandTap(hotspot.roomIndex, hotspot.standId);
            });
            return;
          }
          self.onHotspotTap(hotspot.roomIndex, hotspot.photoIndex);
        });
        self.hotspotLayer.appendChild(el);
        self.hotspotElements.push({ el: el, hotspot: hotspot });
      })(this.hotspots[i]);
    }
    this.occlusionEyeKey = null;
  };

  Viewer.prototype.flyTo = function (world, done) {
    var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (this.flying) {
      return;
    }
    if (reduce) {
      done();
      return;
    }
    this.flying = true;
    var self = this;
    var from = { target: this.target.slice(), distance: this.distance, pitch: this.pitch };
    var to = { target: [world[0], world[1] + 1.2, world[2]], distance: 1.2, pitch: Math.min(this.pitch, Math.PI * 0.12) };
    var start = performance.now();
    var step = function (now) {
      if (self.destroyed) return;
      var t = Math.min(1, (now - start) / FLY_MS);
      var e = t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
      for (var k = 0; k < 3; k++) {
        self.target[k] = from.target[k] + (to.target[k] - from.target[k]) * e;
      }
      self.distance = from.distance + (to.distance - from.distance) * e;
      self.pitch = from.pitch + (to.pitch - from.pitch) * e;
      self.hotspotLayer.style.opacity = String(1 - e);
      if (t < 1) {
        window.requestAnimationFrame(step);
        return;
      }
      self.flying = false;
      done();
    };
    window.requestAnimationFrame(step);
  };

  Viewer.prototype.spawnRoomLabels = function (labels) {
    for (var i = 0; i < labels.length; i++) {
      var el = document.createElement('span');
      el.className = 'tour-dollhouse-label';
      el.textContent = labels[i].text;
      el.setAttribute('aria-hidden', 'true');
      this.hotspotLayer.insertBefore(el, this.hotspotLayer.firstChild);
      this.roomLabelElements.push({ el: el, world: labels[i].world });
    }
  };

  Viewer.prototype.positionRoomLabels = function () {
    for (var i = 0; i < this.roomLabelElements.length; i++) {
      var entry = this.roomLabelElements[i];
      var screen = this.projectToScreen(entry.world);
      if (screen === null) {
        entry.el.style.display = 'none';
        continue;
      }
      entry.el.style.display = 'block';
      entry.el.style.transform = 'translate(' + screen[0].toFixed(1) + 'px,' + screen[1].toFixed(1) + 'px) translate(-50%, -50%)';
    }
  };

  Viewer.prototype.spotEllipse = function (world, center) {
    var eye = this.eyePosition();
    var fx = world[0] - eye[0];
    var fz = world[2] - eye[2];
    var flen = Math.sqrt(fx * fx + fz * fz) || 1;
    fx /= flen;
    fz /= flen;
    var side = this.projectToScreen([world[0] + fz * SPOT_RADIUS_M, world[1], world[2] - fx * SPOT_RADIUS_M], true);
    var depth = this.projectToScreen([world[0] + fx * SPOT_RADIUS_M, world[1], world[2] + fz * SPOT_RADIUS_M], true);
    if (!side || !depth) {
      return [SPOT_MIN_PX, SPOT_MIN_PX * 0.6];
    }
    var w = 2 * Math.hypot(side[0] - center[0], side[1] - center[1]);
    var h = 2 * Math.hypot(depth[0] - center[0], depth[1] - center[1]);
    var scale = w > SPOT_MAX_PX ? SPOT_MAX_PX / w : w < SPOT_MIN_PX ? SPOT_MIN_PX / Math.max(1, w) : 1;
    return [w * scale, Math.max(4, h * scale)];
  };

  Viewer.prototype.eyePosition = function () {
    var cx = this.target[0] + this.distance * Math.sin(this.yaw) * Math.cos(this.pitch);
    var cy = this.target[1] + this.distance * Math.sin(this.pitch);
    var cz = this.target[2] + this.distance * Math.cos(this.yaw) * Math.cos(this.pitch);
    return [cx, cy, cz];
  };

  Viewer.prototype.resize = function () {
    var dpr = window.devicePixelRatio || 1;
    var w = this.canvas.clientWidth || 640;
    var h = this.canvas.clientHeight || 480;
    if (this.canvas.width !== Math.round(w * dpr) || this.canvas.height !== Math.round(h * dpr)) {
      this.canvas.width = Math.round(w * dpr);
      this.canvas.height = Math.round(h * dpr);
    }
  };

  Viewer.prototype.render = function () {
    var gl = this.gl;
    this.resize();
    gl.viewport(0, 0, this.canvas.width, this.canvas.height);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.useProgram(this.program);

    var aspect = this.canvas.width / Math.max(1, this.canvas.height);
    var proj = window.TourDollhouseMath.perspective(FOV_Y, aspect, 0.05, 2000);
    var eye = this.eyePosition();
    var view = window.TourDollhouseMath.lookAt(eye, this.target, [0, 1, 0]);
    var mvp = window.TourDollhouseMath.multiply(proj, view);
    this.mvp = mvp;
    gl.uniformMatrix4fv(this.uMvp, false, mvp);
    gl.uniform3f(this.uEye, eye[0], eye[1], eye[2]);

    var parts = this.visibleParts();
    gl.uniform1f(this.uPass, 0.0);
    for (var i = 0; i < parts.length; i++) {
      this.renderPart(parts[i]);
    }
    gl.uniform1f(this.uPass, 1.0);
    gl.enable(gl.BLEND);
    gl.depthMask(false);
    for (var j = 0; j < parts.length; j++) {
      this.renderPart(parts[j]);
    }
    gl.depthMask(true);
    gl.disable(gl.BLEND);

    this.positionHotspots();
  };

  Viewer.prototype.renderPart = function (part) {
    var gl = this.gl;

    gl.bindBuffer(gl.ARRAY_BUFFER, part.posBuf);
    gl.enableVertexAttribArray(this.aPos);
    gl.vertexAttribPointer(this.aPos, 3, gl.FLOAT, false, 0, 0);

    gl.bindBuffer(gl.ARRAY_BUFFER, part.nrmBuf);
    gl.enableVertexAttribArray(this.aNrm);
    gl.vertexAttribPointer(this.aNrm, 3, gl.FLOAT, false, 0, 0);

    gl.bindBuffer(gl.ARRAY_BUFFER, part.fadeBuf);
    gl.enableVertexAttribArray(this.aFade);
    gl.vertexAttribPointer(this.aFade, 3, gl.FLOAT, false, 0, 0);

    gl.uniform1f(this.uPainted, part.painted ? 1.0 : 0.0);
    if (part.painted) {
      gl.enable(gl.POLYGON_OFFSET_FILL);
      gl.polygonOffset(-1.0, -2.0);
    }

    if (part.texture) {
      gl.bindBuffer(gl.ARRAY_BUFFER, part.uvBuf);
      gl.enableVertexAttribArray(this.aUV);
      gl.vertexAttribPointer(this.aUV, 2, gl.FLOAT, false, 0, 0);
      gl.disableVertexAttribArray(this.aCol);
      gl.vertexAttrib4f(this.aCol, 1.0, 1.0, 1.0, 1.0);
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, part.texture);
      gl.uniform1i(this.uSampler, 0);
      gl.uniform1f(this.uUseTexture, 1.0);
    } else {
      gl.disableVertexAttribArray(this.aUV);
      gl.vertexAttrib2f(this.aUV, 0.0, 0.0);
      gl.bindBuffer(gl.ARRAY_BUFFER, part.colBuf);
      gl.enableVertexAttribArray(this.aCol);
      gl.vertexAttribPointer(this.aCol, 4, gl.FLOAT, false, 0, 0);
      gl.uniform1f(this.uUseTexture, 0.0);
    }

    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, part.idxBuf);
    gl.drawElements(gl.TRIANGLES, part.indexCount, part.indexType, 0);
    if (part.painted) {
      gl.disable(gl.POLYGON_OFFSET_FILL);
    }
  };

  Viewer.prototype.positionHotspots = function () {
    var eye = this.eyePosition();
    var eyeKey = eye[0].toFixed(3) + ',' + eye[1].toFixed(3) + ',' + eye[2].toFixed(3);
    if (eyeKey !== this.occlusionEyeKey) {
      this.occlusionEyeKey = eyeKey;
      this.occluded = this.hotspotElements.map(function (entry) {
        return this.isOccluded(eye, entry.hotspot.world);
      }, this);
    }
    for (var i = 0; i < this.hotspotElements.length; i++) {
      var entry = this.hotspotElements[i];
      entry.el.classList.toggle('is-behind', this.occluded[i]);
      var screen = this.projectToScreen(entry.hotspot.world);
      if (screen === null) {
        entry.el.style.display = 'none';
        continue;
      }
      entry.el.style.display = 'block';
      if (entry.hotspot.kind === 'spot') {
        var size = this.spotEllipse(entry.hotspot.world, screen);
        entry.el.style.width = size[0].toFixed(1) + 'px';
        entry.el.style.height = size[1].toFixed(1) + 'px';
        entry.el.style.left = (screen[0] - size[0] / 2) + 'px';
        entry.el.style.top = (screen[1] - size[1] / 2) + 'px';
        continue;
      }
      entry.el.style.left = (screen[0] - HOTSPOT_PIXEL_SIZE / 2) + 'px';
      entry.el.style.top = (screen[1] - HOTSPOT_PIXEL_SIZE / 2) + 'px';
    }
    this.positionRoomLabels();
  };

  Viewer.prototype.occluderTriangles = function () {
    if (this.occluders !== undefined) {
      return this.occluders;
    }
    var total = 0;
    for (var pi = 0; pi < this.mesh.parts.length; pi++) {
      total += this.mesh.parts[pi].indices.length / 3;
    }
    if (total > MAX_OCCLUSION_TRIANGLES) {
      this.occluders = null;
      return null;
    }
    var tris = new Float32Array(total * 9);
    var fades = new Float32Array(total * 5);
    var o = 0;
    var f = 0;
    for (var pj = 0; pj < this.mesh.parts.length; pj++) {
      var pos = this.mesh.parts[pj].positions;
      var idx = this.mesh.parts[pj].indices;
      var fd = this.mesh.parts[pj].fades;
      for (var k = 0; k < idx.length; k++) {
        var v = idx[k] * 3;
        tris[o++] = pos[v];
        tris[o++] = pos[v + 1];
        tris[o++] = pos[v + 2];
        if (k % 3 === 0) {
          fades[f++] = fd ? fd[v] : 0;
          fades[f++] = fd ? fd[v + 1] : 0;
          fades[f++] = fd ? fd[v + 2] : 0;
          fades[f++] = pos[v];
          fades[f++] = pos[v + 2];
        }
      }
    }
    this.occluders = tris;
    this.occluderFades = fades;
    return tris;
  };

  Viewer.prototype.isOccluded = function (eye, point) {
    var tris = this.occluderTriangles();
    if (!tris) {
      return false;
    }
    var dx = point[0] - eye[0];
    var dy = point[1] - eye[1];
    var dz = point[2] - eye[2];
    var length = Math.sqrt(dx * dx + dy * dy + dz * dz);
    if (length < 1e-6) {
      return false;
    }
    dx /= length;
    dy /= length;
    dz /= length;
    var limit = length - OCCLUSION_CLEARANCE_M;
    var fades = this.occluderFades;
    for (var t = 0; t < tris.length; t += 9) {
      var fo = (t / 9) * 5;
      if (fades[fo + 2] > 0.5) {
        var ex = eye[0] - fades[fo + 3];
        var ez = eye[2] - fades[fo + 4];
        var el = Math.sqrt(ex * ex + ez * ez) || 1;
        if ((fades[fo] * ex + fades[fo + 1] * ez) / el < -FADE_START) {
          continue;
        }
      }
      var e1x = tris[t + 3] - tris[t], e1y = tris[t + 4] - tris[t + 1], e1z = tris[t + 5] - tris[t + 2];
      var e2x = tris[t + 6] - tris[t], e2y = tris[t + 7] - tris[t + 1], e2z = tris[t + 8] - tris[t + 2];
      var px = dy * e2z - dz * e2y, py = dz * e2x - dx * e2z, pz = dx * e2y - dy * e2x;
      var det = e1x * px + e1y * py + e1z * pz;
      if (det > -1e-9 && det < 1e-9) {
        continue;
      }
      var inv = 1 / det;
      var sx = eye[0] - tris[t], sy = eye[1] - tris[t + 1], sz = eye[2] - tris[t + 2];
      var u = (sx * px + sy * py + sz * pz) * inv;
      if (u < 0 || u > 1) {
        continue;
      }
      var qx = sy * e1z - sz * e1y, qy = sz * e1x - sx * e1z, qz = sx * e1y - sy * e1x;
      var w = (dx * qx + dy * qy + dz * qz) * inv;
      if (w < 0 || u + w > 1) {
        continue;
      }
      var hit = (e2x * qx + e2y * qy + e2z * qz) * inv;
      if (hit > 1e-4 && hit < limit) {
        return true;
      }
    }
    return false;
  };

  Viewer.prototype.rayAt = function (sx, sy) {
    var w = this.canvas.clientWidth || 1;
    var h = this.canvas.clientHeight || 1;
    var eye = this.eyePosition();
    var f = [this.target[0] - eye[0], this.target[1] - eye[1], this.target[2] - eye[2]];
    var fl = Math.hypot(f[0], f[1], f[2]) || 1;
    f = [f[0] / fl, f[1] / fl, f[2] / fl];
    var r = [-f[2], 0, f[0]];
    var rl = Math.hypot(r[0], r[2]) || 1;
    r = [r[0] / rl, 0, r[2] / rl];
    var u = [r[1] * f[2] - r[2] * f[1], r[2] * f[0] - r[0] * f[2], r[0] * f[1] - r[1] * f[0]];
    var t = Math.tan(FOV_Y / 2);
    var nx = (2 * sx / w - 1) * t * (w / h);
    var ny = (1 - 2 * sy / h) * t;
    var d = [f[0] + r[0] * nx + u[0] * ny, f[1] + r[1] * nx + u[1] * ny, f[2] + r[2] * nx + u[2] * ny];
    var dl = Math.hypot(d[0], d[1], d[2]) || 1;
    return { origin: eye, dir: [d[0] / dl, d[1] / dl, d[2] / dl] };
  };

  Viewer.prototype.photoAt = function (sx, sy) {
    var ray = this.rayAt(sx, sy);
    var o = ray.origin;
    var d = ray.dir;
    var best = Infinity;
    var bestPart = null;
    for (var pi = 0; pi < this.mesh.parts.length; pi++) {
      var part = this.mesh.parts[pi];
      var pos = part.positions;
      var idx = part.indices;
      var fd = part.fades;
      for (var k = 0; k + 2 < idx.length; k += 3) {
        var a = idx[k] * 3, b = idx[k + 1] * 3, c = idx[k + 2] * 3;
        if (fd && (fd[a + 2] > 0.5 || fd[b + 2] > 0.5 || fd[c + 2] > 0.5)) {
          var ex = o[0] - (pos[a] + pos[b] + pos[c]) / 3;
          var ez = o[2] - (pos[a + 2] + pos[b + 2] + pos[c + 2]) / 3;
          var el = Math.sqrt(ex * ex + ez * ez) || 1;
          var fx = (fd[a] + fd[b] + fd[c]) / 3;
          var fz = (fd[a + 1] + fd[b + 1] + fd[c + 1]) / 3;
          if ((fx * ex + fz * ez) / el < -TAP_FADE_CUTOFF) {
            continue;
          }
        }
        var e1x = pos[b] - pos[a], e1y = pos[b + 1] - pos[a + 1], e1z = pos[b + 2] - pos[a + 2];
        var e2x = pos[c] - pos[a], e2y = pos[c + 1] - pos[a + 1], e2z = pos[c + 2] - pos[a + 2];
        var nx = e1y * e2z - e1z * e2y, ny = e1z * e2x - e1x * e2z, nz = e1x * e2y - e1y * e2x;
        if (part.photoId && nx * d[0] + ny * d[1] + nz * d[2] >= 0) {
          continue;
        }
        var px = d[1] * e2z - d[2] * e2y, py = d[2] * e2x - d[0] * e2z, pz = d[0] * e2y - d[1] * e2x;
        var det = e1x * px + e1y * py + e1z * pz;
        if (det > -1e-9 && det < 1e-9) {
          continue;
        }
        var inv = 1 / det;
        var sxv = o[0] - pos[a], syv = o[1] - pos[a + 1], szv = o[2] - pos[a + 2];
        var bu = (sxv * px + syv * py + szv * pz) * inv;
        if (bu < 0 || bu > 1) {
          continue;
        }
        var qx = syv * e1z - szv * e1y, qy = szv * e1x - sxv * e1z, qz = sxv * e1y - syv * e1x;
        var bv = (d[0] * qx + d[1] * qy + d[2] * qz) * inv;
        if (bv < 0 || bu + bv > 1) {
          continue;
        }
        var dist = (e2x * qx + e2y * qy + e2z * qz) * inv;
        if (dist > 1e-4 && dist < best) {
          best = dist;
          bestPart = part;
        }
      }
    }
    if (!bestPart || !bestPart.photoId) {
      return null;
    }
    return this.photoTargets[bestPart.photoId] || null;
  };

  Viewer.prototype.projectToScreen = function (p, unclipped) {
    var m = this.mvp;
    if (!m) {
      return null;
    }
    var x = m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12];
    var y = m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13];
    var w = m[3] * p[0] + m[7] * p[1] + m[11] * p[2] + m[15];
    if (w <= 0) {
      return null;
    }
    var ndcX = x / w;
    var ndcY = y / w;
    if (!unclipped && (ndcX < -1 || ndcX > 1 || ndcY < -1 || ndcY > 1)) {
      return null;
    }
    return [
      (ndcX + 1) * 0.5 * this.canvas.clientWidth,
      (1 - ndcY) * 0.5 * this.canvas.clientHeight
    ];
  };

  Viewer.prototype.start = function () {
    if (this.running) {
      return;
    }
    this.running = true;
    var self = this;
    var loop = function () {
      if (!self.running) {
        return;
      }
      self.render();
      window.requestAnimationFrame(loop);
    };
    window.requestAnimationFrame(loop);
  };

  Viewer.prototype.stop = function () {
    this.running = false;
    this.destroyed = true;
    if (this.cancelPaint) {
      this.cancelPaint();
      this.cancelPaint = null;
    }
    var gl = this.gl;
    if (!gl) {
      return;
    }
    for (var i = 0; i < this.parts.length; i++) {
      var part = this.parts[i];
      if (part.posBuf) gl.deleteBuffer(part.posBuf);
      if (part.nrmBuf) gl.deleteBuffer(part.nrmBuf);
      if (part.uvBuf) gl.deleteBuffer(part.uvBuf);
      if (part.colBuf) gl.deleteBuffer(part.colBuf);
      if (part.idxBuf) gl.deleteBuffer(part.idxBuf);
      if (part.fadeBuf) gl.deleteBuffer(part.fadeBuf);
    }
    for (var t = 0; t < this.paintedTextures.length; t++) {
      gl.deleteTexture(this.paintedTextures[t]);
    }
    this.paintedTextures = [];
    this.parts = [];
    for (var key in this.imageTextures) {
      if (Object.prototype.hasOwnProperty.call(this.imageTextures, key)) {
        gl.deleteTexture(this.imageTextures[key]);
      }
    }
    this.imageTextures = {};
    if (this.program) { gl.deleteProgram(this.program); this.program = null; }
  };

  function compile(gl, vertSrc, fragSrc) {
    var vs = gl.createShader(gl.VERTEX_SHADER);
    gl.shaderSource(vs, vertSrc);
    gl.compileShader(vs);
    if (!gl.getShaderParameter(vs, gl.COMPILE_STATUS)) {
      throw new Error('vertex shader: ' + gl.getShaderInfoLog(vs));
    }
    var fs = gl.createShader(gl.FRAGMENT_SHADER);
    gl.shaderSource(fs, fragSrc);
    gl.compileShader(fs);
    if (!gl.getShaderParameter(fs, gl.COMPILE_STATUS)) {
      throw new Error('fragment shader: ' + gl.getShaderInfoLog(fs));
    }
    var program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      throw new Error('link: ' + gl.getProgramInfoLog(program));
    }
    return program;
  }

  window.TourDollhouse = { render: render, stop: stop };
})();
