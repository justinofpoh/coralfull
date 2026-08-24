export type ImportCandidate = {
  id: string;
  file: File;
  fileName: string;
  fileSizeBytes: number;
  pixelWidth?: number;
  pixelHeight?: number;
  capturedAt?: Date;
  cameraModel?: string;
  thumbnailUrl: string;
};

const SUPPORTED = new Set(["jpg", "jpeg", "png"]);

function extension(name: string) {
  return name.split(".").pop()?.toLowerCase() ?? "";
}

export function naturalCompare(a: string, b: string) {
  return a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });
}

export function collectImageFiles(fileList: FileList | File[]) {
  const files = Array.from(fileList);
  const images: File[] = [];
  let skipped = 0;
  for (const file of files) {
    if (SUPPORTED.has(extension(file.name))) images.push(file);
    else skipped += 1;
  }
  images.sort((a, b) =>
    naturalCompare(a.webkitRelativePath || a.name, b.webkitRelativePath || b.name)
  );
  return { images, skipped };
}

function readAscii(bytes: Uint8Array, offset: number, length: number) {
  return String.fromCharCode(...bytes.subarray(offset, offset + length));
}

function parseJpegExif(buffer: ArrayBuffer): { cameraModel?: string; capturedAt?: Date } {
  const bytes = new Uint8Array(buffer);
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) return {};
  let offset = 2;
  while (offset + 4 < bytes.length) {
    if (bytes[offset] !== 0xff) break;
    const marker = bytes[offset + 1];
    const size = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (marker === 0xe1) {
      const start = offset + 4;
      if (readAscii(bytes, start, 4) !== "Exif") return {};
      return parseTiff(bytes.subarray(start + 6), buffer.slice(start + 6));
    }
    offset += 2 + size;
    if (marker === 0xda) break;
  }
  return {};
}

function parseTiff(bytes: Uint8Array, buffer: ArrayBuffer): { cameraModel?: string; capturedAt?: Date } {
  const view = new DataView(buffer);
  const little = readAscii(bytes, 0, 2) === "II";
  const u16 = (at: number) => view.getUint16(at, little);
  const u32 = (at: number) => view.getUint32(at, little);
  const readIfd = (at: number) => {
    const count = u16(at);
    const entries: { tag: number; type: number; count: number; value: number }[] = [];
    for (let i = 0; i < count; i += 1) {
      const base = at + 2 + i * 12;
      entries.push({
        tag: u16(base),
        type: u16(base + 2),
        count: u32(base + 4),
        value: u32(base + 8),
      });
    }
    return entries;
  };
  const decodeString = (entry: { type: number; count: number; value: number }) => {
    const length = entry.count;
    const offset = length <= 4 ? undefined : entry.value;
    const from = offset ?? 0;
    if (length <= 4) {
      const chars = [];
      let packed = entry.value;
      for (let i = 0; i < length - 1; i += 1) {
        chars.push(packed & 0xff);
        packed >>= 8;
      }
      return String.fromCharCode(...chars);
    }
    return readAscii(bytes, from, Math.max(0, length - 1));
  };

  const ifd0 = readIfd(u32(4));
  let cameraModel: string | undefined;
  let exifOffset: number | undefined;
  for (const entry of ifd0) {
    if (entry.tag === 0x0110) cameraModel = decodeString(entry) || undefined;
    if (entry.tag === 0x8769) exifOffset = entry.value;
  }
  let capturedAt: Date | undefined;
  if (exifOffset) {
    const exif = readIfd(exifOffset);
    const original = exif.find((entry) => entry.tag === 0x9003);
    if (original) {
      const raw = decodeString(original);
      const match = raw.match(/^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})/);
      if (match) {
        capturedAt = new Date(
          Number(match[1]),
          Number(match[2]) - 1,
          Number(match[3]),
          Number(match[4]),
          Number(match[5]),
          Number(match[6])
        );
      }
    }
  }
  return { cameraModel, capturedAt };
}

async function dimensionsOf(file: File) {
  const bitmap = await createImageBitmap(file);
  const size = { width: bitmap.width, height: bitmap.height };
  bitmap.close();
  return size;
}

export async function readCandidate(file: File): Promise<ImportCandidate> {
  const thumbnailUrl = URL.createObjectURL(file);
  const candidate: ImportCandidate = {
    id: `${file.webkitRelativePath || file.name}:${file.size}:${file.lastModified}`,
    file,
    fileName: file.name,
    fileSizeBytes: file.size,
    thumbnailUrl,
  };
  try {
    const size = await dimensionsOf(file);
    candidate.pixelWidth = size.width;
    candidate.pixelHeight = size.height;
  } catch {
    // unreadable
  }
  if (extension(file.name) === "png") return candidate;
  try {
    const header = await file.slice(0, 128 * 1024).arrayBuffer();
    const exif = parseJpegExif(header);
    candidate.cameraModel = exif.cameraModel;
    candidate.capturedAt = exif.capturedAt;
  } catch {
    // no EXIF
  }
  return candidate;
}
