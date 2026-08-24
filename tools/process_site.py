#!/usr/bin/env python3
"""End-to-end processing pipeline for an uploaded coral survey site.

The macOS app copies the user's photos into an app-managed site directory and
launches this orchestrator. Everything the app later displays is produced
here, from real tools only: Agisoft Metashape Pro (reconstruction, depth,
mesh, texture) and the CoralScapes segmentation model (health classes).

Site directory layout (created under the app's Application Support folder):

  <site>/photos/                     imported source photos (copied by the app)
  <site>/project/site.psx (+ .files) Metashape project
  <site>/mesh/mesh.ply               textured binary PLY (chunk-internal frame)
  <site>/mesh/mesh.jpg               texture page
  <site>/mesh/metashape_result.json  bridge output: cameras, calibration, stats
  <site>/analysis/frames/            per-frame rgb/semantic/mask/depth/meta
  <site>/analysis/vertex_labels.bin  uint8 per PLY vertex: 0 other, 1 healthy, 2 unhealthy
  <site>/analysis/site_sequence.json the manifest the app loads (format below)
  <site>/cover.jpg                   dashboard cover image
  <site>/status.json                 staged progress the app polls (format below)

Manifest format (analysis/site_sequence.json), version 2:

  {
    "version": 2,
    "site": <display name>, "siteId": <stable id>,
    "generatedAt": iso8601,
    "semanticModel": <hugging face model id>,
    "depthProducer": "Agisoft Metashape dense depth map",
    "scale": {"calibrated": false, "note": ...},
    "classes": {"0": "other/background", "1": "healthy coral", "2": "unhealthy coral"},
    "mesh": {"ply": relpath, "texture": relpath, "vertexLabels": relpath,
              "vertices": int, "faces": int, "textureSize": int},
    "metashape": {"version": str, "createdAt": iso, "finishedAt": iso,
                   "photoCount": int, "alignedCameras": int,
                   "imageResolution": [w, h], "project": path,
                   "timingsSeconds": {...}},
    "labels3d": {"counts": {"other": n, "healthy": n, "unhealthy": n},
                  "minVotes": int, "labeledVertexPercent": float},
    "frames": [ per-frame entries, see process_frame(); all asset paths are
                relative to the manifest's directory ]
  }

Status format (status.json): {"state": "running|ready|failed|cancelled",
"error": str|null, "stages": [{"id", "title", "state", "detail", "percent"}]}.
Percentages are only reported when a real measure exists (Metashape task
progress, frames completed); stages without one just show running/done.

Usage:
  tools/reef_segment/.venv/bin/python tools/process_site.py \
      --site-dir "<app support>/coralfull/sites/<uuid>" \
      --site-id <uuid> --site-name "North Bommie"
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parents[1]
for extra in (REPO / "tools", REPO / "tools" / "reef_segment"):
    if str(extra) not in sys.path:
        sys.path.insert(0, str(extra))

from site_b_live_analysis import (  # noqa: E402
    CLASS_COLORS,
    CLASS_NAMES,
    atomic_image,
    atomic_json,
    capture_timestamp,
    depth_visualisation,
    display_frame,
)

try:
    import OpenEXR
except ImportError as error:  # pragma: no cover
    raise SystemExit("Install OpenEXR in the pipeline venv: pip install OpenEXR") from error

METASHAPE_APP = Path("/Applications/MetashapePro.app/Contents/MacOS/MetashapePro")
SUPPORTED_SUFFIXES = {".jpg", ".jpeg", ".png"}
MANIFEST_NAME = "site_sequence.json"

OTHER, HEALTHY, UNHEALTHY = 0, 1, 2

STAGES = [
    ("import", "Importing photos"),
    ("validate", "Validating photos & metadata"),
    ("align", "Building Metashape project & aligning photos"),
    ("depth", "Building dense depth maps"),
    ("mesh", "Building textured 3D mesh"),
    ("segment", "Running CoralScapes segmentation"),
    ("lift", "Preparing 3D health labels"),
    ("finalize", "Packaging analysis"),
    ("publish", "Publishing to the backend"),
]
RUNNER_PHASE_TO_STAGE = {
    "starting": "align",
    "add_photos": "align",
    "match": "align",
    "align": "align",
    "depth_maps": "depth",
    "model": "mesh",
    "vertex_colors": "mesh",
    "uv": "mesh",
    "texture": "mesh",
    "export": "mesh",
    "finished": "mesh",
}
RUNNER_PHASE_DETAIL = {
    "add_photos": "Adding photos to the project",
    "match": "Matching features across photos",
    "align": "Aligning cameras",
    "depth_maps": "Computing dense depth per camera",
    "model": "Building mesh from depth maps",
    "vertex_colors": "Colorizing mesh vertices",
    "uv": "Unwrapping texture coordinates",
    "texture": "Blending photo texture",
    "export": "Exporting textured PLY",
}


class Status:
    """Owns status.json; every mutation is written atomically."""

    def __init__(self, site_dir: Path, site_id: str, site_name: str):
        self.path = site_dir / "status.json"
        self.site_id = site_id
        self.site_name = site_name
        self.state = "running"
        self.error: str | None = None
        self.stages = [
            {"id": stage_id, "title": title, "state": "pending", "detail": None, "percent": None}
            for stage_id, title in STAGES
        ]

    def stage(self, stage_id: str) -> dict:
        return next(stage for stage in self.stages if stage["id"] == stage_id)

    def update(
        self,
        stage_id: str,
        state: str | None = None,
        detail: str | None = None,
        percent: float | None = None,
    ) -> None:
        stage = self.stage(stage_id)
        if state:
            stage["state"] = state
        if detail is not None:
            stage["detail"] = detail
        stage["percent"] = None if percent is None else round(float(percent), 1)
        self.write()

    def fail(self, stage_id: str, message: str) -> None:
        self.update(stage_id, state="failed", detail=message)
        self.state = "failed"
        self.error = message
        self.write()

    def finish(self) -> None:
        self.state = "ready"
        self.write()

    def cancel(self) -> None:
        self.state = "cancelled"
        for stage in self.stages:
            if stage["state"] == "running":
                stage["state"] = "pending"
        self.write()

    def write(self) -> None:
        atomic_json(
            {
                "version": 1,
                "siteId": self.site_id,
                "siteName": self.site_name,
                "state": self.state,
                "error": self.error,
                "updatedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
                "stages": self.stages,
            },
            self.path,
        )


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--site-dir", type=Path, required=True)
    parser.add_argument("--site-id", required=True)
    parser.add_argument("--site-name", required=True)
    parser.add_argument("--device", default=None, help="torch device for segmentation")
    parser.add_argument("--display-width", type=int, default=1280)
    parser.add_argument("--texture-size", type=int, default=4096)
    parser.add_argument("--match-downscale", type=int, default=1)
    parser.add_argument("--depth-downscale", type=int, default=4)
    parser.add_argument("--min-votes", type=int, default=2)
    parser.add_argument("--force", action="store_true", help="Redo completed stages")
    parser.add_argument(
        "--api",
        default=os.environ.get("CORALFULL_API", "http://localhost:8321"),
        help="backend base URL; the finished site is uploaded here",
    )
    parser.add_argument(
        "--no-publish",
        action="store_true",
        help="leave the finished site on this machine only",
    )
    return parser.parse_args()


def natural_key(name: str) -> list:
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", name)]


def site_photos(photos_dir: Path) -> list[Path]:
    if not photos_dir.is_dir():
        return []
    return sorted(
        (path for path in photos_dir.iterdir() if path.suffix.lower() in SUPPORTED_SUFFIXES),
        key=lambda path: natural_key(path.name),
    )


# ---------------------------------------------------------------- validation


def validate(photos: list[Path], status: Status) -> tuple[int, int]:
    status.update("validate", state="running")
    if len(photos) < 3:
        raise PipelineError("validate", f"Need at least 3 photos, found {len(photos)}.")
    sizes: dict[tuple[int, int], int] = {}
    for path in photos:
        try:
            with Image.open(path) as image:
                sizes[image.size] = sizes.get(image.size, 0) + 1
        except Exception as error:
            raise PipelineError("validate", f"Unreadable image {path.name}: {error}") from error
    dominant = max(sizes, key=sizes.get)
    if len(sizes) > 1:
        odd = sum(count for size, count in sizes.items() if size != dominant)
        status.update(
            "validate",
            detail=f"{len(photos)} photos; {odd} differ from the dominant {dominant[0]}×{dominant[1]}",
        )
    status.update(
        "validate",
        state="done",
        detail=f"{len(photos)} photos · {dominant[0]}×{dominant[1]}",
    )
    return dominant


class PipelineError(Exception):
    def __init__(self, stage_id: str, message: str):
        super().__init__(message)
        self.stage_id = stage_id
        self.message = message


# ---------------------------------------------------------------- metashape


class MetashapeRun:
    def __init__(self, site_dir: Path, args: argparse.Namespace):
        self.project = site_dir / "project" / "site.psx"
        self.mesh_dir = site_dir / "mesh"
        self.progress_path = self.mesh_dir / "metashape_progress.json"
        self.result_path = self.mesh_dir / "metashape_result.json"
        self.args = args
        self.process: subprocess.Popen | None = None

    def result(self) -> dict | None:
        try:
            return json.loads(self.result_path.read_text())
        except (OSError, json.JSONDecodeError):
            return None

    def completed(self) -> bool:
        result = self.result()
        return bool(
            result
            and result.get("ok")
            and Path(result.get("meshPly", "")).exists()
            and Path(result.get("meshTexture", "")).exists()
        )

    def run(self, photos_dir: Path, status: Status) -> dict:
        if not METASHAPE_APP.exists():
            raise PipelineError(
                "align",
                "Agisoft Metashape Pro is not installed at /Applications/MetashapePro.app. "
                "Install and activate it, then retry processing.",
            )
        self.result_path.unlink(missing_ok=True)
        self.progress_path.unlink(missing_ok=True)
        if self.project.exists():
            self.project.unlink()
        files_dir = self.project.with_suffix(".files")
        if files_dir.exists():
            shutil.rmtree(files_dir)

        command = [
            str(METASHAPE_APP),
            "-r",
            str(REPO / "tools" / "metashape_build.py"),
            "--",
            "--project", str(self.project),
            "--photos", str(photos_dir),
            "--mesh-dir", str(self.mesh_dir),
            "--progress", str(self.progress_path),
            "--result", str(self.result_path),
            "--match-downscale", str(self.args.match_downscale),
            "--depth-downscale", str(self.args.depth_downscale),
            "--texture-size", str(self.args.texture_size),
        ]
        log_path = self.mesh_dir / "metashape.log"
        self.mesh_dir.mkdir(parents=True, exist_ok=True)
        with open(log_path, "w") as log:
            self.process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            active_stage = "align"
            while self.process.poll() is None:
                time.sleep(1.0)
                active_stage = self.mirror_progress(status, active_stage)
        self.process = None

        result = self.result()
        if not result:
            raise PipelineError(
                active_stage,
                f"Metashape exited without a result. See log: {log_path}",
            )
        if not result.get("ok"):
            raise PipelineError(active_stage, f"Metashape failed: {result.get('error')}")
        for stage_id in ("align", "depth", "mesh"):
            status.update(stage_id, state="done", percent=None)
        return result

    def mirror_progress(self, status: Status, active_stage: str) -> str:
        try:
            progress = json.loads(self.progress_path.read_text())
        except (OSError, json.JSONDecodeError):
            return active_stage
        phase = progress.get("phase", "starting")
        stage_id = RUNNER_PHASE_TO_STAGE.get(phase, active_stage)
        if stage_id != active_stage:
            for done_id in ("align", "depth", "mesh"):
                if done_id == stage_id:
                    break
                if status.stage(done_id)["state"] == "running":
                    status.update(done_id, state="done", percent=None)
        status.update(
            stage_id,
            state="running",
            detail=RUNNER_PHASE_DETAIL.get(phase),
            percent=progress.get("percent"),
        )
        return stage_id

    def terminate(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()


# ---------------------------------------------------------- depth extraction


class DepthArchive:
    """Locates d<cameraKey>.exr dense depth maps inside a saved .psx project."""

    def __init__(self, project: Path):
        self.members: dict[int, tuple[Path, str]] = {}
        files_dir = project.with_suffix(".files")
        pattern = re.compile(r"(?:^|/)d(\d+)\.exr$")
        for archive_path in sorted(files_dir.rglob("*.zip")):
            if "depth_maps" not in str(archive_path.parent):
                continue
            try:
                with zipfile.ZipFile(archive_path) as archive:
                    names = archive.namelist()
            except zipfile.BadZipFile:
                continue
            for name in names:
                match = pattern.search(name)
                if match:
                    self.members.setdefault(int(match.group(1)), (archive_path, name))

    def read(self, camera_key: int) -> np.ndarray:
        if camera_key not in self.members:
            raise PipelineError(
                "segment", f"No dense depth map for camera key {camera_key} in the project."
            )
        archive_path, member = self.members[camera_key]
        with zipfile.ZipFile(archive_path) as archive:
            payload = archive.read(member)
        with tempfile.NamedTemporaryFile(suffix=".exr") as temporary:
            temporary.write(payload)
            temporary.flush()
            exr = OpenEXR.File(temporary.name)
            return exr.parts[0].channels["Z"].pixels.astype(np.float32)


# ------------------------------------------------------------------- frames


def frame_paths(analysis_dir: Path, label: str) -> dict[str, Path]:
    frames = analysis_dir / "frames"
    return {
        "rgb": frames / f"{label}_rgb.jpg",
        "semantic": frames / f"{label}_semantic.jpg",
        "mask": frames / f"{label}_mask.png",
        "depth": frames / f"{label}_depth.png",
        "meta": frames / f"{label}_meta.json",
    }


def frame_complete(paths: dict[str, Path]) -> bool:
    return all(path.exists() for path in paths.values())


def process_frame(
    label: str,
    camera_key: int,
    image_path: Path,
    depth_archive: DepthArchive,
    analysis_dir: Path,
    segmenter,
    display_width: int,
) -> dict:
    paths = frame_paths(analysis_dir, label)

    rgb = display_frame(image_path, display_width)
    atomic_image(rgb, paths["rgb"], quality=92)

    mask, _probabilities = segmenter.predict(paths["rgb"])
    atomic_image(Image.fromarray(mask, mode="L"), paths["mask"])

    rgb_array = np.asarray(rgb, dtype=np.float32)
    colors = CLASS_COLORS[np.minimum(mask, len(CLASS_COLORS) - 1)]
    overlay = (rgb_array * 0.34 + colors.astype(np.float32) * 0.66).clip(0, 255).astype(np.uint8)
    atomic_image(Image.fromarray(overlay, "RGB"), paths["semantic"], quality=90)

    depth = depth_archive.read(camera_key)
    depth_image, valid_pixels, lower, upper = depth_visualisation(depth, rgb.size)
    atomic_image(depth_image, paths["depth"])

    total = int(mask.size)
    counts = {str(index): int((mask == index).sum()) for index in range(3)}
    entry = {
        "label": label,
        "cameraId": camera_key,
        "capturedAt": capture_timestamp(image_path),
        "sourceImage": str(image_path),
        "rgb": f"frames/{paths['rgb'].name}",
        "semantic": f"frames/{paths['semantic'].name}",
        "mask": f"frames/{paths['mask'].name}",
        "depth": f"frames/{paths['depth'].name}",
        "pixels": counts,
        "healthyPercent": round(100 * counts["1"] / total, 2),
        "unhealthyPercent": round(100 * counts["2"] / total, 2),
        "depthResolution": list(depth.shape[::-1]),
        "depthValidPixels": valid_pixels,
        "depthValidPercent": round(100 * valid_pixels / depth.size, 2),
        "depthRelativeMin": lower,
        "depthRelativeMax": upper,
        "depthUnits": "relative (unscaled reconstruction)",
    }
    atomic_json(entry, paths["meta"])
    return entry


# ------------------------------------------------------------------ 3D lift


def read_ply_vertices(path: Path) -> tuple[np.ndarray, int, int]:
    """Read vertex positions from a binary little-endian PLY (any layout)."""
    with open(path, "rb") as handle:
        if handle.readline().strip() != b"ply":
            raise PipelineError("lift", f"{path.name} is not a PLY file")
        type_sizes = {
            "char": "i1", "uchar": "u1", "short": "i2", "ushort": "u2",
            "int": "i4", "uint": "u4", "float": "f4", "double": "f8",
            "int8": "i1", "uint8": "u1", "int16": "i2", "uint16": "u2",
            "int32": "i4", "uint32": "u4", "float32": "f4", "float64": "f8",
        }
        elements: list[tuple[str, int, list[tuple[str, str] | None]]] = []
        fmt = None
        while True:
            line = handle.readline().decode("ascii").strip()
            if line == "end_header":
                break
            parts = line.split()
            if parts[0] == "format":
                fmt = parts[1]
            elif parts[0] == "element":
                elements.append((parts[1], int(parts[2]), []))
            elif parts[0] == "property":
                if parts[1] == "list":
                    elements[-1][2].append(None)
                else:
                    elements[-1][2].append((parts[2], type_sizes[parts[1]]))
        if fmt != "binary_little_endian":
            raise PipelineError("lift", f"Unsupported PLY format {fmt}")

        vertices = None
        vertex_count = 0
        face_count = 0
        for name, count, properties in elements:
            if name == "vertex":
                if any(prop is None for prop in properties):
                    raise PipelineError("lift", "List property in vertex element")
                dtype = np.dtype([(prop_name, "<" + kind) for prop_name, kind in properties])
                data = np.frombuffer(handle.read(dtype.itemsize * count), dtype=dtype)
                vertices = np.stack(
                    [data["x"], data["y"], data["z"]], axis=1
                ).astype(np.float64)
                vertex_count = count
            elif name == "face":
                face_count = count
                break  # faces are not needed for the lift
        if vertices is None:
            raise PipelineError("lift", "PLY has no vertex element")
        return vertices, vertex_count, face_count


def internal_mesh_vertices(site_dir: Path, result: dict, exported: np.ndarray) -> np.ndarray:
    """Mesh vertices in the chunk-internal frame (matching camera transforms).

    The PLY export is written in Metashape's "Local Coordinates" frame, which
    for an unreferenced chunk does not match the internal frame the cameras
    and dense depth use. The bridge dumps internal-frame vertices in export
    order; verify that order with a rigid (Kabsch) fit against the exported
    vertices before trusting the correspondence.
    """
    path = Path(result.get("internalVertices") or site_dir / "mesh" / "internal_vertices.bin")
    if not path.exists():
        raise PipelineError(
            "lift",
            "The reconstruction predates the internal-vertex export; rerun processing with --force.",
        )
    internal = np.fromfile(path, dtype=np.float32).reshape(-1, 3).astype(np.float64)
    if len(internal) != len(exported):
        raise PipelineError(
            "lift",
            f"Vertex count mismatch: PLY has {len(exported)}, internal dump has {len(internal)}.",
        )
    centered_internal = internal - internal.mean(axis=0)
    centered_exported = exported - exported.mean(axis=0)
    correlation = centered_internal.T @ centered_exported
    u, _s, vt = np.linalg.svd(correlation)
    rotation = vt.T @ u.T
    if np.linalg.det(rotation) < 0:
        vt[-1] *= -1
        rotation = vt.T @ u.T
    residual = np.sqrt(np.mean(np.sum((centered_internal @ rotation.T - centered_exported) ** 2, axis=1)))
    diagonal = float(np.linalg.norm(exported.max(axis=0) - exported.min(axis=0)))
    if residual > 0.001 * max(diagonal, 1e-9):
        raise PipelineError(
            "lift",
            "Exported PLY vertices do not correspond to the internal vertex dump "
            f"(rigid-fit residual {residual:.4f}); cannot map 3D labels onto the mesh.",
        )
    return internal


def project_metashape(
    points: np.ndarray, camera: dict, sensor: dict
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Project chunk-frame points through a calibrated Metashape camera.

    Returns pixel coordinates, camera-space depth, and an in-front mask.
    """
    transform = np.array(camera["transform"], dtype=np.float64)
    world_to_camera = np.linalg.inv(transform)
    local = points @ world_to_camera[:3, :3].T + world_to_camera[:3, 3]
    z = local[:, 2]
    in_front = z > 1e-6
    x = np.where(in_front, local[:, 0] / np.where(in_front, z, 1.0), 0.0)
    y = np.where(in_front, local[:, 1] / np.where(in_front, z, 1.0), 0.0)

    k1, k2, k3 = sensor["k1"], sensor["k2"], sensor["k3"]
    p1, p2 = sensor["p1"], sensor["p2"]
    r2 = x * x + y * y
    radial = 1.0 + r2 * (k1 + r2 * (k2 + r2 * k3))
    x_distorted = x * radial + p1 * (r2 + 2 * x * x) + 2 * p2 * x * y
    y_distorted = y * radial + p2 * (r2 + 2 * y * y) + 2 * p1 * x * y

    width, height, focal = sensor["width"], sensor["height"], sensor["f"]
    u = width * 0.5 + sensor["cx"] + x_distorted * focal
    v = height * 0.5 + sensor["cy"] + y_distorted * focal
    return np.stack([u, v], axis=1), z, in_front


def lift_labels(
    vertices: np.ndarray,
    result: dict,
    labels_by_camera: dict[int, np.ndarray],
    depth_archive: DepthArchive,
    min_votes: int,
    on_progress,
) -> np.ndarray:
    from lift import expand_health_labels, reduce_votes  # reef_segment

    sensors = {sensor["key"]: sensor for sensor in result["sensors"]}
    votes = np.zeros((len(vertices), 3), dtype=np.uint16)
    usable = [
        camera
        for camera in result["cameras"]
        if camera["aligned"] and camera["key"] in labels_by_camera
    ]
    for index, camera in enumerate(usable, start=1):
        sensor = sensors[camera["sensorKey"]]
        mask = labels_by_camera[camera["key"]]
        depth = depth_archive.read(camera["key"])

        uv, z, in_front = project_metashape(vertices, camera, sensor)
        width, height = sensor["width"], sensor["height"]
        inside = (
            in_front
            & (uv[:, 0] >= 0) & (uv[:, 0] < width)
            & (uv[:, 1] >= 0) & (uv[:, 1] < height)
        )
        candidates = np.nonzero(inside)[0]
        if not len(candidates):
            continue

        depth_h, depth_w = depth.shape
        du = np.clip((uv[candidates, 0] * depth_w / width).astype(np.int32), 0, depth_w - 1)
        dv = np.clip((uv[candidates, 1] * depth_h / height).astype(np.int32), 0, depth_h - 1)
        surface = depth[dv, du]
        visible = (
            np.isfinite(surface)
            & (surface > 0)
            & (np.abs(z[candidates] - surface) <= np.maximum(0.05 * surface, 1e-4))
        )
        candidates = candidates[visible]
        if not len(candidates):
            continue

        mask_h, mask_w = mask.shape
        mu = np.clip((uv[candidates, 0] * mask_w / width).astype(np.int32), 0, mask_w - 1)
        mv = np.clip((uv[candidates, 1] * mask_h / height).astype(np.int32), 0, mask_h - 1)
        classes = np.clip(mask[mv, mu].astype(np.int32), 0, 2)
        votes[candidates, classes] += 1
        on_progress(index, len(usable))

    labels = reduce_votes(votes, min_votes)
    diagonal = float(np.linalg.norm(vertices.max(axis=0) - vertices.min(axis=0)))
    labels = expand_health_labels(vertices, labels, radius=0.002 * diagonal, iterations=1)
    return labels


# ----------------------------------------------------------------- manifest


def write_manifest(
    site_dir: Path,
    site_id: str,
    site_name: str,
    model_id: str | None,
    result: dict,
    label_counts: dict[str, int] | None,
    min_votes: int,
) -> dict:
    analysis_dir = site_dir / "analysis"
    entries = []
    for meta_path in sorted((analysis_dir / "frames").glob("*_meta.json")):
        try:
            entry = json.loads(meta_path.read_text())
        except json.JSONDecodeError:
            continue
        if frame_complete(frame_paths(analysis_dir, entry["label"])):
            entries.append(entry)
    entries.sort(key=lambda item: natural_key(item["label"]))

    manifest: dict = {
        "version": 2,
        "site": site_name,
        "siteId": site_id,
        "generatedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "semanticModel": model_id or "EPFL-ECEO CoralScapes",
        "depthProducer": "Agisoft Metashape dense depth map",
        "scale": {
            "calibrated": bool(result.get("scaleCalibrated")),
            "note": (
                "Reconstruction is unscaled; depths are relative until a "
                "scale-bar constraint is applied in Metashape."
            ),
        },
        "classes": CLASS_NAMES,
        "mesh": {
            "ply": "../mesh/mesh.ply",
            "texture": "../mesh/mesh.jpg",
            "vertexLabels": "vertex_labels.bin" if label_counts else None,
            "vertices": result.get("vertices"),
            "faces": result.get("faces"),
            "textureSize": result.get("textureSize"),
        },
        "metashape": {
            "version": result.get("metashapeVersion"),
            "createdAt": result.get("createdAt"),
            "finishedAt": result.get("finishedAt"),
            "photoCount": result.get("photoCount"),
            "alignedCameras": result.get("alignedCameras"),
            "imageResolution": result.get("imageResolution"),
            "project": result.get("project"),
            "timingsSeconds": result.get("timingsSeconds"),
        },
        "frames": entries,
    }
    if label_counts:
        total = sum(label_counts.values()) or 1
        manifest["labels3d"] = {
            "counts": label_counts,
            "minVotes": min_votes,
            "labeledVertexPercent": round(
                100 * (label_counts["healthy"] + label_counts["unhealthy"]) / total, 2
            ),
        }
    atomic_json(manifest, analysis_dir / MANIFEST_NAME)
    return manifest


# --------------------------------------------------------------------- main


def main() -> None:
    args = arguments()
    site_dir = args.site_dir.resolve()
    photos_dir = site_dir / "photos"
    analysis_dir = site_dir / "analysis"
    status = Status(site_dir, args.site_id, args.site_name)

    metashape = MetashapeRun(site_dir, args)

    def handle_terminate(signum, frame):  # noqa: ARG001
        metashape.terminate()
        status.cancel()
        sys.exit(130)

    signal.signal(signal.SIGTERM, handle_terminate)
    signal.signal(signal.SIGINT, handle_terminate)

    try:
        photos = site_photos(photos_dir)
        status.update("import", state="done", detail=f"{len(photos)} photos in app storage")
        validate(photos, status)

        if metashape.completed() and not args.force:
            for stage_id in ("align", "depth", "mesh"):
                status.update(stage_id, state="done", detail="Reused existing reconstruction")
            result = metashape.result()
        else:
            result = metashape.run(photos_dir, status)

        cameras_by_label = {
            camera["label"]: camera for camera in result["cameras"] if camera["aligned"]
        }
        photo_by_label = {path.stem: path for path in photos}
        labels = [label for label in photo_by_label if label in cameras_by_label]
        labels.sort(key=natural_key)
        skipped = sorted(set(photo_by_label) - set(labels), key=natural_key)
        if not labels:
            raise PipelineError("segment", "No photos correspond to aligned cameras.")

        depth_archive = DepthArchive(metashape.project)

        pending = [
            label
            for label in labels
            if args.force or not frame_complete(frame_paths(analysis_dir, label))
        ]
        status.update(
            "segment",
            state="running",
            detail=f"{len(labels)} frames"
            + (f" · {len(skipped)} photos not aligned, skipped" if skipped else ""),
            percent=0.0 if pending else None,
        )
        segmenter = None
        model_id = None
        if pending:
            from segment import HealthSegmenter  # deferred: heavy torch import

            segmenter = HealthSegmenter(device=args.device)
            model_id = segmenter.model_id
        for index, label in enumerate(pending, start=1):
            camera = cameras_by_label[label]
            process_frame(
                label,
                camera["key"],
                photo_by_label[label],
                depth_archive,
                analysis_dir,
                segmenter,
                args.display_width,
            )
            write_manifest(
                site_dir, args.site_id, args.site_name, model_id, result, None, args.min_votes
            )
            status.update(
                "segment",
                state="running",
                detail=f"Frame {index} of {len(pending)}",
                percent=100 * index / len(pending),
            )
        status.update("segment", state="done", detail=f"{len(labels)} frames segmented", percent=None)

        status.update("lift", state="running")
        exported_vertices, vertex_count, _faces = read_ply_vertices(site_dir / "mesh" / "mesh.ply")
        vertices = internal_mesh_vertices(site_dir, result, exported_vertices)
        labels_path = analysis_dir / "vertex_labels.bin"
        if labels_path.exists() and labels_path.stat().st_size == vertex_count and not args.force:
            vertex_labels = np.frombuffer(labels_path.read_bytes(), dtype=np.uint8)
        else:
            masks = {}
            for label in labels:
                mask_path = frame_paths(analysis_dir, label)["mask"]
                masks[cameras_by_label[label]["key"]] = np.array(Image.open(mask_path))
            vertex_labels = lift_labels(
                vertices,
                result,
                masks,
                depth_archive,
                args.min_votes,
                lambda done, total: status.update(
                    "lift", state="running", detail=f"View {done} of {total}",
                    percent=100 * done / total,
                ),
            )
            labels_path.parent.mkdir(parents=True, exist_ok=True)
            temporary = labels_path.with_suffix(".bin.tmp")
            temporary.write_bytes(np.ascontiguousarray(vertex_labels, dtype=np.uint8).tobytes())
            os.replace(temporary, labels_path)
        label_counts = {
            "other": int((vertex_labels == OTHER).sum()),
            "healthy": int((vertex_labels == HEALTHY).sum()),
            "unhealthy": int((vertex_labels == UNHEALTHY).sum()),
        }
        status.update(
            "lift",
            state="done",
            detail=(
                f"healthy {label_counts['healthy']:,} · unhealthy {label_counts['unhealthy']:,} "
                f"of {vertex_count:,} vertices"
            ),
            percent=None,
        )

        status.update("finalize", state="running")
        manifest = write_manifest(
            site_dir, args.site_id, args.site_name, model_id, result, label_counts, args.min_votes
        )
        if manifest["frames"]:
            cover_source = analysis_dir / manifest["frames"][len(manifest["frames"]) // 2]["rgb"]
            with Image.open(cover_source) as cover:
                cover = cover.convert("RGB")
                cover.thumbnail((960, 960))
                atomic_image(cover, site_dir / "cover.jpg", quality=88)
        status.update("finalize", state="done", detail=f"{len(manifest['frames'])} frames packaged")

        # Publish. Without this a finished site exists only on this machine and
        # no other client can see it. A failure here is reported but does not
        # fail the run: the analysis is complete and on disk, and publishing can
        # be retried with tools/publish_site.py (uploads are idempotent).
        if args.no_publish:
            status.update("publish", state="done", detail="skipped (--no-publish)")
        else:
            status.update("publish", state="running")
            try:
                from publish_site import publish_site

                publish_site(
                    site_dir=site_dir,
                    site_id=args.site_id,
                    site_name=args.site_name,
                    photo_count=len(manifest["frames"]),
                    api=args.api,
                )
                status.update("publish", state="done", detail=f"uploaded to {args.api}")
            except Exception as error:  # noqa: BLE001
                status.update(
                    "publish",
                    state="failed",
                    detail=f"{error}; retry with tools/publish_site.py --dir {site_dir}",
                )
                print(f"publish failed (analysis is still on disk): {error}",
                      file=sys.stderr, flush=True)

        status.finish()
        print(f"site ready: {site_dir}", flush=True)
    except PipelineError as error:
        status.fail(error.stage_id, error.message)
        print(f"pipeline failed at {error.stage_id}: {error.message}", file=sys.stderr, flush=True)
        sys.exit(1)
    except Exception as error:  # noqa: BLE001
        running = next((s["id"] for s in status.stages if s["state"] == "running"), "finalize")
        status.fail(running, f"{type(error).__name__}: {error}")
        raise


if __name__ == "__main__":
    main()
