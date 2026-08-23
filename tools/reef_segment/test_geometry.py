#!/usr/bin/env python3
"""Geometry tests for COLMAP reading, projection, and similarity alignment."""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from align import apply_similarity, icp_similarity, invert_similarity, umeyama
from classes import HEALTHY, OTHER, UNHEALTHY, health_id
from colmap_io import project_points, qvec_to_rotmat, read_cameras, read_images
from lift import reduce_votes, vote_labels
from ply_io import read_centers


def test_colmap_workspace() -> None:
    sparse = Path("/Users/juno/Desktop/COLMAP Workspace/sparse/0")
    cameras = read_cameras(sparse / "cameras.bin")
    images = read_images(sparse / "images.bin")
    assert len(cameras) == 1
    camera = next(iter(cameras.values()))
    assert camera.model == "SIMPLE_RADIAL"
    assert camera.width == 3840 and camera.height == 2160
    assert len(images) == 584
    assert images[0].name.endswith(".JPG")


def test_project_camera_center_is_invalid() -> None:
    sparse = Path("/Users/juno/Desktop/COLMAP Workspace/sparse/0")
    cameras = read_cameras(sparse / "cameras.bin")
    images = read_images(sparse / "images.bin")
    pose = images[0]
    camera = cameras[pose.camera_id]
    rot = qvec_to_rotmat(pose.qvec)
    center = -rot.T @ pose.tvec
    uv, valid = project_points(center[None, :], pose, camera)
    assert not valid[0]


def test_umeyama_recovers_known_transform() -> None:
    rng = np.random.default_rng(1)
    src = rng.normal(size=(200, 3))
    scale, rot, _ = umeyama(src, src)
    assert abs(scale - 1) < 1e-6
    rot = np.array([[0, -1, 0], [1, 0, 0], [0, 0, 1]], dtype=np.float64)
    trans = np.array([0.25, -0.5, 0.1])
    dst = apply_similarity(src, 1.7, rot, trans)
    est_s, est_r, est_t = umeyama(src, dst)
    recovered = apply_similarity(src, est_s, est_r, est_t)
    assert np.allclose(recovered, dst, atol=1e-8)


def test_invert_roundtrip() -> None:
    src = np.array([[0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 2.0, 0.0], [0.0, 0.0, 3.0]])
    scale, rot, trans = 2.0, np.eye(3), np.array([1.0, 2.0, 3.0])
    dst = apply_similarity(src, scale, rot, trans)
    inv = invert_similarity(scale, rot, trans)
    back = apply_similarity(dst, *inv)
    assert np.allclose(back, src)


def test_vote_majority() -> None:
    points = np.array([[0.0, 0.0, 1.0]])

    class FakePose:
        name = "a.jpg"
        camera_id = 1
        qvec = np.array([1.0, 0.0, 0.0, 0.0])
        tvec = np.array([0.0, 0.0, 0.0])

    class FakeCam:
        camera_id = 1
        model = "SIMPLE_PINHOLE"
        model_id = 0
        width = 10
        height = 10
        params = np.array([1.0, 5.0, 5.0])
        fx = 1.0
        fy = 1.0
        cx = 5.0
        cy = 5.0

    mask = np.full((10, 10), HEALTHY, dtype=np.uint8)
    fine, coarse, seen = vote_labels(
        points,
        [FakePose()],
        {1: FakeCam()},
        lambda name: mask,
        min_votes=1,
    )
    assert fine[0] == HEALTHY
    assert coarse[0] == HEALTHY
    assert seen[0] == 1


def test_coral_beats_majority_other() -> None:
    votes = np.zeros((1, 3), dtype=np.uint16)
    votes[0, OTHER] = 40
    votes[0, HEALTHY] = 3
    health = reduce_votes(votes, min_votes=2)
    assert health[0] == HEALTHY


def test_ply_counts() -> None:
    cleaned = Path("/Users/juno/Desktop/coralfull/web/public/reef_struct_orient_proper_cleaned.ply")
    colmap_ply = Path("/Users/juno/Desktop/COLMAP Workspace/reef_3dgs.ply")
    assert len(read_centers(cleaned)) == 139307
    assert len(read_centers(colmap_ply)) == 172712


def test_other_stays_other() -> None:
    points = np.array([[0.0, 0.0, 1.0]])

    class FakePose:
        name = "a.jpg"
        camera_id = 1
        qvec = np.array([1.0, 0.0, 0.0, 0.0])
        tvec = np.array([0.0, 0.0, 0.0])

    class FakeCam:
        camera_id = 1
        model = "SIMPLE_PINHOLE"
        model_id = 0
        width = 10
        height = 10
        params = np.array([1.0, 5.0, 5.0])
        fx = 1.0
        fy = 1.0
        cx = 5.0
        cy = 5.0

    mask = np.full((10, 10), OTHER, dtype=np.uint8)
    fine, coarse, seen = vote_labels(
        points,
        [FakePose()],
        {1: FakeCam()},
        lambda name: mask,
        min_votes=1,
    )
    assert fine[0] == OTHER
    assert coarse[0] == OTHER
    assert seen[0] == 1


def test_dilate_and_expand() -> None:
    from lift import dilate_health_mask, expand_health_labels

    mask = np.zeros((9, 9), dtype=np.uint8)
    mask[4, 4] = HEALTHY
    grown = dilate_health_mask(mask, iterations=2)
    assert grown[4, 4] == HEALTHY
    assert grown[3, 4] == HEALTHY
    assert grown[0, 0] == OTHER

    points = np.array(
        [[0.0, 0.0, 0.0], [0.005, 0.0, 0.0], [1.0, 0.0, 0.0]],
        dtype=np.float64,
    )
    labels = np.array([HEALTHY, OTHER, OTHER], dtype=np.uint8)
    expanded = expand_health_labels(points, labels, radius=0.01, iterations=1)
    assert expanded[0] == HEALTHY
    assert expanded[1] == HEALTHY
    assert expanded[2] == OTHER


def test_health_mapping() -> None:
    assert health_id(25) == HEALTHY  # acropora alive
    assert health_id(4) == UNHEALTHY  # other coral bleached
    assert health_id(20) == UNHEALTHY  # branching dead
    assert health_id(5) == OTHER  # sand
    assert health_id(12) == OTHER  # unknown hard substrate
    from classes import map_fine_mask

    mapped = map_fine_mask(np.array([[25, 12], [4, 5]], dtype=np.uint8))
    assert mapped[0, 0] == HEALTHY
    assert mapped[0, 1] == OTHER
    assert mapped[1, 0] == UNHEALTHY
    assert mapped[1, 1] == OTHER


def test_prob_fusion_argmax() -> None:
    points = np.array([[0.0, 0.0, 1.0]])

    class FakePose:
        name = "a.jpg"
        camera_id = 1
        qvec = np.array([1.0, 0.0, 0.0, 0.0])
        tvec = np.array([0.0, 0.0, 0.0])

    class FakeCam:
        camera_id = 1
        model = "SIMPLE_PINHOLE"
        model_id = 0
        width = 10
        height = 10
        params = np.array([1.0, 5.0, 5.0])
        fx = 1.0
        fy = 1.0
        cx = 5.0
        cy = 5.0

    mask = np.full((10, 10), OTHER, dtype=np.uint8)
    probs = np.zeros((3, 10, 10), dtype=np.float32)
    probs[UNHEALTHY] = 0.55
    probs[OTHER] = 0.30
    probs[HEALTHY] = 0.15
    fine, coarse, seen = vote_labels(
        points,
        [FakePose()],
        {1: FakeCam()},
        lambda name: (mask, probs),
        min_votes=1,
    )
    assert coarse[0] == UNHEALTHY
    assert seen[0] == 1


def main() -> None:
    tests = [
        test_colmap_workspace,
        test_project_camera_center_is_invalid,
        test_umeyama_recovers_known_transform,
        test_invert_roundtrip,
        test_vote_majority,
        test_coral_beats_majority_other,
        test_ply_counts,
        test_other_stays_other,
        test_health_mapping,
        test_dilate_and_expand,
        test_prob_fusion_argmax,
    ]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    print("OK")


if __name__ == "__main__":
    main()
