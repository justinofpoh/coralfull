"use client";

import { useEffect, useRef, useState } from "react";
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import type {
  PackedSplats,
  SparkRenderer as SparkRendererInstance,
  SplatMesh as SplatMeshInstance,
} from "@sparkjsdev/spark";
import styles from "./ReefViewer.module.css";

// Served with the site, so the clean viewer no longer depends on the Azure blob.
const DEFAULT_REEF_URL = "/reef-structure-clean-v1.ply";
const REEF_URL = process.env.NEXT_PUBLIC_REEF_MODEL_URL ?? DEFAULT_REEF_URL;
// SuperSplat exports named this way have already had the water-column and
// survey artefacts manually removed. Do not crop their legitimate edge splats.
const IS_MANUALLY_CLEANED_REEF = /reef-structure-clean-v\d+\.(ply|spz)$/i.test(
  REEF_URL
);
// The reconstruction includes the diver's surrounding water column and a few
// distant camera artefacts. Keep the central survey volume as the default view.
const CLEAN_BOUNDS_TRIM_PERCENT = 0.05;
// A small number of huge, low-detail Gaussians create a foggy halo even after
// manual crop selection. They are rendering artefacts rather than coral detail.
const OVERSIZED_SPLAT_PERCENTILE = 0.99;
// Average survey-camera orientation from this COLMAP reconstruction.
const SURVEY_VIEW_DIRECTION = new THREE.Vector3(
  -0.64116,
  0.53074,
  -0.55428
).normalize();
const SURVEY_CAMERA_UP = new THREE.Vector3(
  0.00848,
  -0.82589,
  -0.56377
).normalize();

type LoadState =
  | { phase: "loading"; progress: number }
  | { phase: "ready"; progress: 100 }
  | { phase: "error"; message: string; progress: 0 };

type ReefFrame = {
  bounds: THREE.Box3;
  horizontal: THREE.Vector3;
  vertical: THREE.Vector3;
  depth: THREE.Vector3;
};

function getTrimmedBounds(
  splatCount: number,
  trimPercent: number,
  forEachCenter: (callback: (center: THREE.Vector3) => void) => void
) {
  const xValues = new Float32Array(splatCount);
  const yValues = new Float32Array(splatCount);
  const zValues = new Float32Array(splatCount);
  let index = 0;

  forEachCenter((center) => {
    xValues[index] = center.x;
    yValues[index] = center.y;
    zValues[index] = center.z;
    index += 1;
  });

  if (index === 0) return new THREE.Box3();

  const populatedX = xValues.subarray(0, index);
  const populatedY = yValues.subarray(0, index);
  const populatedZ = zValues.subarray(0, index);

  populatedX.sort();
  populatedY.sort();
  populatedZ.sort();

  const lowerIndex = Math.floor((index - 1) * trimPercent);
  const upperIndex = Math.ceil((index - 1) * (1 - trimPercent));

  return new THREE.Box3(
    new THREE.Vector3(
      populatedX[lowerIndex],
      populatedY[lowerIndex],
      populatedZ[lowerIndex]
    ),
    new THREE.Vector3(
      populatedX[upperIndex],
      populatedY[upperIndex],
      populatedZ[upperIndex]
    )
  );
}

function hideSurveyNoise(splats: PackedSplats) {
  const splatCount = splats.getNumSplats();

  if (splatCount === 0) return;

  const coreBounds = getTrimmedBounds(
    splatCount,
    CLEAN_BOUNDS_TRIM_PERCENT,
    (visit) => {
      splats.forEachSplat((_index, center) => visit(center));
    }
  );

  splats.forEachSplat(
    (index, center, scales, quaternion, opacity, color) => {
      const isOutsideCore = !coreBounds.containsPoint(center);

      if (isOutsideCore) {
        splats.setSplat(index, center, scales, quaternion, 0, color);
      }
    }
  );

  // `setSplat` changes the packed data; this asks Spark to upload it to the GPU.
  splats.needsUpdate = true;
}

function hideOversizedSplatArtefacts(splats: PackedSplats) {
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
  const cap = populatedSizes[
    Math.floor((count - 1) * OVERSIZED_SPLAT_PERCENTILE)
  ];

  splats.forEachSplat(
    (index, center, scales, quaternion, opacity, color) => {
      if (Math.max(scales.x, scales.y, scales.z) > cap) {
        splats.setSplat(index, center, scales, quaternion, 0, color);
      }
    }
  );

  splats.needsUpdate = true;
}

function getReefFrame(splatMesh: SplatMeshInstance): ReefFrame {
  const bounds = new THREE.Box3();
  const mean = new THREE.Vector3();
  let visibleCount = 0;

  splatMesh.forEachSplat((_index, center, _scales, _quaternion, opacity) => {
    if (opacity <= 0) return;

    bounds.expandByPoint(center);
    mean.add(center);
    visibleCount += 1;
  });

  if (visibleCount === 0 || bounds.isEmpty()) {
    return {
      bounds: splatMesh.getBoundingBox(true),
      horizontal: new THREE.Vector3(1, 0, 0),
      vertical: new THREE.Vector3(0, 1, 0),
      depth: SURVEY_VIEW_DIRECTION.clone(),
    };
  }

  mean.multiplyScalar(1 / visibleCount);

  const covariance = [
    [0, 0, 0],
    [0, 0, 0],
    [0, 0, 0],
  ];

  splatMesh.forEachSplat((_index, center, _scales, _quaternion, opacity) => {
    if (opacity <= 0) return;

    const offset = center.clone().sub(mean);
    const values = [offset.x, offset.y, offset.z];

    for (let row = 0; row < 3; row += 1) {
      for (let column = 0; column < 3; column += 1) {
        covariance[row][column] += values[row] * values[column];
      }
    }
  });

  for (let row = 0; row < 3; row += 1) {
    for (let column = 0; column < 3; column += 1) {
      covariance[row][column] /= visibleCount;
    }
  }

  // Jacobi iteration gives us the long, tall, and shallow axes of the retained reef.
  const values = covariance.map((row) => [...row]);
  const vectors = [
    [1, 0, 0],
    [0, 1, 0],
    [0, 0, 1],
  ];

  for (let iteration = 0; iteration < 24; iteration += 1) {
    let first = 0;
    let second = 1;
    let largest = 0;

    for (let row = 0; row < 3; row += 1) {
      for (let column = row + 1; column < 3; column += 1) {
        const magnitude = Math.abs(values[row][column]);

        if (magnitude > largest) {
          largest = magnitude;
          first = row;
          second = column;
        }
      }
    }

    if (largest < 0.000001) break;

    const angle =
      0.5 *
      Math.atan2(
        2 * values[first][second],
        values[second][second] - values[first][first]
      );
    const cosine = Math.cos(angle);
    const sine = Math.sin(angle);
    const firstValue = values[first][first];
    const secondValue = values[second][second];
    const crossValue = values[first][second];

    values[first][first] =
      cosine * cosine * firstValue -
      2 * sine * cosine * crossValue +
      sine * sine * secondValue;
    values[second][second] =
      sine * sine * firstValue +
      2 * sine * cosine * crossValue +
      cosine * cosine * secondValue;
    values[first][second] = 0;
    values[second][first] = 0;

    for (let index = 0; index < 3; index += 1) {
      if (index === first || index === second) continue;

      const firstEntry = values[index][first];
      const secondEntry = values[index][second];
      values[index][first] = values[first][index] =
        cosine * firstEntry - sine * secondEntry;
      values[index][second] = values[second][index] =
        sine * firstEntry + cosine * secondEntry;
    }

    for (let index = 0; index < 3; index += 1) {
      const firstEntry = vectors[index][first];
      const secondEntry = vectors[index][second];
      vectors[index][first] = cosine * firstEntry - sine * secondEntry;
      vectors[index][second] = sine * firstEntry + cosine * secondEntry;
    }
  }

  const axes = [0, 1, 2]
    .map((index) => ({
      value: values[index][index],
      axis: new THREE.Vector3(
        vectors[0][index],
        vectors[1][index],
        vectors[2][index]
      ).normalize(),
    }))
    .sort((first, second) => second.value - first.value);

  const horizontal = axes[0].axis;
  const depth = axes[2].axis;

  if (depth.dot(SURVEY_VIEW_DIRECTION) < 0) depth.negate();

  const vertical = new THREE.Vector3().crossVectors(depth, horizontal).normalize();

  if (vertical.dot(SURVEY_CAMERA_UP) < 0) vertical.negate();

  return { bounds, horizontal, vertical, depth };
}

function fitCameraToReef(
  camera: THREE.PerspectiveCamera,
  controls: OrbitControls,
  frame: ReefFrame
) {
  const { bounds, depth, vertical } = frame;
  const center = bounds.getCenter(new THREE.Vector3());
  const size = bounds.getSize(new THREE.Vector3());
  const radius = Math.max(size.length() / 2, 0.25);
  const verticalHalfFov = THREE.MathUtils.degToRad(camera.fov / 2);
  const horizontalHalfFov = Math.atan(
    Math.tan(verticalHalfFov) * camera.aspect
  );
  const distance =
    (radius / Math.sin(Math.min(verticalHalfFov, horizontalHalfFov))) * 1.35;

  camera.up.copy(vertical);
  camera.position.copy(center).addScaledVector(depth, distance);
  camera.near = Math.max(distance / 10_000, 0.001);
  camera.far = Math.max(distance * 100, 100);
  camera.updateProjectionMatrix();

  controls.target.copy(center);
  controls.minDistance = distance * 0.04;
  controls.maxDistance = distance * 12;
  camera.lookAt(center);
  controls.update();
}

export default function ReefViewer() {
  const containerRef = useRef<HTMLDivElement>(null);
  const resetViewRef = useRef<() => void>(() => undefined);
  const [attempt, setAttempt] = useState(0);
  const [loadState, setLoadState] = useState<LoadState>({
    phase: "loading",
    progress: 0,
  });

  useEffect(() => {
    const containerElement = containerRef.current;

    if (!containerElement) return;

    const container: HTMLDivElement = containerElement;

    let disposed = false;
    let renderer: THREE.WebGLRenderer | null = null;
    let controls: OrbitControls | null = null;
    let sparkRenderer: SparkRendererInstance | null = null;
    let splatMesh: SplatMeshInstance | null = null;
    let resizeObserver: ResizeObserver | null = null;
    let resetView: (() => void) | null = null;

    setLoadState({ phase: "loading", progress: 0 });

    async function initializeViewer() {
      try {
        const { SparkRenderer, SplatMesh } = await import("@sparkjsdev/spark");

        if (disposed) return;

        const width = Math.max(container.clientWidth, 1);
        const height = Math.max(container.clientHeight, 1);
        const scene = new THREE.Scene();
        scene.background = new THREE.Color(0x06110f);

        const camera = new THREE.PerspectiveCamera(55, width / height, 0.01, 1000);
        camera.position.set(0, 0, 5);

        renderer = new THREE.WebGLRenderer({ antialias: false });
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
          url: REEF_URL,
          // The raw survey benefits from a conservative runtime crop. The
          // curated export is already clean, so every retained coral stays visible.
          constructSplats: IS_MANUALLY_CLEANED_REEF
            ? hideOversizedSplatArtefacts
            : hideSurveyNoise,
          onProgress: (event) => {
            if (disposed || !event.lengthComputable || event.total === 0) return;

            const progress = Math.min(
              99,
              Math.round((event.loaded / event.total) * 100)
            );

            setLoadState((current) => {
              if (current.phase === "loading" && current.progress === progress) {
                return current;
              }

              return { phase: "loading", progress };
            });
          },
        });
        scene.add(splatMesh);

        await splatMesh.initialized;

        if (disposed || !controls) return;

        const reefFrame = getReefFrame(splatMesh);
        resetView = () => fitCameraToReef(camera, controls!, reefFrame);

        resetView();
        resetViewRef.current = resetView;
        setLoadState({ phase: "ready", progress: 100 });

        renderer.setAnimationLoop(() => {
          controls?.update();
          renderer?.render(scene, camera);
        });

        resizeObserver = new ResizeObserver(() => {
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
        if (disposed) return;

        console.error("Unable to load the reef model", error);
        setLoadState({
          phase: "error",
          progress: 0,
          message:
            error instanceof Error
              ? error.message
              : "The reef model could not be loaded.",
        });
      }
    }

    void initializeViewer();

    return () => {
      disposed = true;
      resetViewRef.current = () => undefined;
      resizeObserver?.disconnect();
      if (renderer && resetView) {
        renderer.domElement.removeEventListener("dblclick", resetView);
      }
      renderer?.setAnimationLoop(null);
      controls?.dispose();
      splatMesh?.dispose();
      sparkRenderer?.dispose();
      renderer?.dispose();

      if (renderer?.domElement.parentNode === container) {
        container.removeChild(renderer.domElement);
      }
    };
  }, [attempt]);

  return (
    <main className={styles.viewerShell}>
      <div ref={containerRef} className={styles.canvasContainer} />

      <header className={styles.header}>
        <p className={styles.eyebrow}>Living Seas</p>
        <h1>Padang Bai reef scan</h1>
      </header>

      {loadState.phase === "loading" && (
        <section className={styles.statusCard} role="status" aria-live="polite">
          <div className={styles.statusHeading}>
            <span className={styles.spinner} aria-hidden="true" />
            <strong>Loading the 3D reef</strong>
          </div>
          <p>
            {loadState.progress > 0
              ? `${loadState.progress}% downloaded`
              : "Connecting to the reef model…"}
          </p>
          <div
            className={styles.progressTrack}
            role="progressbar"
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={loadState.progress}
          >
            <span style={{ width: `${loadState.progress}%` }} />
          </div>
          <small>The first visit can take about a minute.</small>
        </section>
      )}

      {loadState.phase === "error" && (
        <section className={styles.statusCard} role="alert">
          <strong>We couldn’t load the reef.</strong>
          <p>{loadState.message}</p>
          <button type="button" onClick={() => setAttempt((value) => value + 1)}>
            Try again
          </button>
        </section>
      )}

      {loadState.phase === "ready" && (
        <div className={styles.viewerControls}>
          <button type="button" onClick={() => resetViewRef.current()}>
            Reframe reef
          </button>
          <span>Clean structure view · drag to orbit · scroll or pinch to zoom · double-click to reframe</span>
        </div>
      )}
    </main>
  );
}
