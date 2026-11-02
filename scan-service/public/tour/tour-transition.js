(function () {
  'use strict';

  var NEAR_M = 0.05;
  var FAR_M = 200;
  var MIN_MS = 800;
  var MAX_MS = 1600;
  var BASE_MS = 650;
  var MS_PER_M = 260;
  var FEATHER = 0.12;

  var VS = 'attribute vec3 a_pos;attribute float a_shade;uniform vec3 u_eye;uniform vec3 u_right;uniform vec3 u_up;uniform vec3 u_fwd;uniform vec2 u_scale;uniform vec2 u_depth;varying vec3 v_world;varying float v_shade;void main(){vec3 r=a_pos-u_eye;float z=dot(r,u_fwd);gl_Position=vec4(dot(r,u_right)*u_scale.x,dot(r,u_up)*u_scale.y,z*u_depth.x+u_depth.y,z);v_world=a_pos;v_shade=a_shade;}';
  var PRECISION = '#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n';
  var SOLID_FS = PRECISION + 'uniform vec3 u_color;varying vec3 v_world;varying float v_shade;void main(){gl_FragColor=vec4(min(u_color*v_shade,vec3(1.0)),1.0);}';
  var PHOTO_FS = PRECISION + 'uniform sampler2D u_tex;uniform vec3 u_center;uniform vec3 u_pr;uniform vec3 u_pu;uniform vec3 u_pf;uniform vec4 u_frame;uniform vec3 u_gain;uniform float u_alpha;uniform float u_feather;varying vec3 v_world;varying float v_shade;void main(){vec3 d=v_world-u_center;float z=dot(d,u_pf);if(z<0.05)discard;float x=dot(d,u_pr)/z;float y=dot(d,u_pu)/z;vec2 uv=vec2((x-u_frame.x)/(u_frame.y-u_frame.x),(u_frame.z-y)/(u_frame.z-u_frame.w));if(uv.x<0.0||uv.x>1.0||uv.y<0.0||uv.y>1.0)discard;float a=1.0;if(u_feather>0.0){float e=u_feather;a=smoothstep(0.0,e,uv.x)*smoothstep(0.0,e,1.0-uv.x)*smoothstep(0.0,e,uv.y)*smoothstep(0.0,e,1.0-uv.y);}vec3 c=min(texture2D(u_tex,uv).rgb*u_gain,vec3(1.0));gl_FragColor=vec4(c,a*u_alpha);}';

  function enabled() {
    try {
      return new URLSearchParams(window.location.search).get('transition') !== 'fade';
    } catch (err) {
      return false;
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
    var common = ['eye', 'right', 'up', 'fwd', 'scale', 'depth'];
    gl.__tourTransition = {
      solid: locations(gl, solid, common.concat(['color'])),
      photo: locations(gl, photo, common.concat(['tex', 'center', 'pr', 'pu', 'pf', 'frame', 'gain', 'alpha', 'feather']))
    };
    return gl.__tourTransition;
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
      sources.push({ tex: tex, pose: s.pose, frame: s.frame, center: s.center, gain: s.gain || [1, 1, 1], feather: typeof s.feather === 'number' ? s.feather : FEATHER, set: s.set, room: s.room });
    });
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
      meshes = [];
      owned = [];
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
      gl.clearColor(bg[0] * 0.6, bg[1] * 0.6, bg[2] * 0.6, 1);
      gl.clearDepth(1);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.enable(gl.DEPTH_TEST);
      gl.depthFunc(gl.LESS);
      gl.depthMask(true);
      gl.disable(gl.BLEND);
      gl.disable(gl.CULL_FACE);

      var sp = progs.solid;
      gl.useProgram(sp.prog);
      setView(sp, v, sx, sy);
      gl.uniform3fv(sp.color, bg);
      meshes.forEach(function (mesh) {
        bindMesh(sp, mesh);
        gl.drawArrays(gl.TRIANGLES, 0, mesh.count);
      });

      gl.depthMask(false);
      gl.depthFunc(gl.LEQUAL);
      gl.enable(gl.BLEND);
      gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
      var pp = progs.photo;
      gl.useProgram(pp.prog);
      setView(pp, v, sx, sy);
      gl.uniform1i(pp.tex, 0);
      gl.activeTexture(gl.TEXTURE0);
      [0, 1].forEach(function (set) {
        var alpha = set === 0 ? 1 : v.mix;
        if (alpha <= 0.001) return;
        var list = sources.filter(function (s) { return s.set === set; });
        list.sort(function (a, b) {
          var fa = a.pose.fwd[0] * v.basis.fwd[0] + a.pose.fwd[1] * v.basis.fwd[1] + a.pose.fwd[2] * v.basis.fwd[2];
          var fb = b.pose.fwd[0] * v.basis.fwd[0] + b.pose.fwd[1] * v.basis.fwd[1] + b.pose.fwd[2] * v.basis.fwd[2];
          return fa - fb;
        });
        list.forEach(function (s) {
          gl.uniform3fv(pp.center, s.center);
          gl.uniform3fv(pp.pr, s.pose.right);
          gl.uniform3fv(pp.pu, s.pose.up);
          gl.uniform3fv(pp.pf, s.pose.fwd);
          gl.uniform4f(pp.frame, s.frame.left, s.frame.right, s.frame.top, s.frame.bottom);
          gl.uniform3fv(pp.gain, s.gain);
          gl.uniform1f(pp.alpha, alpha);
          gl.uniform1f(pp.feather, s.feather);
          gl.bindTexture(gl.TEXTURE_2D, s.tex);
          bindMesh(pp, meshes[s.room]);
          gl.drawArrays(gl.TRIANGLES, 0, meshes[s.room].count);
        });
      });
      gl.disableVertexAttribArray(pp.pos);
      if (pp.shade >= 0) gl.disableVertexAttribArray(pp.shade);
      gl.depthMask(true);
      gl.disable(gl.DEPTH_TEST);
      if (opts.onFrame) opts.onFrame(v);
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

  window.TourTransition = { enabled: enabled, run: run, triangulate: triangulate };
})();
