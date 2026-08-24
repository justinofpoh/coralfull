export type UploadedStateKind =
  | "importing"
  | "processing"
  | "ready"
  | "failed"
  | "cancelled"
  | "interrupted";

export type UploadedState =
  | { kind: Exclude<UploadedStateKind, "failed"> }
  | { kind: "failed"; message: string };

export type UploadedSite = {
  id: string;
  name: string;
  createdAt: string;
  state: UploadedState;
  photoCount: number;
  sourcePhotoDirectory?: string | null;
  metashapeProjectPath?: string | null;
  meshPlyPath?: string | null;
  meshTexturePath?: string | null;
  analysisManifestPath?: string | null;
};

export type PipelineStage = {
  id: string;
  title: string;
  state: "pending" | "running" | "done" | "failed" | string;
  detail?: string | null;
  percent?: number | null;
};

export type PipelineStatus = {
  state: "running" | "ready" | "failed" | "cancelled" | string;
  error?: string | null;
  updatedAt?: string | null;
  stages: PipelineStage[];
};

export type AnalysisFrame = {
  label: string;
  cameraId: number;
  capturedAt?: string | null;
  rgb: string;
  semantic: string;
  depth: string;
  healthyPercent: number;
  unhealthyPercent: number;
  depthValidPercent: number;
  depthRelativeMin?: number;
  depthRelativeMax?: number;
};

export type AnalysisSequence = {
  site: string;
  siteId?: string;
  generatedAt?: string;
  semanticModel: string;
  depthProducer: string;
  scale: { calibrated: boolean; note: string };
  frames: AnalysisFrame[];
  mesh?: {
    ply?: string | null;
    texture?: string | null;
    vertexLabels?: string | null;
    vertices?: number | null;
    faces?: number | null;
    textureSize?: number | null;
  } | null;
  metashape?: {
    version?: string | null;
    createdAt?: string | null;
    finishedAt?: string | null;
    photoCount?: number | null;
    alignedCameras?: number | null;
    imageResolution?: number[] | null;
    project?: string | null;
  } | null;
  labels3d?: {
    counts: Record<string, number>;
    minVotes?: number | null;
    labeledVertexPercent?: number | null;
  } | null;
};

export type SitePriority = "high" | "medium" | "low";

export type DashboardSite = {
  id: string;
  name: string;
  photoCount: number;
  priority: SitePriority;
  coverUrl: string | null;
  /**
   * Every site now comes from the backend and is an analysis package. The old
   * "splat", "placeholder" and "uploaded" kinds described where the data lived,
   * which is no longer a distinction the UI has to make.
   */
  kind: "analysis";
  uploadedState?: UploadedState | null;
  /** Live stage progress, polled locally while the pipeline is running. */
  status?: PipelineStatus | null;
  tags?: string[];
  /** False until a manifest has been published, i.e. nothing to open yet. */
  hasAnalysis?: boolean;
};
