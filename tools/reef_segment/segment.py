"""Coral health segmentation using the model on origin/segmentation."""

from __future__ import annotations

import importlib.util
import os
import sys
from pathlib import Path

import numpy as np
from PIL import Image

from classes import health_lut

REPO = Path(__file__).resolve().parents[2]
FILES = REPO / "files"
if str(FILES) not in sys.path:
    sys.path.insert(0, str(FILES))

from segmenter import BASE_REPO_ID, EVAL_SIZE, Segmenter  # noqa: E402

SEGFORMER_ID = "EPFL-ECEO/segformer-b2-finetuned-coralscapes-1024-1024"


def resolve_checkpoint() -> str | None:
    env = os.environ.get("CORAL_HEALTH_CHECKPOINT")
    if env:
        if env.startswith("hf://") or Path(env).exists():
            return env
    for path in (
        FILES / "checkpoints" / "best_model.pt",
        Path(__file__).resolve().parent / "checkpoints" / "best_model.pt",
    ):
        if path.exists():
            return str(path)
    return None


def _torch_device(torch, device: str | None):
    if device is not None:
        return torch.device(device)
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def _collapse_probs(fine_probs: np.ndarray, lut: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    health_probs = np.zeros((3, *fine_probs.shape[1:]), dtype=np.float32)
    for fine_id, group in enumerate(lut):
        if fine_id >= fine_probs.shape[0]:
            break
        health_probs[group] += fine_probs[fine_id]
    mask = health_probs.argmax(axis=0).astype(np.uint8)
    return mask, health_probs


class HealthSegmenter:
    """3-class healthy / unhealthy / other segmenter."""

    def __init__(self, checkpoint: str | Path | None = None, device: str | None = None):
        import torch

        self.torch = torch
        self._impl = None
        self._lut = health_lut()
        self.device = _torch_device(torch, device)
        requested = str(checkpoint) if checkpoint is not None else resolve_checkpoint()

        if requested is not None:
            print(f"using fine-tuned checkpoint {requested}", flush=True)
            self._impl = Segmenter(requested, device=str(self.device))
            self.backend = "finetuned"
            self.model_id = requested
            return

        try:
            print(f"loading {BASE_REPO_ID} and collapsing to 3 health classes", flush=True)
            self.model, self.processor = self._load_dpt(self.device)
            self.backend = "collapsed-dpt"
            self.model_id = BASE_REPO_ID
            return
        except Exception as error:
            print(f"DPT backbone unavailable ({error.__class__.__name__}: {error})", flush=True)
            print(f"falling back to {SEGFORMER_ID} collapsed to 3 health classes", flush=True)

        self.model, self.processor = self._load_segformer(self.device)
        self.backend = "collapsed-segformer"
        self.model_id = SEGFORMER_ID

    def _load_dpt(self, device):
        from huggingface_hub import snapshot_download

        root = Path(snapshot_download(BASE_REPO_ID))
        spec = importlib.util.spec_from_file_location(
            "coralscapes_hub_model", root / "coralscapes_hub_model.py"
        )
        assert spec is not None and spec.loader is not None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        model = mod.Dinov3DPTSegmenter.from_pretrained(root, map_location=device)
        model.to(device)
        model.eval()
        return model, model.processor

    def _load_segformer(self, device):
        from transformers import AutoImageProcessor, SegformerForSemanticSegmentation

        processor = AutoImageProcessor.from_pretrained(SEGFORMER_ID)
        model = SegformerForSemanticSegmentation.from_pretrained(SEGFORMER_ID)
        model.to(device)
        model.eval()
        return model, processor

    def predict(self, image_path: Path) -> tuple[np.ndarray, np.ndarray]:
        if self._impl is not None:
            result = self._impl.predict(image_path)
            return result.mask.astype(np.uint8), result.probs.astype(np.float32)

        if self.backend == "collapsed-dpt":
            return self._predict_dpt(image_path)
        return self._predict_segformer(image_path)

    def _predict_dpt(self, image_path: Path) -> tuple[np.ndarray, np.ndarray]:
        image = Image.open(image_path).convert("RGB")
        orig_w, orig_h = image.size
        resized = image.resize(EVAL_SIZE, resample=Image.BILINEAR)
        pixel_values = self.processor(
            images=resized, return_tensors="pt", do_resize=False
        )["pixel_values"].to(self.device)
        with self.torch.no_grad():
            logits = self.model(pixel_values)
            fine_probs = self.torch.nn.functional.softmax(logits, dim=1)
            fine_probs = self.torch.nn.functional.interpolate(
                fine_probs, size=(orig_h, orig_w), mode="bilinear", align_corners=False
            )[0].cpu().numpy()
        return _collapse_probs(fine_probs, self._lut)

    def _predict_segformer(self, image_path: Path) -> tuple[np.ndarray, np.ndarray]:
        image = Image.open(image_path).convert("RGB")
        orig_w, orig_h = image.size
        max_side = 1024
        scale = min(1.0, max_side / max(orig_w, orig_h))
        if scale < 1:
            image = image.resize(
                (max(1, int(orig_w * scale)), max(1, int(orig_h * scale))),
                resample=Image.BILINEAR,
            )
        inputs = self.processor(images=image, return_tensors="pt")
        inputs = {key: value.to(self.device) for key, value in inputs.items()}
        with self.torch.no_grad():
            logits = self.model(**inputs).logits
            fine_probs = self.torch.nn.functional.softmax(logits, dim=1)
            fine_probs = self.torch.nn.functional.interpolate(
                fine_probs, size=(orig_h, orig_w), mode="bilinear", align_corners=False
            )[0].cpu().numpy()
        return _collapse_probs(fine_probs, self._lut)

    def segment(self, image_path: Path) -> np.ndarray:
        mask, _probs = self.predict(image_path)
        return mask
