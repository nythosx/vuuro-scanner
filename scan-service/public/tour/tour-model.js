import * as THREE from './vendor/three/three.module.min.js';
import { GLTFLoader } from './vendor/three/GLTFLoader.js';
import { OrbitControls } from './vendor/three/OrbitControls.js';

var CEILING_CLASS = 3;
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

function Viewer(viewport, gltf, info) {
  var self = this;
  this.viewport = viewport;
  this.mode = 'photo';
  this.showCeiling = false;
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

  var box = new THREE.Box3().setFromObject(this.root);
  var center = box.getCenter(new THREE.Vector3());
  var size = Math.max(box.getSize(new THREE.Vector3()).length(), 1);
  this.camera = new THREE.PerspectiveCamera(50, 1, 0.05, size * 20);
  this.camera.position.copy(center).add(new THREE.Vector3(0, size * 0.8, size * 0.7));
  this.controls = new OrbitControls(this.camera, canvas);
  this.controls.target.copy(center);
  this.controls.enableDamping = true;
  this.controls.screenSpacePanning = true;
  this.controls.maxDistance = size * 5;
  this.controls.update();
  this.home = { position: this.camera.position.clone(), target: center.clone() };

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
  this.controls.target.copy(hits[0].point);
  this.camera.position.copy(hits[0].point).add(offset.multiplyScalar(0.6));
  this.controls.update();
};

Viewer.prototype.resetView = function () {
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
};

Viewer.prototype.dispose = function () {
  cancelAnimationFrame(this.frameId);
  window.removeEventListener('resize', this.onResize);
  this.renderer.domElement.removeEventListener('dblclick', this.onDoubleClick);
  this.renderer.domElement.removeEventListener('touchend', this.onTouchEnd);
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

function render(viewport, model, buildUrl) {
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
      active = new Viewer(viewport, gltf, caption(model));
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
