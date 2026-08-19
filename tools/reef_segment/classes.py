"""3-class coral health labels used by the segmentation-branch model."""

from __future__ import annotations

# Matches files/segmenter.py DEFAULT_CLASS_NAMES
OTHER = 0
HEALTHY = 1
UNHEALTHY = 2

CLASS_NAMES = {
    OTHER: "other/background",
    HEALTHY: "healthy coral",
    UNHEALTHY: "unhealthy coral",
}

CLASS_COLORS = {
    OTHER: "#4b5563",
    HEALTHY: "#00c800",
    UNHEALTHY: "#dc1e1e",
}

# Coralscapes 39-class collapse used when the fine-tuned 3-class
# checkpoint is not on disk. Alive tissue -> healthy; dead/bleached -> unhealthy.
CORALSCAPES: dict[int, str] = {
    1: "seagrass",
    2: "trash",
    3: "other coral dead",
    4: "other coral bleached",
    5: "sand",
    6: "other coral alive",
    7: "human",
    8: "transect tools",
    9: "fish",
    10: "algae covered substrate",
    11: "other animal",
    12: "unknown hard substrate",
    13: "background",
    14: "dark",
    15: "transect line",
    16: "massive/meandering bleached",
    17: "massive/meandering alive",
    18: "rubble",
    19: "branching bleached",
    20: "branching dead",
    21: "millepora",
    22: "branching alive",
    23: "massive/meandering dead",
    24: "clam",
    25: "acropora alive",
    26: "sea cucumber",
    27: "turbinaria",
    28: "table acropora alive",
    29: "sponge",
    30: "anemone",
    31: "pocillopora alive",
    32: "table acropora dead",
    33: "meandering bleached",
    34: "stylophora alive",
    35: "sea urchin",
    36: "meandering alive",
    37: "meandering dead",
    38: "crown of thorn",
    39: "dead clam",
}

_HEALTHY = {
    "other coral alive",
    "massive/meandering alive",
    "branching alive",
    "millepora",
    "acropora alive",
    "turbinaria",
    "table acropora alive",
    "pocillopora alive",
    "stylophora alive",
    "meandering alive",
}
_UNHEALTHY = {
    name
    for name in CORALSCAPES.values()
    if "bleached" in name or name.endswith("dead") or " dead" in name
} - {"dead clam"}


def health_id(fine_id: int) -> int:
    name = CORALSCAPES.get(int(fine_id))
    if name in _HEALTHY:
        return HEALTHY
    if name in _UNHEALTHY:
        return UNHEALTHY
    return OTHER


def health_lut(size: int = 40) -> np.ndarray:
    import numpy as np

    lut = np.full(size, OTHER, dtype=np.uint8)
    for fine_id in range(size):
        lut[fine_id] = health_id(fine_id)
    return lut


def map_fine_mask(fine: np.ndarray) -> np.ndarray:
    import numpy as np

    lut = health_lut(max(40, int(fine.max()) + 1 if fine.size else 40))
    return lut[np.clip(fine, 0, len(lut) - 1)]
