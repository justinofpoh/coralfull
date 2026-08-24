import * as THREE from "three";

type VertexLayout = {
  stride: number;
  positionOffset: number;
  normalOffset: number | null;
  faceHasTextureCoordinates: boolean;
};

export type LoadedMesh = {
  geometry: THREE.BufferGeometry;
  healthy?: THREE.BufferGeometry;
  unhealthy?: THREE.BufferGeometry;
  texture: THREE.Texture | null;
  vertexCount: number;
  faceCount: number;
  labelCounts: { healthy: number; unhealthy: number };
};

const SIZES: Record<string, number> = {
  char: 1,
  uchar: 1,
  int8: 1,
  uint8: 1,
  short: 2,
  ushort: 2,
  int16: 2,
  uint16: 2,
  int: 4,
  uint: 4,
  int32: 4,
  uint32: 4,
  float: 4,
  float32: 4,
  double: 8,
  float64: 8,
};

function headerValue(header: string, element: string) {
  const line = header.split("\n").find((row) => row.startsWith(`element ${element} `));
  return line ? Number(line.trim().split(" ").pop()) : 0;
}

function parseLayout(header: string): VertexLayout {
  let inVertex = false;
  let inFace = false;
  let offset = 0;
  let position: number | null = null;
  let normal: number | null = null;
  let faceTexture = false;
  for (const line of header.split("\n")) {
    const parts = line.trim().split(/\s+/);
    if (parts[0] === "element") {
      inVertex = parts[1] === "vertex";
      inFace = parts[1] === "face";
    } else if (parts[0] === "property" && inVertex && parts[1] !== "list") {
      const size = SIZES[parts[1]];
      if (!size) throw new Error("Unsupported PLY vertex property.");
      if (parts[2] === "x") position = offset;
      if (parts[2] === "nx") normal = offset;
      offset += size;
    } else if (parts[0] === "property" && inFace && parts[1] === "list" && parts[4] === "texcoord") {
      faceTexture = true;
    }
  }
  if (position === null) throw new Error("The exported PLY header is incomplete.");
  return {
    stride: offset,
    positionOffset: position,
    normalOffset: normal,
    faceHasTextureCoordinates: faceTexture,
  };
}

function overlayGeometry(
  classId: number,
  labels: Uint8Array,
  cornerSources: number[],
  positions: number[],
  normals: number[],
  offset: number
) {
  const overlay: number[] = [];
  const triangleCount = cornerSources.length / 3;
  for (let triangle = 0; triangle < triangleCount; triangle += 1) {
    const base = triangle * 3;
    let matches = 0;
    for (let corner = 0; corner < 3; corner += 1) {
      if (labels[cornerSources[base + corner]] === classId) matches += 1;
    }
    if (matches < 2) continue;
    for (let corner = 0; corner < 3; corner += 1) {
      const index = base + corner;
      const px = positions[index * 3];
      const py = positions[index * 3 + 1];
      const pz = positions[index * 3 + 2];
      const nx = normals[index * 3];
      const ny = normals[index * 3 + 1];
      const nz = normals[index * 3 + 2];
      overlay.push(px + nx * offset, py + ny * offset, pz + nz * offset);
    }
  }
  if (overlay.length === 0) return undefined;
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(overlay, 3));
  geometry.computeVertexNormals();
  return geometry;
}

export async function loadMetashapeMesh(
  plyUrl: string,
  textureUrl?: string | null,
  labelsUrl?: string | null
): Promise<LoadedMesh> {
  const plyBuffer = await fetch(plyUrl).then((response) => {
    if (!response.ok) throw new Error("Could not load the PLY mesh.");
    return response.arrayBuffer();
  });
  const bytes = new Uint8Array(plyBuffer);
  const headerEndBytes = new TextEncoder().encode("end_header\n");
  let headerEnd = -1;
  for (let i = 0; i < bytes.length - headerEndBytes.length; i += 1) {
    let match = true;
    for (let j = 0; j < headerEndBytes.length; j += 1) {
      if (bytes[i + j] !== headerEndBytes[j]) {
        match = false;
        break;
      }
    }
    if (match) {
      headerEnd = i + headerEndBytes.length;
      break;
    }
  }
  if (headerEnd < 0) throw new Error("The exported PLY header is incomplete.");
  const header = new TextDecoder().decode(bytes.subarray(0, headerEnd));
  if (!header.includes("format binary_little_endian 1.0")) {
    throw new Error("Only binary little-endian Metashape PLY files are supported.");
  }
  const vertexCount = headerValue(header, "vertex");
  const faceCount = headerValue(header, "face");
  const layout = parseLayout(header);
  const view = new DataView(plyBuffer);

  const sourcePositions = new Float32Array(vertexCount * 3);
  const sourceNormals = new Float32Array(vertexCount * 3);
  let cursor = headerEnd;
  for (let i = 0; i < vertexCount; i += 1) {
    const start = cursor;
    sourcePositions[i * 3] = view.getFloat32(start + layout.positionOffset, true);
    sourcePositions[i * 3 + 1] = view.getFloat32(start + layout.positionOffset + 4, true);
    sourcePositions[i * 3 + 2] = view.getFloat32(start + layout.positionOffset + 8, true);
    if (layout.normalOffset !== null) {
      sourceNormals[i * 3] = view.getFloat32(start + layout.normalOffset, true);
      sourceNormals[i * 3 + 1] = view.getFloat32(start + layout.normalOffset + 4, true);
      sourceNormals[i * 3 + 2] = view.getFloat32(start + layout.normalOffset + 8, true);
    } else {
      sourceNormals[i * 3 + 2] = 1;
    }
    cursor = start + layout.stride;
  }

  let labels: Uint8Array | null = null;
  if (labelsUrl) {
    const response = await fetch(labelsUrl);
    if (response.ok) {
      const data = new Uint8Array(await response.arrayBuffer());
      if (data.length === vertexCount) labels = data;
    }
  }

  const renderPositions: number[] = [];
  const renderNormals: number[] = [];
  const uvs: number[] = [];
  const cornerSources: number[] = [];

  for (let face = 0; face < faceCount; face += 1) {
    const count = view.getUint8(cursor);
    cursor += 1;
    const indices: number[] = [];
    for (let i = 0; i < count; i += 1) {
      indices.push(view.getUint32(cursor, true));
      cursor += 4;
    }
    const faceUv: number[] = [];
    if (layout.faceHasTextureCoordinates) {
      const uvCount = view.getUint8(cursor);
      cursor += 1;
      for (let i = 0; i < uvCount; i += 1) {
        faceUv.push(view.getFloat32(cursor, true));
        cursor += 4;
      }
    }
    if (count !== 3) continue;
    for (let corner = 0; corner < 3; corner += 1) {
      const sourceIndex = indices[corner];
      renderPositions.push(
        sourcePositions[sourceIndex * 3],
        sourcePositions[sourceIndex * 3 + 1],
        sourcePositions[sourceIndex * 3 + 2]
      );
      renderNormals.push(
        sourceNormals[sourceIndex * 3],
        sourceNormals[sourceIndex * 3 + 1],
        sourceNormals[sourceIndex * 3 + 2]
      );
      cornerSources.push(sourceIndex);
      const uvOffset = corner * 2;
      if (faceUv[uvOffset + 1] !== undefined) {
        uvs.push(faceUv[uvOffset], 1 - faceUv[uvOffset + 1]);
      } else {
        uvs.push(0, 0);
      }
    }
  }

  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.Float32BufferAttribute(renderPositions, 3));
  geometry.setAttribute("normal", new THREE.Float32BufferAttribute(renderNormals, 3));
  geometry.setAttribute("uv", new THREE.Float32BufferAttribute(uvs, 2));
  geometry.computeBoundingBox();
  const box = geometry.boundingBox!;
  const center = box.getCenter(new THREE.Vector3());
  const size = box.getSize(new THREE.Vector3());
  const largest = Math.max(size.x, size.y, size.z) || 1;
  geometry.translate(-center.x, -center.y, -center.z);
  geometry.scale(1 / largest, 1 / largest, 1 / largest);

  const offset = largest * 0.0015;
  const labelCounts = { healthy: 0, unhealthy: 0 };
  let healthy: THREE.BufferGeometry | undefined;
  let unhealthy: THREE.BufferGeometry | undefined;
  if (labels) {
    for (const value of labels) {
      if (value === 1) labelCounts.healthy += 1;
      if (value === 2) labelCounts.unhealthy += 1;
    }
    healthy = overlayGeometry(1, labels, cornerSources, renderPositions, renderNormals, offset);
    unhealthy = overlayGeometry(2, labels, cornerSources, renderPositions, renderNormals, offset);
    healthy?.translate(-center.x, -center.y, -center.z);
    healthy?.scale(1 / largest, 1 / largest, 1 / largest);
    unhealthy?.translate(-center.x, -center.y, -center.z);
    unhealthy?.scale(1 / largest, 1 / largest, 1 / largest);
  }

  let texture: THREE.Texture | null = null;
  if (textureUrl) {
    const image = await new Promise<HTMLImageElement>((resolve, reject) => {
      const element = new Image();
      element.crossOrigin = "anonymous";
      element.onload = () => resolve(element);
      element.onerror = () => reject(new Error("Could not load mesh texture."));
      element.src = textureUrl;
    }).catch(() => null);
    if (image) {
      texture = new THREE.Texture(image);
      texture.colorSpace = THREE.SRGBColorSpace;
      texture.flipY = false;
      texture.needsUpdate = true;
    }
  }

  return {
    geometry,
    healthy,
    unhealthy,
    texture,
    vertexCount,
    faceCount,
    labelCounts,
  };
}
