"use client";

import { useEffect, useRef } from "react";
import * as THREE from "three";
import { PLYLoader } from "three/addons/loaders/PLYLoader.js";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

export default function ReefViewer() {
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!containerRef.current) return;

    const container = containerRef.current;

    // Scene
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x111111);

    // Camera
    const camera = new THREE.PerspectiveCamera(
      60,
      container.clientWidth / container.clientHeight,
      0.1,
      10000
    );

    camera.position.set(0, 0, 5);

    // Renderer
    const renderer = new THREE.WebGLRenderer({
      antialias: true,
    });

    renderer.setSize(
      container.clientWidth,
      container.clientHeight
    );

    renderer.setPixelRatio(window.devicePixelRatio);

    container.appendChild(renderer.domElement);

    // Mouse controls
    const controls = new OrbitControls(
      camera,
      renderer.domElement
    );

    controls.enableDamping = true;

    // Load PLY
    const loader = new PLYLoader();

    loader.load(
      "https://coralfullstorage.blob.core.windows.net/reefs/one_reef_star.ply",

      (geometry) => {
        geometry.computeVertexNormals();

        const material = new THREE.PointsMaterial({
          size: 0.01,
          vertexColors: geometry.hasAttribute("color"),
        });

        const pointCloud = new THREE.Points(
          geometry,
          material
        );

        scene.add(pointCloud);

        // Center model
        geometry.computeBoundingBox();

        const boundingBox = geometry.boundingBox;

        if (boundingBox) {
          const center = new THREE.Vector3();

          boundingBox.getCenter(center);

          pointCloud.position.sub(center);
        }
      },

      (progress) => {
        if (progress.total) {
          console.log(
            `${(
              (progress.loaded / progress.total) *
              100
            ).toFixed(1)}% loaded`
          );
        }
      },

      (error) => {
        console.error(
          "Error loading PLY:",
          error
        );
      }
    );

    // Animation loop
    function animate() {
      requestAnimationFrame(animate);

      controls.update();

      renderer.render(scene, camera);
    }

    animate();

    // Resize
    function handleResize() {
      const width = container.clientWidth;
      const height = container.clientHeight;

      camera.aspect = width / height;
      camera.updateProjectionMatrix();

      renderer.setSize(width, height);
    }

    window.addEventListener(
      "resize",
      handleResize
    );

    // Cleanup
    return () => {
      window.removeEventListener(
        "resize",
        handleResize
      );

      controls.dispose();
      renderer.dispose();

      if (renderer.domElement.parentNode) {
        renderer.domElement.parentNode.removeChild(
          renderer.domElement
        );
      }
    };
  }, []);

  return (
    <div
      ref={containerRef}
      style={{
        width: "100%",
        height: "100vh",
      }}
    />
  );
}