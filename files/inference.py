"""
Command-line inference for the coral health segmenter.

Usage:
    python inference.py example.jpg
    python inference.py example.jpg --checkpoint checkpoints/best_model.pt
    python inference.py example.jpg --checkpoint hf://your-username/coral-health/best_model.pt
    python inference.py example.jpg --out result.png --save-npy
"""

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

from segmenter import Segmenter

# Visualization colors only -- not part of the model's output, just for
# the saved PNG so you can eyeball the mask.
CLASS_COLORS = {
    0: (60, 60, 60),    # other/background -> dark gray
    1: (0, 200, 0),      # healthy coral -> green
    2: (220, 30, 30),    # unhealthy coral -> red
}


def colorize(mask: np.ndarray) -> np.ndarray:
    h, w = mask.shape
    rgb = np.zeros((h, w, 3), dtype=np.uint8)
    for class_id, color in CLASS_COLORS.items():
        rgb[mask == class_id] = color
    return rgb


def main():
    parser = argparse.ArgumentParser(description="Run the coral health segmenter on a single image.")
    parser.add_argument("image", type=str, help="Path to the input image.")
    parser.add_argument(
        "--checkpoint", type=str, default="checkpoints/best_model.pt",
        help="Local path or hf://<repo_id>/<filename> reference to the fine-tuned weights.",
    )
    parser.add_argument("--out", type=str, default=None, help="Where to save the color mask PNG.")
    parser.add_argument("--save-npy", action="store_true", help="Also save raw mask.npy and probs.npy arrays.")
    args = parser.parse_args()

    segmenter = Segmenter(args.checkpoint)
    result = segmenter.predict(args.image)

    print(f"mask shape:  {result.mask.shape}   dtype: {result.mask.dtype}")
    print(f"probs shape: {result.probs.shape}   dtype: {result.probs.dtype}")

    total = result.mask.size
    print("\nClass breakdown:")
    for class_id, name in result.class_names.items():
        pct = (result.mask == class_id).sum() / total * 100
        print(f"  {class_id}  {name:20s} {pct:5.1f}%")

    image_path = Path(args.image)
    out_path = Path(args.out) if args.out else image_path.with_name(f"{image_path.stem}_mask.png")
    Image.fromarray(colorize(result.mask)).save(out_path)
    print(f"\nSaved color mask to {out_path}")

    if args.save_npy:
        mask_path = out_path.with_suffix(".mask.npy")
        probs_path = out_path.with_suffix(".probs.npy")
        np.save(mask_path, result.mask)
        np.save(probs_path, result.probs)
        print(f"Saved raw arrays to {mask_path} and {probs_path}")


if __name__ == "__main__":
    main()
