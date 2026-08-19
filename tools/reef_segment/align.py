"""Estimate a similarity transform from COLMAP-frame Gaussians to the SuperSplat export."""

from __future__ import annotations

import numpy as np
from scipy.spatial import cKDTree


def _pca_axes(points: np.ndarray) -> tuple[np.ndarray, np.ndarray, float]:
    center = points.mean(axis=0)
    centered = points - center
    cov = centered.T @ centered / max(len(points) - 1, 1)
    _, vecs = np.linalg.eigh(cov)
    axes = vecs[:, ::-1]
    if np.linalg.det(axes) < 0:
        axes[:, -1] *= -1
    scale = np.sqrt(np.mean(np.sum(centered**2, axis=1)))
    return center, axes, float(scale + 1e-12)


def pca_similarity(src: np.ndarray, dst: np.ndarray) -> tuple[float, np.ndarray, np.ndarray]:
    src_c, src_axes, src_s = _pca_axes(src)
    dst_c, dst_axes, dst_s = _pca_axes(dst)
    scale = dst_s / src_s
    best = None
    best_err = np.inf
    signs = [
        (1, 1, 1),
        (1, 1, -1),
        (1, -1, 1),
        (-1, 1, 1),
    ]
    dst_sample = dst[np.linspace(0, len(dst) - 1, min(8000, len(dst)), dtype=int)]
    tree = cKDTree(dst_sample)
    src_sample = src[np.linspace(0, len(src) - 1, min(4000, len(src)), dtype=int)]
    for sx, sy, sz in signs:
        axes = src_axes.copy()
        axes[:, 0] *= sx
        axes[:, 1] *= sy
        axes[:, 2] *= sz
        if np.linalg.det(axes) < 0:
            axes[:, 2] *= -1
        rot = dst_axes @ axes.T
        transformed = scale * (src_sample - src_c) @ rot.T + dst_c
        err = float(np.median(tree.query(transformed, k=1)[0]))
        if err < best_err:
            best_err = err
            best = (scale, rot, dst_c - scale * rot @ src_c)
    assert best is not None
    return best


def umeyama(src: np.ndarray, dst: np.ndarray) -> tuple[float, np.ndarray, np.ndarray]:
    src_c = src.mean(axis=0)
    dst_c = dst.mean(axis=0)
    src_d = src - src_c
    dst_d = dst - dst_c
    cov = (dst_d.T @ src_d) / len(src)
    u, s, vt = np.linalg.svd(cov)
    d = np.ones(3)
    if np.linalg.det(u) * np.linalg.det(vt) < 0:
        d[-1] = -1
    rot = u @ np.diag(d) @ vt
    var = np.sum(src_d**2) / len(src)
    scale = float(np.sum(s * d) / max(var, 1e-12))
    trans = dst_c - scale * rot @ src_c
    return scale, rot, trans


def apply_similarity(points: np.ndarray, scale: float, rot: np.ndarray, trans: np.ndarray) -> np.ndarray:
    return (scale * (rot @ points.T).T) + trans


def invert_similarity(scale: float, rot: np.ndarray, trans: np.ndarray) -> tuple[float, np.ndarray, np.ndarray]:
    inv_scale = 1.0 / scale
    inv_rot = rot.T
    inv_trans = -inv_scale * inv_rot @ trans
    return inv_scale, inv_rot, inv_trans


def icp_similarity(
    src: np.ndarray,
    dst: np.ndarray,
    iterations: int = 20,
    sample: int = 12000,
) -> tuple[float, np.ndarray, np.ndarray, float]:
    rng = np.random.default_rng(0)
    src_idx = rng.choice(len(src), size=min(sample, len(src)), replace=False)
    dst_idx = rng.choice(len(dst), size=min(sample, len(dst)), replace=False)
    src_s = src[src_idx]
    dst_s = dst[dst_idx]
    scale, rot, trans = pca_similarity(src_s, dst_s)
    tree = cKDTree(dst_s)
    err = np.inf
    for _ in range(iterations):
        transformed = apply_similarity(src_s, scale, rot, trans)
        dist, nn = tree.query(transformed, k=1)
        cutoff = np.quantile(dist, 0.8)
        keep = dist <= cutoff
        if keep.sum() < 32:
            break
        scale, rot, trans = umeyama(src_s[keep], dst_s[nn[keep]])
        err = float(np.median(dist[keep]))
    return scale, rot, trans, err
