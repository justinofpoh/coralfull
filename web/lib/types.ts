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
  kind: "splat" | "analysis" | "placeholder" | "uploaded";
  uploadedState?: UploadedState | null;
  status?: PipelineStatus | null;
};

export const BUILT_IN_SITES: DashboardSite[] = [
  {
    id: "site-a",
    name: "Main Reef Structure",
    photoCount: 129,
    priority: "high",
    coverUrl: "/covers/site-a.jpeg",
    kind: "splat",
  },
  {
    id: "site-b",
    name: "Site B",
    photoCount: 26,
    priority: "medium",
    coverUrl: "/covers/site-b.png",
    kind: "analysis",
  },
  {
    id: "site-c",
    name: "Site C",
    photoCount: 40,
    priority: "low",
    coverUrl: "/covers/site-c.png",
    kind: "placeholder",
  },
];
