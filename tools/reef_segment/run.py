#!/usr/bin/env python3
"""Segment survey photos and lift labels onto the SuperSplat Gaussian cloud.

Does not retrain or rebuild the 3D reconstruction. Cameras stay in COLMAP
space; SuperSplat's orientation is undone with a similarity transform.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from align import apply_similarity, icp_similarity, invert_similarity
from classes import CLASS_COLORS, CLASS_NAMES, HEALTHY, OTHER, UNHEALTHY, map_fine_mask
from colmap_io import project_points, read_cameras, read_images
from lift import dilate_health_mask, expand_health_labels, vote_labels
from ply_io import read_centers


def parse_args() -> argparse.Namespace:
    repo = Path("/Users/juno/Desktop/coralfull")
    colmap = Path("/Users/juno/Desktop/COLMAP Workspace")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--images", type=Path, default=colmap / "images")
    parser.add_argument("--sparse", type=Path, default=colmap / "sparse" / "0")
    parser.add_argument("--colmap-ply", type=Path, default=colmap / "reef_3dgs.ply")
    parser.add_argument(
        "--target-ply",
        type=Path,
        default=repo / "web" / "public" / "reef_struct_orient_proper_cleaned.ply",
    )
    parser.add_argument("--out-dir", type=Path, default=repo / "web" / "public")
    parser.add_argument("--cache-dir", type=Path, default=ROOT / "cache" / "health3")
    parser.add_argument("--stride", type=int, default=2)
    parser.add_argument("--min-votes", type=int, default=3)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--debug-views", type=int, default=4)
    parser.add_argument("--checkpoint", type=str, default=None)
    parser.add_argument(
        "--reuse-cache",
        action="store_true",
        help="Skip the model and fuse cached 3-class PNGs with hard votes.",
    )
    parser.add_argument(
        "--from-fine-cache",
        type=Path,
        default=ROOT / "cache" / "masks",
        help="Optional 39-class Coralscapes mask dir to collapse to 3 classes.",
    )
    parser.add_argument(
        "--resegment",
        action="store_true",
        help="Force 2D inference even if cached masks exist.",
    )
    return parser.parse_args()


DEBUG_PALETTE = {
    OTHER: (60, 60, 60),
    HEALTHY: (0, 200, 0),
    UNHEALTHY: (220, 30, 30),
}


def save_debug_overlay(
    image_path: Path,
    mask: np.ndarray,
    out_path: Path,
) -> None:
    image = Image.open(image_path).convert("RGB").resize((mask.shape[1], mask.shape[0]))
    overlay = np.array(image, dtype=np.float32)
    color_lut = np.zeros((256, 3), dtype=np.float32)
    for class_id, rgb in DEBUG_PALETTE.items():
        color_lut[class_id] = rgb
    colored = color_lut[mask]
    mixed = overlay * 0.45 + colored * 0.55
    mixed[mask == OTHER] = overlay[mask == OTHER]
    Image.fromarray(mixed.clip(0, 255).astype(np.uint8)).save(out_path)


def write_sidecar(
    out_dir: Path,
    stem: str,
    fine: np.ndarray,
    coarse: np.ndarray,
    seen: np.ndarray,
    min_votes: int,
    model_id: str,
) -> Path:
    coral = (coarse == HEALTHY) | (coarse == UNHEALTHY)
    meta = {
        "ply": f"{stem}.ply",
        "ids": f"{stem}.labels.bin",
        "fine": f"{stem}.fine.bin",
        "model": model_id,
        "splatCount": int(len(coarse)),
        "minVotes": min_votes,
        "classes": [
            {"id": cid, "name": name, "color": CLASS_COLORS[cid]}
            for cid, name in CLASS_NAMES.items()
        ],
        "counts": {
            CLASS_NAMES[cid]: int((coarse == cid).sum()) for cid in CLASS_NAMES
        },
        "labeledFraction": float(coral.mean()),
        "meanVotes": float(seen.mean()),
    }
    (out_dir / f"{stem}.labels.json").write_text(json.dumps(meta, indent=2))
    (out_dir / f"{stem}.labels.bin").write_bytes(np.ascontiguousarray(coarse, dtype=np.uint8).tobytes())
    (out_dir / f"{stem}.fine.bin").write_bytes(np.ascontiguousarray(fine, dtype=np.uint8).tobytes())
    return out_dir / f"{stem}.labels.json"


def main() -> None:
    args = parse_args()
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    debug_dir = args.out_dir / "segment_debug"
    debug_dir.mkdir(exist_ok=True)

    cameras = read_cameras(args.sparse / "cameras.bin")
    poses = read_images(args.sparse / "images.bin")
    poses = sorted(poses, key=lambda pose: pose.name)[:: max(args.stride, 1)]
    if args.limit > 0:
        poses = poses[: args.limit]
    print(f"cameras={len(cameras)} views={len(poses)}", flush=True)

    colmap_points = read_centers(args.colmap_ply)
    target_points = read_centers(args.target_ply)
    scale, rot, trans, err = icp_similarity(colmap_points, target_points)
    inv_scale, inv_rot, inv_trans = invert_similarity(scale, rot, trans)
    points_colmap = apply_similarity(target_points, inv_scale, inv_rot, inv_trans)
    print(f"alignment median nn error={err:.5f} scale={scale:.5f}", flush=True)

    check_pose = poses[len(poses) // 2]
    check_camera = cameras[check_pose.camera_id]
    uv, visible = project_points(points_colmap, check_pose, check_camera)
    print(
        f"alignment check view={check_pose.name} visible_splats={int(visible.mean()*100)}%",
        flush=True,
    )
    image = Image.open(args.images / check_pose.name).convert("RGB")
    draw = ImageDraw.Draw(image)
    sample = np.nonzero(visible)[0]
    if len(sample) > 4000:
        sample = sample[np.linspace(0, len(sample) - 1, 4000, dtype=int)]
    for u, v in uv[sample]:
        draw.ellipse((u - 2, v - 2, u + 2, v + 2), fill=(0, 255, 140))
    image.thumbnail((1600, 900))
    image.save(debug_dir / "alignment_check.jpg")

    from segment import HealthSegmenter, resolve_checkpoint

    checkpoint = args.checkpoint or resolve_checkpoint()
    fine_ready = all(
        (args.from_fine_cache / f"{Path(pose.name).stem}.png").exists() for pose in poses
    )
    use_fine_cache = (
        not args.resegment
        and checkpoint is None
        and not args.reuse_cache
        and fine_ready
    )
    if args.reuse_cache:
        segmenter = None
        model_id = "cached-3class-masks"
    elif use_fine_cache:
        segmenter = None
        model_id = "collapsed-from-coralscapes-cache"
        print(
            f"mapping {len(poses)} cached Coralscapes masks in {args.from_fine_cache} to 3 health classes",
            flush=True,
        )
    else:
        segmenter = HealthSegmenter(checkpoint=checkpoint)
        model_id = segmenter.model_id

    def mask_for_image(name: str):
        cached = args.cache_dir / f"{Path(name).stem}.png"
        image_path = args.images / name
        if use_fine_cache:
            fine_path = args.from_fine_cache / f"{Path(name).stem}.png"
            if not fine_path.exists():
                print(f"missing fine mask {name}", flush=True)
                return None
            mask = dilate_health_mask(map_fine_mask(np.array(Image.open(fine_path))))
            Image.fromarray(mask, mode="L").save(cached)
            return mask, None
        if segmenter is None:
            if not cached.exists():
                print(f"missing cached mask {name}", flush=True)
                return None
            return np.array(Image.open(cached)), None
        if not image_path.exists():
            print(f"missing image {name}", flush=True)
            return None
        print(f"segment {name}", flush=True)
        mask, probs = segmenter.predict(image_path)
        mask = dilate_health_mask(mask)
        Image.fromarray(mask, mode="L").save(cached)
        return mask, probs

    debug_left = args.debug_views

    def mask_and_debug(name: str):
        nonlocal debug_left
        result = mask_for_image(name)
        if result is None:
            return None
        mask, probs = result
        if debug_left > 0:
            save_debug_overlay(
                args.images / name, mask, debug_dir / f"{Path(name).stem}_overlay.jpg"
            )
            debug_left -= 1
        return mask, probs

    fine, coarse, seen = vote_labels(
        points_colmap,
        poses,
        cameras,
        mask_and_debug,
        min_votes=args.min_votes,
    )
    coarse = expand_health_labels(target_points, coarse, radius=0.004, iterations=1)
    fine = coarse
    stem = args.target_ply.stem
    meta_path = write_sidecar(
        args.out_dir, stem, fine, coarse, seen, args.min_votes, model_id
    )
    macos_dir = Path("/Users/juno/Desktop/coralfull/macos/coralfull/coralfull/ReefViewer")
    if macos_dir.exists():
        for suffix in (".labels.json", ".labels.bin", ".fine.bin"):
            src = args.out_dir / f"{stem}{suffix}"
            shutil.copy2(src, macos_dir / src.name)
    print(json.dumps(json.loads(meta_path.read_text())["counts"], indent=2))
    print(f"wrote {meta_path}")


if __name__ == "__main__":
    main()
