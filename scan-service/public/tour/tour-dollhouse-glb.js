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
    var result = extractParts(json, bin);
    var scene = json.scenes && json.scenes[json.scene || 0];
    result.roomPoses = scene && scene.extras && Array.isArray(scene.extras.room_poses) ? scene.extras.room_poses : null;
    return result;
  }

  function extractParts(gltf, bin) {
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

    var images = (gltf.images || []).map(function (image) {
      var bufferView = gltf.bufferViews[image.bufferView];
      var byteOffset = bufferView.byteOffset || 0;
      return {
        bytes: bin.subarray(byteOffset, byteOffset + bufferView.byteLength),
        mime: image.mimeType || 'image/jpeg'
      };
    });

    function imageIndexForMaterial(materialIndex) {
      if (materialIndex === undefined || !gltf.materials) {
        return null;
      }
      var material = gltf.materials[materialIndex];
      var pbr = material && material.pbrMetallicRoughness;
      var baseColorTexture = pbr && pbr.baseColorTexture;
      if (!baseColorTexture || !gltf.textures) {
        return null;
      }
      var texture = gltf.textures[baseColorTexture.index];
      return texture ? texture.source : null;
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

    var parts = primitives.map(function (prim) {
      var positions = readAccessor(prim.attributes.POSITION);
      var normals = prim.attributes.NORMAL !== undefined ? readAccessor(prim.attributes.NORMAL) : null;
      var uvs = prim.attributes.TEXCOORD_0 !== undefined ? readAccessor(prim.attributes.TEXCOORD_0) : null;
      var colors = null;
      if (prim.attributes.COLOR_0 !== undefined) {
        var raw = readAccessor(prim.attributes.COLOR_0);
        var isVec4 = gltf.accessors[prim.attributes.COLOR_0].type === 'VEC4';
        var comps = isVec4 ? 4 : 3;
        var vCount = raw.length / comps;
        colors = new Float32Array(vCount * 4);
        for (var cv = 0; cv < vCount; cv++) {
          colors[cv * 4] = raw[cv * comps];
          colors[cv * 4 + 1] = raw[cv * comps + 1];
          colors[cv * 4 + 2] = raw[cv * comps + 2];
          colors[cv * 4 + 3] = isVec4 ? raw[cv * comps + 3] : 1.0;
        }
      }
      return {
        positions: positions,
        normals: normals,
        uvs: uvs,
        colors: colors,
        indices: readAccessor(prim.indices),
        imageIndex: imageIndexForMaterial(prim.material)
      };
    });

    return { parts: parts, images: images };
  }

  window.TourDollhouseGlb = { parse: parseGlb };
})();
