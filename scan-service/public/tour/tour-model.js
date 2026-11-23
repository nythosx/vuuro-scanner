import * as THREE from './vendor/three/three.module.min.js';
import { GLTFLoader } from './vendor/three/GLTFLoader.js';
import { OrbitControls } from './vendor/three/OrbitControls.js';

var CEILING_CLASS = 3;
var WALL_CLASS = 1;
var OCCLUSION_IDLE_MS = 250;
var OCCLUSION_SLOW_MS = 60;
var OCCLUSION_GAP_M = 0.15;
var MODES = ['photo', 'clay', 'mesh'];
var active = null;

function t(key, params) {
  return window.TourStrings ? window.TourStrings.t(key, params) : key;
}

function clearNode(node) {
  while (node.firstChild) {
    node.removeChild(node.firstChild);
  }
}

function status(viewport, text, isError) {
  clearNode(viewport);
  var stage = document.createElement('div');
  stage.className = 'tour-model';
  var p = document.createElement('p');
  p.className = 'tour-status' + (isError ? ' is-error' : '');
  p.textContent = text;
  stage.appendChild(p);
  viewport.appendChild(stage);
  return p;
}

function stop() {
  if (active) {
    active.dispose();
    active = null;
  }
}

function classOf(material) {
  var data = material && material.userData ? material.userData : {};
  return typeof data.class === 'number' ? data.class : null;
}

function prepare(root) {
  var parts = [];
  root.traverse(function (object) {
    if (!object.isMesh) {
      return;
    }
    if (!object.geometry.getAttribute('normal')) {
      object.geometry.computeVertexNormals();
    }
    parts.push({ mesh: object, photo: object.material, classId: classOf(object.material) });
  });
  return parts;
}

var PHONE_TEXTURE_PIXELS = 12000000;
var DESKTOP_TEXTURE_PIXELS = 48000000;

function textureBudget() {
  var coarse = window.matchMedia && window.matchMedia('(pointer: coarse)').matches;
  return coarse ? PHONE_TEXTURE_PIXELS : DESKTOP_TEXTURE_PIXELS;
}

function fitTextures(root, budget) {
  var textures = [];
  root.traverse(function (object) {
    if (!object.isMesh || !object.material || !object.material.map) {
      return;
    }
    var map = object.material.map;
    if (textures.indexOf(map) === -1 && map.image && map.image.width > 0 && map.image.height > 0) {
      textures.push(map);
    }
  });
  var total = textures.reduce(function (sum, map) { return sum + map.image.width * map.image.height; }, 0);
  if (total <= budget) {
    return 1;
  }
  var scale = Math.sqrt(budget / total);
  textures.forEach(function (map) {
    var image = map.image;
    var canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(image.width * scale));
    canvas.height = Math.max(1, Math.round(image.height * scale));
    var context = canvas.getContext('2d');
    if (!context) {
      return;
    }
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    if (typeof image.close === 'function') {
      image.close();
    }
    map.image = canvas;
    map.needsUpdate = true;
  });
  return scale;
}

var PORTRAIT_MAX_PULL_BACK = 3;
var LABEL_LIFT_M = 0.1;
var ROOM_AREA_SLACK_M2 = 0.15;
var ROOM_AREA_SLACK_SHARE = 0.03;

function finiteTriple(value) {
  return Array.isArray(value) && value.length === 3 && value.every(function (v) { return typeof v === 'number' && isFinite(v); });
}

function startViewOf(extras) {
  var start = extras && extras.start_view;
  if (!start || !finiteTriple(start.position) || !finiteTriple(start.target)) {
    return null;
  }
  var position = new THREE.Vector3().fromArray(start.position);
  var target = new THREE.Vector3().fromArray(start.target);
  if (position.distanceTo(target) < 0.1) {
    return null;
  }
  return { position: position, target: target };
}

function outlineExtent(outline) {
  if (!Array.isArray(outline) || outline.length < 3) {
    return null;
  }
  var xs = outline.map(function (p) { return Number(p[0]); });
  var ys = outline.map(function (p) { return Number(p[1]); });
  if (!xs.concat(ys).every(isFinite)) {
    return null;
  }
  return [Math.max.apply(null, xs) - Math.min.apply(null, xs), Math.max.apply(null, ys) - Math.min.apply(null, ys)];
}

function matchRoomLabels(marks, rooms) {
  if (!Array.isArray(marks) || !Array.isArray(rooms)) {
    return [];
  }
  var pairs = [];
  marks.forEach(function (mark, markIndex) {
    if (!mark || !finiteTriple(mark.center) || !(mark.area_m2 > 0)) {
      return;
    }
    rooms.forEach(function (room, roomIndex) {
      var area = Number(room && room.floor_area_m2);
      if (!room || !room.label || !(area > 0)) {
        return;
      }
      var diff = Math.abs(area - mark.area_m2);
      if (diff > Math.max(ROOM_AREA_SLACK_M2, mark.area_m2 * ROOM_AREA_SLACK_SHARE)) {
        return;
      }
      var score = diff / mark.area_m2;
      var extent = outlineExtent(room.outline_m);
      if (extent && mark.width_m > 0 && mark.length_m > 0) {
        var straight = Math.abs(extent[0] - mark.width_m) + Math.abs(extent[1] - mark.length_m);
        var turned = Math.abs(extent[0] - mark.length_m) + Math.abs(extent[1] - mark.width_m);
        score += Math.min(straight, turned) / (mark.width_m + mark.length_m);
      }
      pairs.push({ mark: markIndex, room: roomIndex, score: score });
    });
  });
  pairs.sort(function (a, b) { return a.score - b.score; });
  var usedMarks = {};
  var usedRooms = {};
  var labels = [];
  pairs.forEach(function (pair) {
    if (usedMarks[pair.mark] || usedRooms[pair.room]) {
      return;
    }
    usedMarks[pair.mark] = true;
    usedRooms[pair.room] = true;
    var center = marks[pair.mark].center;
    labels.push({ text: String(rooms[pair.room].label), position: new THREE.Vector3(center[0], center[1] + LABEL_LIFT_M, center[2]) });
  });
  return labels;
}
var KEEP_SHARE = 0.9;
var KEEP_MARGIN_M = 2;

function weightedValue(entries, share, total) {
  var passed = 0;
  for (var i = 0; i < entries.length; i++) {
    passed += entries[i].weight;
    if (passed >= total * share) {
      return entries[i].value;
    }
  }
  return entries.length ? entries[entries.length - 1].value : 0;
}

function framingBox(parts, root) {
  var full = new THREE.Box3().setFromObject(root);
  var boxes = [];
  var total = 0;
  parts.forEach(function (part) {
    if (part.classId === CEILING_CLASS) {
      return;
    }
    var geometry = part.mesh.geometry;
    var weight = geometry.index ? geometry.index.count / 3 : geometry.getAttribute('position').count / 3;
    var box = new THREE.Box3().setFromObject(part.mesh);
    if (!(weight > 0) || box.isEmpty()) {
      return;
    }
    boxes.push({ box: box, center: box.getCenter(new THREE.Vector3()), weight: weight });
    total += weight;
  });
  if (!total) {
    return full;
  }
  var middle = new THREE.Vector3();
  ['x', 'y', 'z'].forEach(function (axis) {
    var sorted = boxes.map(function (b) { return { value: b.center[axis], weight: b.weight }; }).sort(function (a, b) { return a.value - b.value; });
    middle[axis] = weightedValue(sorted, 0.5, total);
  });
  var distances = boxes.map(function (b) { return { value: b.center.distanceTo(middle), weight: b.weight }; }).sort(function (a, b) { return a.value - b.value; });
  var reach = weightedValue(distances, KEEP_SHARE, total);
  var limit = Math.max(reach * 2, reach + KEEP_MARGIN_M);
  var kept = new THREE.Box3();
  boxes.forEach(function (b) {
    if (b.center.distanceTo(middle) <= limit) {
      kept.union(b.box);
    }
  });
  return kept.isEmpty() ? full : kept;
}

function Viewer(viewport, gltf, info, rooms) {
  var self = this;
  this.viewport = viewport;
  this.mode = 'photo';
  this.showCeiling = false;
  this.showLabels = true;
  this.frameId = 0;

  clearNode(viewport);
  var stage = document.createElement('div');
  stage.className = 'tour-model';
  var canvas = document.createElement('canvas');
  canvas.className = 'tour-model-canvas';
  stage.appendChild(canvas);
  this.bar = document.createElement('div');
  this.bar.className = 'tour-model-bar';
  stage.appendChild(this.bar);
  if (info) {
    var caption = document.createElement('p');
    caption.className = 'tour-model-caption';
    caption.textContent = info;
    stage.appendChild(caption);
  }
  this.labelLayer = document.createElement('div');
  this.labelLayer.className = 'tour-model-labels';
  stage.appendChild(this.labelLayer);
  viewport.appendChild(stage);
  this.stage = stage;

  this.renderer = new THREE.WebGLRenderer({ canvas: canvas, antialias: true });
  this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  this.scene = new THREE.Scene();
  this.scene.add(new THREE.HemisphereLight(0xffffff, 0x8a8a8a, 1.6));
  var sun = new THREE.DirectionalLight(0xffffff, 1.4);
  sun.position.set(3, 8, 5);
  this.scene.add(sun);
  this.root = gltf.scene;
  this.scene.add(this.root);
  this.parts = prepare(this.root);
  this.clay = new THREE.MeshLambertMaterial({ color: 0xd1d1d1, side: THREE.DoubleSide });
  this.wire = new THREE.MeshBasicMaterial({ color: 0x7373ff, wireframe: true });

  var full = new THREE.Box3().setFromObject(this.root);
  var box = framingBox(this.parts, this.root);
  var center = box.getCenter(new THREE.Vector3());
  var size = Math.max(box.getSize(new THREE.Vector3()).length(), 1);
  var fullSize = Math.max(full.getSize(new THREE.Vector3()).length(), size);
  this.camera = new THREE.PerspectiveCamera(50, 1, 0.02, fullSize * 20);
  this.camera.position.copy(center).add(new THREE.Vector3(0, size * 0.8, size * 0.7));
  this.controls = new OrbitControls(this.camera, canvas);
  this.controls.target.copy(center);
  this.controls.enableDamping = true;
  this.controls.screenSpacePanning = true;
  this.controls.maxDistance = size * 5;
  this.controls.update();
  this.home = { position: this.camera.position.clone(), target: center.clone() };
  this.homeOffset = new THREE.Vector3(0, size * 0.8, size * 0.7);
  this.homeFollowsAspect = true;
  var extras = gltf.scene.userData || {};
  var start = startViewOf(extras);
  if (start) {
    this.home.target.copy(start.target);
    this.homeOffset.copy(start.position).sub(start.target);
    this.homeFollowsAspect = false;
    this.controls.maxDistance = Math.max(this.controls.maxDistance, this.homeOffset.length() * 3);
  }
  this.labels = matchRoomLabels(extras.rooms, rooms).map(function (label) {
    var node = document.createElement('span');
    node.className = 'tour-model-label';
    node.textContent = label.text;
    self.labelLayer.appendChild(node);
    return { node: node, position: label.position, behind: false };
  });
  this.projected = new THREE.Vector3();
  this.occlusionRay = new THREE.Raycaster();
  this.occlusionOn = true;
  this.cameraKey = '';
  this.idleSince = 0;
  this.labelsToCheck = 0;
  this.nextLabel = 0;
  this.hasWalls = this.parts.some(function (part) { return part.classId === WALL_CLASS; });
  this.atHome = true;
  this.onControlStart = function () { self.atHome = false; };
  this.controls.addEventListener('start', this.onControlStart);

  this.raycaster = new THREE.Raycaster();
  this.onDoubleClick = function (event) { self.focusAt(event.clientX, event.clientY); };
  canvas.addEventListener('dblclick', this.onDoubleClick);
  this.lastTap = 0;
  this.onTouchEnd = function (event) {
    if (event.changedTouches.length !== 1 || event.touches.length !== 0) {
      return;
    }
    var now = Date.now();
    if (now - self.lastTap < 300) {
      var touch = event.changedTouches[0];
      self.focusAt(touch.clientX, touch.clientY);
      self.lastTap = 0;
    } else {
      self.lastTap = now;
    }
  };
  canvas.addEventListener('touchend', this.onTouchEnd);
  this.onResize = function () { self.resize(); };
  window.addEventListener('resize', this.onResize);

  this.buildBar();
  this.apply();
  this.resize();
  var loop = function () {
    self.frameId = requestAnimationFrame(loop);
    self.controls.update();
    self.renderer.render(self.scene, self.camera);
    self.placeLabels();
  };
  loop();
}

Viewer.prototype.buildBar = function () {
  var self = this;
  clearNode(this.bar);
  MODES.forEach(function (mode) {
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'tour-model-btn' + (self.mode === mode ? ' is-active' : '');
    btn.textContent = t('model_mode_' + mode);
    btn.setAttribute('aria-pressed', self.mode === mode ? 'true' : 'false');
    btn.setAttribute('data-model-mode', mode);
    btn.addEventListener('click', function () {
      self.mode = mode;
      self.apply();
      self.buildBar();
    });
    self.bar.appendChild(btn);
  });
  if (this.parts.some(function (part) { return part.classId === CEILING_CLASS; })) {
    var ceiling = document.createElement('button');
    ceiling.type = 'button';
    ceiling.className = 'tour-model-btn' + (this.showCeiling ? ' is-active' : '');
    ceiling.textContent = t('model_ceiling');
    ceiling.setAttribute('aria-pressed', this.showCeiling ? 'true' : 'false');
    ceiling.setAttribute('data-model-mode', 'ceiling');
    ceiling.addEventListener('click', function () {
      self.showCeiling = !self.showCeiling;
      self.apply();
      self.buildBar();
    });
    this.bar.appendChild(ceiling);
  }
  if (this.labels.length > 0) {
    var names = document.createElement('button');
    names.type = 'button';
    names.className = 'tour-model-btn' + (this.showLabels ? ' is-active' : '');
    names.textContent = t('model_labels');
    names.setAttribute('aria-pressed', this.showLabels ? 'true' : 'false');
    names.setAttribute('data-model-mode', 'labels');
    names.addEventListener('click', function () {
      self.showLabels = !self.showLabels;
      self.labelLayer.hidden = !self.showLabels;
      self.buildBar();
    });
    this.bar.appendChild(names);
  }
  var reset = document.createElement('button');
  reset.type = 'button';
  reset.className = 'tour-model-btn';
  reset.textContent = t('model_reset_view');
  reset.setAttribute('data-model-mode', 'reset');
  reset.addEventListener('click', function () { self.resetView(); });
  this.bar.appendChild(reset);
};

Viewer.prototype.apply = function () {
  var self = this;
  this.scene.background = new THREE.Color(this.mode === 'mesh' ? 0x000000 : 0xededed);
  this.parts.forEach(function (part) {
    part.mesh.material = self.mode === 'photo' ? part.photo : self.mode === 'clay' ? self.clay : self.wire;
    part.mesh.visible = part.classId !== CEILING_CLASS || self.showCeiling || self.mode === 'mesh';
  });
};

Viewer.prototype.focusAt = function (clientX, clientY) {
  var rect = this.renderer.domElement.getBoundingClientRect();
  var pointer = new THREE.Vector2(((clientX - rect.left) / rect.width) * 2 - 1, -((clientY - rect.top) / rect.height) * 2 + 1);
  this.raycaster.setFromCamera(pointer, this.camera);
  var hits = this.raycaster.intersectObject(this.root, true).filter(function (hit) { return hit.object.visible; });
  if (hits.length === 0) {
    return;
  }
  var offset = this.camera.position.clone().sub(this.controls.target);
  this.atHome = false;
  this.controls.target.copy(hits[0].point);
  this.camera.position.copy(hits[0].point).add(offset.multiplyScalar(0.6));
  this.controls.update();
};

Viewer.prototype.checkOcclusion = function () {
  var key = this.camera.position.toArray().concat(this.controls.target.toArray()).map(function (v) { return v.toFixed(3); }).join(',') + this.mode + this.showCeiling;
  var now = performance.now();
  if (key !== this.cameraKey) {
    this.cameraKey = key;
    this.idleSince = now;
    this.labelsToCheck = this.labels.length;
    return;
  }
  if (!this.occlusionOn || this.labelsToCheck === 0 || now - this.idleSince < OCCLUSION_IDLE_MS) {
    return;
  }
  var label = this.labels[this.nextLabel % this.labels.length];
  this.nextLabel = (this.nextLabel + 1) % this.labels.length;
  this.labelsToCheck -= 1;
  if (this.mode === 'mesh') {
    label.behind = false;
    return;
  }
  var hasWalls = this.hasWalls;
  var occluders = this.parts.filter(function (part) {
    return part.mesh.visible && (hasWalls ? part.classId === WALL_CLASS : true);
  }).map(function (part) { return part.mesh; });
  var direction = label.position.clone().sub(this.camera.position);
  var distance = direction.length();
  if (distance <= OCCLUSION_GAP_M * 2) {
    label.behind = false;
    return;
  }
  this.occlusionRay.set(this.camera.position, direction.divideScalar(distance));
  this.occlusionRay.near = 0;
  this.occlusionRay.far = distance - OCCLUSION_GAP_M;
  var started = performance.now();
  label.behind = this.occlusionRay.intersectObjects(occluders, false).length > 0;
  if (performance.now() - started > OCCLUSION_SLOW_MS) {
    this.occlusionOn = false;
    this.labels.forEach(function (each) { each.behind = false; });
  }
};

Viewer.prototype.placeLabels = function () {
  if (this.labels.length === 0 || !this.showLabels) {
    return;
  }
  this.checkOcclusion();
  var width = this.stage.clientWidth;
  var height = this.stage.clientHeight;
  var self = this;
  this.labels.forEach(function (label) {
    self.projected.copy(label.position).project(self.camera);
    var visible = self.projected.z > -1 && self.projected.z < 1 && Math.abs(self.projected.x) <= 1 && Math.abs(self.projected.y) <= 1;
    label.node.hidden = !visible;
    label.node.classList.toggle('is-behind', label.behind);
    if (visible) {
      var x = (self.projected.x + 1) / 2 * width;
      var y = (1 - self.projected.y) / 2 * height;
      label.node.style.transform = 'translate(' + x.toFixed(1) + 'px, ' + y.toFixed(1) + 'px) translate(-50%, -50%)';
    }
  });
};

Viewer.prototype.resetView = function () {
  this.atHome = true;
  this.camera.position.copy(this.home.position);
  this.controls.target.copy(this.home.target);
  this.controls.update();
};

Viewer.prototype.resize = function () {
  var width = Math.max(this.stage.clientWidth, 1);
  var height = Math.max(this.stage.clientHeight, 1);
  this.renderer.setSize(width, height, false);
  this.camera.aspect = width / height;
  this.camera.updateProjectionMatrix();
  var scale = this.homeFollowsAspect ? Math.min(PORTRAIT_MAX_PULL_BACK, Math.max(1, 1 / this.camera.aspect)) : 1;
  this.home.position.copy(this.home.target).add(this.homeOffset.clone().multiplyScalar(scale));
  if (this.atHome) {
    this.camera.position.copy(this.home.position);
    this.controls.target.copy(this.home.target);
    this.controls.update();
  }
};

Viewer.prototype.dispose = function () {
  cancelAnimationFrame(this.frameId);
  window.removeEventListener('resize', this.onResize);
  this.renderer.domElement.removeEventListener('dblclick', this.onDoubleClick);
  this.renderer.domElement.removeEventListener('touchend', this.onTouchEnd);
  this.controls.removeEventListener('start', this.onControlStart);
  this.controls.dispose();
  this.root.traverse(function (object) {
    if (object.isMesh) {
      object.geometry.dispose();
    }
  });
  this.parts.forEach(function (part) {
    if (part.photo.map) {
      part.photo.map.dispose();
    }
    part.photo.dispose();
  });
  this.clay.dispose();
  this.wire.dispose();
  this.renderer.dispose();
};

function caption(model) {
  if (!model) {
    return '';
  }
  var parts = [];
  if (typeof model.triangles === 'number') {
    parts.push(t('model_triangles', { count: model.triangles.toLocaleString() }));
  }
  if (typeof model.photos === 'number' && model.photos > 0) {
    parts.push(t(model.photos === 1 ? 'model_photo_one' : 'model_photos', { count: model.photos }));
  }
  return parts.join(' · ');
}

function render(viewport, model, buildUrl, rooms) {
  stop();
  if (!model || !model.url) {
    status(viewport, t('model_unavailable'), false);
    return;
  }
  var loading = status(viewport, t('loading_3d'), false);
  var token = {};
  active = { dispose: function () { token.cancelled = true; } };
  fetch(buildUrl(model.url), { credentials: 'omit' })
    .then(function (res) {
      if (!res.ok) {
        throw new Error('HTTP ' + res.status);
      }
      var total = Number(res.headers.get('Content-Length')) || 0;
      if (!res.body || !total) {
        return res.arrayBuffer();
      }
      var reader = res.body.getReader();
      var chunks = [];
      var received = 0;
      var pump = function () {
        return reader.read().then(function (step) {
          if (step.done) {
            var out = new Uint8Array(received);
            var at = 0;
            chunks.forEach(function (chunk) { out.set(chunk, at); at += chunk.length; });
            return out.buffer;
          }
          chunks.push(step.value);
          received += step.value.length;
          if (!token.cancelled) {
            loading.textContent = t('model_loading_percent', { percent: Math.min(100, Math.round(received * 100 / total)) });
          }
          return pump();
        });
      };
      return pump();
    })
    .then(function (buffer) {
      return new Promise(function (resolve, reject) {
        new GLTFLoader().parse(buffer, '', resolve, reject);
      });
    })
    .then(function (gltf) {
      if (token.cancelled) {
        return;
      }
      fitTextures(gltf.scene, textureBudget());
      active = new Viewer(viewport, gltf, caption(model), rooms);
    })
    .catch(function (err) {
      if (token.cancelled) {
        return;
      }
      status(viewport, t('model_load_failed', { reason: err && err.message ? err.message : 'unknown error' }), true);
    });
}

window.TourModel = { render: render, stop: stop };
window.dispatchEvent(new Event('tourmodelready'));
