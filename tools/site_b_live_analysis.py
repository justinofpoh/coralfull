#!/usr/bin/env python3
"""Generate the Site B live-analysis frame sequence for the macOS app.

For every master camera in the Metashape project that has a matching survey
image, this produces a synchronized artifact set:

  site_b_frames/<label>_rgb.jpg       exact RGB source frame (display size)
  site_b_frames/<label>_semantic.jpg  CoralScapes class overlay
  site_b_frames/<label>_mask.png      raw 3-class mask (0 other, 1 healthy, 2 unhealthy)
  site_b_frames/<label>_depth.png     Metashape dense depth for that camera
  site_b_frames/<label>_meta.json     per-frame stats sidecar
  site_b_sequence.json                manifest the app watches

The macOS app polls the manifest in this directory by default:
~/Library/Application Support/coralfull/SiteB/live-analysis

The manifest is rewritten atomically after every completed frame, so the app
timeline grows live while this script runs and never observes a partial frame.
Re-running skips frames whose artifacts already exist (use --force to redo).

Example:
  tools/reef_segment/.venv/bin/python tools/site_b_live_analysis.py \
    --images-dir ~/Desktop/reef_module_1/left \
    --metashape-project ~/Desktop/reef_module_1_agisoft.psx
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import sys
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree

import numpy as np
from PIL import Image

try:
    import OpenEXR
except ImportError as error:  # pragma: no cover - clear CLI failure path
    raise SystemExit("Install OpenEXR: python -m pip install OpenEXR") from error


ROOT = Path(__file__).resolve().parents[1]
SEGMENT_TOOL = ROOT / "tools" / "reef_segment"
if str(SEGMENT_TOOL) not in sys.path:
    sys.path.insert(0, str(SEGMENT_TOOL))

from segment import HealthSegmenter  # noqa: E402


# The app is not sandboxed, so its Application Support lives directly in the
# user library (the old sandboxed container path no longer applies).
DEFAULT_OUTPUT = (
    Path.home() / "Library/Application Support/coralfull/SiteB/live-analysis"
)
FRAMES_SUBDIR = "site_b_frames"
MANIFEST_NAME = "site_b_sequence.json"
CLASS_COLORS = np.array([[66, 82, 103], [0, 200, 0], [220, 30, 30]], dtype=np.uint8)
CLASS_NAMES = {"0": "other/background", "1": "healthy coral", "2": "unhealthy coral"}
DEPTH_STOPS = np.array(
    [
        [31, 39, 120], [48, 81, 206], [29, 153, 230], [51, 205, 153],
        [155, 225, 70], [245, 221, 55], [247, 134, 38], [198, 44, 37],
    ],
    dtype=np.float32,
)
DEPTH_INVALID = np.array([7, 23, 38], dtype=np.float32)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--images-dir",
        type=Path,
        default=Path.home() / "Desktop/reef_module_1/left",
        help="Directory of master-camera survey frames (JPG, named by camera label)",
    )
    parser.add_argument(
        "--metashape-project",
        type=Path,
        default=Path.home() / "Desktop/reef_module_1_agisoft.psx",
        help=".psx project with dense depth maps",
    )
    parser.add_argument("--frames", nargs="*", help="Optional camera labels; defaults to all")
    parser.add_argument("--out-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--display-width", type=int, default=1280)
    parser.add_argument("--device", default=None, help="Optional torch device (mps, cpu, cuda)")
    parser.add_argument("--force", action="store_true", help="Regenerate existing frames")
    return parser.parse_args()


def atomic_bytes(payload: bytes, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(payload)
    os.replace(temporary, path)


def atomic_image(image: Image.Image, path: Path, **save_options: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    image_format = "PNG" if path.suffix.lower() == ".png" else "JPEG"
    image.save(temporary, format=image_format, **save_options)
    os.replace(temporary, path)


def atomic_json(value: dict[str, object], path: Path) -> None:
    atomic_bytes((json.dumps(value, indent=2) + "\n").encode(), path)


def master_cameras(project: Path) -> dict[str, int]:
    """Map master camera labels to camera ids from the chunk document."""
    chunk = project.with_suffix(".files") / "0" / "chunk.zip"
    with zipfile.ZipFile(chunk) as archive:
        xml = ElementTree.fromstring(archive.read("doc.xml"))
    labels: dict[str, int] = {}
    for camera in xml.findall(".//camera"):
        if camera.get("master_id") is None and camera.get("label"):
            labels[camera.attrib["label"]] = int(camera.attrib["id"])
    if not labels:
        raise ValueError(f"No master cameras found in {project}")
    return labels


def capture_timestamp(image_path: Path) -> str | None:
    try:
        exif = Image.open(image_path).getexif()
    except Exception:
        return None
    raw = exif.get(36867) or exif.get(306)  # DateTimeOriginal, then DateTime
    if not raw:
        return None
    try:
        parsed = datetime.datetime.strptime(str(raw), "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None
    return parsed.isoformat()


def display_frame(source: Path, display_width: int) -> Image.Image:
    image = Image.open(source).convert("RGB")
    if image.width > display_width:
        height = max(1, round(image.height * display_width / image.width))
        image = image.resize((display_width, height), Image.Resampling.LANCZOS)
    return image


def metashape_depth(project: Path, camera: int) -> np.ndarray:
    project_data = project.with_suffix(".files") / "0" / "0" / "depth_maps"
    member = f"0/d{camera}.exr"
    payload: bytes | None = None
    for archive_name in ("data1.zip", "data0.zip"):
        archive_path = project_data / archive_name
        if not archive_path.exists():
            continue
        with zipfile.ZipFile(archive_path) as archive:
            if member in archive.namelist():
                payload = archive.read(member)
                break
    if payload is None:
        raise ValueError(f"No depth map for camera {camera}")

    with tempfile.NamedTemporaryFile(suffix=".exr") as temporary:
        temporary.write(payload)
        temporary.flush()
        exr = OpenEXR.File(temporary.name)
        return exr.parts[0].channels["Z"].pixels.astype(np.float32)


def depth_visualisation(
    depth: np.ndarray, output_size: tuple[int, int]
) -> tuple[Image.Image, int, float, float]:
    valid = np.isfinite(depth) & (depth > 0)
    if not valid.any():
        raise ValueError("Metashape depth map has no valid pixels")
    lower, upper = np.percentile(depth[valid], [2, 98])
    near = np.zeros_like(depth, dtype=np.float32)
    near[valid] = 1 - np.clip((depth[valid] - lower) / (upper - lower), 0, 1)
    position = near * (len(DEPTH_STOPS) - 1)
    left = np.floor(position).astype(np.int32)
    right = np.minimum(left + 1, len(DEPTH_STOPS) - 1)
    mix = (position - left)[..., None]
    color = DEPTH_STOPS[left] * (1 - mix) + DEPTH_STOPS[right] * mix
    color[~valid] = DEPTH_INVALID
    image = Image.fromarray(color.astype(np.uint8), "RGB").resize(
        output_size, Image.Resampling.BILINEAR
    )
    return image, int(valid.sum()), float(lower), float(upper)


def frame_paths(out_dir: Path, label: str) -> dict[str, Path]:
    frames = out_dir / FRAMES_SUBDIR
    return {
        "rgb": frames / f"{label}_rgb.jpg",
        "semantic": frames / f"{label}_semantic.jpg",
        "mask": frames / f"{label}_mask.png",
        "depth": frames / f"{label}_depth.png",
        "meta": frames / f"{label}_meta.json",
    }


def frame_complete(paths: dict[str, Path]) -> bool:
    return all(path.exists() for path in paths.values())


def write_manifest(out_dir: Path, model_id: str | None) -> dict[str, object]:
    entries = []
    frames_dir = out_dir / FRAMES_SUBDIR
    for meta_path in sorted(frames_dir.glob("*_meta.json")):
        try:
            entry = json.loads(meta_path.read_text())
        except json.JSONDecodeError:
            continue
        paths = frame_paths(out_dir, entry["label"])
        if frame_complete(paths):
            entries.append(entry)
    entries.sort(key=lambda item: item["label"])

    manifest: dict[str, object] = {
        "version": 2,
        "site": "Site B",
        "generatedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "semanticModel": model_id or "EPFL-ECEO CoralScapes",
        "depthProducer": "Agisoft Metashape dense depth map",
        "scale": {
            "calibrated": False,
            "note": (
                "Reconstruction is unscaled; depths are relative until the "
                "200 mm scale-bar constraint is applied in Metashape."
            ),
        },
        "classes": CLASS_NAMES,
        "frames": entries,
    }
    atomic_json(manifest, out_dir / MANIFEST_NAME)
    return manifest


def process_frame(
    label: str,
    camera: int,
    image_path: Path,
    project: Path,
    out_dir: Path,
    segmenter: HealthSegmenter,
    display_width: int,
) -> dict[str, object]:
    paths = frame_paths(out_dir, label)

    rgb = display_frame(image_path, display_width)
    atomic_image(rgb, paths["rgb"], quality=92)

    mask, _probabilities = segmenter.predict(paths["rgb"])
    atomic_image(Image.fromarray(mask, mode="L"), paths["mask"])

    rgb_array = np.asarray(rgb, dtype=np.float32)
    colors = CLASS_COLORS[np.minimum(mask, len(CLASS_COLORS) - 1)]
    overlay = (rgb_array * 0.34 + colors.astype(np.float32) * 0.66).clip(0, 255).astype(np.uint8)
    atomic_image(Image.fromarray(overlay, "RGB"), paths["semantic"], quality=90)

    depth = metashape_depth(project, camera)
    depth_image, valid_pixels, lower, upper = depth_visualisation(depth, rgb.size)
    atomic_image(depth_image, paths["depth"])

    total = int(mask.size)
    counts = {str(index): int((mask == index).sum()) for index in range(3)}
    entry: dict[str, object] = {
        "label": label,
        "cameraId": camera,
        "capturedAt": capture_timestamp(image_path),
        "sourceImage": str(image_path),
        "rgb": f"{FRAMES_SUBDIR}/{paths['rgb'].name}",
        "semantic": f"{FRAMES_SUBDIR}/{paths['semantic'].name}",
        "mask": f"{FRAMES_SUBDIR}/{paths['mask'].name}",
        "depth": f"{FRAMES_SUBDIR}/{paths['depth'].name}",
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


def main() -> None:
    args = arguments()
    if not args.images_dir.is_dir():
        raise SystemExit(f"Images directory does not exist: {args.images_dir}")
    if not args.metashape_project.exists():
        raise SystemExit(f"Metashape project does not exist: {args.metashape_project}")

    cameras = master_cameras(args.metashape_project)
    labels = args.frames or sorted(
        label for label in cameras if (args.images_dir / f"{label}.JPG").exists()
    )
    if not labels:
        raise SystemExit("No frames matched between the project and the images directory")

    missing = [label for label in labels if label not in cameras]
    if missing:
        raise SystemExit(f"Labels missing from project: {missing}")

    pending = [
        label
        for label in labels
        if args.force or not frame_complete(frame_paths(args.out_dir, label))
    ]
    print(f"{len(labels)} frames requested, {len(pending)} to generate", flush=True)

    segmenter = HealthSegmenter(device=args.device) if pending else None
    model_id = segmenter.model_id if segmenter else None

    for index, label in enumerate(pending, start=1):
        image_path = args.images_dir / f"{label}.JPG"
        entry = process_frame(
            label,
            cameras[label],
            image_path,
            args.metashape_project,
            args.out_dir,
            segmenter,
            args.display_width,
        )
        write_manifest(args.out_dir, model_id)
        print(
            f"[{index}/{len(pending)}] {label}: healthy {entry['healthyPercent']}%, "
            f"depth valid {entry['depthValidPercent']}%",
            flush=True,
        )

    manifest = write_manifest(args.out_dir, model_id)
    print(f"manifest: {args.out_dir / MANIFEST_NAME} ({len(manifest['frames'])} frames)")


if __name__ == "__main__":
    main()
