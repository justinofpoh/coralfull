"""
Coral health segmenter -- construct and run the fine-tuned DINOv3-DPT
health-segmentation model (background / healthy coral / unhealthy coral).

    from segmenter import Segmenter

    segmenter = Segmenter("checkpoints/best_model.pt")
    result = segmenter.predict("path/to/image.jpg")

    result.mask          # (H, W) int64      -- class id per pixel
    result.probs         # (C, H, W) float32 -- per-class probability per pixel
    result.class_names   # {0: "other/background", 1: "healthy coral", 2: "unhealthy coral"}

See README.md for install / weights / usage instructions.
"""

from __future__ import annotations

import json
import importlib.util
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Union, Tuple

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image
from huggingface_hub import snapshot_download, hf_hub_download


# ============================================================
# Model identity / architecture constants
# ============================================================

BASE_REPO_ID = "EPFL-ECEO/coralscapes-vit-b-dpt"  # pretrained base this was fine-tuned from
ORIGINAL_NUM_CLASSES = 40                          # base model's class count (39 classes + unlabeled)
NUM_CLASSES = 3                                    # this fine-tuned model's class count

DEFAULT_CLASS_NAMES = {
    0: "other/background",
    1: "healthy coral",
    2: "unhealthy coral",
}

# Model input resolution. Must stay divisible by 16 (DINOv3 patch size).
# The full input image (any size) is resized to this for the forward pass,
# then every output is resized back to the image's ORIGINAL resolution
# before being returned. No cropping happens anywhere in this pipeline, so
# mask[y, x] / probs[:, y, x] always correspond to pixel (y, x) of the
# exact image you passed in -- no offset/scale bookkeeping needed when
# mapping back to source (e.g. COLMAP) image coordinates.
EVAL_SIZE: Tuple[int, int] = (1376, 768)  # (W, H)


# ============================================================
# Architecture construction
# ============================================================

def _replace_classification_head(
    model: nn.Module,
    new_num_classes: int,
    old_num_classes: int = ORIGINAL_NUM_CLASSES,
    head_name_hint: Optional[str] = None,
) -> nn.Module:
    """
    Swaps the base model's out_channels=40 output Conv2d for one with
    out_channels=new_num_classes. Found by searching for a Conv2d with
    out_channels == old_num_classes (for this base model this resolves to
    'seg_head.head.4').
    """
    candidates = [
        name for name, module in model.named_modules()
        if isinstance(module, nn.Conv2d) and module.out_channels == old_num_classes
    ]
    if not candidates:
        raise RuntimeError(
            f"Could not find a Conv2d layer with out_channels == {old_num_classes}. "
            "Inspect the model with print(model) and pass head_name_hint explicitly."
        )

    target_name = head_name_hint or candidates[-1]
    *parent_path, leaf_name = target_name.split(".")
    parent = model
    for p in parent_path:
        parent = getattr(parent, p)

    old_conv = getattr(parent, leaf_name)
    new_conv = nn.Conv2d(
        in_channels=old_conv.in_channels,
        out_channels=new_num_classes,
        kernel_size=old_conv.kernel_size,
        stride=old_conv.stride,
        padding=old_conv.padding,
        bias=old_conv.bias is not None,
    )
    setattr(parent, leaf_name, new_conv)
    return model


def build_model(device: torch.device) -> nn.Module:
    """
    Constructs the exact architecture the fine-tuned checkpoint was trained
    with: base EPFL-ECEO/coralscapes-vit-b-dpt (DINOv3 backbone + DPT head)
    with its final Conv2d swapped from 40 -> NUM_CLASSES outputs.

    Only builds the architecture (head weights are freshly initialized /
    random at this point) -- call load_finetuned_weights() to load the
    actual trained weights in, or just use the Segmenter class below which
    does both steps for you.
    """
    root = Path(snapshot_download(BASE_REPO_ID))

    spec = importlib.util.spec_from_file_location(
        "coralscapes_hub_model", root / "coralscapes_hub_model.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    model = mod.Dinov3DPTSegmenter.from_pretrained(root, map_location=device)
    model = _replace_classification_head(model, NUM_CLASSES)
    return model


def load_finetuned_weights(model: nn.Module, checkpoint_path: Union[str, Path], device: torch.device) -> nn.Module:
    state_dict = torch.load(str(checkpoint_path), map_location=device)
    model.load_state_dict(state_dict)
    return model


def _resolve_checkpoint(checkpoint: Union[str, Path]) -> Path:
    """
    Accepts either:
      - a local path, e.g. "checkpoints/best_model.pt"
      - a Hugging Face Hub reference, e.g. "hf://your-username/coral-health/best_model.pt"
        (downloads + caches it locally via huggingface_hub, then returns the local path)
    This is the mechanism for "externally hosted weights" -- upload
    best_model.pt to a model repo on the Hub (public or private) and point
    Segmenter at it with the hf:// form; no code changes needed elsewhere.
    """
    checkpoint_str = str(checkpoint)
    if checkpoint_str.startswith("hf://"):
        remainder = checkpoint_str[len("hf://"):]
        repo_id, _, filename = remainder.rpartition("/")
        if not repo_id or not filename:
            raise ValueError(
                "hf:// checkpoint must look like hf://<repo_id>/<filename>, "
                "e.g. hf://your-username/coral-health/best_model.pt"
            )
        return Path(hf_hub_download(repo_id=repo_id, filename=filename))
    return Path(checkpoint)


# ============================================================
# Result container
# ============================================================

@dataclass
class SegmentationResult:
    mask: np.ndarray    # (H, W) int64      -- class id per pixel, H,W == input image size
    probs: np.ndarray   # (C, H, W) float32 -- per-class probability, same H,W as mask
    class_names: dict   # {0: "other/background", 1: "healthy coral", 2: "unhealthy coral"}


# ============================================================
# Segmenter -- the main callable interface
# ============================================================

class Segmenter:
    def __init__(
        self,
        checkpoint: Union[str, Path],
        device: Optional[str] = None,
        eval_size: Tuple[int, int] = EVAL_SIZE,
        class_names: Optional[dict] = None,
    ):
        """
        checkpoint: local path to a .pt/.pth state_dict (e.g.
            "checkpoints/best_model.pt"), or "hf://<repo_id>/<filename>" to
            pull from the Hugging Face Hub. See README for details.
        device: "cuda" / "mps" / "cpu". Auto-detected if not given.
        class_names: override the default {0,1,2} -> name mapping. If a
            `label_map.json` file exists next to the checkpoint (the
            training script writes one automatically), it's loaded from
            there unless you pass class_names explicitly.
        """
        checkpoint_path = _resolve_checkpoint(checkpoint)
        if not checkpoint_path.exists():
            raise FileNotFoundError(
                f"Checkpoint not found at {checkpoint_path}. See README.md for how to "
                "obtain best_model.pt and where to place it, or use the hf:// form."
            )

        if device is not None:
            self.device = torch.device(device)
        elif torch.cuda.is_available():
            self.device = torch.device("cuda")
        else:
            # Avoid automatic MPS selection: CoralScapes DINOv3/DPT can abort
            # in Metal before Python has an opportunity to fall back safely.
            self.device = torch.device("cpu")

        self.eval_size = eval_size

        if class_names is not None:
            self.class_names = class_names
        else:
            label_map_path = checkpoint_path.parent / "label_map.json"
            if label_map_path.exists():
                with open(label_map_path) as f:
                    self.class_names = {int(k): v for k, v in json.load(f).items()}
            else:
                self.class_names = DEFAULT_CLASS_NAMES

        model = build_model(self.device)
        model = load_finetuned_weights(model, checkpoint_path, self.device)
        model.to(self.device)
        model.eval()
        self.model = model

        # Preprocessing (resize + normalization) is handled by the base
        # model's own `processor`, loaded as part of the base repo snapshot
        # inside build_model(). This is the authoritative source of
        # mean/std/resize behavior -- it's the same object used during
        # training, so predict() below matches training-time preprocessing
        # exactly. To inspect the exact numbers yourself:
        #   print(segmenter.processor.image_mean, segmenter.processor.image_std)
        self.processor = self.model.processor

    @torch.no_grad()
    def predict(self, image: Union[str, Path, Image.Image]) -> SegmentationResult:
        if isinstance(image, (str, Path)):
            image = Image.open(image).convert("RGB")
        else:
            image = image.convert("RGB")

        orig_w, orig_h = image.size

        # ---- preprocessing ----
        # Whole image resized (no cropping/padding) to eval_size, divisible
        # by 16 for the DINOv3 patch grid. Normalization is applied by
        # self.processor.
        image_resized = image.resize(self.eval_size, resample=Image.BILINEAR)
        pixel_values = self.processor(
            images=image_resized, return_tensors="pt", do_resize=False
        )["pixel_values"].to(self.device)

        # ---- inference ----
        logits = self.model(pixel_values)          # (1, C, Heval, Weval)
        probs_eval = F.softmax(logits, dim=1)[0]    # (C, Heval, Weval)

        # ---- resize back to the ORIGINAL input resolution ----
        # We resize the probabilities themselves (not just an already-taken
        # argmax), then derive the mask from those resized probs. That
        # keeps mask and probs mutually consistent, and keeps probs
        # meaningful for downstream multi-view fusion (e.g. averaging
        # per-pixel class probabilities across camera views before a final
        # argmax) rather than fusing already-discretized class ids.
        probs_full = F.interpolate(
            probs_eval.unsqueeze(0), size=(orig_h, orig_w), mode="bilinear", align_corners=False
        )[0]  # (C, H, W)

        mask_full = probs_full.argmax(dim=0).cpu().numpy().astype(np.int64)   # (H, W)
        probs_full = probs_full.cpu().numpy().astype(np.float32)               # (C, H, W)

        return SegmentationResult(mask=mask_full, probs=probs_full, class_names=self.class_names)
