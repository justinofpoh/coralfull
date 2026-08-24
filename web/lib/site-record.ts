import type { UploadedSite, UploadedState } from "./types";

type SwiftState = Record<string, Record<string, string> | string>;

export function decodeState(raw: unknown): UploadedState {
  if (typeof raw === "string") {
    if (raw === "failed") return { kind: "failed", message: "Processing failed." };
    return { kind: raw as Exclude<UploadedState["kind"], "failed"> };
  }
  if (!raw || typeof raw !== "object") return { kind: "interrupted" };

  const record = raw as SwiftState;
  const key = Object.keys(record)[0];
  if (!key) return { kind: "interrupted" };
  if (key === "failed") {
    const inner = record.failed;
    const message =
      typeof inner === "string"
        ? inner
        : inner && typeof inner === "object"
          ? inner._0 || inner.String || Object.values(inner)[0] || "Processing failed."
          : "Processing failed.";
    return { kind: "failed", message };
  }
  return { kind: key as Exclude<UploadedState["kind"], "failed"> };
}

export function encodeState(state: UploadedState): SwiftState {
  if (state.kind === "failed") return { failed: { _0: state.message } };
  return { [state.kind]: {} };
}

export function decodeSite(raw: Record<string, unknown>): UploadedSite {
  return {
    id: String(raw.id),
    name: String(raw.name ?? "Untitled site"),
    createdAt: String(raw.createdAt ?? new Date().toISOString()),
    state: decodeState(raw.state),
    photoCount: Number(raw.photoCount ?? 0),
    sourcePhotoDirectory: (raw.sourcePhotoDirectory as string | null) ?? null,
    metashapeProjectPath: (raw.metashapeProjectPath as string | null) ?? null,
    meshPlyPath: (raw.meshPlyPath as string | null) ?? null,
    meshTexturePath: (raw.meshTexturePath as string | null) ?? null,
    analysisManifestPath: (raw.analysisManifestPath as string | null) ?? null,
  };
}

export function encodeSite(site: UploadedSite) {
  return {
    id: site.id,
    name: site.name,
    createdAt: site.createdAt,
    state: encodeState(site.state),
    photoCount: site.photoCount,
    sourcePhotoDirectory: site.sourcePhotoDirectory ?? undefined,
    metashapeProjectPath: site.metashapeProjectPath ?? undefined,
    meshPlyPath: site.meshPlyPath ?? undefined,
    meshTexturePath: site.meshTexturePath ?? undefined,
    analysisManifestPath: site.analysisManifestPath ?? undefined,
  };
}

export function isTerminal(state: UploadedState) {
  return (
    state.kind === "ready" ||
    state.kind === "failed" ||
    state.kind === "cancelled" ||
    state.kind === "interrupted"
  );
}
