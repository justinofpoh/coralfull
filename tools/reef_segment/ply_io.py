"""Binary little-endian Gaussian splat PLY helpers."""

from __future__ import annotations

from pathlib import Path

import numpy as np


def read_header(data: bytes) -> tuple[int, list[str], int]:
    marker = b"end_header\n"
    end = data.find(marker)
    if end < 0:
        raise ValueError("PLY header is missing end_header")
    header = data[:end].decode("utf-8", errors="replace")
    properties: list[str] = []
    vertex_count = 0
    reading = False
    for line in header.splitlines():
        if line.startswith("element vertex "):
            vertex_count = int(line.split()[-1])
            reading = True
        elif line.startswith("element "):
            reading = False
        elif reading and line.startswith("property float "):
            properties.append(line.split()[-1])
    return vertex_count, properties, end + len(marker)


def read_centers(path: Path) -> np.ndarray:
    data = Path(path).read_bytes()
    count, properties, body_start = read_header(data)
    needed = ["x", "y", "z"]
    for name in needed:
        if name not in properties:
            raise ValueError(f"PLY is missing {name}")
    body = np.frombuffer(data, dtype=np.float32, offset=body_start)
    stride = len(properties)
    if body.size < count * stride:
        raise ValueError("PLY body is truncated")
    vertices = body[: count * stride].reshape(count, stride)
    idx = [properties.index(name) for name in needed]
    return np.ascontiguousarray(vertices[:, idx], dtype=np.float64)
