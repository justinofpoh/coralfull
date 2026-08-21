"""Project 2D health masks onto Gaussian splat centers."""

from __future__ import annotations

from collections.abc import Callable

import numpy as np
from scipy.ndimage import binary_dilation
from scipy.spatial import cKDTree

from classes import HEALTHY, OTHER, UNHEALTHY
from colmap_io import Camera, ImagePose, project_points

LabelResult = np.ndarray | tuple[np.ndarray, np.ndarray | None] | None


def _unpack(result: LabelResult) -> tuple[np.ndarray, np.ndarray | None] | tuple[None, None]:
    if result is None:
        return None, None
    if isinstance(result, tuple):
        mask = result[0]
        probs = result[1] if len(result) > 1 else None
        return mask, probs
    return result, None


def dilate_health_mask(mask: np.ndarray, iterations: int = 18) -> np.ndarray:
    """Grow tiny coral detections so small fragments survive the 3D lift."""
    healthy = mask == HEALTHY
    unhealthy = mask == UNHEALTHY
    if not healthy.any() and not unhealthy.any():
        return mask
    grown_h = binary_dilation(healthy, iterations=iterations)
    grown_u = binary_dilation(unhealthy, iterations=iterations)
    out = mask.copy()
    out[grown_h] = HEALTHY
    out[grown_u & ~grown_h] = UNHEALTHY
    return out


def expand_health_labels(
    points: np.ndarray,
    labels: np.ndarray,
    radius: float = 0.012,
    iterations: int = 2,
) -> np.ndarray:
    """Fill holes by copying nearby coral labels onto unlabeled splats."""
    out = labels.copy()
    for _ in range(iterations):
        coral = np.nonzero(out != OTHER)[0]
        other = np.nonzero(out == OTHER)[0]
        if len(coral) == 0 or len(other) == 0:
            break
        tree = cKDTree(points[coral])
        dist, nn = tree.query(points[other], k=1, workers=-1)
        take = dist <= radius
        if not np.any(take):
            break
        out[other[take]] = out[coral[nn[take]]]
    return out


def vote_labels(
    points_colmap: np.ndarray,
    poses: list[ImagePose],
    cameras: dict[int, Camera],
    mask_for_image: Callable[[str], LabelResult],
    min_votes: int = 3,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    n = len(points_colmap)
    votes = np.zeros((n, 3), dtype=np.uint16)
    accum = np.zeros((n, 3), dtype=np.float64)
    seen = np.zeros(n, dtype=np.uint16)
    used_probs = False

    for pose in poses:
        mask, probs = _unpack(mask_for_image(pose.name))
        if mask is None:
            continue
        camera = cameras[pose.camera_id]
        uv, valid = project_points(points_colmap, pose, camera)
        if not np.any(valid):
            continue
        scale_u = mask.shape[1] / camera.width
        scale_v = mask.shape[0] / camera.height
        xs = np.clip((uv[valid, 0] * scale_u).astype(np.int32), 0, mask.shape[1] - 1)
        ys = np.clip((uv[valid, 1] * scale_v).astype(np.int32), 0, mask.shape[0] - 1)
        idxs = np.nonzero(valid)[0]
        labels = np.clip(mask[ys, xs].astype(np.int32), 0, 2)
        votes[idxs, labels] += 1
        seen[idxs] += 1
        if probs is not None:
            accum[idxs] += probs[:, ys, xs].T
            used_probs = True

    if used_probs:
        health = reduce_probs(accum, seen, min_votes)
    else:
        health = reduce_votes(votes, min_votes)
    return health, health, seen


def reduce_votes(votes: np.ndarray, min_votes: int) -> np.ndarray:
    coral = votes[:, HEALTHY] + votes[:, UNHEALTHY]
    choice = np.where(
        votes[:, HEALTHY] >= votes[:, UNHEALTHY], HEALTHY, UNHEALTHY
    ).astype(np.uint8)
    health = np.full(len(votes), OTHER, dtype=np.uint8)
    health[coral >= min_votes] = choice[coral >= min_votes]
    return health


def reduce_probs(accum: np.ndarray, seen: np.ndarray, min_votes: int) -> np.ndarray:
    mean = accum / np.maximum(seen[:, None], 1)
    health = mean.argmax(axis=1).astype(np.uint8)
    health[seen < min_votes] = OTHER
    return health
