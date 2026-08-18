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

const DEFAULT_REEF_URL =
  "https://coralfullstorage.blob.core.windows.net/reefs/reef_ds2.ply";
const REEF_URL = process.env.NEXT_PUBLIC_REEF_MODEL_URL ?? DEFAULT_REEF_URL;
const BOUNDS_TRIM_PERCENT = 0.01;
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

function getTrimmedBounds(
  splatCount: number,
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

  const lowerIndex = Math.floor((index - 1) * BOUNDS_TRIM_PERCENT);
  const upperIndex = Math.ceil((index - 1) * (1 - BOUNDS_TRIM_PERCENT));

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

function hideOutlierSplats(splats: PackedSplats) {
  const splatCount = splats.getNumSplats();

  if (splatCount === 0) return;

  const coreBounds = getTrimmedBounds(splatCount, (visit) => {
    splats.forEachSplat((_index, center) => visit(center));
  });
  const coreSize = coreBounds.getSize(new THREE.Vector3());
  const maxSplatScale = Math.max(
    Math.max(coreSize.x, coreSize.y, coreSize.z) * 0.01,
    0.015
  );

  splats.forEachSplat(
    (index, center, scales, quaternion, opacity, color) => {
      const isOutsideCore = !coreBounds.containsPoint(center);
      const isOversized = Math.max(scales.x, scales.y, scales.z) > maxSplatScale;

      if (isOutsideCore || isOversized) {
        splats.setSplat(index, center, scales, quaternion, 0, color);
      }
    }
  );
}

function getRobustBounds(splatMesh: SplatMeshInstance) {
  const splatCount = splatMesh.splats?.getNumSplats() ?? 0;

  if (splatCount === 0) {
    return splatMesh.getBoundingBox(true);
  }

  return getTrimmedBounds(splatCount, (visit) => {
    splatMesh.forEachSplat(
      (_index, center, _scales, _quaternion, opacity) => {
        if (opacity > 0.01) visit(center);
      }
    );
  });
}

function fitCameraToReef(
  camera: THREE.PerspectiveCamera,
  controls: OrbitControls,
  bounds: THREE.Box3
) {
  const center = bounds.getCenter(new THREE.Vector3());
  const size = bounds.getSize(new THREE.Vector3());
  const radius = Math.max(size.length() / 2, 0.25);
  const verticalHalfFov = THREE.MathUtils.degToRad(camera.fov / 2);
  const horizontalHalfFov = Math.atan(
    Math.tan(verticalHalfFov) * camera.aspect
  );
  const distance =
    (radius / Math.sin(Math.min(verticalHalfFov, horizontalHalfFov))) * 1.35;

  camera.up.copy(SURVEY_CAMERA_UP);
  camera.position.copy(center).addScaledVector(SURVEY_VIEW_DIRECTION, distance);
  camera.near = Math.max(distance / 10_000, 0.001);
  camera.far = Math.max(distance * 100, 100);
  camera.updateProjectionMatrix();

  controls.target.copy(center);
  controls.minDistance = distance * 0.04;
  controls.maxDistance = distance * 12;
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
        controls.dampingFactor = 0.08;

        sparkRenderer = new SparkRenderer({ renderer });
        scene.add(sparkRenderer);

        splatMesh = new SplatMesh({
          url: REEF_URL,
          constructSplats: hideOutlierSplats,
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

        const reefBounds = getRobustBounds(splatMesh);
        const resetView = () => fitCameraToReef(camera, controls!, reefBounds);

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
            Reset view
          </button>
          <span>Drag to orbit · scroll to zoom · right-drag to pan</span>
        </div>
      )}
    </main>
  );
}
