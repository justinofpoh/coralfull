#!/usr/bin/env python3
"""Metashape Pro bridge: build a reef reconstruction from a photo folder.

This script runs INSIDE Metashape Pro's bundled Python, launched headlessly:

  /Applications/MetashapePro.app/Contents/MacOS/MetashapePro \
      -r tools/metashape_build.py \
      --project <site>/project/site.psx \
      --photos <site>/photos \
      --mesh-dir <site>/mesh \
      --progress <site>/mesh/metashape_progress.json \
      --result <site>/mesh/metashape_result.json

It creates the project, adds and aligns the photos, builds dense depth maps,
builds and textures a mesh, exports a binary PLY + JPEG texture, and writes a
result JSON containing everything the rest of the pipeline needs: Metashape
version, per-camera calibrated poses and intrinsics, camera keys (used to
locate d<key>.exr dense depth maps inside the saved project), mesh statistics,
and per-phase timings.

Progress is streamed to --progress as small atomic JSON writes so the
orchestrator (tools/process_site.py) can surface real percentages.

The script never raises out of main(): failures are recorded in the result
JSON with ok=false so the orchestrator can present an actionable error.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
import time
import traceback
from array import array
from pathlib import Path

import Metashape


def enum(namespace: str, member: str):
    """Resolve a Metashape enum across 1.x (flat) and 2.x (nested) layouts."""
    scope = getattr(Metashape, namespace, None)
    if scope is not None and hasattr(scope, member):
        return getattr(scope, member)
    return getattr(Metashape, member)


def atomic_json(value: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    os.replace(temporary, path)


def matrix_rows(matrix) -> list[list[float]]:
    try:
        return [[float(matrix[row, col]) for col in range(4)] for row in range(4)]
    except TypeError:
        return [[float(matrix.row(row)[col]) for col in range(4)] for row in range(4)]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--photos", type=Path, required=True)
    parser.add_argument("--mesh-dir", type=Path, required=True)
    parser.add_argument("--progress", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--match-downscale", type=int, default=1)
    parser.add_argument("--depth-downscale", type=int, default=4)
    parser.add_argument("--texture-size", type=int, default=4096)
    # Metashape may leave -r, the script path, or a "--" separator in argv.
    argv = sys.argv[1:]
    if "--" in argv:
        argv = argv[argv.index("--") + 1 :]
    while argv:
        if argv[0] == "-r" and len(argv) >= 2:
            argv = argv[2:]
            continue
        if argv[0].endswith(".py") and not argv[0].startswith("-"):
            argv = argv[1:]
            continue
        break
    return parser.parse_args(argv)


class Progress:
    def __init__(self, path: Path):
        self.path = path
        self.phase = "starting"
        self.last_write = 0.0

    def set_phase(self, phase: str) -> None:
        self.phase = phase
        self.write(0.0, force=True)

    def write(self, percent: float, force: bool = False) -> None:
        now = time.monotonic()
        if not force and now - self.last_write < 0.5:
            return
        self.last_write = now
        atomic_json(
            {
                "phase": self.phase,
                "percent": round(float(percent), 1),
                "updatedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            },
            self.path,
        )

    def callback(self, percent: float) -> None:
        self.write(percent)


def list_photos(photos_dir: Path) -> list[Path]:
    supported = {".jpg", ".jpeg", ".png"}
    return sorted(
        (path for path in photos_dir.iterdir() if path.suffix.lower() in supported),
        key=lambda path: path.name,
    )


def build(args: argparse.Namespace, progress: Progress) -> dict:
    started = datetime.datetime.now().astimezone()
    timings: dict[str, float] = {}

    if not Metashape.app.activated:
        raise RuntimeError(
            "Metashape Pro is installed but not activated. "
            "Open Metashape Pro and activate the license, then retry."
        )

    photos = list_photos(args.photos)
    if len(photos) < 3:
        raise RuntimeError(f"Need at least 3 photos, found {len(photos)} in {args.photos}")

    def timed(phase: str, work) -> None:
        progress.set_phase(phase)
        start = time.monotonic()
        work()
        timings[phase] = round(time.monotonic() - start, 1)
        progress.write(100.0, force=True)

    args.project.parent.mkdir(parents=True, exist_ok=True)
    args.mesh_dir.mkdir(parents=True, exist_ok=True)

    doc = Metashape.Document()
    doc.save(str(args.project))
    chunk = doc.addChunk()

    timed("add_photos", lambda: chunk.addPhotos([str(path) for path in photos]))

    timed(
        "match",
        lambda: chunk.matchPhotos(
            downscale=args.match_downscale,
            generic_preselection=True,
            reference_preselection=False,
            progress=progress.callback,
        ),
    )
    timed("align", lambda: chunk.alignCameras(progress=progress.callback))
    doc.save()

    aligned = [camera for camera in chunk.cameras if camera.transform is not None]
    if len(aligned) < 3:
        raise RuntimeError(
            f"Only {len(aligned)} of {len(chunk.cameras)} photos aligned. "
            "The sequence likely lacks overlap; capture with more overlap and retry."
        )

    timed(
        "depth_maps",
        lambda: chunk.buildDepthMaps(
            downscale=args.depth_downscale,
            filter_mode=enum("FilterMode", "MildFiltering"),
            progress=progress.callback,
        ),
    )
    doc.save()

    timed(
        "model",
        lambda: chunk.buildModel(
            source_data=enum("DataSource", "DepthMapsData"),
            surface_type=enum("SurfaceType", "Arbitrary"),
            interpolation=enum("Interpolation", "EnabledInterpolation"),
            face_count=enum("FaceCount", "MediumFaceCount"),
            progress=progress.callback,
        ),
    )
    if chunk.model is None or not len(chunk.model.faces):
        raise RuntimeError("Metashape did not produce a mesh from the depth maps.")

    try:
        timed(
            "vertex_colors",
            lambda: chunk.colorizeModel(
                source_data=enum("DataSource", "ImagesData"),
                progress=progress.callback,
            ),
        )
    except Exception:
        pass  # Vertex colours are cosmetic; the texture is the primary source.

    timed(
        "uv",
        lambda: chunk.buildUV(
            mapping_mode=enum("MappingMode", "GenericMapping"),
            page_count=1,
            texture_size=args.texture_size,
            progress=progress.callback,
        ),
    )
    timed(
        "texture",
        lambda: chunk.buildTexture(
            blending_mode=enum("BlendingMode", "MosaicBlending"),
            texture_size=args.texture_size,
            fill_holes=True,
            progress=progress.callback,
        ),
    )
    doc.save()

    # The PLY export is written in Metashape's "Local Coordinates" frame,
    # which for an unreferenced chunk is offset onto the WGS84 ellipsoid and
    # therefore does NOT match the chunk-internal frame used by the camera
    # transforms and dense depth values. Dump the vertices in internal
    # coordinates (same order as the export) so the 3D semantic lift can
    # project them through the calibrated cameras.
    progress.set_phase("export")
    internal_path = args.mesh_dir / "internal_vertices.bin"
    coordinates = array("f")
    for vertex in chunk.model.vertices:
        coordinates.extend((vertex.coord.x, vertex.coord.y, vertex.coord.z))
    with open(internal_path, "wb") as handle:
        coordinates.tofile(handle)

    mesh_path = args.mesh_dir / "mesh.ply"
    timed(
        "export",
        lambda: chunk.exportModel(
            path=str(mesh_path),
            binary=True,
            save_texture=True,
            save_uv=True,
            save_normals=True,
            save_colors=True,
            save_cameras=False,
            save_markers=False,
            format=enum("ModelFormat", "ModelFormatPLY"),
            texture_format=enum("ImageFormat", "ImageFormatJPEG"),
            progress=progress.callback,
        ),
    )
    doc.save()

    texture_path = mesh_path.with_suffix(".jpg")
    if not texture_path.exists():
        candidates = sorted(args.mesh_dir.glob("mesh*.jp*g"))
        if candidates:
            candidates[0].rename(texture_path)
        else:
            raise RuntimeError("Textured PLY export did not produce a JPEG texture.")

    sensors = []
    for sensor in chunk.sensors:
        calibration = sensor.calibration
        sensors.append(
            {
                "key": sensor.key,
                "label": sensor.label,
                "width": calibration.width,
                "height": calibration.height,
                "f": calibration.f,
                "cx": calibration.cx,
                "cy": calibration.cy,
                "k1": calibration.k1,
                "k2": calibration.k2,
                "k3": calibration.k3,
                "p1": calibration.p1,
                "p2": calibration.p2,
            }
        )
    cameras = []
    for camera in chunk.cameras:
        cameras.append(
            {
                "key": camera.key,
                "label": camera.label,
                "sensorKey": camera.sensor.key if camera.sensor else None,
                "aligned": camera.transform is not None,
                "transform": matrix_rows(camera.transform) if camera.transform else None,
                "photo": camera.photo.path if camera.photo else None,
            }
        )

    finished = datetime.datetime.now().astimezone()
    return {
        "ok": True,
        "metashapeVersion": Metashape.app.version,
        "createdAt": started.isoformat(timespec="seconds"),
        "finishedAt": finished.isoformat(timespec="seconds"),
        "timingsSeconds": timings,
        "photoCount": len(photos),
        "alignedCameras": len(aligned),
        "imageResolution": [chunk.sensors[0].calibration.width, chunk.sensors[0].calibration.height]
        if chunk.sensors
        else None,
        "vertices": len(chunk.model.vertices),
        "faces": len(chunk.model.faces),
        "textureSize": args.texture_size,
        "depthDownscale": args.depth_downscale,
        "scaleCalibrated": False,
        "project": str(args.project),
        "meshPly": str(mesh_path),
        "meshTexture": str(texture_path),
        "internalVertices": str(internal_path),
        "chunkTransform": matrix_rows(chunk.transform.matrix),
        "sensors": sensors,
        "cameras": cameras,
    }


def main() -> None:
    args = parse_args()
    progress = Progress(args.progress)
    try:
        result = build(args, progress)
    except Exception as error:  # noqa: BLE001 - reported via result JSON
        result = {
            "ok": False,
            "error": f"{type(error).__name__}: {error}",
            "traceback": traceback.format_exc(),
        }
    atomic_json(result, args.result)
    progress.set_phase("finished" if result.get("ok") else "failed")
    Metashape.app.quit()


main()
