import fs from "node:fs";
import path from "node:path";
import { siteBRoot, siteDirectory } from "./paths";

const SITE_B_FALLBACK = {
  ply: "site_b_metashape_mesh.ply",
  texture: "site_b_metashape_mesh.jpg",
  vertexLabels: "site_b_semantic_vertex_labels.bin",
};

export function analysisRoot(siteId: string) {
  if (siteId === "site-b") return siteBRoot();
  return path.join(siteDirectory(siteId), "analysis");
}

export function manifestPath(siteId: string) {
  if (siteId === "site-b") return path.join(siteBRoot(), "site_b_sequence.json");
  return path.join(siteDirectory(siteId), "analysis", "site_sequence.json");
}

export function resolveSiteFile(siteId: string, relativePath: string) {
  const cleaned = relativePath.replace(/^\/+/, "");
  if (!cleaned || cleaned.includes("\0")) return null;
  const allowedRoot = path.resolve(siteId === "site-b" ? siteBRoot() : siteDirectory(siteId));
  const from = siteId === "site-b" ? allowedRoot : path.join(allowedRoot, "analysis");
  const resolved = path.resolve(from, cleaned);
  if (resolved !== allowedRoot && !resolved.startsWith(allowedRoot + path.sep)) {
    return null;
  }
  return resolved;
}

export function mimeFor(filePath: string) {
  const ext = path.extname(filePath).toLowerCase();
  switch (ext) {
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".png":
      return "image/png";
    case ".json":
      return "application/json";
    case ".ply":
      return "application/octet-stream";
    case ".bin":
      return "application/octet-stream";
    default:
      return "application/octet-stream";
  }
}

export { SITE_B_FALLBACK };
