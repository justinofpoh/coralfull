#!/usr/bin/env python3
"""Lift a Site B CoralScapes mask onto its Metashape mesh vertices.

The output is one byte per source PLY vertex: 0 background, 1 healthy coral,
2 unhealthy coral. A vertex is only labelled when its projection agrees with
Metashape's camera-depth map, preventing hidden/back-facing mesh surfaces from
being assigned the semantic class of the foreground reef.
"""

from __future__ import annotations

import argparse
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree

import numpy as np
from PIL import Image

try:
    import OpenEXR
except ImportError as error:  # pragma: no cover - a clear CLI failure mode
    raise SystemExit("Install OpenEXR: python -m pip install OpenEXR") from error


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mesh", type=Path, required=True, help="Metashape binary PLY")
    parser.add_argument("--mask", type=Path, required=True, help="8-bit 0/1/2 semantic mask")
    parser.add_argument("--metashape-project", type=Path, required=True, help=".psx project")
    parser.add_argument("--camera-id", type=int, required=True, help="Master camera ID for the mask")
    parser.add_argument("--output", type=Path, required=True, help="Output raw vertex-label file")
    parser.add_argument(
        "--visibility-tolerance",
        type=float,
        default=0.03,
        help="Maximum relative difference from dense depth for a visible vertex",
    )
    return parser.parse_args()


def mesh_vertices(path: Path) -> np.ndarray:
    data = path.read_bytes()
    header_end = data.index(b"end_header\n") + len(b"end_header\n")
    header = data[:header_end].decode("utf-8")
    vertex_count = int(
        next(line.split()[-1] for line in header.splitlines() if line.startswith("element vertex "))
    )
    layout = np.dtype(
        [
            ("x", "<f4"), ("y", "<f4"), ("z", "<f4"),
            ("nx", "<f4"), ("ny", "<f4"), ("nz", "<f4"),
            ("red", "u1"), ("green", "u1"), ("blue", "u1"),
        ]
    )
    vertices = np.frombuffer(data, dtype=layout, count=vertex_count, offset=header_end)
    return np.column_stack((vertices["x"], vertices["y"], vertices["z"])).astype(np.float64)


def project_data(project: Path, camera_id: int) -> tuple[np.ndarray, float, float, float, int, int]:
    chunk_path = project.with_suffix(".files") / "0" / "chunk.zip"
    with zipfile.ZipFile(chunk_path) as archive:
        root = ElementTree.fromstring(archive.read("doc.xml"))

    camera = root.find(f".//camera[@id='{camera_id}']")
    if camera is None or camera.findtext("transform") is None:
        raise ValueError(f"Camera {camera_id} has no Metashape transform")
    sensor = root.find(f".//sensor[@id='{camera.get('sensor_id')}']")
    calibration = sensor.find("calibration[@class='adjusted']") if sensor is not None else None
    resolution = sensor.find("resolution") if sensor is not None else None
    if calibration is None or resolution is None:
        raise ValueError(f"Camera {camera_id} has no adjusted frame calibration")

    values = {child.tag: float(child.text) for child in calibration if child.text is not None}
    transform = np.array(list(map(float, camera.findtext("transform").split()))).reshape(4, 4)
    return (
        transform,
        values["f"],
        values.get("cx", 0.0),
        values.get("cy", 0.0),
        int(resolution.get("width")),
        int(resolution.get("height")),
    )


def camera_depth(project: Path, camera_id: int) -> np.ndarray:
    source = project.with_suffix(".files") / "0" / "0" / "depth_maps"
    member = f"0/d{camera_id}.exr"
    payload = None
    for archive_name in ("data1.zip", "data0.zip"):
        with zipfile.ZipFile(source / archive_name) as archive:
            if member in archive.namelist():
                payload = archive.read(member)
                break
    if payload is None:
        raise ValueError(f"No dense depth map for camera {camera_id}")

    with tempfile.NamedTemporaryFile(suffix=".exr") as temporary:
        temporary.write(payload)
        temporary.flush()
        return OpenEXR.File(temporary.name).parts[0].channels["Z"].pixels.astype(np.float32)


def main() -> None:
    args = arguments()
    vertices = mesh_vertices(args.mesh)
    mask = np.asarray(Image.open(args.mask).convert("L"), dtype=np.uint8)
    transform, focal, cx, cy, width, height = project_data(args.metashape_project, args.camera_id)
    depth = camera_depth(args.metashape_project, args.camera_id)

    homogeneous = np.column_stack((vertices, np.ones(len(vertices))))
    with np.errstate(divide="ignore", invalid="ignore", over="ignore"):
        camera_points = (np.linalg.inv(transform) @ homogeneous.T).T[:, :3]
        z = camera_points[:, 2]
        normalized_x = camera_points[:, 0] / z
        normalized_y = camera_points[:, 1] / z
    # Metashape's depth map is in the camera's undistorted image coordinate
    # space, so project using the adjusted focal length and principal point.
    pixel_x = focal * normalized_x + cx + width / 2
    pixel_y = focal * normalized_y + cy + height / 2
    projected = (
        np.isfinite(pixel_x)
        & np.isfinite(pixel_y)
        & (z > 0)
        & (pixel_x >= 0)
        & (pixel_x < width)
        & (pixel_y >= 0)
        & (pixel_y < height)
    )

    labels = np.zeros(len(vertices), dtype=np.uint8)
    vertex_indices = np.flatnonzero(projected)
    depth_x = np.clip((pixel_x[projected] * depth.shape[1] / width).astype(int), 0, depth.shape[1] - 1)
    depth_y = np.clip((pixel_y[projected] * depth.shape[0] / height).astype(int), 0, depth.shape[0] - 1)
    measured_depth = depth[depth_y, depth_x]
    visible = np.isfinite(measured_depth) & (measured_depth > 0)
    with np.errstate(divide="ignore", invalid="ignore"):
        visible &= np.abs(z[projected] - measured_depth) / measured_depth <= args.visibility_tolerance

    mask_x = np.clip((pixel_x[projected] * mask.shape[1] / width).astype(int), 0, mask.shape[1] - 1)
    mask_y = np.clip((pixel_y[projected] * mask.shape[0] / height).astype(int), 0, mask.shape[0] - 1)
    visible_indices = vertex_indices[visible]
    labels[visible_indices] = np.clip(mask[mask_y[visible], mask_x[visible]], 0, 2)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(labels.tobytes())
    print(
        f"Wrote {args.output} ({len(labels)} vertex labels): "
        f"healthy={(labels == 1).sum()}, unhealthy={(labels == 2).sum()}, "
        f"visible={len(visible_indices)}"
    )


if __name__ == "__main__":
    main()
