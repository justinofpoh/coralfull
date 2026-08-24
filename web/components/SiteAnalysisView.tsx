"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import MeshViewer from "@/components/MeshViewer";
import type { AnalysisSequence } from "@/lib/types";

type SiteAnalysisViewProps = {
  siteId: string;
  siteName: string;
  onClose: () => void;
};

function fileUrl(siteId: string, relative?: string | null) {
  if (!relative) return null;
  return `/api/sites/${siteId}/files/${relative.split("/").map(encodeURIComponent).join("/")}`;
}

function shortNumber(label: string) {
  return label.split("_").pop() ?? label;
}

function formatWhen(value?: string | null) {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

export default function SiteAnalysisView({
  siteId,
  siteName,
  onClose,
}: SiteAnalysisViewProps) {
  const [sequence, setSequence] = useState<AnalysisSequence | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [index, setIndex] = useState(0);
  const [displayMode, setDisplayMode] = useState<"texture" | "wireframe">("texture");
  const [depthSource, setDepthSource] = useState<"camera" | "viewport">("camera");
  const [showHealthy, setShowHealthy] = useState(false);
  const [showUnhealthy, setShowUnhealthy] = useState(false);
  const [playing, setPlaying] = useState(false);
  const [metadataOpen, setMetadataOpen] = useState(false);
  const [viewportDepth, setViewportDepth] = useState<string | null>(null);
  const [meshInfo, setMeshInfo] = useState<{
    vertexCount: number;
    faceCount: number;
    labelCounts: { healthy: number; unhealthy: number };
    hasLabels: boolean;
  } | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetch(`/api/sites/${siteId}/analysis`)
      .then(async (response) => {
        if (!response.ok) {
          const body = (await response.json().catch(() => ({}))) as { error?: string };
          throw new Error(body.error || "No analysis package found.");
        }
        return response.json() as Promise<AnalysisSequence>;
      })
      .then((data) => {
        if (!cancelled) setSequence(data);
      })
      .catch((caught: Error) => {
        if (!cancelled) setError(caught.message);
      });
    return () => {
      cancelled = true;
    };
  }, [siteId]);

  const frames = sequence?.frames ?? [];
  const frame = frames[index];

  useEffect(() => {
    if (!playing || frames.length === 0) return;
    const timer = window.setInterval(() => {
      setIndex((current) => (current + 1) % frames.length);
    }, 800);
    return () => window.clearInterval(timer);
  }, [playing, frames.length]);

  const plyUrl = fileUrl(siteId, sequence?.mesh?.ply);
  const textureUrl = fileUrl(siteId, sequence?.mesh?.texture);
  const labelsUrl = fileUrl(siteId, sequence?.mesh?.vertexLabels);
  const calibrated = sequence?.scale.calibrated ?? false;
  const healthyCount = sequence?.labels3d?.counts.healthy ?? meshInfo?.labelCounts.healthy;
  const unhealthyCount = sequence?.labels3d?.counts.unhealthy ?? meshInfo?.labelCounts.unhealthy;

  const onMeshInfo = useCallback(
    (info: {
      vertexCount: number;
      faceCount: number;
      labelCounts: { healthy: number; unhealthy: number };
      hasLabels: boolean;
    }) => setMeshInfo(info),
    []
  );

  const metadataRows = useMemo(() => {
    if (!sequence) return [];
    const rows: [string, string][] = [];
    if (sequence.metashape?.version) rows.push(["Metashape", sequence.metashape.version]);
    if (sequence.metashape?.createdAt) {
      rows.push(["Reconstructed", formatWhen(sequence.metashape.createdAt) ?? sequence.metashape.createdAt]);
    }
    if (sequence.metashape?.photoCount) {
      const aligned = sequence.metashape.alignedCameras;
      rows.push([
        "Photos",
        aligned ? `${sequence.metashape.photoCount} (${aligned} aligned)` : String(sequence.metashape.photoCount),
      ]);
    }
    if (sequence.metashape?.imageResolution?.length === 2) {
      rows.push([
        "Source resolution",
        `${sequence.metashape.imageResolution[0]}×${sequence.metashape.imageResolution[1]}`,
      ]);
    }
    const vertices = sequence.mesh?.vertices ?? meshInfo?.vertexCount;
    const faces = sequence.mesh?.faces ?? meshInfo?.faceCount;
    if (vertices) rows.push(["Mesh vertices", vertices.toLocaleString()]);
    if (faces) rows.push(["Mesh faces", faces.toLocaleString()]);
    if (sequence.mesh?.textureSize) {
      rows.push(["Texture", `${sequence.mesh.textureSize}×${sequence.mesh.textureSize}`]);
    }
    if (sequence.semanticModel) rows.push(["Semantic model", sequence.semanticModel]);
    rows.push(["Scale", calibrated ? "Calibrated" : "Not calibrated"]);
    if (sequence.generatedAt) {
      rows.push(["Analysis generated", formatWhen(sequence.generatedAt) ?? sequence.generatedAt]);
    }
    return rows;
  }, [sequence, meshInfo, calibrated]);

  return (
    <div className="analysis-shell">
      <header className="analysis-header">
        <button type="button" className="ghost-button" onClick={onClose}>
          ← Back
        </button>
        <div>
          <h1>{siteName}</h1>
          <p>Metashape reconstruction · CoralScapes segmentation</p>
        </div>
      </header>

      <div className="analysis-body">
        <div className="analysis-main">
          <section className="analysis-panel reconstruction">
            <div className="panel-heading">
              <div>
                <h2>3D reconstruction</h2>
                <p>
                  {siteName}
                  {(sequence?.mesh?.vertices ?? meshInfo?.vertexCount)
                    ? ` · ${(sequence?.mesh?.vertices ?? meshInfo?.vertexCount)?.toLocaleString()} vertices`
                    : ""}
                  {(sequence?.mesh?.faces ?? meshInfo?.faceCount)
                    ? ` · ${(sequence?.mesh?.faces ?? meshInfo?.faceCount)?.toLocaleString()} faces`
                    : ""}
                  {" · Agisoft Metashape"}
                </p>
              </div>
              <div className="segmented">
                <button
                  type="button"
                  className={displayMode === "texture" ? "on" : ""}
                  onClick={() => setDisplayMode("texture")}
                >
                  Colour
                </button>
                <button
                  type="button"
                  className={displayMode === "wireframe" ? "on" : ""}
                  onClick={() => setDisplayMode("wireframe")}
                >
                  Wireframe
                </button>
              </div>
            </div>

            <div className="mesh-stage">
              {plyUrl ? (
                <MeshViewer
                  plyUrl={plyUrl}
                  textureUrl={textureUrl}
                  labelsUrl={labelsUrl}
                  displayMode={displayMode}
                  showHealthy={showHealthy}
                  showUnhealthy={showUnhealthy}
                  captureViewportDepth={depthSource === "viewport"}
                  onMeshInfo={onMeshInfo}
                  onViewportDepth={setViewportDepth}
                />
              ) : (
                <div className="mesh-empty">3D mesh unavailable</div>
              )}
              <div className="orbit-hint">
                <span>Drag to orbit</span>
                <span>Scroll to zoom</span>
                {depthSource === "viewport" ? <span>Orbit updates the 3D-view depth card</span> : null}
              </div>
              {(meshInfo?.hasLabels || sequence?.labels3d) && (
                <div className="health-filters">
                  <p>3D HEALTH LABELS</p>
                  <div>
                    <HealthChip
                      title="Healthy"
                      count={healthyCount}
                      color="#00c800"
                      on={showHealthy}
                      onToggle={() => setShowHealthy((value) => !value)}
                    />
                    <HealthChip
                      title="Unhealthy"
                      count={unhealthyCount}
                      color="#dc1e1e"
                      on={showUnhealthy}
                      onToggle={() => setShowUnhealthy((value) => !value)}
                    />
                  </div>
                </div>
              )}
            </div>

            <div className="mesh-metrics">
              <Metric title="Source" value="Agisoft PLY" />
              <Metric
                title="Scale"
                value={calibrated ? "Calibrated" : "Not calibrated · relative units"}
              />
              <Metric title="Depth" value={calibrated ? "Scale-calibrated" : "Relative units"} />
            </div>
          </section>

          <section className="analysis-panel timeline">
            <div className="panel-heading">
              <div>
                <h3>Capture timeline</h3>
                <p>
                  {frame
                    ? `${frame.label} · ${formatWhen(frame.capturedAt) ?? "no capture time"} · camera ${frame.cameraId}`
                    : "Waiting for analysis frames…"}
                </p>
              </div>
              <div className="timeline-controls">
                <button type="button" disabled={index <= 0} onClick={() => { setPlaying(false); setIndex((value) => Math.max(0, value - 1)); }}>
                  ‹
                </button>
                <button type="button" onClick={() => setPlaying((value) => !value)}>
                  {playing ? "Pause" : "Play"}
                </button>
                <button type="button" disabled={index >= frames.length - 1} onClick={() => { setPlaying(false); setIndex((value) => Math.min(frames.length - 1, value + 1)); }}>
                  ›
                </button>
              </div>
            </div>
            {frames.length === 0 ? (
              <p className="timeline-empty">The frame strip appears once analysis artifacts are available.</p>
            ) : (
              <>
                <div className="thumb-strip">
                  {frames.map((item, itemIndex) => (
                    <button
                      key={item.label}
                      type="button"
                      className={itemIndex === index ? "selected" : ""}
                      onClick={() => {
                        setPlaying(false);
                        setIndex(itemIndex);
                      }}
                    >
                      <img src={fileUrl(siteId, item.rgb) ?? ""} alt="" />
                      <span>{shortNumber(item.label)}</span>
                    </button>
                  ))}
                </div>
                <input
                  type="range"
                  min={0}
                  max={Math.max(frames.length - 1, 0)}
                  value={index}
                  onChange={(event) => {
                    setPlaying(false);
                    setIndex(Number(event.target.value));
                  }}
                />
                <div className="timeline-meta">
                  <span>{frames[0]?.label}</span>
                  <span>
                    {index + 1} of {frames.length} frames
                  </span>
                  <span>{frames.at(-1)?.label}</span>
                </div>
              </>
            )}
          </section>
        </div>

        <aside className="analysis-rail">
          <div>
            <h2>Analysis</h2>
            <p>{frame ? `Frame ${shortNumber(frame.label)} · processed outputs` : "Processed survey outputs"}</p>
          </div>

          {error ? (
            <div className="unavailable">
              <strong>Artifacts unavailable</strong>
              <p>{error}</p>
            </div>
          ) : !sequence ? (
            <div className="loading-card">Loading analysis artifacts…</div>
          ) : frame ? (
            <>
              <PreviewCard
                title="RGB input"
                subtitle={
                  frame.capturedAt
                    ? `${frame.label} · ${formatWhen(frame.capturedAt)}`
                    : frame.label
                }
                src={fileUrl(siteId, frame.rgb)}
              />
              <PreviewCard
                title="Semantic segmentation"
                subtitle={`CoralScapes · ${frame.healthyPercent.toFixed(1)}% healthy${
                  frame.unhealthyPercent >= 0.1
                    ? ` · ${frame.unhealthyPercent.toFixed(1)}% unhealthy`
                    : ""
                }`}
                src={fileUrl(siteId, frame.semantic)}
              />
              <div className="preview-card">
                <div className="preview-image">
                  {depthSource === "camera" ? (
                    <img src={fileUrl(siteId, frame.depth) ?? ""} alt="" />
                  ) : viewportDepth ? (
                    <img src={viewportDepth} alt="" />
                  ) : (
                    <span>Orbit the mesh to render 3D-view depth</span>
                  )}
                  <em>{calibrated ? "CALIBRATED" : "RELATIVE"}</em>
                </div>
                <div className="depth-head">
                  <strong>Depth</strong>
                  <div className="segmented small">
                    <button type="button" className={depthSource === "camera" ? "on" : ""} onClick={() => setDepthSource("camera")}>
                      Camera
                    </button>
                    <button type="button" className={depthSource === "viewport" ? "on" : ""} onClick={() => setDepthSource("viewport")}>
                      3D view
                    </button>
                  </div>
                </div>
                <p>
                  {depthSource === "camera"
                    ? `Metashape dense depth · camera ${frame.cameraId} · ${frame.depthValidPercent.toFixed(0)}% coverage · ${calibrated ? "scale-calibrated" : "relative units"}`
                    : `Rendered from the current 3D viewport · orbit or zoom to update · ${calibrated ? "scale-calibrated" : "relative units"}`}
                </p>
              </div>
            </>
          ) : null}

          <div className="metadata-card">
            <button type="button" onClick={() => setMetadataOpen((value) => !value)}>
              Reconstruction metadata {metadataOpen ? "▾" : "▸"}
            </button>
            {metadataOpen && (
              <dl>
                {metadataRows.map(([label, value]) => (
                  <div key={label}>
                    <dt>{label}</dt>
                    <dd>{value}</dd>
                  </div>
                ))}
              </dl>
            )}
          </div>

          <div className="provenance">
            <strong>Analysis provenance</strong>
            <p>
              Measured outputs for {frames.length} survey frames: {sequence?.semanticModel ?? "EPFL CoralScapes"} class
              masks and Metashape dense depth per camera.{" "}
              {sequence?.scale.note ??
                "Depths stay relative until a scale constraint is applied in Metashape."}
            </p>
          </div>
        </aside>
      </div>
    </div>
  );
}
function Metric({ title, value }: { title: string; value: string }) {
  return (
    <div className="metric">
      <span>{title}</span>
      <strong>{value}</strong>
    </div>
  );
}

function PreviewCard({
  title,
  subtitle,
  src,
}: {
  title: string;
  subtitle: string;
  src: string | null;
}) {
  return (
    <div className="preview-card">
      <div className="preview-image">{src ? <img src={src} alt="" /> : null}</div>
      <strong>{title}</strong>
      <p>{subtitle}</p>
    </div>
  );
}

function HealthChip({
  title,
  count,
  color,
  on,
  onToggle,
}: {
  title: string;
  count?: number;
  color: string;
  on: boolean;
  onToggle: () => void;
}) {
  const empty = count === 0;
  return (
    <button
      type="button"
      className={`health-chip ${on ? "on" : ""}`}
      style={{ ["--chip" as string]: color }}
      disabled={empty}
      onClick={onToggle}
      title={
        empty
          ? `${title} coral: zero detections in the lifted 3D labels`
          : `Highlight ${title.toLowerCase()} coral vertices on the mesh`
      }
    >
      <i style={{ background: color }} />
      {empty ? `${title} · none detected` : title}
      {count && count > 0 ? <span>{count.toLocaleString()}</span> : null}
    </button>
  );
}
