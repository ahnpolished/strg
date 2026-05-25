# strg-model

Monorepo for training and evaluating ML models that extract structured workout data from handwritten journal photos.

## Structure

```
strg/
├── packages/common/     # Shared Pydantic schema (WorkoutEntry, WorkoutPage)
├── models/server/       # Server-side model experiments (Qwen2-VL, InternVL2, Florence-2, Donut)
├── models/local/        # Local/on-device model experiments (moondream2, SmolVLM, MiniCPM-V, Phi-3.5)
├── evaluation/          # Evaluation harness: CER + field-level accuracy, W&B logging
└── data/
    ├── test/            # 10-photo evaluation set (jpg + json ground truth per photo)
    └── train/           # Training set (90/10 split, versioned as W&B artifacts)
```

## Dev setup

```bash
uv sync --all-packages
pre-commit install
```

## Running evaluation

```bash
uv run python -m evaluation.run --model <name> --predictions data/predictions/<path> --ground-truth data/test
```

## Key decisions

- Output schema: `WorkoutPage` (list of `WorkoutEntry`) defined in `packages/common`
- Accuracy targets: field-level exact match >= 90% AND CER <= 10%
- Server model fine-tuning: QLoRA via HuggingFace PEFT
- Local model export: CoreML for iOS
- Experiment tracking: W&B project `strg-model`
