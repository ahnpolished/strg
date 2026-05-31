# strg-model

ML model training and evaluation for extracting structured workout data from handwritten journal photos.

## Structure

```
model/
├── models/
│   ├── server/      # Server-side models (Qwen2-VL, InternVL2, etc.)
│   └── local/       # On-device models (moondream2, SmolVLM, etc.)
├── packages/common/ # Shared Pydantic schema (WorkoutEntry, WorkoutPage)
├── data/
│   ├── test/        # 22-photo evaluation set
│   └── train/       # Synthetic training images (100 + 20 val)
├── evaluation/      # CER + field-level accuracy evaluation
├── infra/runpod/    # RunPod GPU provisioning (Terraform)
├── scripts/         # Utility scripts
├── pyproject.toml   # Python workspace root (uv)
└── CLAUDE.md        # Handoff notes and detailed docs
```

## Setup

```bash
cd model
uv sync --all-packages
```

## Evaluation

```bash
uv run python -m evaluation.run --model qwen2-vl --predictions data/predictions/local --ground-truth data/test
```

## Fine-tuning on RunPod

See `infra/runpod/README.md` and `CLAUDE.md`.

## Serving

```bash
uv sync --package models-server
export STRG_QWEN_LORA_CHECKPOINT=models/server/checkpoints/qwen2-vl-lora
uv run python -m models_server.serve
```
