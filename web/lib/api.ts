/**
 * Client for the Go backend.
 *
 * The backend is the source of truth for the site list, the analysis manifest
 * and every artifact. What stays local is the pipeline: Metashape and
 * CoralScapes run on this machine, and their stage-by-stage progress is still
 * polled from `/api/sites/:id/status` while a scan is being built.
 *
 * Until this file existed every fetch was inline in a component.
 */
import { decodeState } from "./site-record";
import type { AnalysisSequence, DashboardSite, SitePriority, UploadedState } from "./types";

const DEFAULT_API_BASE = "http://localhost:8321";

export const API_BASE = (process.env.NEXT_PUBLIC_API_BASE ?? DEFAULT_API_BASE).replace(/\/+$/, "");

/** Shape of a site as the backend serves it. */
type RemoteSite = {
  id: string;
  name: string;
  createdAt: string;
  updatedAt: string;
  /** Swift's Codable enum encoding: {"ready":{}} or {"failed":{"_0":"..."}}. */
  state: unknown;
  photoCount: number;
  priority: SitePriority;
  tags: string[];
  coverUrl: string | null;
  analysisUrl: string | null;
  filesBase: string;
};

/** The backend wraps successes in {data} and errors in a flat AppError. */
type Envelope<T> = { data: T };
type ApiError = { code: string; message: string; status: number; details?: string[] };

export class BackendError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status: number,
    readonly details: string[] = [],
    options?: { cause?: unknown }
  ) {
    super(message, options);
    this.name = "BackendError";
  }
}

export function apiUrl(path: string) {
  return `${API_BASE}${path.startsWith("/") ? path : `/${path}`}`;
}

/**
 * Absolute URL for one artifact, given the path exactly as the manifest spells
 * it. Each segment is encoded, but the separators are kept so nested paths like
 * "site_b_frames/x_rgb.jpg" address correctly.
 */
export function fileUrl(siteId: string, relative?: string | null) {
  if (!relative) return null;
  const encoded = relative.split("/").map(encodeURIComponent).join("/");
  return apiUrl(`/api/sites/${siteId}/files/${encoded}`);
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(apiUrl(path), init);
  } catch (cause) {
    throw new BackendError(
      `Cannot reach the backend at ${API_BASE}. Is it running?`,
      "NETWORK",
      0,
      [],
      { cause }
    );
  }

  if (!response.ok) {
    const body = (await response.json().catch(() => null)) as ApiError | null;
    throw new BackendError(
      body?.message ?? `Request failed (${response.status})`,
      body?.code ?? "UNKNOWN",
      response.status,
      body?.details ?? []
    );
  }
  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

function toDashboardSite(site: RemoteSite): DashboardSite {
  const state = decodeState(site.state) as UploadedState;
  return {
    id: site.id,
    name: site.name,
    photoCount: site.photoCount,
    priority: site.priority ?? "medium",
    coverUrl: site.coverUrl ? apiUrl(site.coverUrl) : null,
    // Every site now comes from the same place; "analysis" is simply what a
    // finished one is. The old splat/placeholder kinds are gone.
    kind: "analysis",
    uploadedState: state,
    tags: site.tags ?? [],
    hasAnalysis: Boolean(site.analysisUrl),
  };
}

export async function listSites(): Promise<DashboardSite[]> {
  const body = await request<Envelope<RemoteSite[]>>("/api/sites");
  return (body.data ?? []).map(toDashboardSite);
}

export async function getSite(siteId: string): Promise<DashboardSite> {
  const body = await request<Envelope<RemoteSite>>(`/api/sites/${siteId}`);
  return toDashboardSite(body.data);
}

/** Creates the row so an in-progress scan is visible before it has artifacts. */
export async function createSite(input: {
  name: string;
  priority?: SitePriority;
  photoCount?: number;
  tags?: string[];
}): Promise<{ id: string }> {
  const body = await request<Envelope<{ site: RemoteSite; missing: string[] }>>("/api/sites", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      name: input.name,
      priority: input.priority ?? "medium",
      photoCount: input.photoCount ?? 0,
      tags: input.tags ?? [],
      state: { importing: {} },
    }),
  });
  return { id: body.data.site.id };
}

export async function patchSite(
  siteId: string,
  patch: {
    name?: string;
    priority?: SitePriority;
    photoCount?: number;
    tags?: string[];
    state?: UploadedState;
  }
): Promise<DashboardSite> {
  const payload: Record<string, unknown> = { ...patch };
  if (patch.state) {
    payload.state =
      patch.state.kind === "failed"
        ? { failed: { _0: patch.state.message } }
        : { [patch.state.kind]: {} };
  }
  const body = await request<Envelope<RemoteSite>>(`/api/sites/${siteId}`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  return toDashboardSite(body.data);
}

export async function deleteSite(siteId: string): Promise<void> {
  await request<void>(`/api/sites/${siteId}`, { method: "DELETE" });
}

/** The manifest is served verbatim, so it decodes straight into AnalysisSequence. */
export async function getAnalysis(siteId: string): Promise<AnalysisSequence> {
  return request<AnalysisSequence>(`/api/sites/${siteId}/analysis`);
}
