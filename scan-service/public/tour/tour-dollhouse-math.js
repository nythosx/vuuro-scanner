(function () {
  'use strict';

  function mat4Perspective(fovy, aspect, near, far) {
    var f = 1 / Math.tan(fovy / 2);
    var nf = 1 / (near - far);
    return new Float32Array([
      f / aspect, 0, 0, 0,
      0, f, 0, 0,
      0, 0, (far + near) * nf, -1,
      0, 0, 2 * far * near * nf, 0
    ]);
  }

  function mat4LookAt(eye, target, up) {
    var zx = eye[0] - target[0];
    var zy = eye[1] - target[1];
    var zz = eye[2] - target[2];
    var zl = Math.hypot(zx, zy, zz) || 1;
    zx /= zl; zy /= zl; zz /= zl;

    var xx = up[1] * zz - up[2] * zy;
    var xy = up[2] * zx - up[0] * zz;
    var xz = up[0] * zy - up[1] * zx;
    var xl = Math.hypot(xx, xy, xz) || 1;
    xx /= xl; xy /= xl; xz /= xl;

    var yx = zy * xz - zz * xy;
    var yy = zz * xx - zx * xz;
    var yz = zx * xy - zy * xx;

    return new Float32Array([
      xx, yx, zx, 0,
      xy, yy, zy, 0,
      xz, yz, zz, 0,
      -(xx * eye[0] + xy * eye[1] + xz * eye[2]),
      -(yx * eye[0] + yy * eye[1] + yz * eye[2]),
      -(zx * eye[0] + zy * eye[1] + zz * eye[2]),
      1
    ]);
  }

  function mat4Multiply(a, b) {
    var out = new Float32Array(16);
    for (var col = 0; col < 4; col++) {
      for (var row = 0; row < 4; row++) {
        out[col * 4 + row] =
          a[0 * 4 + row] * b[col * 4 + 0] +
          a[1 * 4 + row] * b[col * 4 + 1] +
          a[2 * 4 + row] * b[col * 4 + 2] +
          a[3 * 4 + row] * b[col * 4 + 3];
      }
    }
    return out;
  }

  function distanceOutside(point, outline) {
    if (!Array.isArray(outline) || outline.length < 3) return 0;
    var px = Number(point[0]);
    var pz = Number(point[1]);
    var inside = false;
    var best = Infinity;
    for (var i = 0, j = outline.length - 1; i < outline.length; j = i++) {
      var ax = Number(outline[i][0]);
      var az = Number(outline[i][1]);
      var bx = Number(outline[j][0]);
      var bz = Number(outline[j][1]);
      if ((az > pz) !== (bz > pz) && px < (bx - ax) * (pz - az) / (bz - az) + ax) inside = !inside;
      var ex = bx - ax;
      var ez = bz - az;
      var len2 = ex * ex + ez * ez;
      var t = len2 > 0 ? Math.max(0, Math.min(1, ((px - ax) * ex + (pz - az) * ez) / len2)) : 0;
      best = Math.min(best, Math.hypot(ax + ex * t - px, az + ez * t - pz));
    }
    return inside ? 0 : best;
  }

  window.TourDollhouseMath = {
    perspective: mat4Perspective,
    lookAt: mat4LookAt,
    multiply: mat4Multiply,
    distanceOutside: distanceOutside,
    OUTSIDE_TOLERANCE_M: 1.0
  };
})();
