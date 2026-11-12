/**
 * BASIC-89 lane C: real three.js preview of one bundled Siren GLB.
 *
 * Qt truth ported here:
 *   Qt/src/NativeSceneCamera.cpp:13-107  camera pose, fov, fog distances
 *   Qt/src/NativeSceneFrame.cpp:110-119  background / fog colour blend, detail
 *   Qt/src/SceneMath.cpp:64-95           perspective and lookAt
 *   Qt/src/SceneAppearance.cpp:10-68     hidden parts, skip list, material overrides
 *   Qt/src/SceneAppearance.cpp:225-258   floor material and transform
 *   Qt/src/RhiScene.cpp:1422-1433        per-name dark colour table
 *   Qt/shaders/enhancement/opticalSurface.frag:51  KEY_LIGHT direction
 *   Qt/src/NativeScene.cpp:76-78         default actor cell position
 *
 * Explicit gaps (nothing is invented to hide them):
 *   - Qt shadow map is not ported; no castShadow is enabled.
 *   - Qt frame.draws JSON is not part of the asset bundle, so materials come
 *     from the GLB itself plus the three PART_OVERRIDES proven by
 *     SceneAppearance.cpp. Missing parts are reported, never faked.
 *   - Ambient 0.55 has no direct Qt value (same approximation as T15 GAP-1).
 *   - GAP-3: Qt KEY_LIGHT (opticalSurface.frag:51-61) is a custom Lambert +
 *     specular term applied only to hero surfaces (v_mode > 0.5). Three uses
 *     one DirectionalLight with the exact KEY_LIGHT direction, applied
 *     globally; the custom NDotL/spec curve is not reproduced.
 *   - GAP-4: Qt opticalLight is a scalar multiplying the baked light atlas and
 *     emission (RhiScene.cpp:1402,1412-1419; opticalSurface.frag:44,196). The
 *     asset bundle has no light atlas, so this port does not invent a
 *     positional light or per-pixel emission.
 */
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

const DEG = Math.PI / 180;
const NEAR_PLANE = 5;                 // Qt/src/NativeSceneCamera.cpp:98
const FAR_PLANE = 300;                // Qt/src/NativeSceneCamera.cpp:98
const DEFAULT_SHOT = 29.1;            // Qt/src/NativeSceneCamera.cpp:14
const SHOT_ORBIT_START = 22.6;        // Qt/src/NativeSceneCamera.cpp:15
const SHOT_SETTLE_START = 24.25;      // Qt/src/NativeSceneCamera.cpp:16
const DIRECTION_DETAIL = { x: -0.277, y: 0.238, z: 0.931 };  // Qt/src/NativeSceneCamera.cpp:34
const BACKGROUND_DAY = 0xeae5e1;      // Qt/src/NativeSceneFrame.cpp:110-111
const BACKGROUND_NIGHT = 0x11181b;    // Qt/src/NativeSceneFrame.cpp:110-111
const FOG_DAY = 0xeae5e1;             // Qt/src/NativeSceneFrame.cpp:112-113
const FOG_NIGHT = 0x263136;           // Qt/src/NativeSceneFrame.cpp:112-113
const FLOOR_DAY = 0xd8c9b9;           // Qt/src/SceneAppearance.cpp:225-258
const FLOOR_NIGHT = 0x192125;         // Qt/src/SceneAppearance.cpp:225-258
const FLOOR_ROUGHNESS = 0.95;         // Qt/src/SceneAppearance.cpp:225-258
const FLOOR_Y = -4.63;                // Qt/src/NativeSceneFrame.cpp:62
const ACTOR_POSITION = { x: 0, y: -4.6, z: -2.17 };  // Qt/src/NativeScene.cpp:76-78 + NativeScene.h:83-96
const SELECTION_COLOR = 0xe3b15c;
const HIDDEN_PARTS = ['Internal_Ceramic', 'Optical_Edges', 'Subsurface_Optics', 'Optical_Film_Edge', 'Amber_Optical_Inlay', 'Champagne_Index', 'Printed_Label'];  // Qt/src/SceneAppearance.cpp:10-11
const ALWAYS_SKIP_PARTS = ['Carbon_Ink'];  // Qt/src/SceneAppearance.cpp:66-68

const PART_OVERRIDES = {  // Qt/src/SceneAppearance.cpp:86-103
  Frosted_Polymer: { color: 0xfffdfa, transmission: 0.9, thickness: 0.12, roughness: 0.21, ior: 1.46, attenuation: 0xeee6df, attenuationDistance: 2 },
  Ivory_Edges: { color: 0xf0e7df, roughness: 0.31, transmission: 0.65, thickness: 0.04 },
  Optical_Diffuser: { color: 0xe2dad4, transmission: 0, roughness: 0.7 }
};

// Qt RhiScene::dark(name) (RhiScene.cpp:1422-1433) is applied by the surface
// shader as mix(dayColor, darkColor, v_theme). The values below are the exact
// sRGB hex constants from that table; the default and "Orange" fallbacks are
// kept as well. Every cloned/overridden material gets its own day/dark pair.
const DARK_COLORS = {
  Frosted_Polymer: 0x626b70,
  Ivory_Edges: 0x687277,
  Optical_Diffuser: 0x192226,
  Titanium_Fasteners: 0xb1b9bb,
  Index_Inlay: 0xc6a36b,
  Printed_Label: 0x303a3e,
  Subsurface_Optics: 0x939e9f,
  Optical_Edges: 0xbbc3bc,
  Carbon_Ink: 0xb6bdb8
};
const DARK_DEFAULT = 0x969f9f;
const DARK_ORANGE = 0xbb8850;

const ASSET_URLS = {
  'Assets/models/archive-assembly.glb': '/Assets/models/archive-assembly.glb',
  'Assets/models/archive-cassette.glb': '/Assets/models/archive-cassette.glb'
};
const DEFAULT_MODEL = 'Assets/models/archive-assembly.glb';

function clamp01(value) {
  return value < 0 ? 0 : (value > 1 ? 1 : value);
}

function lerp(a, b, t) {
  return a + (b - a) * t;
}

function lerp3(a, b, t) {
  return { x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t), z: lerp(a.z, b.z, t) };
}

function cross3(a, b) {
  return { x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x };
}

function normalize3(v) {
  const length = Math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return length > 0 ? { x: v.x / length, y: v.y / length, z: v.z / length } : { x: 0, y: 0, z: 1 };
}

// Qt's KEY_LIGHT is the direction from the surface towards the light
// (opticalSurface.frag:51). Three's DirectionalLight direction is
// light.position - target, so place the light at normalise(0, 0.55, 0.84).
const KEY_LIGHT_DIRECTION = normalize3({ x: 0.0, y: 0.55, z: 0.84 });

function smooth(value) {
  const v = clamp01(value);
  return v * v * v * (10 + v * (-15 + 6 * v));
}

function rotateY(v, angle) {
  const c = Math.cos(angle);
  const s = Math.sin(angle);
  return { x: v.x * c + v.z * s, y: v.y, z: -v.x * s + v.z * c };
}

function srgbToLinear1(channel) {
  return channel < 0.04045 ? channel * 0.0773993808 : Math.pow(channel * 0.9478672986 + 0.0521327014, 2.4);
}

function hexToLinear(hex) {
  return {
    r: srgbToLinear1(((hex >> 16) & 255) / 255),
    g: srgbToLinear1(((hex >> 8) & 255) / 255),
    b: srgbToLinear1((hex & 255) / 255)
  };
}

function blendLinear(light, dark, t) {
  return { r: lerp(light.r, dark.r, t), g: lerp(light.g, dark.g, t), b: lerp(light.b, dark.b, t) };
}

function darkHexFor(part) {
  if (part && Object.prototype.hasOwnProperty.call(DARK_COLORS, part)) {
    return DARK_COLORS[part];
  }
  if (part && part.indexOf('Orange') >= 0) return DARK_ORANGE;
  return DARK_DEFAULT;
}

// Snapshot the GLB/override day colour once, then remember the Qt dark colour
// for the same part. applyMaterialTheme can therefore re-blend without ever
// accumulating previous theme values.
function prepareMaterialTheme(material, part) {
  if (!material || !material.color) return;
  // Own properties, not userData: Material.copy may share the source userData
  // object, and two clones must not overwrite each other's day/dark colours.
  if (!material.rhineDayColor) {
    material.rhineDayColor = material.color.clone();
  }
  material.rhineDarkColor = new THREE.Color().setHex(darkHexFor(part), THREE.SRGBColorSpace);
  material.color.copy(material.rhineDayColor).lerp(material.rhineDarkColor, theme);
}

function applyMaterialTheme(themeValue) {
  if (!modelRoot) return;
  modelRoot.traverse(function (child) {
    if (!child.isMesh) return;
    const materials = Array.isArray(child.material) ? child.material : [child.material];
    for (let i = 0; i < materials.length; i++) {
      const material = materials[i];
      if (!material || !material.color) continue;
      if (material.rhineDayColor && material.rhineDarkColor) {
        material.color.copy(material.rhineDayColor).lerp(material.rhineDarkColor, themeValue);
      }
    }
  });
}

function computePose(width, height, detail, actorPosition) {
  const shot = DEFAULT_SHOT;
  const orbit = smooth((shot - SHOT_ORBIT_START) / 1.6);
  const settle = smooth((shot - SHOT_SETTLE_START) / 2.25);
  const yaw = (89 - 22 * orbit - 8 * settle) * DEG;
  const elevation = (3 + 40 * smooth((shot - 21.96) / 0.22) - 8 * orbit - 16 * settle) * DEG;
  const span = lerp(lerp(10.8, 10.3, orbit), 7.33, settle);
  const distance = lerp(lerp(28 + 7 * orbit, 140, settle), 72, detail);
  let aim = {
    x: -1.091,
    y: lerp(-2.55 + 0.4 * orbit, -0.045, settle),
    z: lerp(2.48, 0.481, settle)
  };
  let direction = {
    x: -Math.sin(yaw) * Math.cos(elevation),
    y: Math.sin(elevation),
    z: Math.cos(yaw) * Math.cos(elevation)
  };
  direction = normalize3(lerp3(direction, DIRECTION_DETAIL, detail));
  const right = normalize3(cross3({ x: 0, y: 1, z: 0 }, direction));
  const up = normalize3(cross3(direction, right));

  const aspect = width / height;
  const portrait = aspect < 1.05;
  const compact = !portrait && width < 1100;
  const baseSpan = lerp(span, 5.9, detail);
  const portraitDetail = Math.max(6.3 / aspect, 3.7 * height / Math.max(100, 0.54 * height - 156));
  let anchorX = 550 / 1920;
  let anchorY = 560 / 1080;
  let viewSpan = Math.max(baseSpan, baseSpan * (16 / 9) / aspect);
  if (portrait) {
    viewSpan = Math.max(baseSpan, lerp(8.4 / aspect, portraitDetail, detail));
    anchorX = 0.5;
    anchorY = 0.27 + 34 / height;
  } else if (compact) {
    anchorX = 0.27;
    anchorY = 0.49;
  }

  const pixelScale = height / viewSpan;
  if (portrait) {
    // cinematicField is 0 for the default archive field (T15 GAP-6).
    const baseAim = { x: 0, y: -4.6 + 0 + 0.4 + 1.85, z: -2.17 };
    const portraitShift = (0.36 - 0.5) * height / pixelScale;
    aim = {
      x: baseAim.x + up.x * portraitShift,
      y: baseAim.y + up.y * portraitShift,
      z: baseAim.z + up.z * portraitShift
    };
  }
  const rightOffset = (0.5 - anchorX) * width / pixelScale;
  const upOffset = (anchorY - 0.5) * height / pixelScale;
  const detailAim = {
    x: actorPosition.x + right.x * rightOffset + up.x * upOffset,
    y: actorPosition.y + 1.85 + right.y * rightOffset + up.y * upOffset,
    z: actorPosition.z + right.z * rightOffset + up.z * upOffset
  };
  aim = lerp3(aim, detailAim, detail);

  const desiredSpan = viewSpan;
  const targetFov = 2 * Math.atan(desiredSpan / (2 * distance)) / DEG;
  return {
    eye: {
      x: aim.x + direction.x * distance,
      y: aim.y + direction.y * distance,
      z: aim.z + direction.z * distance
    },
    aim: aim,
    direction: direction,
    right: right,
    up: up,
    distance: distance,
    viewSpan: viewSpan,
    targetFov: targetFov
  };
}

function normalizePartName(raw) {
  if (!raw) return '';
  let name = String(raw).trim();
  const cut = name.lastIndexOf('__');
  if (cut >= 0) name = name.slice(cut + 2);
  const dot = name.lastIndexOf('.');
  if (dot > 0) {
    const tail = name.slice(dot + 1);
    let numeric = tail.length > 0;
    for (let i = 0; i < tail.length; i++) {
      const code = tail.charCodeAt(i);
      if (code < 48 || code > 57) { numeric = false; break; }
    }
    if (numeric) name = name.slice(0, dot);
  }
  return name;
}

function round(value, digits) {
  const scale = Math.pow(10, digits);
  return Math.round(value * scale) / scale;
}

function post(type, payload) {
  const bridge = window.RhineSceneBridge;
  if (!bridge || typeof bridge.postMessage !== 'function') return;
  const message = Object.assign({ type: type }, payload || {});
  try {
    bridge.postMessage(JSON.stringify(message));
  } catch (error) {
    // The host may have detached the WebView; there is nothing to report to.
  }
}

function fail(stage, error) {
  const message = error && error.message ? error.message : String(error || 'unknown');
  post('error', { stage: stage, message: String(message).slice(0, 400) });
}

window.addEventListener('error', function (event) {
  fail('script', event.message || 'script error');
});
window.addEventListener('unhandledrejection', function (event) {
  fail('script', event.reason || 'unhandled rejection');
});

const query = new URLSearchParams(window.location.search);
function finiteNumber(value, fallback) {
  if (value === null || value === undefined || value === '') return fallback;
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}
const requestedModel = query.get('model');
const modelKey = Object.prototype.hasOwnProperty.call(ASSET_URLS, requestedModel) ? requestedModel : DEFAULT_MODEL;
let theme = clamp01(finiteNumber(query.get('theme'), 1));
let yawOffset = finiteNumber(query.get('yaw'), 0);

const canvas = document.getElementById('scene-canvas');
let renderer = null;
let scene = null;
let camera = null;
let floor = null;
let modelRoot = null;
let basePose = null;
let resizeObserver = null;
let viewWidth = 1;
let viewHeight = 1;
let needsRender = true;
let readyPosted = false;
let currentEye = { x: 0, y: 0, z: 0 };
let currentAim = { x: 0, y: 0, z: 0 };

function applyThemeColors() {
  if (!scene) return;
  const background = blendLinear(hexToLinear(BACKGROUND_DAY), hexToLinear(BACKGROUND_NIGHT), theme);
  scene.background = new THREE.Color().setRGB(background.r, background.g, background.b, THREE.LinearSRGBColorSpace);
  const fogColor = blendLinear(hexToLinear(FOG_DAY), hexToLinear(FOG_NIGHT), theme);
  if (!scene.fog) {
    scene.fog = new THREE.Fog(new THREE.Color().setRGB(fogColor.r, fogColor.g, fogColor.b, THREE.LinearSRGBColorSpace), NEAR_PLANE, FAR_PLANE);
  } else {
    scene.fog.color.setRGB(fogColor.r, fogColor.g, fogColor.b, THREE.LinearSRGBColorSpace);
  }
  const floorColor = blendLinear(hexToLinear(FLOOR_DAY), hexToLinear(FLOOR_NIGHT), theme);
  if (floor && floor.material) {
    floor.material.color.setRGB(floorColor.r, floorColor.g, floorColor.b, THREE.LinearSRGBColorSpace);
  }
  applyMaterialTheme(theme);
  needsRender = true;
}

function cameraYawRadians() {
  return Math.atan2(currentEye.x - currentAim.x, currentEye.z - currentAim.z);
}

function postYaw() {
  post('yaw', { radians: round(cameraYawRadians(), 6) });
}

function applyView() {
  if (!camera) return;
  basePose = computePose(viewWidth, viewHeight, 1, ACTOR_POSITION);
  const direction = rotateY(basePose.direction, yawOffset);
  const eye = {
    x: basePose.aim.x + direction.x * basePose.distance,
    y: basePose.aim.y + direction.y * basePose.distance,
    z: basePose.aim.z + direction.z * basePose.distance
  };
  currentEye = eye;
  currentAim = basePose.aim;
  camera.position.set(eye.x, eye.y, eye.z);
  camera.up.set(0, 1, 0);
  camera.lookAt(basePose.aim.x, basePose.aim.y, basePose.aim.z);
  camera.fov = basePose.targetFov;
  camera.aspect = viewWidth / viewHeight;
  camera.near = NEAR_PLANE;
  camera.far = FAR_PLANE;
  camera.updateProjectionMatrix();

  // Qt/src/NativeSceneCamera.cpp:96-97 with m_detail = 1: lerp(...) picks the
  // second endpoint, so fogNear = distance - 1 and fogFar = distance + 12.
  const renderedDistance = Math.sqrt(
    (eye.x - basePose.aim.x) * (eye.x - basePose.aim.x) +
    (eye.y - basePose.aim.y) * (eye.y - basePose.aim.y) +
    (eye.z - basePose.aim.z) * (eye.z - basePose.aim.z)
  );
  if (scene && scene.fog) {
    scene.fog.near = renderedDistance - 1;
    scene.fog.far = renderedDistance + 12;
  }
  needsRender = true;
}

function resize() {
  if (!renderer) return;
  viewWidth = Math.max(1, canvas.clientWidth);
  viewHeight = Math.max(1, canvas.clientHeight);
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setSize(viewWidth, viewHeight, false);
  applyView();
}

function makeOverrideMaterial(source, override) {
  const material = new THREE.MeshPhysicalMaterial();
  if (source && source.isMaterial && source.copy) {
    material.copy(source);
  } else {
    material.roughness = 1;
    material.metalness = 1;
  }
  const color = hexToLinear(override.color);
  material.color = new THREE.Color().setRGB(color.r, color.g, color.b, THREE.LinearSRGBColorSpace);
  if (override.transmission !== undefined) material.transmission = override.transmission;
  if (override.thickness !== undefined) material.thickness = override.thickness;
  if (override.roughness !== undefined) material.roughness = override.roughness;
  if (override.ior !== undefined) material.ior = override.ior;
  if (override.metalness !== undefined) material.metalness = override.metalness;
  if (override.attenuation !== undefined) {
    const attenuation = hexToLinear(override.attenuation);
    material.attenuationColor = new THREE.Color().setRGB(attenuation.r, attenuation.g, attenuation.b, THREE.LinearSRGBColorSpace);
  }
  if (override.attenuationDistance !== undefined) material.attenuationDistance = override.attenuationDistance;
  material.needsUpdate = true;
  return material;
}

function cloneMaterial(material) {
  if (Array.isArray(material)) return material.map(function (entry) { return entry && entry.clone ? entry.clone() : entry; });
  return material && material.clone ? material.clone() : material;
}

let meshes = [];
let selected = null;

function clearSelectionHighlight() {
  if (!selected) return;
  for (let i = 0; i < selected.saved.length; i++) {
    const entry = selected.saved[i];
    entry.material.emissive.setHex(entry.emissive);
    entry.material.emissiveIntensity = entry.intensity;
    entry.material.needsUpdate = true;
  }
  selected = null;
}

function highlightMesh(mesh) {
  clearSelectionHighlight();
  const list = Array.isArray(mesh.material) ? mesh.material : [mesh.material];
  const saved = [];
  for (let i = 0; i < list.length; i++) {
    const material = list[i];
    if (!material || !material.emissive || typeof material.emissive.getHex !== 'function') continue;
    saved.push({
      material: material,
      emissive: material.emissive.getHex(),
      intensity: material.emissiveIntensity
    });
    material.emissive.setHex(SELECTION_COLOR);
    material.emissiveIntensity = 0.55;
    material.needsUpdate = true;
  }
  selected = { mesh: mesh, saved: saved };
}

function trianglesOf(geometry) {
  if (!geometry) return 0;
  if (geometry.index && geometry.index.count) return geometry.index.count / 3;
  const position = geometry.getAttribute ? geometry.getAttribute('position') : null;
  return position && position.count ? position.count / 3 : 0;
}

function isVisibleInTree(mesh) {
  let node = mesh;
  while (node) {
    if (node.visible === false) return false;
    if (node === modelRoot) return true;
    node = node.parent;
  }
  return false;
}

function postReady() {
  if (readyPosted) return;
  let triangles = 0;
  let visibleMeshes = 0;
  const parts = [];
  const bounds = new THREE.Box3();
  const temp = new THREE.Box3();
  for (let i = 0; i < meshes.length; i++) {
    const mesh = meshes[i];
    if (!mesh || !isVisibleInTree(mesh)) continue;
    visibleMeshes++;
    triangles += trianglesOf(mesh.geometry);
    const part = mesh.userData.rhinePart;
    if (part && parts.indexOf(part) < 0) parts.push(part);
    mesh.updateMatrixWorld(true);
    if (mesh.geometry) {
      mesh.geometry.computeBoundingBox();
      if (mesh.geometry.boundingBox) {
        temp.copy(mesh.geometry.boundingBox).applyMatrix4(mesh.matrixWorld);
        bounds.union(temp);
      }
    }
  }
  if (bounds.isEmpty()) bounds.set(new THREE.Vector3(0, 0, 0), new THREE.Vector3(0, 0, 0));
  const size = new THREE.Vector3();
  const center = new THREE.Vector3();
  bounds.getSize(size);
  bounds.getCenter(center);
  readyPosted = true;
  post('ready', {
    model: modelKey,
    meshes: visibleMeshes,
    triangles: Math.round(triangles),
    webgl2: !!(renderer && renderer.capabilities && renderer.capabilities.isWebGL2),
    fovDeg: round(camera.fov, 3),
    yaw: round(cameraYawRadians(), 6),
    parts: parts,
    bounds: {
      min: { x: round(bounds.min.x, 4), y: round(bounds.min.y, 4), z: round(bounds.min.z, 4) },
      max: { x: round(bounds.max.x, 4), y: round(bounds.max.y, 4), z: round(bounds.max.z, 4) },
      center: { x: round(center.x, 4), y: round(center.y, 4), z: round(center.z, 4) },
      size: { x: round(size.x, 4), y: round(size.y, 4), z: round(size.z, 4) }
    }
  });
}

function onModelLoaded(gltf) {
  if (!gltf || !gltf.scene) {
    fail('glb', 'GLTFLoader returned no scene');
    return;
  }
  modelRoot = gltf.scene;
  modelRoot.position.set(ACTOR_POSITION.x, ACTOR_POSITION.y, ACTOR_POSITION.z);
  meshes = [];
  modelRoot.traverse(function (child) {
    if (!child.isMesh) return;
    const part = normalizePartName(child.name);
    child.userData.rhinePart = part;
    if (part && (HIDDEN_PARTS.indexOf(part) >= 0 || ALWAYS_SKIP_PARTS.indexOf(part) >= 0)) {
      child.visible = false;
      return;
    }
    // meshIndex is the index in the rendered (visible) mesh list, matching the
    // `meshes` count in the ready event; hidden Qt parts never consume a slot.
    child.userData.rhineMeshIndex = meshes.length;
    const override = part ? PART_OVERRIDES[part] : null;
    if (override) {
      const source = Array.isArray(child.material) ? child.material[0] : child.material;
      child.material = makeOverrideMaterial(source, override);
    } else {
      child.material = cloneMaterial(child.material);
    }
    const materials = Array.isArray(child.material) ? child.material : [child.material];
    for (let i = 0; i < materials.length; i++) {
      if (materials[i]) {
        materials[i].name = 'basic:' + (part || 'part');
        prepareMaterialTheme(materials[i], part);
      }
    }
    meshes.push(child);
  });
  if (meshes.length === 0) {
    fail('glb', 'GLB has no visible meshes after Qt part filtering');
    return;
  }
  scene.add(modelRoot);
  resize();
  renderer.render(scene, camera);
  postReady();
}

const raycaster = new THREE.Raycaster();
const pointer = new THREE.Vector2();
let pointerDown = false;
let pointerId = null;
let startX = 0;
let startY = 0;
let lastX = 0;
let dragging = false;
let lastYawPost = 0;

function pick(clientX, clientY) {
  if (!modelRoot || !camera) return;
  const rect = canvas.getBoundingClientRect();
  const x = ((clientX - rect.left) / Math.max(1, rect.width)) * 2 - 1;
  const y = -((clientY - rect.top) / Math.max(1, rect.height)) * 2 + 1;
  pointer.set(x, y);
  raycaster.setFromCamera(pointer, camera);
  const hits = raycaster.intersectObject(modelRoot, true);
  for (let i = 0; i < hits.length; i++) {
    const mesh = hits[i].object;
    if (!mesh || !mesh.isMesh || !isVisibleInTree(mesh)) continue;
    highlightMesh(mesh);
    post('selection', {
      partName: mesh.userData.rhinePart || normalizePartName(mesh.name),
      meshIndex: Number.isInteger(mesh.userData.rhineMeshIndex) ? mesh.userData.rhineMeshIndex : -1,
      point: {
        x: round(hits[i].point.x, 3),
        y: round(hits[i].point.y, 3),
        z: round(hits[i].point.z, 3)
      }
    });
    return;
  }
  // No hit: no selection event, no invented part name.
}

function endPointer(event) {
  if (!pointerDown || event.pointerId !== pointerId) return;
  pointerDown = false;
  try {
    canvas.releasePointerCapture(event.pointerId);
  } catch (error) {
    // Pointer capture may already be gone.
  }
  if (dragging) {
    postYaw();
  } else if (event.type === 'pointerup') {
    pick(event.clientX, event.clientY);
  }
  dragging = false;
  needsRender = true;
}

canvas.addEventListener('pointerdown', function (event) {
  if (event.button !== undefined && event.button !== 0) return;
  pointerDown = true;
  pointerId = event.pointerId;
  startX = event.clientX;
  startY = event.clientY;
  lastX = event.clientX;
  dragging = false;
  try {
    canvas.setPointerCapture(event.pointerId);
  } catch (error) {
    // Some WebView builds do not expose pointer capture; drag still works.
  }
});

canvas.addEventListener('pointermove', function (event) {
  if (!pointerDown || event.pointerId !== pointerId) return;
  const dx = event.clientX - lastX;
  lastX = event.clientX;
  if (!dragging && (Math.abs(event.clientX - startX) + Math.abs(event.clientY - startY)) > 3) {
    dragging = true;
  }
  if (!dragging) return;
  yawOffset -= dx * 0.008;
  applyView();
  const now = Date.now();
  if (now - lastYawPost > 80) {
    lastYawPost = now;
    postYaw();
  }
  event.preventDefault();
});

canvas.addEventListener('pointerup', endPointer);
canvas.addEventListener('pointercancel', endPointer);
canvas.addEventListener('contextmenu', function (event) { event.preventDefault(); });
canvas.addEventListener('webglcontextlost', function (event) {
  event.preventDefault();
  fail('webgl', 'WebGL context lost');
});

window.__rhineBasicScene = {
  setYaw: function (radians) {
    const value = Number(radians);
    if (!Number.isFinite(value)) return;
    yawOffset = value;
    applyView();
    postYaw();
  },
  resetView: function () {
    yawOffset = 0;
    applyView();
    postYaw();
  },
  setTheme: function (value) {
    const next = Number(value);
    if (!Number.isFinite(next)) return;
    theme = clamp01(next);
    applyThemeColors();
    needsRender = true;
  }
};

function loop() {
  window.requestAnimationFrame(loop);
  if (!needsRender || !renderer || !scene || !camera) return;
  needsRender = false;
  renderer.render(scene, camera);
}

function boot() {
  if (!canvas) {
    fail('webgl', 'canvas #scene-canvas missing');
    return;
  }
  try {
    renderer = new THREE.WebGLRenderer({
      canvas: canvas,
      antialias: true,
      alpha: false,
      powerPreference: 'high-performance'
    });
    renderer.outputColorSpace = THREE.SRGBColorSpace;  // GAP-2: Qt has no tonemap flag
    renderer.toneMapping = THREE.NoToneMapping;        // GAP-2
    renderer.autoClear = true;
    renderer.sortObjects = true;
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  } catch (error) {
    renderer = null;
    fail('webgl', error);
    return;
  }

  scene = new THREE.Scene();
  camera = new THREE.PerspectiveCamera(5, 16 / 9, NEAR_PLANE, FAR_PLANE);
  camera.matrixAutoUpdate = true;

  // GAP-3: exact Qt KEY_LIGHT direction, but Three applies it globally rather
  // than only to the hero/v_mode > 0.5 surfaces. No Qt shadow map is ported.
  const key = new THREE.DirectionalLight(0xffffff, 1.0);
  key.position.set(
    KEY_LIGHT_DIRECTION.x * 20,
    KEY_LIGHT_DIRECTION.y * 20,
    KEY_LIGHT_DIRECTION.z * 20
  );
  key.target.position.set(0, 0, 0);
  key.target.updateMatrixWorld();
  key.name = 'qt-key-light-direction';
  scene.add(key);
  scene.add(key.target);

  const ambient = new THREE.AmbientLight(0xffffff, 0.55);  // GAP-1 approximation
  ambient.name = 'approx-ambient';
  scene.add(ambient);

  // GAP-4: Qt opticalLight is a scalar on the baked light atlas, not a point
  // light. No positional light or emission is invented without that atlas.

  floor = new THREE.Mesh(
    new THREE.PlaneGeometry(200, 200),
    new THREE.MeshStandardMaterial({ roughness: FLOOR_ROUGHNESS, metalness: 0 })
  );
  floor.position.set(0, FLOOR_Y, 0);
  floor.rotation.x = -Math.PI / 2;
  floor.name = 'qt-floor';
  scene.add(floor);

  applyThemeColors();
  resize();
  window.addEventListener('resize', resize);
  if (typeof ResizeObserver !== 'undefined') {
    resizeObserver = new ResizeObserver(resize);
    resizeObserver.observe(canvas);
  }
  window.requestAnimationFrame(loop);

  const loader = new GLTFLoader();
  loader.load(ASSET_URLS[modelKey], onModelLoaded, undefined, function (error) {
    fail('glb', error);
  });
}

boot();
