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
    var primitive = gltf.meshes[0].primitives[0];
    var positions = readAccessor(primitive.attributes.POSITION);
    var normals = primitive.attributes.NORMAL !== undefined ? readAccessor(primitive.attributes.NORMAL) : null;
    var colors = primitive.attributes.COLOR_0 !== undefined ? readAccessor(primitive.attributes.COLOR_0) : null;
    var indices = readAccessor(primitive.indices);
    return { positions: positions, normals: normals, colors: colors, indices: indices };
  }

  window.TourDollhouseGlb = { parse: parseGlb };
})();
