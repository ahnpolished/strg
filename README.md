# strg

Train and serve ML models that extract structured workout data from handwritten journal photos.

## Repository Structure

```
strg/
├── model/                    # ML model codebase
│   ├── models/
│   │   ├── server/           # Server-side models (Qwen2-VL, InternVL2, etc.)
│   │   └── local/            # On-device models (moondream2, SmolVLM, etc.)
│   ├── packages/common/      # Shared Pydantic schema (WorkoutEntry, WorkoutPage)
│   ├── data/                 # Training, validation, and test datasets
│   ├── evaluation/           # CER + field-level accuracy evaluation harness
│   ├── infra/runpod/         # RunPod GPU infrastructure (Terraform + scripts)
│   ├── scripts/              # Utility scripts (install, upload, etc.)
│   ├── pyproject.toml        # Python workspace root (uv)
│   └── README.md             # Model-specific documentation
│
├── apps/
│   └── ios/                  # iOS app (Swift)
│       ├── strg-ios/         # Xcode project
│       └── README.md
│
├── .github/workflows/ci.yml  # CI pipeline
├── .gitignore
└── README.md
```

## Quick Start

### 1. Model Development

```bash
cd model
uv sync --all-packages
# Run evaluation on test set
uv run python -m evaluation.run --model qwen2-vl --predictions data/predictions/local --ground-truth data/test
```

### 2. Fine-tuning on RunPod

See `model/infra/runpod/README.md` and `model/CLAUDE.md`.

### 3. Serving API

```bash
cd model
uv sync --package models-server
export STRG_QWEN_LORA_CHECKPOINT=models/server/checkpoints/qwen2-vl-lora
uv run python -m models_server.serve
```

### 4. iOS App

Open `apps/ios/strg-ios/` in Xcode, configure server URL, build and run.

## Performance

| Metric | Baseline | Fine-tuned | Target |
|--------|----------|------------|--------|
| CER | 0.172 | **0.080** | ≤0.10 |
| Field Accuracy | 0.776 | **0.846** | ≥0.90 |
| Inference Latency (A40) | - | ~7s | - |

## Key Model

**Qwen2-VL-7B-Instruct** + QLoRA adapter (20MB). Fine-tuned on 100 synthetic images for 3 epochs.

## License

MIT
