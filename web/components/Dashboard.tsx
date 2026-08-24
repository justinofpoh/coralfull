"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { CreateSiteSetup, ProcessingSheet } from "@/components/CreateSiteModal";
import ReefViewer from "@/components/ReefViewer";
import SiteAnalysisView from "@/components/SiteAnalysisView";
import {
  collectImageFiles,
  readCandidate,
  type ImportCandidate,
} from "@/lib/import-photos";
import {
  BUILT_IN_SITES,
  type DashboardSite,
  type PipelineStatus,
  type SitePriority,
  type UploadedSite,
} from "@/lib/types";

type SortOrder = "priority" | "name" | "photos";

type ListedSite = UploadedSite & {
  status?: PipelineStatus | null;
  coverUrl?: string | null;
};

export default function Dashboard() {
  const [uploaded, setUploaded] = useState<ListedSite[]>([]);
  const [issues, setIssues] = useState<string[]>([]);
  const [selectedId, setSelectedId] = useState("site-a");
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
    const response = await fetch("/api/sites");
    if (!response.ok) return;
    const body = (await response.json()) as {
      sites: ListedSite[];
      environment: { issues: string[] };
    };
    setUploaded(body.sites);
    setIssues(body.environment.issues);
  }, []);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), 1200);
    return () => window.clearInterval(timer);
  }, [refresh]);

  useEffect(() => {
    folderRef.current?.setAttribute("webkitdirectory", "");
    folderRef.current?.setAttribute("directory", "");
  }, []);

  const allSites: DashboardSite[] = useMemo(() => {
    const extras = uploaded.map((site) => ({
      id: site.id,
      name: site.name,
      photoCount: site.photoCount,
      priority: "medium" as SitePriority,
      coverUrl: site.state.kind === "ready" ? `/api/sites/${site.id}/cover` : null,
      kind: "uploaded" as const,
      uploadedState: site.state,
      status: site.status ?? null,
    }));
    return [...BUILT_IN_SITES, ...extras];
  }, [uploaded]);

  const filtered = useMemo(() => {
    const matches = allSites.filter(
      (site) => !search || site.name.toLowerCase().includes(search.toLowerCase())
    );
    if (sortOrder === "name") return [...matches].sort((a, b) => a.name.localeCompare(b.name));
    if (sortOrder === "photos") return [...matches].sort((a, b) => b.photoCount - a.photoCount);
    const rank = { high: 0, medium: 1, low: 2 };
    return [...matches].sort((a, b) => rank[a.priority] - rank[b.priority]);
  }, [allSites, search, sortOrder]);

  const selected = allSites.find((site) => site.id === selectedId) ?? allSites[0];
  const processingSite = uploaded.find((site) => site.id === processingId) ?? null;

  const openScan = (site = selected) => {
    if (site.kind === "placeholder") return;
    if (site.kind === "uploaded" && site.uploadedState?.kind !== "ready") return;
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
      const created = await fetch("/api/sites", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: siteName }),
      });
      const createdBody = (await created.json()) as { site?: UploadedSite; error?: string };
      if (!created.ok || !createdBody.site) throw new Error(createdBody.error || "Could not create site.");
      const siteId = createdBody.site.id;
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

  const closeSheet = () => {
    candidates.forEach((candidate) => URL.revokeObjectURL(candidate.thumbnailUrl));
    setCandidates([]);
    setPhase("idle");
    setProcessingId(null);
  };

  if (scan?.kind === "splat") {
    return <ReefViewer onClose={() => setScan(null)} siteName={scan.name} />;
  }
  if (scan?.kind === "analysis" || (scan?.kind === "uploaded" && scan.uploadedState?.kind === "ready")) {
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
        <div className="inspector-cover">
          {selected.coverUrl ? <img src={selected.coverUrl} alt="" /> : <div className="cover-fallback" />}
          {selected.kind === "splat" || selected.kind === "analysis" || selected.uploadedState?.kind === "ready" ? (
            <button type="button" className="open-3d" onClick={() => openScan(selected)}>
              {selected.kind === "splat" ? "Open 3D scan" : "Open 3D analysis"}
            </button>
          ) : (
            <span className="soon">
              {selected.uploadedState ? "Processing" : "3D coming soon"}
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
              <button type="button" className="danger" onClick={() => void fetch(`/api/sites/${selected.id}`, { method: "DELETE" }).then(refresh)}>
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
              <button type="button" className="danger" onClick={() => void fetch(`/api/sites/${selected.id}`, { method: "DELETE" }).then(refresh)}>
                Delete site
              </button>
            </div>
          </div>
        )}
        <div className="health-block">
          <button type="button" className="health-toggle" onClick={() => setHealthOpen((value) => !value)}>
            Coral Health {healthOpen ? "▾" : "▸"}
          </button>
          {healthOpen ? (
            <ul className="legend">
              <li><i style={{ background: "#c7a0fa" }} /> Healthy 10</li>
              <li><i style={{ background: "#94c2f7" }} /> Disease 20</li>
              <li><i style={{ background: "#94ccc9" }} /> Dead 30</li>
              <li><i style={{ background: "#c8c8c8" }} /> Others 40</li>
            </ul>
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
                site={processingSite}
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
                  void fetch(`/api/sites/${processingSite.id}`, { method: "DELETE" }).then(() => {
                    closeSheet();
                    setSelectedId("site-a");
                    return refresh();
                  })
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
