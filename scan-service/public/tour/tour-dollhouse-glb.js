(function () {
  'use strict';

  function parseGlb(buffer) {
    var view = new DataView(buffer);
    var magic = view.getUint32(0, true);
    if (magic !== 0x46546C67) {
      throw new Error('not a GLB file');
    }
    var version = view.getUint32(4, true);
    if (version !== 2) {
      throw new Error('unsupported glTF version ' + version);
    }
    var totalLen = view.getUint32(8, true);
    var offset = 12;
    var json = null;
    var bin = null;
    while (offset + 8 <= totalLen) {
      var chunkLen = view.getUint32(offset, true);
      var chunkType = view.getUint32(offset + 4, true);
      var chunkStart = offset + 8;
      if (chunkType === 0x4E4F534A) {
        json = JSON.parse(new TextDecoder('utf-8').decode(new Uint8Array(buffer, chunkStart, chunkLen)));
      } else if (chunkType === 0x004E4942) {
        bin = new Uint8Array(buffer, chunkStart, chunkLen);
      }
      offset = chunkStart + chunkLen;
    }
    if (!json || !bin) {
      throw new Error('GLB is missing its JSON or BIN chunk');
    }
    return extractMesh(json, bin);
  }

  function extractMesh(gltf, bin) {
    function readAccessor(index) {
      var accessor = gltf.accessors[index];
      var bufferView = gltf.bufferViews[accessor.bufferView];
      var byteOffset = (bufferView.byteOffset || 0) + (accessor.byteOffset || 0);
      var components = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4 }[accessor.type];
      var length = accessor.count * components;
      if (accessor.componentType === 5126) {
        return new Float32Array(bin.buffer, bin.byteOffset + byteOffset, length);
      }
      if (accessor.componentType === 5125) {
        return new Uint32Array(bin.buffer, bin.byteOffset + byteOffset, length);
      }
      if (accessor.componentType === 5123) {
        return new Uint16Array(bin.buffer, bin.byteOffset + byteOffset, length);
      }
      if (accessor.componentType === 5121) {
        return new Uint8Array(bin.buffer, bin.byteOffset + byteOffset, length);
      }
      throw new Error('unsupported accessor componentType ' + accessor.componentType);
    }
    var primitives = [];
    for (var m = 0; m < gltf.meshes.length; m++) {
      var mesh = gltf.meshes[m];
      if (mesh && mesh.primitives) {
        for (var p = 0; p < mesh.primitives.length; p++) {
          primitives.push(mesh.primitives[p]);
        }
      }
    }
    if (primitives.length === 0) {
      throw new Error('GLB contains no primitives');
    }
    if (primitives.length === 1) {
      var single = primitives[0];
      var singlePos = readAccessor(single.attributes.POSITION);
      var singleNrm = single.attributes.NORMAL !== undefined ? readAccessor(single.attributes.NORMAL) : null;
      var singleCol = single.attributes.COLOR_0 !== undefined ? readAccessor(single.attributes.COLOR_0) : null;
      var singleIdx = readAccessor(single.indices);
      return { positions: singlePos, normals: singleNrm, colors: singleCol, indices: singleIdx };
    }
    var totalVertices = 0;
    var totalIndices = 0;
    for (var pi = 0; pi < primitives.length; pi++) {
      totalVertices += gltf.accessors[primitives[pi].attributes.POSITION].count;
      totalIndices += gltf.accessors[primitives[pi].indices].count;
    }
    var positions = new Float32Array(totalVertices * 3);
    var normals = new Float32Array(totalVertices * 3);
    var colors = new Float32Array(totalVertices * 4);
    var indices = new Uint32Array(totalIndices);
    var vOffset = 0;
    var iOffset = 0;
    for (var pj = 0; pj < primitives.length; pj++) {
      var prim = primitives[pj];
      var vCount = gltf.accessors[prim.attributes.POSITION].count;
      var pPos = readAccessor(prim.attributes.POSITION);
      positions.set(pPos, vOffset * 3);
      if (prim.attributes.NORMAL !== undefined) {
        var pNrm = readAccessor(prim.attributes.NORMAL);
        normals.set(pNrm, vOffset * 3);
      }
      if (prim.attributes.COLOR_0 !== undefined) {
        var pCol = readAccessor(prim.attributes.COLOR_0);
        var isVec4 = gltf.accessors[prim.attributes.COLOR_0].type === 'VEC4';
        var comps = isVec4 ? 4 : 3;
        for (var cv = 0; cv < vCount; cv++) {
          var cbase = (vOffset + cv) * 4;
          colors[cbase] = pCol[cv * comps];
          colors[cbase + 1] = pCol[cv * comps + 1];
          colors[cbase + 2] = pCol[cv * comps + 2];
          colors[cbase + 3] = isVec4 ? pCol[cv * comps + 3] : 1.0;
        }
      } else {
        for (var dv = 0; dv < vCount; dv++) {
          var dbase = (vOffset + dv) * 4;
          colors[dbase] = 0.85;
          colors[dbase + 1] = 0.84;
          colors[dbase + 2] = 0.82;
          colors[dbase + 3] = 1.0;
        }
      }
      var pIdx = readAccessor(prim.indices);
      for (var k = 0; k < pIdx.length; k++) {
        indices[iOffset + k] = pIdx[k] + vOffset;
      }
      vOffset += vCount;
      iOffset += pIdx.length;
    }
    return { positions: positions, normals: normals, colors: colors, indices: indices };
  }

  window.TourDollhouseGlb = { parse: parseGlb };
})();
