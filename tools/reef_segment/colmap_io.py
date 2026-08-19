"""Minimal COLMAP binary readers for cameras.bin / images.bin."""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

import numpy as np

# https://github.com/colmap/colmap/blob/main/src/colmap/sensor/models.h
CAMERA_MODELS = {
    0: ("SIMPLE_PINHOLE", 3),
    1: ("PINHOLE", 4),
    2: ("SIMPLE_RADIAL", 4),
    3: ("RADIAL", 5),
    4: ("OPENCV", 8),
    5: ("OPENCV_FISHEYE", 8),
    6: ("FULL_OPENCV", 12),
    7: ("FOV", 5),
    8: ("SIMPLE_RADIAL_FISHEYE", 4),
    9: ("RADIAL_FISHEYE", 5),
    10: ("THIN_PRISM_FISHEYE", 12),
}


@dataclass
class Camera:
    camera_id: int
    model_id: int
    width: int
    height: int
    params: np.ndarray

    @property
    def model(self) -> str:
        return CAMERA_MODELS[self.model_id][0]

    @property
    def fx(self) -> float:
        return float(self.params[0])

    @property
    def fy(self) -> float:
        if self.model in {"SIMPLE_PINHOLE", "SIMPLE_RADIAL", "SIMPLE_RADIAL_FISHEYE"}:
            return float(self.params[0])
        return float(self.params[1])

    @property
    def cx(self) -> float:
        if self.model in {"SIMPLE_PINHOLE", "SIMPLE_RADIAL", "SIMPLE_RADIAL_FISHEYE"}:
            return float(self.params[1])
        return float(self.params[2])

    @property
    def cy(self) -> float:
        if self.model in {"SIMPLE_PINHOLE", "SIMPLE_RADIAL", "SIMPLE_RADIAL_FISHEYE"}:
            return float(self.params[2])
        return float(self.params[3])

    @property
    def k1(self) -> float:
        if self.model in {"SIMPLE_RADIAL", "SIMPLE_RADIAL_FISHEYE", "RADIAL"}:
            return float(self.params[-1 if self.model != "RADIAL" else 4])
        if self.model == "SIMPLE_RADIAL":
            return float(self.params[3])
        if self.model == "RADIAL":
            return float(self.params[3])
        if self.model == "OPENCV":
            return float(self.params[4])
        return 0.0


@dataclass
class ImagePose:
    image_id: int
    camera_id: int
    name: str
    qvec: np.ndarray  # w, x, y, z
    tvec: np.ndarray


def qvec_to_rotmat(qvec: np.ndarray) -> np.ndarray:
    w, x, y, z = qvec
    return np.array(
        [
            [1 - 2 * y * y - 2 * z * z, 2 * x * y - 2 * z * w, 2 * x * z + 2 * y * w],
            [2 * x * y + 2 * z * w, 1 - 2 * x * x - 2 * z * z, 2 * y * z - 2 * x * w],
            [2 * x * z - 2 * y * w, 2 * y * z + 2 * x * w, 1 - 2 * x * x - 2 * y * y],
        ],
        dtype=np.float64,
    )


def read_cameras(path: Path) -> dict[int, Camera]:
    data = Path(path).read_bytes()
    num = struct.unpack_from("<Q", data, 0)[0]
    offset = 8
    cameras: dict[int, Camera] = {}
    for _ in range(num):
        camera_id, model_id = struct.unpack_from("<Ii", data, offset)
        offset += 8
        width, height = struct.unpack_from("<QQ", data, offset)
        offset += 16
        n_params = CAMERA_MODELS[model_id][1]
        params = np.array(struct.unpack_from("<" + "d" * n_params, data, offset), dtype=np.float64)
        offset += 8 * n_params
        cameras[camera_id] = Camera(camera_id, model_id, int(width), int(height), params)
    return cameras


def read_images(path: Path) -> list[ImagePose]:
    data = Path(path).read_bytes()
    num = struct.unpack_from("<Q", data, 0)[0]
    offset = 8
    images: list[ImagePose] = []
    for _ in range(num):
        image_id = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        qvec = np.array(struct.unpack_from("<4d", data, offset), dtype=np.float64)
        offset += 32
        tvec = np.array(struct.unpack_from("<3d", data, offset), dtype=np.float64)
        offset += 24
        camera_id = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        end = data.index(b"\x00", offset)
        name = data[offset:end].decode("utf-8")
        offset = end + 1
        n_points2d = struct.unpack_from("<Q", data, offset)[0]
        offset += 8 + n_points2d * 24  # x, y, point3D_id
        images.append(ImagePose(image_id, camera_id, name, qvec, tvec))
    return images


def project_points(points: np.ndarray, pose: ImagePose, camera: Camera) -> tuple[np.ndarray, np.ndarray]:
    """Project COLMAP-world points to pixel coordinates. Returns (uv, valid)."""
    rot = qvec_to_rotmat(pose.qvec)
    cam = (rot @ points.T).T + pose.tvec
    z = cam[:, 2]
    valid = z > 1e-6
    x = cam[:, 0] / np.clip(z, 1e-6, None)
    y = cam[:, 1] / np.clip(z, 1e-6, None)
    if camera.model in {"SIMPLE_RADIAL", "RADIAL"}:
        r2 = x * x + y * y
        k1 = float(camera.params[3])
        k2 = float(camera.params[4]) if camera.model == "RADIAL" else 0.0
        radial = 1.0 + k1 * r2 + k2 * r2 * r2
        x = x * radial
        y = y * radial
    u = camera.fx * x + camera.cx
    v = camera.fy * y + camera.cy
    uv = np.stack([u, v], axis=1)
    in_frame = (
        valid
        & (u >= 0)
        & (v >= 0)
        & (u < camera.width)
        & (v < camera.height)
    )
    return uv, in_frame
