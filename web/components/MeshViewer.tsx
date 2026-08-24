"use client";

import { useEffect, useRef } from "react";
import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { loadMetashapeMesh } from "@/lib/ply";

const depthVertex = /* glsl */ `
  varying float vDist;
  void main() {
    vec4 viewPosition = modelViewMatrix * vec4(position, 1.0);
    vDist = length(viewPosition.xyz);
    gl_Position = projectionMatrix * viewPosition;
  }
`;

const depthFragment = /* glsl */ `
  varying float vDist;
  uniform float uNear;
  uniform float uFar;
  void main() {
    float t = clamp((vDist - uNear) / max(uFar - uNear, 0.0001), 0.0, 1.0);
    float n = 1.0 - t;
    vec3 stops[8];
    stops[0] = vec3(0.122, 0.153, 0.471);
    stops[1] = vec3(0.188, 0.318, 0.808);
    stops[2] = vec3(0.114, 0.600, 0.902);
    stops[3] = vec3(0.200, 0.804, 0.600);
    stops[4] = vec3(0.608, 0.882, 0.275);
    stops[5] = vec3(0.961, 0.867, 0.216);
    stops[6] = vec3(0.969, 0.525, 0.149);
    stops[7] = vec3(0.776, 0.173, 0.145);
    float rampPosition = n * 7.0;
    int lowerStop = int(floor(rampPosition));
    int upperStop = min(lowerStop + 1, 7);
    vec3 rampColor = mix(stops[lowerStop], stops[upperStop], rampPosition - float(lowerStop));
    gl_FragColor = vec4(rampColor, 1.0);
  }
`;

type MeshViewerProps = {
  plyUrl: string;
  textureUrl?: string | null;
  labelsUrl?: string | null;
  displayMode: "texture" | "wireframe";
  showHealthy: boolean;
  showUnhealthy: boolean;
  captureViewportDepth: boolean;
  onMeshInfo?: (info: {
    vertexCount: number;
    faceCount: number;
    labelCounts: { healthy: number; unhealthy: number };
    hasLabels: boolean;
  }) => void;
  onViewportDepth?: (dataUrl: string | null) => void;
};

export default function MeshViewer({
  plyUrl,
  textureUrl,
  labelsUrl,
  displayMode,
  showHealthy,
  showUnhealthy,
  captureViewportDepth,
  onMeshInfo,
  onViewportDepth,
}: MeshViewerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const stateRef = useRef({
    displayMode,
    showHealthy,
    showUnhealthy,
    captureViewportDepth,
    onViewportDepth,
  });

  useEffect(() => {
    stateRef.current = {
      displayMode,
      showHealthy,
      showUnhealthy,
      captureViewportDepth,
      onViewportDepth,
    };
  }, [displayMode, showHealthy, showUnhealthy, captureViewportDepth, onViewportDepth]);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    let disposed = false;
    let renderer: THREE.WebGLRenderer | null = null;
    let controls: OrbitControls | null = null;
    let baseMesh: THREE.Mesh | null = null;
    let healthyMesh: THREE.Mesh | null = null;
    let unhealthyMesh: THREE.Mesh | null = null;
    let depthMesh: THREE.Mesh | null = null;
    let depthTarget: THREE.WebGLRenderTarget | null = null;
    let lastTransform = "";
    const scene = new THREE.Scene();
    scene.background = new THREE.Color(0x050b0a);
    const depthScene = new THREE.Scene();
    depthScene.background = new THREE.Color(0x071726);

    const width = Math.max(container.clientWidth, 1);
    const height = Math.max(container.clientHeight, 1);
    const camera = new THREE.PerspectiveCamera(48, width / height, 0.01, 100);
    camera.position.set(0, 0, 2.55);

    renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.setSize(width, height);
    renderer.outputColorSpace = THREE.SRGBColorSpace;
    container.appendChild(renderer.domElement);

    controls = new OrbitControls(camera, renderer.domElement);
    controls.enableDamping = true;
    controls.target.set(0, 0, 0);

    const light = new THREE.DirectionalLight(0xffffff, 1.1);
    light.position.set(0.4, 0.8, 1.2);
    scene.add(light);
    scene.add(new THREE.AmbientLight(0xffffff, 0.55));

    const depthMaterial = new THREE.ShaderMaterial({
      vertexShader: depthVertex,
      fragmentShader: depthFragment,
      uniforms: {
        uNear: { value: 0.2 },
        uFar: { value: 4 },
      },
      side: THREE.DoubleSide,
    });

    const captureCanvas = document.createElement("canvas");

    async function load() {
      try {
        const mesh = await loadMetashapeMesh(plyUrl, textureUrl, labelsUrl);
        if (disposed) {
          mesh.geometry.dispose();
          mesh.healthy?.dispose();
          mesh.unhealthy?.dispose();
          mesh.texture?.dispose();
          return;
        }
        const material = new THREE.MeshBasicMaterial({
          map: mesh.texture,
          color: mesh.texture ? 0xffffff : 0x52c2b3,
          side: THREE.DoubleSide,
          wireframe: false,
        });
        baseMesh = new THREE.Mesh(mesh.geometry, material);
        baseMesh.userData.texture = mesh.texture;
        scene.add(baseMesh);
        depthMesh = new THREE.Mesh(mesh.geometry, depthMaterial);
        depthScene.add(depthMesh);
        if (mesh.healthy) {
          healthyMesh = new THREE.Mesh(
            mesh.healthy,
            new THREE.MeshBasicMaterial({ color: 0x00c800, side: THREE.DoubleSide })
          );
          healthyMesh.visible = false;
          scene.add(healthyMesh);
        }
        if (mesh.unhealthy) {
          unhealthyMesh = new THREE.Mesh(
            mesh.unhealthy,
            new THREE.MeshBasicMaterial({ color: 0xdc1e1e, side: THREE.DoubleSide })
          );
          unhealthyMesh.visible = false;
          scene.add(unhealthyMesh);
        }
        onMeshInfo?.({
          vertexCount: mesh.vertexCount,
          faceCount: mesh.faceCount,
          labelCounts: mesh.labelCounts,
          hasLabels: Boolean(mesh.healthy || mesh.unhealthy),
        });
      } catch (error) {
        console.error(error);
        onMeshInfo?.({
          vertexCount: 0,
          faceCount: 0,
          labelCounts: { healthy: 0, unhealthy: 0 },
          hasLabels: false,
        });
      }
    }

    void load();

    const resize = () => {
      if (!renderer) return;
      const nextWidth = Math.max(container.clientWidth, 1);
      const nextHeight = Math.max(container.clientHeight, 1);
      camera.aspect = nextWidth / nextHeight;
      camera.updateProjectionMatrix();
      renderer.setSize(nextWidth, nextHeight);
    };
    const observer = new ResizeObserver(resize);
    observer.observe(container);

    renderer.setAnimationLoop(() => {
      controls?.update();
      if (baseMesh) {
        const material = baseMesh.material as THREE.MeshBasicMaterial;
        const wireframe = stateRef.current.displayMode === "wireframe";
        material.wireframe = wireframe;
        material.map = wireframe ? null : (baseMesh.userData.texture as THREE.Texture | null);
        material.color.set(wireframe ? 0x52c2b3 : 0xffffff);
        material.needsUpdate = true;
      }
      if (healthyMesh) healthyMesh.visible = stateRef.current.showHealthy;
      if (unhealthyMesh) unhealthyMesh.visible = stateRef.current.showUnhealthy;
      renderer?.render(scene, camera);

      if (stateRef.current.captureViewportDepth && renderer && depthMesh) {
        const key = `${camera.position.x.toFixed(3)}:${camera.quaternion.x.toFixed(3)}:${camera.zoom}`;
        if (key !== lastTransform) {
          lastTransform = key;
          const distance = camera.position.length();
          depthMaterial.uniforms.uNear.value = Math.max(distance - 0.9, 0.01);
          depthMaterial.uniforms.uFar.value = Math.max(distance + 0.9, 0.02);
          const targetWidth = 360;
          const targetHeight = Math.max(1, Math.round(targetWidth * (camera.aspect ? 1 / camera.aspect : 0.56)));
          if (!depthTarget || depthTarget.width !== targetWidth || depthTarget.height !== targetHeight) {
            depthTarget?.dispose();
            depthTarget = new THREE.WebGLRenderTarget(targetWidth, targetHeight);
          }
          renderer.setRenderTarget(depthTarget);
          renderer.render(depthScene, camera);
          renderer.setRenderTarget(null);
          const pixels = new Uint8Array(targetWidth * targetHeight * 4);
          renderer.readRenderTargetPixels(depthTarget, 0, 0, targetWidth, targetHeight, pixels);
          captureCanvas.width = targetWidth;
          captureCanvas.height = targetHeight;
          const context = captureCanvas.getContext("2d");
          if (context) {
            const image = context.createImageData(targetWidth, targetHeight);
            for (let y = 0; y < targetHeight; y += 1) {
              const src = (targetHeight - 1 - y) * targetWidth * 4;
              const dst = y * targetWidth * 4;
              image.data.set(pixels.subarray(src, src + targetWidth * 4), dst);
            }
            context.putImageData(image, 0, 0);
            stateRef.current.onViewportDepth?.(captureCanvas.toDataURL("image/png"));
          }
        }
      }
    });

    return () => {
      disposed = true;
      observer.disconnect();
      renderer?.setAnimationLoop(null);
      controls?.dispose();
      depthTarget?.dispose();
      baseMesh?.geometry.dispose();
      (baseMesh?.material as THREE.Material | undefined)?.dispose();
      healthyMesh?.geometry.dispose();
      (healthyMesh?.material as THREE.Material | undefined)?.dispose();
      unhealthyMesh?.geometry.dispose();
      (unhealthyMesh?.material as THREE.Material | undefined)?.dispose();
      depthMaterial.dispose();
      renderer?.dispose();
      if (renderer?.domElement.parentNode === container) {
        container.removeChild(renderer.domElement);
      }
    };
  }, [plyUrl, textureUrl, labelsUrl, onMeshInfo]);

  return <div ref={containerRef} className="mesh-canvas" />;
}
