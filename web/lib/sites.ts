import fs from "node:fs";
import path from "node:path";
import type { PipelineStatus, UploadedSite, UploadedState } from "./types";
import { decodeSite, encodeSite, isTerminal } from "./site-record";
import { ensureDir, siteDirectory, sitesRoot } from "./paths";

export function readStatus(siteId: string): PipelineStatus | null {
  const file = path.join(siteDirectory(siteId), "status.json");
  if (!fs.existsSync(file)) return null;
  try {
    return JSON.parse(fs.readFileSync(file, "utf8")) as PipelineStatus;
  } catch {
    return null;
  }
}

export function readSite(siteId: string): UploadedSite | null {
  const file = path.join(siteDirectory(siteId), "site.json");
  if (!fs.existsSync(file)) return null;
  try {
    return decodeSite(JSON.parse(fs.readFileSync(file, "utf8")));
  } catch {
    return null;
  }
}

export function writeSite(site: UploadedSite) {
  const directory = siteDirectory(site.id);
  ensureDir(directory);
  fs.writeFileSync(
    path.join(directory, "site.json"),
    JSON.stringify(encodeSite(site), null, 2)
  );
}

export function updateSite(siteId: string, patch: Partial<UploadedSite>) {
  const current = readSite(siteId);
  if (!current) return null;
  const next = { ...current, ...patch };
  writeSite(next);
  return next;
}

function reconcile(site: UploadedSite, isRunning: boolean): UploadedSite {
  const status = readStatus(site.id);
  if (status?.state === "ready" && site.state.kind !== "ready") {
    return markReady(site.id) ?? { ...site, state: { kind: "ready" } };
  }
  if (isRunning) {
    if (site.state.kind !== "processing") {
      return updateSite(site.id, { state: { kind: "processing" } }) ?? site;
    }
    return site;
  }
  if (isTerminal(site.state) && site.state.kind !== "interrupted") return site;
  let state: UploadedState;
  switch (status?.state) {
    case "ready":
      return markReady(site.id) ?? { ...site, state: { kind: "ready" } };
    case "failed":
      state = { kind: "failed", message: status.error || "Processing failed." };
      break;
    case "cancelled":
      state = { kind: "cancelled" };
      break;
    default:
      state = site.state.kind === "importing" ? site.state : { kind: "interrupted" };
  }
  const next = { ...site, state };
  writeSite(next);
  return next;
}

export function listSites(): UploadedSite[] {
  const root = sitesRoot();
  if (!fs.existsSync(root)) return [];
  const entries = fs.readdirSync(root, { withFileTypes: true });
  const sites: UploadedSite[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const site = readSite(entry.name);
    if (!site) continue;
    const pidFile = path.join(siteDirectory(entry.name), "pipeline.pid");
    let isRunning = false;
    if (fs.existsSync(pidFile)) {
      const pid = Number(fs.readFileSync(pidFile, "utf8").trim());
      try {
        process.kill(pid, 0);
        isRunning = true;
      } catch {
        fs.rmSync(pidFile, { force: true });
      }
    }
    sites.push(reconcile(site, isRunning));
  }
  return sites.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

/**
 * Creates the on-disk working directory for a scan.
 *
 * The id is supplied by the backend, which owns the site record; passing it in
 * keeps one identity across the local directory, the pipeline and the database.
 * It falls back to a fresh uuid so the local pipeline still works standalone.
 */
export function createSiteRecord(name: string, id = crypto.randomUUID().toLowerCase()): UploadedSite {
  const photos = path.join(siteDirectory(id), "photos");
  ensureDir(photos);
  const site: UploadedSite = {
    id,
    name: name.trim() || "New Survey Site",
    createdAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    state: { kind: "importing" },
    photoCount: 0,
    sourcePhotoDirectory: photos,
  };
  writeSite(site);
  return site;
}

export function uniquePhotoName(directory: string, originalName: string, used: Set<string>) {
  const ext = path.extname(originalName);
  const stem = path.basename(originalName, ext);
  const parent = path.basename(path.dirname(originalName));
  const candidates = [`${stem}${ext}`, `${parent}_${stem}${ext}`];
  for (const name of candidates) {
    if (!used.has(name.toLowerCase())) {
      used.add(name.toLowerCase());
      return name;
    }
  }
  let extra = 2;
  while (true) {
    const name = `${parent}_${stem}_${extra}${ext}`;
    extra += 1;
    if (!used.has(name.toLowerCase())) {
      used.add(name.toLowerCase());
      return name;
    }
  }
}

export function existingPhotoNames(siteId: string) {
  const photos = path.join(siteDirectory(siteId), "photos");
  const used = new Set<string>();
  if (!fs.existsSync(photos)) return used;
  for (const name of fs.readdirSync(photos)) used.add(name.toLowerCase());
  return used;
}

export function deleteSite(siteId: string) {
  const directory = siteDirectory(siteId);
  fs.rmSync(directory, { recursive: true, force: true });
}

export function coverPath(siteId: string) {
  return path.join(siteDirectory(siteId), "cover.jpg");
}

export function markReady(siteId: string) {
  const directory = siteDirectory(siteId);
  const analysis = path.join(directory, "analysis", "site_sequence.json");
  let photoCount = readSite(siteId)?.photoCount ?? 0;
  try {
    const manifest = JSON.parse(fs.readFileSync(analysis, "utf8")) as {
      frames?: unknown[];
    };
    if (Array.isArray(manifest.frames)) photoCount = manifest.frames.length;
  } catch {
    // keep existing count
  }
  return updateSite(siteId, {
    state: { kind: "ready" },
    photoCount,
    metashapeProjectPath: path.join(directory, "project", "site.psx"),
    meshPlyPath: path.join(directory, "mesh", "mesh.ply"),
    meshTexturePath: path.join(directory, "mesh", "mesh.jpg"),
    analysisManifestPath: analysis,
  });
}
