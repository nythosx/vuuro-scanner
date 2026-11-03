(function () {
  'use strict';

  var NEAR_M = 0.05;
  var FAR_M = 200;
  var MIN_MS = 800;
  var MAX_MS = 1600;
  var BASE_MS = 650;
  var MS_PER_M = 260;
  var FEATHER = 0.12;
  var DEPTH_GRID = 64;
  var GRAZING_COS = 0.12;
  var BLEND_RATIO = 1.05;
  var FACE_SLACK = 0.003;
  var CUBE_FACES = [
    { fwd: [0, 0, -1], right: [1, 0, 0], up: [0, 1, 0] },
    { fwd: [1, 0, 0], right: [0, 0, 1], up: [0, 1, 0] },
    { fwd: [0, 0, 1], right: [-1, 0, 0], up: [0, 1, 0] },
    { fwd: [-1, 0, 0], right: [0, 0, -1], up: [0, 1, 0] },
    { fwd: [0, 1, 0], right: [1, 0, 0], up: [0, 0, 1] },
    { fwd: [0, -1, 0], right: [1, 0, 0], up: [0, 0, -1] }
  ];

  var VS = 'attribute vec3 a_pos;attribute float a_shade;uniform vec3 u_eye;uniform vec3 u_right;uniform vec3 u_up;uniform vec3 u_fwd;uniform vec2 u_scale;uniform vec2 u_depth;varying vec3 v_world;varying float v_shade;void main(){vec3 r=a_pos-u_eye;float z=dot(r,u_fwd);gl_Position=vec4(dot(r,u_right)*u_scale.x,dot(r,u_up)*u_scale.y,z*u_depth.x+u_depth.y,z);v_world=a_pos;v_shade=a_shade;}';
  var PRECISION = '#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n';
  var SOLID_FS = PRECISION + 'uniform vec3 u_color;varying vec3 v_world;varying float v_shade;void main(){gl_FragColor=vec4(min(u_color*v_shade,vec3(1.0)),1.0);}';
  var PHOTO_FS = PRECISION + 'uniform sampler2D u_tex;uniform vec3 u_center;uniform vec3 u_pr;uniform vec3 u_pu;uniform vec3 u_pf;uniform vec4 u_frame;uniform vec3 u_gain;uniform float u_alpha;uniform float u_feather;uniform float u_slack;varying vec3 v_world;varying float v_shade;void main(){vec3 d=v_world-u_center;float z=dot(d,u_pf);if(z<0.05)discard;float x=dot(d,u_pr)/z;float y=dot(d,u_pu)/z;vec2 uv=vec2((x-u_frame.x)/(u_frame.y-u_frame.x),(u_frame.z-y)/(u_frame.z-u_frame.w));if(uv.x<-u_slack||uv.x>1.0+u_slack||uv.y<-u_slack||uv.y>1.0+u_slack)discard;uv=clamp(uv,0.0,1.0);float a=1.0;if(u_feather>0.0){float e=u_feather;a=smoothstep(0.0,e,uv.x)*smoothstep(0.0,e,1.0-uv.x)*smoothstep(0.0,e,uv.y)*smoothstep(0.0,e,1.0-uv.y);}vec3 c=min(texture2D(u_tex,uv).rgb*u_gain,vec3(1.0));gl_FragColor=vec4(c,a*u_alpha);}';
  var BLIT_VS = 'attribute vec2 a_pos;varying vec2 v_uv;void main(){v_uv=a_pos*0.5+0.5;gl_Position=vec4(a_pos,0.0,1.0);}';
  var BLIT_FS = PRECISION + 'uniform sampler2D u_tex;uniform float u_alpha;varying vec2 v_uv;void main(){gl_FragColor=vec4(texture2D(u_tex,v_uv).rgb,u_alpha);}';

  function enabled() {
    try {
      return new URLSearchParams(window.location.search).get('transition') !== 'fade';
    } catch (err) {
      return false;
    }
  }

  function depthEnabled() {
    try {
      return new URLSearchParams(window.location.search).get('transition') !== 'box';
    } catch (err) {
      return true;
    }
  }

  function compile(gl, vsSource, fsSource) {
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

  function locations(gl, prog, uniforms) {
    var out = { prog: prog, pos: gl.getAttribLocation(prog, 'a_pos'), shade: gl.getAttribLocation(prog, 'a_shade') };
    uniforms.forEach(function (name) { out[name] = gl.getUniformLocation(prog, 'u_' + name); });
    return out;
  }

  function programs(gl) {
    if (gl.__tourTransition) return gl.__tourTransition;
    var solid = compile(gl, VS, SOLID_FS);
    var photo = compile(gl, VS, PHOTO_FS);
    if (!solid || !photo) return null;
    var blit = compile(gl, BLIT_VS, BLIT_FS);
    var common = ['eye', 'right', 'up', 'fwd', 'scale', 'depth'];
    gl.__tourTransition = {
      solid: locations(gl, solid, common.concat(['color'])),
      photo: locations(gl, photo, common.concat(['tex', 'center', 'pr', 'pu', 'pf', 'frame', 'gain', 'alpha', 'feather', 'slack'])),
      blit: blit ? locations(gl, blit, ['tex', 'alpha']) : null
    };
    return gl.__tourTransition;
  }

  function cubeLookup(cube, dir) {
    var x = dir[0];
    var y = dir[1];
    var z = dir[2];
    var ax = Math.abs(x);
    var ay = Math.abs(y);
    var az = Math.abs(z);
    var f;
    var s;
    var t;
    if (ax >= ay && ax >= az) {
      if (ax < 1e-9) return 0;
      f = x > 0 ? 1 : 3;
      s = x > 0 ? z / ax : -z / ax;
      t = y / ax;
    } else if (ay >= az) {
      f = y > 0 ? 4 : 5;
      s = x / ay;
      t = y > 0 ? z / ay : -z / ay;
    } else {
      f = z < 0 ? 0 : 2;
      s = z < 0 ? x / az : -x / az;
      t = y / az;
    }
    var n = cube.size;
    var fx = (s + 1) * n / 2 - 0.5;
    var fy = (1 - t) * n / 2 - 0.5;
    var x0 = Math.max(0, Math.min(n - 1, Math.floor(fx)));
    var y0 = Math.max(0, Math.min(n - 1, Math.floor(fy)));
    var x1 = Math.min(n - 1, x0 + 1);
    var y1 = Math.min(n - 1, y0 + 1);
    var wx = Math.max(0, Math.min(1, fx - x0));
    var wy = Math.max(0, Math.min(1, fy - y0));
    var base = f * n * n;
    var v = cube.view;
    var d00 = v.getUint16((base + y0 * n + x0) * 2, true);
    var d10 = v.getUint16((base + y0 * n + x1) * 2, true);
    var d01 = v.getUint16((base + y1 * n + x0) * 2, true);
    var d11 = v.getUint16((base + y1 * n + x1) * 2, true);
    var w00 = (1 - wx) * (1 - wy);
    var w10 = wx * (1 - wy);
    var w01 = (1 - wx) * wy;
    var w11 = wx * wy;
    var lo = Math.min(d00, d10, d01, d11);
    var hi = Math.max(d00, d10, d01, d11);
    if (lo > 0 && hi <= lo * BLEND_RATIO) {
      return (d00 * w00 + d10 * w10 + d01 * w01 + d11 * w11) / 1000;
    }
    var best = 0;
    var bestW = -1;
    [[d00, w00], [d10, w10], [d01, w01], [d11, w11]].forEach(function (c) {
      if (c[0] > 0 && c[1] > bestW) {
        best = c[0];
        bestW = c[1];
      }
    });
    return best / 1000;
  }

  function depthMesh(gl, cube) {
    var g = DEPTH_GRID;
    var c = cube.center;
    var data = new Float32Array(CUBE_FACES.length * g * g * 2 * 3 * 4);
    var n = 0;
    var ranges = [];
    var row = g + 1;
    var pts = new Float32Array(row * row * 3);
    var ok = new Uint8Array(row * row);
    function grazing(a, b, d) {
      var ux = pts[b] - pts[a];
      var uy = pts[b + 1] - pts[a + 1];
      var uz = pts[b + 2] - pts[a + 2];
      var vx = pts[d] - pts[a];
      var vy = pts[d + 1] - pts[a + 1];
      var vz = pts[d + 2] - pts[a + 2];
      var nx = uy * vz - uz * vy;
      var ny = uz * vx - ux * vz;
      var nz = ux * vy - uy * vx;
      var rx = (pts[a] + pts[b] + pts[d]) / 3 - c[0];
      var ry = (pts[a + 1] + pts[b + 1] + pts[d + 1]) / 3 - c[1];
      var rz = (pts[a + 2] + pts[b + 2] + pts[d + 2]) / 3 - c[2];
      var nl = Math.sqrt(nx * nx + ny * ny + nz * nz);
      var rl = Math.sqrt(rx * rx + ry * ry + rz * rz);
      if (nl < 1e-12 || rl < 1e-9) return true;
      return Math.abs(nx * rx + ny * ry + nz * rz) / (nl * rl) < GRAZING_COS;
    }
    function tri(a, b, d) {
      if (!ok[a] || !ok[b] || !ok[d]) return;
      if (grazing(a * 3, b * 3, d * 3)) return;
      [a, b, d].forEach(function (k) {
        data[n++] = pts[k * 3];
        data[n++] = pts[k * 3 + 1];
        data[n++] = pts[k * 3 + 2];
        data[n++] = 1;
      });
    }
    CUBE_FACES.forEach(function (face) {
      var first = n / 4;
      for (var j = 0; j <= g; j++) {
        var t = 1 - 2 * j / g;
        for (var i = 0; i <= g; i++) {
          var s = -1 + 2 * i / g;
          var dx = face.fwd[0] + face.right[0] * s + face.up[0] * t;
          var dy = face.fwd[1] + face.right[1] * s + face.up[1] * t;
          var dz = face.fwd[2] + face.right[2] * s + face.up[2] * t;
          var len = Math.sqrt(dx * dx + dy * dy + dz * dz);
          dx /= len;
          dy /= len;
          dz /= len;
          var r = cubeLookup(cube, [dx, dy, dz]);
          var k = j * row + i;
          ok[k] = r > 0 ? 1 : 0;
          pts[k * 3] = c[0] + dx * r;
          pts[k * 3 + 1] = c[1] + dy * r;
          pts[k * 3 + 2] = c[2] + dz * r;
        }
      }
      for (var jj = 0; jj < g; jj++) {
        for (var ii = 0; ii < g; ii++) {
          var a = jj * row + ii;
          tri(a, a + 1, a + row + 1);
          tri(a, a + row + 1, a + row);
        }
      }
      ranges.push({ first: first, count: n / 4 - first });
    });
    if (n === 0) return null;
    var buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, data.subarray(0, n), gl.STATIC_DRAW);
    return { buf: buf, count: n / 4, ranges: ranges };
  }

  function validCube(cube) {
    return !!(cube && cube.view && cube.size > 0 && Array.isArray(cube.center) && cube.center.length === 3 &&
      cube.view.byteLength === CUBE_FACES.length * cube.size * cube.size * 2);
  }

  function makeTarget(gl, w, h) {
    var tex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    var rb = gl.createRenderbuffer();
    gl.bindRenderbuffer(gl.RENDERBUFFER, rb);
    gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT16, w, h);
    var fb = gl.createFramebuffer();
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, rb);
    var complete = gl.checkFramebufferStatus(gl.FRAMEBUFFER) === gl.FRAMEBUFFER_COMPLETE;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.bindRenderbuffer(gl.RENDERBUFFER, null);
    var target = { fb: fb, tex: tex, rb: rb, w: w, h: h };
    if (complete) return target;
    releaseTarget(gl, target);
    return null;
  }

  function releaseTarget(gl, target) {
    if (!target) return;
    gl.deleteFramebuffer(target.fb);
    gl.deleteRenderbuffer(target.rb);
    gl.deleteTexture(target.tex);
  }

  function area2(poly) {
    var s = 0;
    for (var i = 0; i < poly.length; i++) {
      var a = poly[i];
      var b = poly[(i + 1) % poly.length];
      s += a[0] * b[1] - b[0] * a[1];
    }
    return s;
  }

  function inTriangle(p, a, b, c) {
    var d1 = (p[0] - b[0]) * (a[1] - b[1]) - (a[0] - b[0]) * (p[1] - b[1]);
    var d2 = (p[0] - c[0]) * (b[1] - c[1]) - (b[0] - c[0]) * (p[1] - c[1]);
    var d3 = (p[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (p[1] - a[1]);
    var neg = d1 < 0 || d2 < 0 || d3 < 0;
    var pos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(neg && pos);
  }

  function triangulate(poly) {
    var idx = poly.map(function (_, i) { return i; });
    if (area2(poly) < 0) idx.reverse();
    var out = [];
    var guard = 0;
    while (idx.length > 3 && guard++ < 1000) {
      var clipped = false;
      for (var i = 0; i < idx.length; i++) {
        var ia = idx[(i + idx.length - 1) % idx.length];
        var ib = idx[i];
        var ic = idx[(i + 1) % idx.length];
        var a = poly[ia];
        var b = poly[ib];
        var c = poly[ic];
        var cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
        if (cross <= 1e-9) continue;
        var blocked = false;
        for (var j = 0; j < idx.length && !blocked; j++) {
          var k = idx[j];
          if (k === ia || k === ib || k === ic) continue;
          if (inTriangle(poly[k], a, b, c)) blocked = true;
        }
        if (blocked) continue;
        out.push([ia, ib, ic]);
        idx.splice(i, 1);
        clipped = true;
        break;
      }
      if (!clipped) break;
    }
    if (idx.length === 3) out.push([idx[0], idx[1], idx[2]]);
    if (idx.length > 3) {
      for (var f = 1; f < idx.length - 1; f++) out.push([idx[0], idx[f], idx[f + 1]]);
    }
    return out;
  }

  function roomMesh(gl, room) {
    var poly = room.outline;
    var h = room.height;
    var data = [];
    function v(x, y, z, shade) { data.push(x, y, z, shade); }
    for (var i = 0; i < poly.length; i++) {
      var a = poly[i];
      var b = poly[(i + 1) % poly.length];
      v(a[0], 0, a[1], 1); v(b[0], 0, b[1], 1); v(b[0], h, b[1], 1);
      v(a[0], 0, a[1], 1); v(b[0], h, b[1], 1); v(a[0], h, a[1], 1);
    }
    triangulate(poly).forEach(function (t) {
      for (var k = 0; k < 3; k++) v(poly[t[k]][0], 0, poly[t[k]][1], 0.72);
      for (var m = 0; m < 3; m++) v(poly[t[m]][0], h, poly[t[m]][1], 1.12);
    });
    var buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(data), gl.STATIC_DRAW);
    return { buf: buf, count: data.length / 4 };
  }

  function uploadImage(gl, img, maxTexture) {
    if (!img || !img.naturalWidth) return null;
    var source = img;
    var longest = Math.max(img.naturalWidth, img.naturalHeight);
    if (longest > maxTexture) {
      var s = maxTexture / longest;
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
      return null;
    }
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return tex;
  }

  function basis(yawDeg, pitchDeg) {
    var t = yawDeg * Math.PI / 180;
    var p = pitchDeg * Math.PI / 180;
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

  function shortestDelta(from, to) {
    var d = (to - from) % 360;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return d;
  }

  function ease(t) {
    return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  }

  function smoothstep(a, b, x) {
    var t = Math.max(0, Math.min(1, (x - a) / (b - a)));
    return t * t * (3 - 2 * t);
  }

  function lerp(a, b, t) {
    return a + (b - a) * t;
  }

  function durationFor(from, to) {
    var dx = to[0] - from[0];
    var dz = to[2] - from[2];
    return Math.max(MIN_MS, Math.min(MAX_MS, BASE_MS + MS_PER_M * Math.sqrt(dx * dx + dz * dz)));
  }

  function run(opts) {
    var gl = opts.ctx;
    var progs = programs(gl);
    if (!progs) return null;
    var meshes = opts.rooms.map(function (room) { return roomMesh(gl, room); });
    var owned = [];
    var sources = [];
    opts.sources.forEach(function (s) {
      var tex = s.tex;
      if (!tex && s.img) {
        tex = uploadImage(gl, s.img, opts.maxTexture);
        if (tex) owned.push(tex);
      }
      if (!tex || !meshes[s.room]) return;
      sources.push({ tex: tex, pose: s.pose, frame: s.frame, center: s.center, gain: s.gain || [1, 1, 1], feather: typeof s.feather === 'number' ? s.feather : FEATHER, set: s.set, room: s.room, face: typeof s.face === 'number' && s.face >= 0 && s.face < CUBE_FACES.length ? s.face : -1 });
    });
    var depthMeshes = [null, null];
    var quad = null;
    var target = null;
    if (depthEnabled() && progs.blit && Array.isArray(opts.depth)) {
      [0, 1].forEach(function (set) {
        if (validCube(opts.depth[set])) depthMeshes[set] = depthMesh(gl, opts.depth[set]);
      });
      if (depthMeshes[0] || depthMeshes[1]) {
        quad = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, quad);
        gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, -1, 1, 1, -1, 1, 1]), gl.STATIC_DRAW);
      }
    }
    var layered = !!quad;
    var from = opts.from;
    var to = opts.to;
    var yawDelta = shortestDelta(from.yaw, to.yaw);
    var duration = opts.durationMs || durationFor(from.eye, to.eye);
    var start = null;
    var frame = null;
    var finished = false;

    function cleanup() {
      meshes.forEach(function (m) { gl.deleteBuffer(m.buf); });
      owned.forEach(function (t) { gl.deleteTexture(t); });
      depthMeshes.forEach(function (m) { if (m) gl.deleteBuffer(m.buf); });
      if (quad) gl.deleteBuffer(quad);
      releaseTarget(gl, target);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      meshes = [];
      owned = [];
      depthMeshes = [null, null];
      quad = null;
      target = null;
    }

    function bindMesh(p, mesh) {
      gl.bindBuffer(gl.ARRAY_BUFFER, mesh.buf);
      gl.enableVertexAttribArray(p.pos);
      gl.vertexAttribPointer(p.pos, 3, gl.FLOAT, false, 16, 0);
      if (p.shade >= 0) {
        gl.enableVertexAttribArray(p.shade);
        gl.vertexAttribPointer(p.shade, 1, gl.FLOAT, false, 16, 12);
      }
    }

    function setView(p, view, sx, sy) {
      gl.uniform3fv(p.eye, view.eye);
      gl.uniform3fv(p.right, view.basis.right);
      gl.uniform3fv(p.up, view.basis.up);
      gl.uniform3fv(p.fwd, view.basis.fwd);
      gl.uniform2f(p.scale, sx, sy);
      gl.uniform2f(p.depth, (FAR_M + NEAR_M) / (FAR_M - NEAR_M), -2 * FAR_M * NEAR_M / (FAR_M - NEAR_M));
    }

    function viewAt(t) {
      var move = ease(t);
      var turn = ease(Math.min(1, t * 1.5));
      return {
        eye: [lerp(from.eye[0], to.eye[0], move), lerp(from.eye[1], to.eye[1], move), lerp(from.eye[2], to.eye[2], move)],
        yaw: from.yaw + yawDelta * turn,
        pitch: lerp(from.pitch, to.pitch, turn),
        fov: lerp(from.fov, to.fov, turn),
        mix: smoothstep(0.2, 0.85, t)
      };
    }

    function draw(t) {
      var size = opts.size();
      var width = size[0];
      var height = size[1];
      var dpr = Math.min(2, window.devicePixelRatio || 1);
      var cw = Math.max(1, Math.round(width * dpr));
      var ch = Math.max(1, Math.round(height * dpr));
      if (opts.canvas.width !== cw || opts.canvas.height !== ch) {
        opts.canvas.width = cw;
        opts.canvas.height = ch;
      }
      gl.viewport(0, 0, cw, ch);
      var v = viewAt(t);
      v.basis = basis(v.yaw, v.pitch);
      var focal = Math.max(width, height) / 2 / Math.tan(v.fov * Math.PI / 360);
      var sx = focal / (width / 2);
      var sy = focal / (height / 2);
      var bg = opts.background;
      if (layered) layered = drawLayered(v, sx, sy, cw, ch);
      if (layered) {
        if (opts.onFrame) opts.onFrame(v);
        return;
      }
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.clearColor(bg[0] * 0.6, bg[1] * 0.6, bg[2] * 0.6, 1);
      gl.clearDepth(1);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.enable(gl.DEPTH_TEST);
      gl.depthFunc(gl.LESS);
      gl.depthMask(true);
      gl.disable(gl.BLEND);
      gl.disable(gl.CULL_FACE);
      solidPass(v, sx, sy, meshes);
      [0, 1].forEach(function (set) {
        var alpha = set === 0 ? 1 : v.mix;
        if (alpha <= 0.001) return;
        photoPass(setList(set, v), v, sx, sy, alpha, roomTarget);
      });
      gl.depthMask(true);
      gl.disable(gl.DEPTH_TEST);
      if (opts.onFrame) opts.onFrame(v);
    }

    function roomTarget(s) {
      var m = meshes[s.room];
      return m ? { mesh: m, first: 0, count: m.count } : null;
    }

    function setList(set, v) {
      var list = sources.filter(function (s) { return s.set === set; });
      list.sort(function (a, b) {
        var fa = a.pose.fwd[0] * v.basis.fwd[0] + a.pose.fwd[1] * v.basis.fwd[1] + a.pose.fwd[2] * v.basis.fwd[2];
        var fb = b.pose.fwd[0] * v.basis.fwd[0] + b.pose.fwd[1] * v.basis.fwd[1] + b.pose.fwd[2] * v.basis.fwd[2];
        return fa - fb;
      });
      return list;
    }

    function solidPass(v, sx, sy, list) {
      var sp = progs.solid;
      gl.useProgram(sp.prog);
      setView(sp, v, sx, sy);
      gl.uniform3fv(sp.color, opts.background);
      list.forEach(function (mesh) {
        bindMesh(sp, mesh);
        gl.drawArrays(gl.TRIANGLES, 0, mesh.count);
      });
    }

    function photoPass(list, v, sx, sy, alpha, targetFor) {
      gl.depthMask(false);
      gl.depthFunc(gl.LEQUAL);
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
      var pp = progs.photo;
      gl.useProgram(pp.prog);
      setView(pp, v, sx, sy);
      gl.uniform1i(pp.tex, 0);
      gl.activeTexture(gl.TEXTURE0);
      list.forEach(function (s) {
        var t = targetFor(s);
        if (!t || t.count <= 0) return;
        gl.uniform3fv(pp.center, s.center);
        gl.uniform3fv(pp.pr, s.pose.right);
        gl.uniform3fv(pp.pu, s.pose.up);
        gl.uniform3fv(pp.pf, s.pose.fwd);
        gl.uniform4f(pp.frame, s.frame.left, s.frame.right, s.frame.top, s.frame.bottom);
        gl.uniform3fv(pp.gain, s.gain);
        gl.uniform1f(pp.alpha, alpha);
        gl.uniform1f(pp.feather, s.feather);
        gl.uniform1f(pp.slack, s.face >= 0 ? FACE_SLACK : 0);
        gl.bindTexture(gl.TEXTURE_2D, s.tex);
        bindMesh(pp, t.mesh);
        gl.drawArrays(gl.TRIANGLES, t.first, t.count);
      });
      gl.disableVertexAttribArray(pp.pos);
      if (pp.shade >= 0) gl.disableVertexAttribArray(pp.shade);
    }

    function drawSet(set, v, sx, sy) {
      var list = setList(set, v);
      gl.enable(gl.DEPTH_TEST);
      gl.depthFunc(gl.LESS);
      gl.depthMask(true);
      gl.disable(gl.BLEND);
      gl.disable(gl.CULL_FACE);
      solidPass(v, sx, sy, meshes);
      photoPass(list, v, sx, sy, 1, roomTarget);
      var dm = depthMeshes[set];
      if (!dm) return;
      gl.depthMask(true);
      gl.clear(gl.DEPTH_BUFFER_BIT);
      gl.depthFunc(gl.LESS);
      gl.disable(gl.BLEND);
      solidPass(v, sx, sy, [dm]);
      photoPass(list, v, sx, sy, 1, function (s) {
        var r = s.face >= 0 ? dm.ranges[s.face] : null;
        return r ? { mesh: dm, first: r.first, count: r.count } : { mesh: dm, first: 0, count: dm.count };
      });
    }

    function clearTo(bg) {
      gl.clearColor(bg[0] * 0.6, bg[1] * 0.6, bg[2] * 0.6, 1);
      gl.clearDepth(1);
      gl.depthMask(true);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    }

    function drawLayered(v, sx, sy, cw, ch) {
      var needTop = v.mix > 0.001 && sources.some(function (s) { return s.set === 1; });
      if (needTop && (!target || target.w !== cw || target.h !== ch)) {
        releaseTarget(gl, target);
        target = makeTarget(gl, cw, ch);
        if (!target) return false;
      }
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.viewport(0, 0, cw, ch);
      clearTo(opts.background);
      drawSet(0, v, sx, sy);
      if (needTop) {
        gl.bindFramebuffer(gl.FRAMEBUFFER, target.fb);
        gl.viewport(0, 0, cw, ch);
        clearTo(opts.background);
        drawSet(1, v, sx, sy);
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(0, 0, cw, ch);
        gl.disable(gl.DEPTH_TEST);
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        var bp = progs.blit;
        gl.useProgram(bp.prog);
        gl.bindBuffer(gl.ARRAY_BUFFER, quad);
        gl.enableVertexAttribArray(bp.pos);
        gl.vertexAttribPointer(bp.pos, 2, gl.FLOAT, false, 8, 0);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, target.tex);
        gl.uniform1i(bp.tex, 0);
        gl.uniform1f(bp.alpha, v.mix);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
        gl.disableVertexAttribArray(bp.pos);
      }
      gl.depthMask(true);
      gl.disable(gl.DEPTH_TEST);
      return true;
    }

    function snapshot() {
      try {
        var c = document.createElement('canvas');
        c.width = opts.canvas.width;
        c.height = opts.canvas.height;
        c.getContext('2d').drawImage(opts.canvas, 0, 0);
        return c;
      } catch (err) {
        return null;
      }
    }

    function step(now) {
      frame = null;
      if (finished) return;
      if (start === null) start = now;
      var t = Math.min(1, (now - start) / duration);
      draw(t);
      if (t < 1) {
        frame = requestAnimationFrame(step);
        return;
      }
      finished = true;
      var shot = snapshot();
      cleanup();
      if (opts.onDone) opts.onDone(shot);
    }

    frame = requestAnimationFrame(step);
    return {
      cancel: function () {
        if (finished) return;
        finished = true;
        if (frame) cancelAnimationFrame(frame);
        frame = null;
        try {
          cleanup();
        } catch (err) {}
      }
    };
  }

  window.TourTransition = { enabled: enabled, depthEnabled: depthEnabled, run: run, triangulate: triangulate, depthMesh: depthMesh, cubeLookup: cubeLookup };
})();
