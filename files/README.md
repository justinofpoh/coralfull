# Coral Health Segmenter

Fine-tuned from the pretrained [`EPFL-ECEO/coralscapes-vit-b-dpt`](https://huggingface.co/EPFL-ECEO/coralscapes-vit-b-dpt)
(DINOv3 backbone + DPT segmentation head) on the
[Coralscapes](https://huggingface.co/datasets/EPFL-ECEO/coralscapes) dataset, with the
original 39 fine-grained classes collapsed to 3 health classes.

## 1. Install dependencies

```bash
pip install -r requirements.txt
```

Requires Python 3.10+. Tested with the package versions pinned in `requirements.txt`;
if you hit compatibility issues, match whatever `torch`/`huggingface_hub` versions you
used during training, since those are what the checkpoint was produced with.

Note: `datasets` is **not** required for inference-only use (only needed if you also
want to re-run the training/eval scripts against the Coralscapes dataset itself).

## 2. Get the weights

`best_model.pt` is produced by the training script (`coralscapes_health_finetune.py`)
and is **not** included in this package — it's produced locally on whatever machine you
trained on. Two ways to make it available here:

**Option A -- local file.** Copy `checkpoints/best_model.pt` (and the `label_map.json`
saved alongside it) from your training run into a `checkpoints/` folder next to these
scripts:

```
coral_segmenter/
├── segmenter.py
├── inference.py
├── requirements.txt
├── README.md
└── checkpoints/
    ├── best_model.pt
    └── label_map.json
```

**Option B -- host it externally, reference by URL-like string.** Upload
`best_model.pt` to a model repo on the Hugging Face Hub (public or private) and point
at it directly — no code changes needed:

```python
segmenter = Segmenter("hf://your-username/coral-health/best_model.pt")
```

```bash
python inference.py example.jpg --checkpoint hf://your-username/coral-health/best_model.pt
```

This downloads and caches the file locally the first time, then reuses the cache.

## 3. Run inference

**Command line:**

```bash
python inference.py example.jpg
```

Optional flags: `--checkpoint <path or hf://...>`, `--out result.png`, `--save-npy`
(also dumps raw `mask.npy` / `probs.npy` arrays alongside the PNG).

**Python API:**

```python
from segmenter import Segmenter

segmenter = Segmenter("checkpoints/best_model.pt")
result = segmenter.predict("path/to/image.jpg")   # also accepts a PIL.Image directly

result.mask          # (H, W) int64
result.probs         # (C, H, W) float32
result.class_names   # {0: "other/background", 1: "healthy coral", 2: "unhealthy coral"}

class_id = result.mask[y, x]
class_probs = result.probs[:, y, x]
```

## 4. Class mapping

| ID | Meaning |
|----|---------|
| 0  | other / background / non-coral (sand, rubble, fish, water, transect gear, etc.) |
| 1  | healthy coral (living tissue) |
| 2  | unhealthy coral (dead or bleached) |

This is the health remapping applied on top of Coralscapes' original 39 classes during
fine-tuning — see `segmenter.py`'s `DEFAULT_CLASS_NAMES` / the training script for the
exact original-class → health-class mapping. Note this covers only "alive vs.
dead/bleached" — it does **not** distinguish disease, cyanobacteria, scarring types,
physical damage, or coral-killing sponge, since the base dataset has no labels for
those (see project notes on the stage-2 extension plan).

If `label_map.json` exists next to your checkpoint (written automatically by the
training script), `Segmenter` loads class names from there instead of the default —
useful if you retrain with a different class set later.

## 5. Input / output format

**Input:** any RGB image, any resolution — pass a file path, `Path`, or a `PIL.Image`
directly. No resizing/cropping/format conversion needed on your end.

**Output:** a `SegmentationResult` with:
- `mask`: `(H, W)` `int64` array, one class id per pixel.
- `probs`: `(C, H, W)` `float32` array, softmax class probabilities per pixel. `C = 3`.
- `class_names`: `{int: str}` mapping.

**H, W always match your input image's original resolution exactly** — the model
internally resizes to 1376×768 for the forward pass, but every output is resized back
up before being returned. No cropping is performed anywhere in the pipeline, so
`mask[y, x]` / `probs[:, y, x]` correspond directly to pixel `(y, x)` of the image you
passed in — no offset or scale bookkeeping is needed when mapping predictions back to
source image coordinates (e.g. for COLMAP-based multi-view fusion).

`mask` is derived as `argmax(probs)` on the *resized* (full-resolution) probabilities,
not from a separately-resized argmax — so `mask` and `probs` are always mutually
consistent. This also means `probs` (not just `mask`) is the right thing to pass into
any multi-view fusion step: average/weight per-pixel probabilities across views, then
take the argmax at the end, rather than fusing already-discretized class ids.

## 6. Preprocessing details

- **Resize:** whole image resized (bilinear, no cropping/padding) to 1376×768 before
  being fed to the model. This size is fixed because DINOv3 requires dimensions
  divisible by 16 (its patch size).
- **Normalization / mean-std:** handled by the base model's own `processor` object
  (loaded automatically as part of the pretrained model snapshot) — this is the exact
  same object used during training, so there's no separate config to keep in sync. To
  inspect the literal numbers:
  ```python
  print(segmenter.processor.image_mean, segmenter.processor.image_std)
  ```
- **Cropping/padding:** none. The only difference between your input image's aspect
  ratio and the model's fixed 1376×768 input is a non-aspect-preserving resize (matching
  how the original Coralscapes eval script does it) — this is undone symmetrically when
  results are resized back to your original image's exact `(H, W)` before being returned.

## 7. Sample run

```bash
python inference.py example.jpg
```

Expected console output looks like:

```
mask shape:  (1024, 2048)   dtype: int64
probs shape: (3, 1024, 2048)   dtype: float32

Class breakdown:
  0  other/background     71.4%
  1  healthy coral        22.1%
  2  unhealthy coral       6.5%

Saved color mask to example_mask.png
```
