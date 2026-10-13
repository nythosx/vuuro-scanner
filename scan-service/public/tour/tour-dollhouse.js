(function () {
  'use strict';

  var HOTSPOT_PIXEL_SIZE = 24;

  function render(viewport, url, rooms, onBackToPlan, onHotspotTap, buildUrl) {
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
        var hotspots = buildHotspots(rooms || []);
        var stage = buildStage(viewport, onBackToPlan);
        var viewer = new Viewer(stage.canvas, gltf, hotspots, stage.hotspotLayer, onHotspotTap);
        viewer.start();
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
    stage.appendChild(backButton(onBackToPlan));
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
    stage.appendChild(backButton(onBackToPlan));
    viewport.appendChild(stage);
  }

  function buildStage(viewport, onBackToPlan) {
    clearNode(viewport);
    var stage = document.createElement('div');
    stage.className = 'tour-dollhouse';

    var canvas = document.createElement('canvas');
    canvas.className = 'tour-dollhouse-canvas';
    stage.appendChild(canvas);

    var hotspotLayer = document.createElement('div');
    hotspotLayer.className = 'tour-dollhouse-hotspots';
    stage.appendChild(hotspotLayer);

    stage.appendChild(backButton(onBackToPlan));
    viewport.appendChild(stage);

    return { stage: stage, canvas: canvas, hotspotLayer: hotspotLayer };
  }

  function backButton(onBackToPlan) {
    var back = document.createElement('button');
    back.type = 'button';
    back.className = 'tour-btn tour-btn-back tour-dollhouse-back';
    back.textContent = window.TourStrings.t('back_to_plan');
    back.addEventListener('click', onBackToPlan);
    return back;
  }

  function clearNode(node) {
    while (node.firstChild) {
      node.removeChild(node.firstChild);
    }
  }

  function buildHotspots(rooms) {
    var allHaveOrigin = rooms.length > 0 && rooms.every(function (room) {
      var origin = room.structure_origin_m;
      return Array.isArray(origin) && origin.length === 2
        && isFinite(Number(origin[0])) && isFinite(Number(origin[1]));
    });
    var hotspots = [];
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
      var photos = Array.isArray(room.photos) ? room.photos : [];
      for (var p = 0; p < photos.length; p++) {
        var pos = photos[p].position_m;
        if (!Array.isArray(pos) || pos.length < 2) {
          continue;
        }
        var px = Number(pos[0]);
        var pz = Number(pos[1]);
        if (!isFinite(px) || !isFinite(pz)) {
          continue;
        }
        hotspots.push({
          roomIndex: i,
          photoIndex: p,
          world: [px + ox, height / 2, pz + oz],
          roomHeight: height,
          label: (room.label || '') + ' photo ' + (p + 1)
        });
      }
    }
    return hotspots;
  }

  function Viewer(canvas, mesh, hotspots, hotspotLayer, onHotspotTap) {
    this.canvas = canvas;
    this.gl = canvas.getContext('webgl', { antialias: true, alpha: false });
    if (!this.gl) {
      throw new Error(window.TourStrings.t('webgl_unavailable'));
    }
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
    this.dragging = false;
    this.lastPointer = null;
    this.activePointers = {};
    this.pinchDistance = null;
    this.hotspotElements = [];
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
      'uniform mat4 uMvp;',
      'varying vec3 vNrm;',
      'varying vec4 vCol;',
      'void main() {',
      '  gl_Position = uMvp * vec4(aPos, 1.0);',
      '  vNrm = aNrm;',
      '  vCol = aCol;',
      '}'
    ].join('\n');
    var frag = [
      'precision mediump float;',
      'varying vec3 vNrm;',
      'varying vec4 vCol;',
      'void main() {',
      '  vec3 n = normalize(vNrm);',
      '  vec3 light = normalize(vec3(0.35, 0.85, 0.4));',
      '  float diff = max(dot(n, light), 0.0);',
      '  float ambient = 0.55;',
      '  float shade = ambient + diff * 0.55;',
      '  gl_FragColor = vec4(vCol.rgb * shade, vCol.a);',
      '}'
    ].join('\n');
    var program = compile(gl, vert, frag);
    this.program = program;
    this.aPos = gl.getAttribLocation(program, 'aPos');
    this.aNrm = gl.getAttribLocation(program, 'aNrm');
    this.aCol = gl.getAttribLocation(program, 'aCol');
    this.uMvp = gl.getUniformLocation(program, 'uMvp');

    this.posBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.posBuf);
    gl.bufferData(gl.ARRAY_BUFFER, this.mesh.positions, gl.STATIC_DRAW);

    this.nrmBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.nrmBuf);
    gl.bufferData(gl.ARRAY_BUFFER, this.mesh.normals || new Float32Array(this.mesh.positions.length), gl.STATIC_DRAW);

    this.colBuf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.colBuf);
    var vertexCount = this.mesh.positions.length / 3;
    var colors = this.mesh.colors;
    if (!colors) {
      colors = new Float32Array(vertexCount * 4);
      for (var i = 0; i < vertexCount; i++) {
        colors[i * 4 + 0] = 0.85;
        colors[i * 4 + 1] = 0.84;
        colors[i * 4 + 2] = 0.82;
        colors[i * 4 + 3] = 1.0;
      }
    }
    gl.bufferData(gl.ARRAY_BUFFER, colors, gl.STATIC_DRAW);

    this.idxBuf = gl.createBuffer();
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.idxBuf);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, this.mesh.indices, gl.STATIC_DRAW);
    this.indexCount = this.mesh.indices.length;
    gl.enable(gl.DEPTH_TEST);
    gl.clearColor(0.94, 0.93, 0.90, 1.0);
  };

  Viewer.prototype.frameToBounds = function () {
    var p = this.mesh.positions;
    var min = [Infinity, Infinity, Infinity];
    var max = [-Infinity, -Infinity, -Infinity];
    for (var i = 0; i < p.length; i += 3) {
      for (var k = 0; k < 3; k++) {
        var v = p[i + k];
        if (v < min[k]) min[k] = v;
        if (v > max[k]) max[k] = v;
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
    var size = Math.max(max[0] - min[0], max[1] - min[1], max[2] - min[2]);
    this.distance = size * 1.4 + 4;
  };

  Viewer.prototype.bindControls = function () {
    var self = this;
    var canvas = this.canvas;
    canvas.style.touchAction = 'none';
    canvas.addEventListener('pointerdown', function (event) {
      self.activePointers[event.pointerId] = { x: event.clientX, y: event.clientY };
      var ids = Object.keys(self.activePointers);
      if (ids.length === 2) {
        self.pinchDistance = self.pointerDistance();
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
      delete self.activePointers[event.pointerId];
      if (Object.keys(self.activePointers).length < 2) {
        self.pinchDistance = null;
      }
      self.dragging = false;
      self.lastPointer = null;
      try { canvas.releasePointerCapture(event.pointerId); } catch (e) {}
    });
    canvas.addEventListener('pointercancel', function (event) {
      delete self.activePointers[event.pointerId];
      self.pinchDistance = null;
      self.dragging = false;
      self.lastPointer = null;
    });
    canvas.addEventListener('wheel', function (event) {
      event.preventDefault();
      self.distance *= Math.pow(1.0015, event.deltaY);
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
        el.className = 'tour-dollhouse-hotspot';
        el.setAttribute('aria-label', hotspot.label);
        el.addEventListener('click', function () {
          self.onHotspotTap(hotspot.roomIndex, hotspot.photoIndex);
        });
        self.hotspotLayer.appendChild(el);
        self.hotspotElements.push({ el: el, hotspot: hotspot });
      })(this.hotspots[i]);
    }
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
    var proj = window.TourDollhouseMath.perspective(Math.PI / 3.5, aspect, 0.05, 2000);
    var eye = this.eyePosition();
    var view = window.TourDollhouseMath.lookAt(eye, this.target, [0, 1, 0]);
    var mvp = window.TourDollhouseMath.multiply(proj, view);
    this.mvp = mvp;

    gl.uniformMatrix4fv(this.uMvp, false, mvp);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.posBuf);
    gl.enableVertexAttribArray(this.aPos);
    gl.vertexAttribPointer(this.aPos, 3, gl.FLOAT, false, 0, 0);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.nrmBuf);
    gl.enableVertexAttribArray(this.aNrm);
    gl.vertexAttribPointer(this.aNrm, 3, gl.FLOAT, false, 0, 0);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.colBuf);
    gl.enableVertexAttribArray(this.aCol);
    gl.vertexAttribPointer(this.aCol, 4, gl.FLOAT, false, 0, 0);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, this.idxBuf);
    gl.drawElements(gl.TRIANGLES, this.indexCount, gl.UNSIGNED_INT, 0);

    this.positionHotspots();
  };

  Viewer.prototype.positionHotspots = function () {
    var eye = this.eyePosition();
    var eyeY = eye[1];
    for (var i = 0; i < this.hotspotElements.length; i++) {
      var entry = this.hotspotElements[i];
      var ceilingY = entry.hotspot.roomHeight || (entry.hotspot.world[1] * 2);
      if (eyeY > ceilingY) {
        entry.el.style.display = 'none';
        continue;
      }
      var screen = this.projectToScreen(entry.hotspot.world);
      if (screen === null) {
        entry.el.style.display = 'none';
        continue;
      }
      entry.el.style.display = 'block';
      entry.el.style.left = (screen[0] - HOTSPOT_PIXEL_SIZE / 2) + 'px';
      entry.el.style.top = (screen[1] - HOTSPOT_PIXEL_SIZE / 2) + 'px';
      entry.el.style.width = HOTSPOT_PIXEL_SIZE + 'px';
      entry.el.style.height = HOTSPOT_PIXEL_SIZE + 'px';
    }
  };

  Viewer.prototype.projectToScreen = function (p) {
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
    if (ndcX < -1 || ndcX > 1 || ndcY < -1 || ndcY > 1) {
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

  window.TourDollhouse = { render: render };
})();
