"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { CreateSiteSetup, ProcessingSheet } from "@/components/CreateSiteModal";
import SiteAnalysisView from "@/components/SiteAnalysisView";
import {
  collectImageFiles,
  readCandidate,
  type ImportCandidate,
} from "@/lib/import-photos";
import { createSite, deleteSite, getAnalysis, listSites } from "@/lib/api";
import { type DashboardSite, type PipelineStatus } from "@/lib/types";

type SortOrder = "priority" | "name" | "photos";

/** Local stage progress for scans still being built on this machine. */
type LocalStatus = { id: string; status: PipelineStatus | null };

export default function Dashboard() {
  const [sites, setSites] = useState<DashboardSite[]>([]);
  const [issues, setIssues] = useState<string[]>([]);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [sortOrder, setSortOrder] = useState<SortOrder>("priority");
  const [healthOpen, setHealthOpen] = useState(true);
  const [scan, setScan] = useState<DashboardSite | null>(null);
  const [phase, setPhase] = useState<"idle" | "setup" | "processing">("idle");
  const [processingId, setProcessingId] = useState<string | null>(null);
  const [candidates, setCandidates] = useState<ImportCandidate[]>([]);
  const [skipped, setSkipped] = useState(0);
  const [reading, setReading] = useState(false);
  const [siteName, setSiteName] = useState("");
  const [importError, setImportError] = useState<string | null>(null);
  const filesRef = useRef<HTMLInputElement>(null);
  const folderRef = useRef<HTMLInputElement>(null);

  const refresh = useCallback(async () => {
    try {
      const remote = await listSites();
      setLoadError(null);

      // Only sites still being built need their stages polled, and that data
      // only exists on the machine running the pipeline.
      const pending = remote.filter(
        (site) => site.uploadedState && site.uploadedState.kind !== "ready"
      );
      const statuses = await Promise.all(
        pending.map(async (site): Promise<LocalStatus> => {
          try {
            const response = await fetch(`/api/sites/${site.id}/status`);
            if (!response.ok) return { id: site.id, status: null };
            const body = (await response.json()) as { status?: PipelineStatus | null };
            return { id: site.id, status: body.status ?? null };
          } catch {
            return { id: site.id, status: null };
          }
        })
      );
      const byId = new Map(statuses.map((entry) => [entry.id, entry.status]));
      setSites(remote.map((site) => ({ ...site, status: byId.get(site.id) ?? null })));
    } catch (error) {
      setLoadError(error instanceof Error ? error.message : "Could not load sites.");
    }
  }, []);

  // Pipeline prerequisites (Metashape, the segmentation venv) are a property of
  // this machine, not the backend.
  useEffect(() => {
    void fetch("/api/env")
      .then((response) => (response.ok ? response.json() : null))
      .then((body: { issues?: string[] } | null) => setIssues(body?.issues ?? []))
      .catch(() => setIssues([]));
  }, []);

  useEffect(() => {
    const initialRefresh = window.setTimeout(() => void refresh(), 0);
    const timer = window.setInterval(() => void refresh(), 1200);
    return () => {
      window.clearTimeout(initialRefresh);
      window.clearInterval(timer);
    };
  }, [refresh]);

  useEffect(() => {
    folderRef.current?.setAttribute("webkitdirectory", "");
    folderRef.current?.setAttribute("directory", "");
  }, []);

  const allSites: DashboardSite[] = sites;

  const filtered = useMemo(() => {
    const matches = allSites.filter(
      (site) => !search || site.name.toLowerCase().includes(search.toLowerCase())
    );
    if (sortOrder === "name") return [...matches].sort((a, b) => a.name.localeCompare(b.name));
    if (sortOrder === "photos") return [...matches].sort((a, b) => b.photoCount - a.photoCount);
    const rank = { high: 0, medium: 1, low: 2 };
    return [...matches].sort((a, b) => rank[a.priority] - rank[b.priority]);
  }, [allSites, search, sortOrder]);

  const selected =
    allSites.find((site) => site.id === selectedId) ?? allSites[0] ?? null;
  const processingSite: DashboardSite | null = processingId
    ? allSites.find((site) => site.id === processingId) ?? null
    : null;

  const openScan = (site = selected) => {
    // A site with no published manifest has nothing to render yet.
    if (!site || !site.hasAnalysis) return;
    setScan(site);
  };

  const beginImport = async (fileList: FileList | null) => {
    if (!fileList || fileList.length === 0) return;
    const { images, skipped: skippedCount } = collectImageFiles(fileList);
    setSkipped(skippedCount);
    setReading(true);
    setPhase("setup");
    const folderName = images[0]?.webkitRelativePath?.split("/")[0];
    setSiteName(
      folderName
        ? folderName.replace(/[_-]/g, " ").replace(/\b\w/g, (char) => char.toUpperCase())
        : "New Survey Site"
    );
    const next = await Promise.all(images.map(readCandidate));
    setCandidates(next);
    setReading(false);
  };

  const startProcessing = async () => {
    try {
      const { id: siteId } = await createSite({
        name: siteName,
        photoCount: candidates.length,
      });
      const created = await fetch("/api/sites", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: siteId, name: siteName }),
      });
      if (!created.ok) {
        const body = (await created.json().catch(() => ({}))) as { error?: string };
        throw new Error(body.error || "Could not create local site storage.");
      }
      const batchSize = 4;
      for (let i = 0; i < candidates.length; i += batchSize) {
        const form = new FormData();
        for (const candidate of candidates.slice(i, i + batchSize)) {
          form.append("photos", candidate.file, candidate.file.name);
        }
        const uploadedBatch = await fetch(`/api/sites/${siteId}/photos`, {
          method: "POST",
          body: form,
        });
        if (!uploadedBatch.ok) throw new Error("Could not copy photos into app storage.");
      }
      await fetch(`/api/sites/${siteId}/process`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "{}",
      });
      candidates.forEach((candidate) => URL.revokeObjectURL(candidate.thumbnailUrl));
      setCandidates([]);
      setProcessingId(siteId);
      setSelectedId(siteId);
      setPhase("processing");
      await refresh();
    } catch (error) {
      setImportError(error instanceof Error ? error.message : "Could not import photos.");
      setPhase("idle");
    }
  };

  /**
   * Removes a scan from both halves of the system.
   *
   * The backend goes first: if it fails, the local directory is left alone and
   * the site simply stays listed, which is recoverable. The reverse ordering
   * would delete the photos and leave an unopenable row behind.
   */
  const removeSite = useCallback(
    async (siteId: string) => {
      try {
        await deleteSite(siteId);
      } catch (error) {
        setLoadError(error instanceof Error ? error.message : "Could not delete site.");
        return;
      }
      await fetch(`/api/sites/${siteId}`, { method: "DELETE" }).catch(() => {});
      if (selectedId === siteId) setSelectedId(null);
      await refresh();
    },
    [refresh, selectedId]
  );

  const [health, setHealth] = useState<{
    healthyPercent: number;
    unhealthyPercent: number;
    labelled: number;
  } | null>(null);

  useEffect(() => {
    if (!selected?.hasAnalysis) {
      setHealth(null);
      return;
    }
    let cancelled = false;
    void getAnalysis(selected.id)
      .then((sequence) => {
        const counts = sequence.labels3d?.counts;
        const healthy = counts?.healthy ?? 0;
        const unhealthy = counts?.unhealthy ?? 0;
        const total = healthy + unhealthy;
        if (cancelled) return;
        setHealth(
          total > 0
            ? {
                healthyPercent: (healthy / total) * 100,
                unhealthyPercent: (unhealthy / total) * 100,
                labelled: total,
              }
            : null
        );
      })
      .catch(() => {
        if (!cancelled) setHealth(null);
      });
    return () => {
      cancelled = true;
    };
  }, [selected?.id, selected?.hasAnalysis]);

  const closeSheet = () => {
    candidates.forEach((candidate) => URL.revokeObjectURL(candidate.thumbnailUrl));
    setCandidates([]);
    setPhase("idle");
    setProcessingId(null);
  };

  if (scan) {
    return (
      <SiteAnalysisView
        siteId={scan.id}
        siteName={scan.name}
        onClose={() => setScan(null)}
      />
    );
  }

  return (
    <div className="desktop">
      <aside className="sidebar">
        <h1>CoralFull</h1>
        <p className="sidebar-kicker">Workspace</p>
        <button type="button" className={!scan ? "nav on" : "nav"}>
          Dashboard
        </button>
        <button type="button" className="nav" onClick={() => openScan()}>
          3D View
        </button>
        <button type="button" className="nav" disabled>
          Map
        </button>
      </aside>

      <main className="content">
        {loadError ? (
          <div className="load-error" role="alert">
            {loadError}
          </div>
        ) : null}
        <div className="toolbar">
          <input
            className="search"
            placeholder="Search sites"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
          <button type="button" className="toolbar-btn" onClick={() => filesRef.current?.click()}>
            + Create site
          </button>
          <select value={sortOrder} onChange={(event) => setSortOrder(event.target.value as SortOrder)}>
            <option value="priority">Priority</option>
            <option value="name">Name</option>
            <option value="photos">Photos</option>
          </select>
          <button type="button" className="toolbar-btn" onClick={() => setHealthOpen((value) => !value)}>
            i
          </button>
        </div>

        <div className="content-scroll">
          <h2>Dashboard</h2>
          <div className="info-card">
            <h3>Coral Health Information</h3>
            <p>Information about the coral health will only be available after uploading photos / videos.</p>
            <p>Click on each of the site to get an overview of the coral’s health at each of the sites.</p>
          </div>
          <div className="sites-head">
            <h3>Sites</h3>
            <button type="button" className="primary" onClick={() => filesRef.current?.click()}>
              + Create site from photos
            </button>
          </div>
          <div className="site-grid">
            {filtered.map((site) => (
              <button
                key={site.id}
                type="button"
                className={site.id === selected.id ? "site-card selected" : "site-card"}
                onClick={() => setSelectedId(site.id)}
              >
                <div className="cover">
                  {site.coverUrl ? (
                    <img src={site.coverUrl} alt="" />
                  ) : (
                    <div className="cover-fallback">
                      {site.uploadedState?.kind === "processing" ? (
                        <>
                          <div className="spinner" />
                          <span>{site.status?.stages.find((stage) => stage.state === "running")?.title ?? "Processing"}</span>
                        </>
                      ) : (
                        <span>Preview appears after processing</span>
                      )}
                    </div>
                  )}
                </div>
                <strong>{site.name}</strong>
                <div className="badges">
                  <span className="badge">{site.photoCount} photos</span>
                  {site.uploadedState ? (
                    <StateBadge state={site.uploadedState.kind} status={site.status} />
                  ) : (
                    <span className={`badge priority ${site.priority}`}>
                      {site.priority === "medium" ? "Med" : site.priority[0]!.toUpperCase() + site.priority.slice(1)}
                    </span>
                  )}
                </div>
              </button>
            ))}
          </div>
        </div>
      </main>

      <aside className="inspector">
        <h2>Site</h2>
        {!selected ? (
          <p className="inspector-empty">
            No sites yet. Use &ldquo;Create site&rdquo; to import photos, or publish one with
            <code> tools/publish_site.py</code>.
          </p>
        ) : (
        <>
        <div className="inspector-cover">
          {selected.coverUrl ? <img src={selected.coverUrl} alt="" /> : <div className="cover-fallback" />}
          {selected.hasAnalysis ? (
            <button type="button" className="open-3d" onClick={() => openScan(selected)}>
              Open 3D analysis
            </button>
          ) : (
            <span className="soon">
              {selected.uploadedState?.kind === "failed" ? "Failed" : "Processing"}
            </span>
          )}
        </div>
        <h3>{selected.name}</h3>
        {selected.uploadedState?.kind === "processing" || selected.uploadedState?.kind === "importing" ? (
          <div className="inspector-status">
            <p>{selected.status?.stages.find((stage) => stage.state === "running")?.title ?? "Processing…"}</p>
            <button type="button" onClick={() => { setProcessingId(selected.id); setPhase("processing"); }}>
              View progress
            </button>
          </div>
        ) : null}
        {selected.uploadedState?.kind === "failed" ? (
          <div className="inspector-status fail">
            <strong>Processing failed</strong>
            <p>{selected.uploadedState.message}</p>
            <div className="row">
              <button type="button" onClick={() => void fetch(`/api/sites/${selected.id}/process`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ retry: true }) })}>
                Retry
              </button>
              <button type="button" onClick={() => { setProcessingId(selected.id); setPhase("processing"); }}>
                Details
              </button>
              <button type="button" className="danger" onClick={() => void removeSite(selected.id)}>
                Delete site
              </button>
            </div>
          </div>
        ) : null}
        {(selected.uploadedState?.kind === "cancelled" || selected.uploadedState?.kind === "interrupted") && (
          <div className="inspector-status">
            <strong>
              {selected.uploadedState.kind === "cancelled"
                ? "Processing was cancelled"
                : "Processing was interrupted"}
            </strong>
            <div className="row">
              <button type="button" onClick={() => void fetch(`/api/sites/${selected.id}/process`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ retry: true }) })}>
                Resume processing
              </button>
              <button type="button" className="danger" onClick={() => void removeSite(selected.id)}>
                Delete site
              </button>
            </div>
          </div>
        )}
        </>
        )}
        <div className="health-block">
          <button type="button" className="health-toggle" onClick={() => setHealthOpen((value) => !value)}>
            Coral Health {healthOpen ? "▾" : "▸"}
          </button>
          {healthOpen ? (
            health ? (
              <ul className="legend">
                <li>
                  <i style={{ background: "#00c800" }} /> Healthy{" "}
                  {health.healthyPercent.toFixed(1)}%
                </li>
                <li>
                  <i style={{ background: "#dc1e1e" }} /> Unhealthy{" "}
                  {health.unhealthyPercent.toFixed(1)}%
                </li>
                <li className="legend-note">
                  {health.labelled.toLocaleString()} labelled vertices
                </li>
              </ul>
            ) : (
              <p className="legend-note">
                {selected?.hasAnalysis ? "No 3D labels in this scan." : "No analysis yet."}
              </p>
            )
          ) : null}
        </div>
      </aside>

      <input
        ref={filesRef}
        type="file"
        hidden
        multiple
        accept="image/jpeg,image/png,.jpg,.jpeg,.png"
        onChange={(event) => {
          void beginImport(event.target.files);
          event.target.value = "";
        }}
      />
      <input
        ref={folderRef}
        type="file"
        hidden
        multiple
        onChange={(event) => {
          void beginImport(event.target.files);
          event.target.value = "";
        }}
      />

      {phase !== "idle" && (
        <div className="modal-backdrop" role="dialog" aria-modal="true">
          <div className="modal">
            {phase === "setup" ? (
              <>
                <div className="picker-row">
                  <button type="button" onClick={() => filesRef.current?.click()}>
                    Choose photos
                  </button>
                  <button type="button" onClick={() => folderRef.current?.click()}>
                    Choose folder
                  </button>
                </div>
                <CreateSiteSetup
                  siteName={siteName}
                  onSiteNameChange={setSiteName}
                  candidates={candidates}
                  onRemove={(id) => setCandidates((current) => current.filter((item) => item.id !== id))}
                  skippedCount={skipped}
                  reading={reading}
                  issues={issues}
                  onCancel={closeSheet}
                  onStart={() => void startProcessing()}
                />
              </>
            ) : processingSite ? (
              <ProcessingSheet
                site={{
                  name: processingSite.name,
                  state: processingSite.uploadedState ?? { kind: "importing" },
                }}
                status={processingSite.status ?? null}
                onOpenAnalysis={() => {
                  const site = allSites.find((item) => item.id === processingSite.id);
                  closeSheet();
                  if (site) openScan(site);
                }}
                onDismiss={closeSheet}
                onCancel={() => void fetch(`/api/sites/${processingSite.id}/cancel`, { method: "POST" })}
                onRetry={() =>
                  void fetch(`/api/sites/${processingSite.id}/process`, {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ retry: true }),
                  })
                }
                onDelete={() =>
                  void removeSite(processingSite.id).then(closeSheet)
                }
              />
            ) : (
              <div className="sheet">
                <div className="sheet-reading">
                  <div className="spinner" />
                  <p>Starting processing…</p>
                  <button type="button" onClick={closeSheet}>
                    Close
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      )}

      {importError ? (
        <div className="modal-backdrop">
          <div className="alert">
            <h2>Could not import photos</h2>
            <p>{importError}</p>
            <button type="button" className="primary" onClick={() => setImportError(null)}>
              OK
            </button>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function StateBadge({
  state,
  status,
}: {
  state: string;
  status?: PipelineStatus | null;
}) {
  const percent = status?.stages.find((stage) => stage.state === "running")?.percent;
  const label =
    state === "processing" && percent != null
      ? `Processing ${Math.round(percent)}%`
      : state === "ready"
        ? "Ready"
        : state === "failed"
          ? "Failed"
          : state === "cancelled"
            ? "Cancelled"
            : state === "interrupted"
              ? "Interrupted"
              : state === "importing"
                ? "Importing"
                : "Processing";
  return <span className={`badge state ${state}`}>{label}</span>;
}
