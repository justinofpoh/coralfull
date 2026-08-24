"use client";

import { useMemo } from "react";
import type { ImportCandidate } from "@/lib/import-photos";
import type { PipelineStatus, UploadedSite } from "@/lib/types";

type CreateSiteModalProps = {
  siteName: string;
  onSiteNameChange: (value: string) => void;
  candidates: ImportCandidate[];
  onRemove: (id: string) => void;
  skippedCount: number;
  reading: boolean;
  issues: string[];
  onCancel: () => void;
  onStart: () => void;
};

export function CreateSiteSetup({
  siteName,
  onSiteNameChange,
  candidates,
  onRemove,
  skippedCount,
  reading,
  issues,
  onCancel,
  onStart,
}: CreateSiteModalProps) {
  const dominantResolution = useMemo(() => {
    const resolutions = candidates
      .filter((item) => item.pixelWidth && item.pixelHeight)
      .map((item) => `${item.pixelWidth}×${item.pixelHeight}`);
    if (resolutions.length === 0) return null;
    const counts = new Map<string, number>();
    for (const value of resolutions) counts.set(value, (counts.get(value) ?? 0) + 1);
    return [...counts.entries()].sort((a, b) => b[1] - a[1])[0][0];
  }, [candidates]);

  const captureRange = useMemo(() => {
    const dates = candidates
      .map((item) => item.capturedAt)
      .filter((value): value is Date => Boolean(value))
      .sort((a, b) => a.getTime() - b.getTime());
    if (dates.length === 0) return null;
    const first = dates[0];
    const last = dates[dates.length - 1];
    const sameDay = first.toDateString() === last.toDateString();
    if (sameDay) {
      return `${first.toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })} – ${last.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })}`;
    }
    return `${first.toLocaleDateString()} – ${last.toLocaleDateString()}`;
  }, [candidates]);

  const cameraSummary = useMemo(() => {
    const models = new Set(candidates.map((item) => item.cameraModel).filter(Boolean));
    if (models.size === 0) return null;
    if (models.size === 1) return [...models][0]!;
    return `${models.size} camera models`;
  }, [candidates]);

  const messages: { text: string; blocking: boolean }[] = [];
  if (candidates.length < 3) {
    messages.push({
      text: `At least 3 overlapping photos are required for reconstruction; ${candidates.length} selected.`,
      blocking: true,
    });
  }
  if (dominantResolution) {
    const odd = candidates.filter(
      (item) => item.pixelWidth && `${item.pixelWidth}×${item.pixelHeight}` !== dominantResolution
    ).length;
    if (odd > 0) {
      messages.push({
        text: `${odd} photo${odd === 1 ? "" : "s"} differ from the dominant resolution (${dominantResolution}). Mixed sizes can weaken alignment.`,
        blocking: false,
      });
    }
  }
  const unreadable = candidates.filter((item) => !item.pixelWidth).length;
  if (unreadable > 0) {
    messages.push({
      text: `${unreadable} photo${unreadable === 1 ? "" : "s"} could not be read and will likely fail processing. Consider removing them.`,
      blocking: false,
    });
  }
  if (!siteName.trim()) messages.push({ text: "Enter a site name.", blocking: true });
  for (const issue of issues) messages.push({ text: issue, blocking: true });

  const canStart = !reading && !messages.some((item) => item.blocking);

  if (reading) {
    return (
      <div className="sheet">
        <div className="sheet-reading">
          <div className="spinner" />
          <h2>Reading photo metadata…</h2>
          <p>Checking resolution, capture times, and camera details.</p>
        </div>
      </div>
    );
  }

  return (
    <div className="sheet">
      <header className="sheet-head">
        <h2>Create site from photos</h2>
        <p>Photos are copied into app-managed storage; the original folder is not needed afterwards.</p>
      </header>
      <div className="sheet-body">
        <label className="field">
          <span>Site name</span>
          <input
            value={siteName}
            onChange={(event) => onSiteNameChange(event.target.value)}
            placeholder="e.g. North Bommie transect"
          />
        </label>
        <div className="summary-tiles">
          <SummaryTile title="Photos" value={String(candidates.length)} />
          <SummaryTile title="Resolution" value={dominantResolution ?? "—"} />
          <SummaryTile title="Capture range" value={captureRange ?? "No EXIF times"} />
          <SummaryTile title="Camera" value={cameraSummary ?? "Unknown"} />
        </div>
        {(messages.length > 0 || skippedCount > 0) && (
          <div className="validation">
            {skippedCount > 0 ? (
              <p className="info">
                {skippedCount} unsupported file{skippedCount === 1 ? "" : "s"} were skipped (JPG, JPEG, and PNG are supported).
              </p>
            ) : null}
            {messages.map((message) => (
              <p key={message.text} className={message.blocking ? "blocking" : "warn"}>
                {message.text}
              </p>
            ))}
          </div>
        )}
        <div>
          <h3>Photos ({candidates.length})</h3>
          <p className="hint">Remove blurred or off-transect photos before processing.</p>
          <div className="photo-grid">
            {candidates.map((candidate) => (
              <div key={candidate.id} className="photo-cell">
                <div className="photo-thumb">
                  {candidate.thumbnailUrl ? <img src={candidate.thumbnailUrl} alt="" /> : null}
                  <button type="button" onClick={() => onRemove(candidate.id)} aria-label={`Remove ${candidate.fileName}`}>
                    ×
                  </button>
                </div>
                <span>{candidate.fileName}</span>
                <small>
                  {candidate.pixelWidth && candidate.pixelHeight
                    ? `${candidate.pixelWidth}×${candidate.pixelHeight}`
                    : "—"}
                </small>
              </div>
            ))}
          </div>
        </div>
      </div>
      <footer className="sheet-foot">
        <button type="button" onClick={onCancel}>
          Cancel
        </button>
        <button type="button" className="primary" disabled={!canStart} onClick={onStart}>
          Start processing
        </button>
      </footer>
    </div>
  );
}

function SummaryTile({ title, value }: { title: string; value: string }) {
  return (
    <div className="summary-tile">
      <span>{title}</span>
      <strong>{value}</strong>
    </div>
  );
}

type ProcessingProps = {
  /**
   * Only the name and state are read here. Narrowing the prop keeps this sheet
   * independent of where a site record comes from, now that the backend serves
   * the list and the local pipeline only supplies stage progress.
   */
  site: Pick<UploadedSite, "name" | "state">;
  status: PipelineStatus | null;
  onOpenAnalysis: () => void;
  onDismiss: () => void;
  onCancel: () => void;
  onRetry: () => void;
  onDelete: () => void;
};

export function ProcessingSheet({
  site,
  status,
  onOpenAnalysis,
  onDismiss,
  onCancel,
  onRetry,
  onDelete,
}: ProcessingProps) {
  const subtitle = {
    importing: "Copying photos into app storage…",
    processing: "Reconstruction and analysis are running. You can keep using the app.",
    ready: "Ready for inspection.",
    failed: "Processing failed.",
    cancelled: "Processing was cancelled.",
    interrupted: "Processing was interrupted.",
  }[site.state.kind];

  const stages =
    status?.stages ??
    [
      {
        id: "import",
        title: "Importing photos",
        state: site.state.kind === "importing" ? "running" : "pending",
        detail: "Copying into app-managed storage",
        percent: null,
      },
    ];

  return (
    <div className="sheet">
      <header className="sheet-head">
        <h2>{site.name}</h2>
        <p>{subtitle}</p>
      </header>
      <div className="sheet-body">
        {stages.map((stage) => (
          <div key={stage.id} className={`stage ${stage.state}`}>
            <span className="stage-icon">
              {stage.state === "done" ? "✓" : stage.state === "running" ? "…" : stage.state === "failed" ? "✕" : "○"}
            </span>
            <div>
              <strong>
                {stage.title}
                {stage.state === "running" && stage.percent != null ? ` ${Math.round(stage.percent)}%` : ""}
              </strong>
              {stage.detail ? <p>{stage.detail}</p> : null}
              {stage.state === "running" && stage.percent != null ? (
                <progress value={stage.percent} max={100} />
              ) : null}
            </div>
          </div>
        ))}
        {site.state.kind === "failed" ? (
          <div className="failure">
            <strong>What went wrong</strong>
            <p>{site.state.message}</p>
          </div>
        ) : null}
      </div>
      <footer className="sheet-foot">
        {site.state.kind === "importing" || site.state.kind === "processing" ? (
          <>
            <button type="button" className="danger" onClick={onCancel}>
              Cancel processing
            </button>
            <button type="button" onClick={onDismiss}>
              Continue in background
            </button>
          </>
        ) : site.state.kind === "ready" ? (
          <>
            <button type="button" onClick={onDismiss}>
              Close
            </button>
            <button type="button" className="primary" onClick={onOpenAnalysis}>
              Open 3D analysis
            </button>
          </>
        ) : (
          <>
            <button type="button" className="danger" onClick={onDelete}>
              Delete site
            </button>
            <button type="button" onClick={onDismiss}>
              Close
            </button>
            <button type="button" className="primary" onClick={onRetry}>
              Retry
            </button>
          </>
        )}
      </footer>
    </div>
  );
}
