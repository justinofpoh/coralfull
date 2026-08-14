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
    loader.setCustomPropertyNameMapping({
      // Gaussian-splat PLY files store their base color as spherical-harmonic
      // DC coefficients instead of PLY's standard red/green/blue properties.
      splatColor: ["f_dc_0", "f_dc_1", "f_dc_2"],
    });

    loader.load(
      "https://coralfullstorage.blob.core.windows.net/reefs/reef_ds2.ply",

      (geometry) => {
        const splatColor = geometry.getAttribute("splatColor");

        if (splatColor) {
          const colors = new Float32Array(splatColor.count * 3);
          const sphericalHarmonicDC = 0.28209479177387814;

          for (let index = 0; index < splatColor.count; index += 1) {
            const colorIndex = index * 3;

            colors[colorIndex] = THREE.MathUtils.clamp(
              0.5 + sphericalHarmonicDC * splatColor.getX(index),
              0,
              1
            );
            colors[colorIndex + 1] = THREE.MathUtils.clamp(
              0.5 + sphericalHarmonicDC * splatColor.getY(index),
              0,
              1
            );
            colors[colorIndex + 2] = THREE.MathUtils.clamp(
              0.5 + sphericalHarmonicDC * splatColor.getZ(index),
              0,
              1
            );
          }

          geometry.setAttribute("color", new THREE.BufferAttribute(colors, 3));
        }

        const material = new THREE.PointsMaterial({
          size: 0.08,
          sizeAttenuation: true,
          vertexColors: true,
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

          // Fit the full cloud instead of placing the camera inside it.
          geometry.computeBoundingSphere();
          const radius = geometry.boundingSphere?.radius ?? 1;
          const verticalHalfFov = THREE.MathUtils.degToRad(camera.fov / 2);
          const horizontalHalfFov = Math.atan(
            Math.tan(verticalHalfFov) * camera.aspect
          );
          const distance =
            (radius / Math.sin(Math.min(verticalHalfFov, horizontalHalfFov))) *
            1.2;

          camera.position.set(0, 0, distance);
          camera.near = Math.max(distance / 1000, 0.01);
          camera.far = distance * 10;
          camera.updateProjectionMatrix();
          controls.target.set(0, 0, 0);
          controls.update();
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
