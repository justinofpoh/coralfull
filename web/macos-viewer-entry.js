import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { RgbaArray, SparkRenderer, SplatMesh } from "@sparkjsdev/spark";

const MODEL_URL = "./reef_struct_orient_proper_cleaned.ply";
const LABELS_URL = "./reef_struct_orient_proper_cleaned.labels.bin";
const LABELS_META_URL = "./reef_struct_orient_proper_cleaned.labels.json";
const OVERSIZED_SPLAT_PERCENTILE = 0.99;
const CAMERA_UP = new THREE.Vector3(0, 1, 0);
const OVERLAY_COLORS = [
  null,
  new THREE.Color("#00c800"),
  new THREE.Color("#dc1e1e"),
];

function hideOversizedSplatArtefacts(splats) {
  const splatCount = splats.getNumSplats();
  if (splatCount === 0) return;

  const sizes = new Float32Array(splatCount);
  let count = 0;

  splats.forEachSplat((_index, _center, scales) => {
    sizes[count] = Math.max(scales.x, scales.y, scales.z);
    count += 1;
  });

  const populatedSizes = sizes.subarray(0, count);
  populatedSizes.sort();
  const cap = populatedSizes[Math.floor((count - 1) * OVERSIZED_SPLAT_PERCENTILE)];

  splats.forEachSplat((index, center, scales, quaternion, opacity, color) => {
    if (Math.max(scales.x, scales.y, scales.z) > cap) {
      splats.setSplat(index, center, scales, quaternion, 0, color);
    }
  });

  splats.needsUpdate = true;
}

function getReefBounds(splatMesh) {
  const bounds = new THREE.Box3();
  let visibleCount = 0;

  splatMesh.forEachSplat((_index, center, _scales, _quaternion, opacity) => {
    if (opacity <= 0) return;
    bounds.expandByPoint(center);
    visibleCount += 1;
  });

  if (visibleCount === 0 || bounds.isEmpty()) {
    return splatMesh.getBoundingBox(true);
  }

  return bounds;
}

function getSideViewDirection(size) {
  const alongX = size.x <= size.z;
  return new THREE.Vector3(alongX ? 1 : 0, 0.28, alongX ? 0 : 1).normalize();
}

function fitCameraToReef(camera, controls, bounds) {
  const center = bounds.getCenter(new THREE.Vector3());
  const size = bounds.getSize(new THREE.Vector3());
  const radius = Math.max(size.length() / 2, 0.25);
  const verticalHalfFov = THREE.MathUtils.degToRad(camera.fov / 2);
  const horizontalHalfFov = Math.atan(Math.tan(verticalHalfFov) * camera.aspect);
  const distance =
    (radius / Math.sin(Math.min(verticalHalfFov, horizontalHalfFov))) * 1.35;
  const viewFrom = getSideViewDirection(size);

  camera.up.copy(CAMERA_UP);
  camera.position.copy(center).addScaledVector(viewFrom, distance);
  camera.near = Math.max(distance / 10_000, 0.001);
  camera.far = Math.max(distance * 100, 100);
  camera.updateProjectionMatrix();

  controls.target.copy(center);
  controls.minDistance = distance * 0.04;
  controls.maxDistance = distance * 12;
  camera.lookAt(center);
  controls.update();
}

function notifyNative(payload) {
  window.webkit?.messageHandlers?.reef?.postMessage(payload);
}

function setLoadState(phase, progress = 0, message = "") {
  const loading = document.getElementById("loading");
  const error = document.getElementById("error");
  const controls = document.getElementById("controls");
  const progressLabel = document.getElementById("progress-label");
  const progressBar = document.getElementById("progress-bar");
  const errorMessage = document.getElementById("error-message");

  if (loading) loading.hidden = phase !== "loading";
  if (error) error.hidden = phase !== "error";
  if (controls) controls.hidden = phase !== "ready";

  if (progressLabel) {
    progressLabel.textContent =
      progress > 0 ? `${progress}% loaded` : "Preparing the reef scan…";
  }
  if (progressBar) progressBar.style.width = `${progress}%`;
  if (errorMessage && message) errorMessage.textContent = message;

  notifyNative({ phase, progress, message });
}

function captureOriginalColors(splatMesh) {
  const originals = [];
  splatMesh.forEachSplat((index, _center, _scales, _quat, _opacity, color) => {
    originals[index] = color.clone();
  });
  return originals;
}

function paintSemanticOverlay(splatMesh, originals, labels, enabled) {
  const packed = splatMesh.packedSplats;
  if (!packed) return;
  const count = packed.getNumSplats();
  splatMesh.maxSh = enabled ? 0 : 3;
  splatMesh.enableLod = false;

  if (!enabled) {
    splatMesh.splatRgba = null;
    packed.forEachSplat((index, center, scales, quaternion, opacity) => {
      const original = originals[index];
      if (!original) return;
      packed.setSplat(index, center, scales, quaternion, opacity, original);
    });
    packed.needsUpdate = true;
    splatMesh.updateGenerator();
    return;
  }

  const rgba = splatMesh.splatRgba ?? new RgbaArray({ capacity: count });
  const bytes = rgba.ensureCapacity(count);
  packed.forEachSplat((index, center, scales, quaternion, opacity, color) => {
    const original = originals[index] ?? color;
    const cls = labels[index] || 0;
    const overlay = OVERLAY_COLORS[cls];
    const next = overlay ?? original;
    const offset = index * 4;
    bytes[offset] = Math.round(next.r * 255);
    bytes[offset + 1] = Math.round(next.g * 255);
    bytes[offset + 2] = Math.round(next.b * 255);
    bytes[offset + 3] = Math.round(Math.max(opacity, 0) * 255);
    packed.setSplat(index, center, scales, quaternion, opacity, next);
  });
  rgba.count = count;
  rgba.needsUpdate = true;
  splatMesh.splatRgba = rgba;
  packed.needsUpdate = true;
  splatMesh.updateGenerator();
}

async function loadSemanticLabels() {
  try {
    const [binResponse, metaResponse] = await Promise.all([
      fetch(LABELS_URL),
      fetch(LABELS_META_URL),
    ]);
    if (!binResponse.ok) return null;
    const labels = new Uint8Array(await binResponse.arrayBuffer());
    const meta = metaResponse.ok ? await metaResponse.json() : null;
    return { labels, meta };
  } catch {
    return null;
  }
}

function waitForCanvasSize(element, timeoutMs = 2500) {
  if (element.clientWidth > 8 && element.clientHeight > 8) {
    return Promise.resolve();
  }

  return new Promise((resolve) => {
    const observer = new ResizeObserver(() => {
      if (element.clientWidth > 8 && element.clientHeight > 8) {
        observer.disconnect();
        resolve();
      }
    });
    observer.observe(element);
    setTimeout(() => {
      observer.disconnect();
      resolve();
    }, timeoutMs);
  });
}

async function mountViewer() {
  const container = document.getElementById("canvas");
  if (!container) return;

  let disposed = false;
  let renderer = null;
  let controls = null;
  let sparkRenderer = null;
  let splatMesh = null;
  let resetView = () => undefined;

  window.reframeReef = () => resetView();
  window.retryReef = () => {
    disposed = true;
    renderer?.setAnimationLoop(null);
    controls?.dispose();
    splatMesh?.dispose();
    sparkRenderer?.dispose();
    renderer?.dispose();
    container.replaceChildren();
    void mountViewer();
  };

  setLoadState("loading", 0);
  await waitForCanvasSize(container);

  try {
    const width = Math.max(container.clientWidth, 640);
    const height = Math.max(container.clientHeight, 400);
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x06110f);

    const camera = new THREE.PerspectiveCamera(55, width / height, 0.01, 1000);
    camera.position.set(0, 0, 5);

    renderer = new THREE.WebGLRenderer({ antialias: false, alpha: false });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setSize(width, height);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    container.appendChild(renderer.domElement);

    controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.dampingFactor = 0.07;
    controls.rotateSpeed = 0.55;
    controls.zoomSpeed = 0.75;
    controls.panSpeed = 0.55;
    controls.screenSpacePanning = true;
    controls.zoomToCursor = true;

    sparkRenderer = new SparkRenderer({ renderer });
    scene.add(sparkRenderer);

    splatMesh = new SplatMesh({
      url: MODEL_URL,
      constructSplats: hideOversizedSplatArtefacts,
      onProgress: (event) => {
        if (disposed || !event.lengthComputable || event.total === 0) return;
        setLoadState(
          "loading",
          Math.min(99, Math.round((event.loaded / event.total) * 100))
        );
      },
    });
    scene.add(splatMesh);

    await splatMesh.initialized;
    if (disposed || !controls) return;

    const bounds = getReefBounds(splatMesh);
    resetView = () => fitCameraToReef(camera, controls, bounds);
    resetView();
    setLoadState("ready", 100);

    try {
      const originals = captureOriginalColors(splatMesh);
      const semantic = await loadSemanticLabels();
      let overlayOn = Boolean(semantic);
      if (semantic) {
        paintSemanticOverlay(splatMesh, originals, semantic.labels, overlayOn);
        const toggle = document.getElementById("overlay-toggle");
        const legend = document.getElementById("legend");
        const coverage = document.getElementById("coverage");
        if (toggle) {
          toggle.hidden = false;
          toggle.textContent = "Hide overlay";
          toggle.onclick = () => {
            overlayOn = !overlayOn;
            paintSemanticOverlay(splatMesh, originals, semantic.labels, overlayOn);
            toggle.textContent = overlayOn ? "Hide overlay" : "Show overlay";
            if (legend) legend.hidden = !overlayOn;
          };
        }
        if (legend) legend.hidden = !overlayOn;
        if (coverage && semantic.meta?.counts) {
          const healthy = semantic.meta.counts["healthy coral"] ?? 0;
          const unhealthy = semantic.meta.counts["unhealthy coral"] ?? 0;
          const coral = healthy + unhealthy;
          coverage.textContent =
            coral > 0
              ? `${Math.round((healthy / coral) * 100)}% healthy of detected coral`
              : "";
        }
      }
    } catch (error) {
      console.error("Unable to apply semantic overlay", error);
    }

    renderer.setAnimationLoop(() => {
      controls?.update();
      renderer?.render(scene, camera);
    });

    const resizeObserver = new ResizeObserver(() => {
      if (!renderer) return;
      const nextWidth = Math.max(container.clientWidth, 1);
      const nextHeight = Math.max(container.clientHeight, 1);
      camera.aspect = nextWidth / nextHeight;
      camera.updateProjectionMatrix();
      renderer.setSize(nextWidth, nextHeight);
    });
    resizeObserver.observe(container);
    renderer.domElement.addEventListener("dblclick", resetView);
  } catch (error) {
    console.error("Unable to load the reef model", error);
    setLoadState(
      "error",
      0,
      error instanceof Error ? error.message : "The reef model could not be loaded."
    );
  }
}

void mountViewer();
