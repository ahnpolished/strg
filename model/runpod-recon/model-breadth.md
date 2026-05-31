# Read-only model breadth reconnaissance

Scope: inspected server model runners (`qwen2-vl`, `internvl2`, `florence2`, `donut`), runner registry, RunPod install/test scripts, dependencies, schema, evaluation constraints, and existing prediction/eval artifacts. No project/source files were modified.

## Executive recommendation

Fastest useful path beyond `qwen2-vl`:

1. **Prioritize `internvl2` as the next serious challenger.** Historical saved results on the first 10 pages are already near target and slightly better than `qwen2-vl` on CER: `internvl2` CER `0.0623`, macro field acc `0.8988`, parse errors `0`; `qwen2-vl` CER `0.1082`, macro field acc `0.8929` (`data/eval_results.json`). The likely RunPod blocker is not model logic but **`torchvision` being removed by the fast install script**, while `InternVL2Runner.predict()` imports `torchvision.transforms`.
2. **Make `florence2` the quickest smoke/breadth run**, because it is small and has no obvious install blocker in current server deps. It is unlikely to be competitive without parser work: existing saved results are CER `0.2095`, macro field acc `0.6522`, parse errors `2`.
3. **Make `donut` a low-cost smoke run after dependency/parser hardening.** It is small, but current zero-shot DocVQA JSON parsing is brittle and `sentencepiece` is not in the lock/deps. Existing saved results are CER `0.2251`, macro field acc `0.6146`, parse errors `4`.
4. **Before treating any new RunPod result as final, fix/evaluate the evaluation harness limitations**: it silently skips missing predictions and zips predicted/reference entries, so missing/extra rows are under-penalized. The current test set has **22 pages / 156 entries**, but saved server predictions only cover `001`-`010`; historical `data/eval_results.json` is therefore a partial old comparison, not a full current test-set result.

## Runner registry and execution path

- Registry/CLI is in `models/server/src/models_server/run.py`:
  - `MODEL_CHOICES = ["qwen2-vl", "internvl2", "florence2", "donut"]` at lines 12-12.
  - `_load_runner()` imports only the selected runner at lines 15-35. This is good: optional/dependent model imports do not break unrelated runs.
  - Batch output path is `args.output / args.model` at lines 55-56.
  - Summary tracks `photos_evaluated`, `parse_error_count`, latency, peak VRAM at lines 58-72.
- Base batch runner is in `models/server/src/models_server/base.py`:
  - Processes `*.jp*g` and `*.png` at line 25, so `.jpg` and `.jpeg` are included.
  - Any `predict()` exception is caught, logged, and converted to `WorkoutPage()` with `parse_error=True` at lines 27-34.
  - Empty-but-non-exception pages are **not** counted as parse errors.

## RunPod install/test constraints

- Server package deps (`models/server/pyproject.toml` lines 5-14): `common`, `torch>=2.0`, `transformers>=4.40,<5.0`, `pillow>=10.0`, `wandb>=0.16`, `accelerate>=0.26`, `timm`, `einops`.
- Lock currently resolves key packages to `transformers==4.57.6`, `torch==2.12.0`, `torchvision==0.27.0`, `timm==1.0.27`, `accelerate==1.13.0`, `wandb==0.27.0`.
- `scripts/runpod_install_fast.sh` is optimized for RunPod PyTorch images:
  - Syncs only `models-server` and `evaluation` in server mode (lines 22-27).
  - Creates `.venv` with `--system-site-packages` to reuse base image PyTorch/CUDA (lines 109-110).
  - Skips installing torch/CUDA packages including `torchvision` (lines 80-103).
  - Then explicitly uninstalls `torchvision` for non-local modes (lines 131-138) to avoid mismatched `torchvision::nms` import failures.
  - This helps Qwen/Florence, but is a direct problem for InternVL2.
- RunPod test script `infra/runpod/scripts/pod-tests.sh`:
  - Model selected by `STRG_TEST_MODEL`, default `qwen2-vl` (lines 24-28).
  - Runs `bash scripts/runpod_install_fast.sh server` (line 59).
  - Executes inference with `.venv/bin/python -m models_server.run --model "$MODEL" ...` (lines 97-103).
  - Evaluates with `.venv/bin/python -m evaluation.run` (lines 119-123).
  - Fails unless `avg_cer <= 0.10` and `macro_field_accuracy >= 0.90` (lines 152-168).
- RunPod infra defaults target low-cost 48GB first, then 24GB GPUs: A40, RTX A6000, RTX 3090, RTX A5000, RTX 4090, RTX 6000 Ada (`infra/runpod/variables.tf` lines 47-57). README says use fast install and avoid full workspace sync (`infra/runpod/README.md` lines 173-187).

## Schema and evaluation constraints

Schema (`packages/common/src/common/schema.py`):

- `WorkoutEntry`: `date: date | None`, required `exercise: str`, optional `sets`, `reps`, `weight_kg`, `weight_lbs`, `notes` (lines 7-14).
- `WorkoutPage.entries` default empty list (lines 17-18).
- `entries_to_text()` chooses `weight_kg` if present, else `weight_lbs` (lines 33-48).

Prompt (`models/server/src/models_server/prompt.py`):

- Requires JSON with `entries` array and fields including both `weight_kg` and `weight_lbs` (lines 4-17).
- Critical row rule: every physical row equals one entry, never merge rows (lines 19-23).
- Weight rule: kg/no unit goes to `weight_kg`; lbs goes to `weight_lbs`; do not convert (lines 32-33).
- Exercise must be copied exactly; no expanding abbreviations (line 30).

Evaluation (`evaluation/src/evaluation/run.py`, `evaluation/src/evaluation/metrics.py`):

- Fields exact-matched: date, exercise, sets, reps, weight_kg, weight_lbs, notes (`metrics.py` lines 11-23).
- Exercise/notes are case-insensitive stripped strings; numeric weights are exact float equality (`metrics.py` lines 13-19).
- `evaluate_pages()` only compares `zip(predicted.entries, reference.entries)` (`metrics.py` line 35), so extra/missing rows are not directly penalized except through omitted field rows.
- If a prediction file is missing, `evaluation.run` warns and skips it (`run.py` lines 32-37).
- If no files are evaluated, `avg_cer` becomes `0.0` (`run.py` line 50), but field accuracy is `0.0`; this can make CER misleading.
- Historical helper `data/run_all_evals.py` does count empty predictions as parse errors and skips missing prediction files (lines 23-32), but it is separate from the RunPod `evaluation.run` path.

Current `data/test` has 22 image/JSON pairs and 156 reference entries. Pages `011` and `022` include 19 total `weight_lbs` entries, so broadened current testing will exercise lbs handling more than the old 10-page saved predictions did.

## Per-model findings and likely fixes

### 1. `qwen2-vl`

File: `models/server/src/models_server/qwen2_vl.py`

- Model: `Qwen/Qwen2-VL-7B-Instruct` (line 156).
- Load: `AutoProcessor.from_pretrained`; `Qwen2VLForConditionalGeneration.from_pretrained(... torch_dtype=torch.bfloat16, device_map="auto")` (lines 158-164).
- Predict path uses chat template with PIL image and shared extraction prompt (lines 166-184).
- Robust shared helpers:
  - `_extract_json()` strips markdown fences, wraps bare arrays, tracks braces, and attempts truncated JSON recovery (lines 85-152).
  - `_normalize_entries()` normalizes date formats, list-to-scalar reps/sets/weights, default sets, kg/lbs conflicts, and bracketed notes (lines 14-82).

RunPod readiness: **best-known baseline; no obvious code/dependency blocker from inspected files.** Historical result is close but below target due CER `0.1082` and macro acc `0.8929`.

Likely fixes if improving later:

- Keep shared parser/normalizer as the baseline for other generative runners.
- Consider removing or gating `[DEBUG] raw output` after diagnosis (line 189), but this is not a run blocker.

### 2. `internvl2`

File: `models/server/src/models_server/internvl2.py`

- Model: `OpenGVLab/InternVL2-8B` (line 17).
- Load uses `AutoTokenizer` and `AutoModel` with `trust_remote_code=True`, bf16, `device_map="auto"` (lines 19-26).
- Predict imports `torchvision.transforms` and `InterpolationMode` inside `predict()` (lines 28-30), resizes to `448x448`, normalizes ImageNet stats, then calls `self._model.chat(...)` (lines 32-48).
- It reuses Qwen JSON extraction and normalization (lines 49-54).

RunPod readiness: **highest-value next model, but likely fails today in server-mode RunPod install** because `runpod_install_fast.sh` intentionally uninstalls `torchvision` for server mode (lines 131-138), and `InternVL2Runner.predict()` requires it.

Fastest likely code fix:

- Replace the `torchvision.transforms` dependency with a tiny PIL/numpy/torch preprocessing helper in `internvl2.py`: resize with bicubic to `(448, 448)`, convert to float tensor `[0,1]`, permute to CHW, normalize with `IMAGENET_MEAN/STD`, unsqueeze, cast bf16. `numpy` is already present transitively via Transformers/Torch stacks.
- Alternative: conditionally install a matching `torchvision` only for `STRG_TEST_MODEL=internvl2`, but this reintroduces the exact mismatch risk the install script is avoiding. Manual preprocessing is safer and faster.

Operational constraints:

- InternVL2-8B bf16 should fit 24GB+ for single-image inference in many cases; existing finetune doc says QLoRA training wants >=20GB VRAM and A100/H100 recommended for training, but inference is lighter.
- Historical saved results are near pass: likely worth running immediately after fixing preprocessing.

### 3. `florence2`

File: `models/server/src/models_server/florence2.py`

- Model: `microsoft/florence-2-large` (line 15).
- Load uses `AutoProcessor` and `AutoModelForCausalLM` with `trust_remote_code=True`, fp16, `device_map="auto"`, `attn_implementation="eager"` (lines 17-25).
- Predict runs only the fixed Florence OCR task `<OCR>` (lines 10-11, 27-59).
- Parser is a local heuristic over OCR lines (lines 62-112).

RunPod readiness: **probably easiest non-Qwen smoke run.** Server deps include likely Florence remote-code needs (`timm`, `einops`, `pillow`, Transformers). The install script comment explicitly says Florence/Qwen do not need torchvision for the baseline path.

Likely code fixes before treating results as meaningful:

- Remove or gate verbose debug prints in `predict()` (lines 31-44); not a crash blocker, but noisy on 22 pages.
- Do not default missing dates to `datetime.date.today()` (line 104); schema allows `None`, and defaulting to run date corrupts exact-match evaluation.
- Respect lbs schema: current parser converts lbs to kg (`weight_kg = val * 0.4536` at line 100), contradicting prompt/schema. It should set `weight_lbs=val` for lb units and not convert.
- Current heuristic only recognizes `sets x reps` and explicit `kg/lb`; many handwritten rows in pages 011-022 are single-set rows and lbs rows, so parser work will dominate metrics.
- Consider logging raw OCR text when `entries` is empty; currently empty pages are not counted as parse errors by `base.py` unless an exception occurs.

Expected outcome: good for confirming infrastructure/model breadth quickly; unlikely to pass thresholds without OCR parser improvements or a second structured parse model.

### 4. `donut`

File: `models/server/src/models_server/donut.py`

- Model: `naver-clova-ix/donut-base-finetuned-docvqa` (line 17).
- Load uses `DonutProcessor` and `VisionEncoderDecoderModel`, fp16 on CUDA if available (lines 29-35).
- Prompt asks for JSON fields `date, exercise, sets, reps, weight_kg, notes` but **omits `weight_lbs`** (lines 19-23).
- Predict decodes, strips special tokens/tags, and immediately `json.loads(sequence)` then validates (lines 60-65).

RunPod readiness: **small model, but likely dependency/parser fragile.** `sentencepiece` is not present in `uv.lock` or `models-server` deps; Donut/XLM-R tokenizer loading may require it depending on tokenizer path. Even if load succeeds, zero-shot DocVQA often returns non-JSON/natural answer text, and current parser turns that into exceptions/empty pages.

Fastest likely fixes:

- Add tokenizer dependency if load fails on RunPod: most likely `sentencepiece` (and keep `protobuf` available via existing deps/transitives). Because RunPod install uses `uv sync --frozen`, update the lock if dependency metadata changes.
- Update `_QUESTION` to include `weight_lbs` and the same no-conversion schema rule.
- Reuse Qwen’s `_extract_json()` and `_normalize_entries()` around the decoded sequence instead of raw `json.loads(sequence)`.
- Preserve/print the raw decoded answer when parsing fails; otherwise every failure becomes an empty `WorkoutPage` with limited diagnosis.

Expected outcome: useful breadth smoke due low VRAM/download cost; not a likely pass candidate without fine-tuning or much stronger output parsing.

## Existing saved results caveats

Existing `data/predictions/server/*` contains only `001.json`-`010.json` per server model. `data/test` now contains `001`-`022`, so old `data/eval_results.json` is only a partial comparison.

Historical partial server results:

| Model | CER | Macro field acc | Parse errors | Notes |
|---|---:|---:|---:|---|
| qwen2-vl | 0.1082 | 0.8929 | 0 | Closest baseline, just misses both thresholds. |
| internvl2 | 0.0623 | 0.8988 | 0 | Best next candidate; misses field acc by ~0.0012 on old set. |
| florence2 | 0.2095 | 0.6522 | 2 | Runs as OCR+heuristic; parser bottleneck. |
| donut | 0.2251 | 0.6146 | 4 | Zero-shot DocVQA JSON is brittle. |

## Suggested RunPod sequence after fixes

1. **Shared sanity:** keep using `infra/runpod/scripts/pod-tests.sh` with `TF_VAR_env='{"STRG_TEST_MODEL":"<model>"}'` or equivalent env injection. Keep `WANDB_MODE=disabled` behavior unless an API key is present.
2. **Run `florence2` smoke first** if the objective is simply non-Qwen breadth with minimal blockers. It should validate registry, install, HF cache, and evaluation quickly.
3. **Fix InternVL2 preprocessing and run `internvl2` next.** This is the most likely model to beat/replace Qwen quickly.
4. **Harden Donut deps/parser and run `donut` last.** Treat as breadth data, not near-term pass candidate.
5. **For honest full-set comparisons**, address evaluation row-count/missing-file penalties or at least report `photos_evaluated`, missing predictions, empty pages, and total reference/predicted entry counts alongside CER/accuracy.

## Validation checks to run when edits are allowed

Targeted local/import checks:

```bash
.venv/bin/python - <<'PY'
import importlib
for m in [
    'models_server.run',
    'models_server.qwen2_vl',
    'models_server.internvl2',
    'models_server.florence2',
    'models_server.donut',
]:
    importlib.import_module(m)
    print(m, 'OK')
PY
```

RunPod per-model command path:

```bash
export TF_VAR_env='{"STRG_TEST_MODEL":"internvl2"}'  # or florence2/donut
bash infra/runpod/scripts/test-loop.sh --iterations 1 --iteration-timeout 1200 --log-file infra/runpod/logs/<model>.log
```

Expected success criteria from pod script:

- Inference completes without fatal install/import/model crash.
- Evaluation emits JSON with `evaluated_photos > 0`.
- Pass only if `avg_cer <= 0.10` and `macro_field_accuracy >= 0.90`.

## High-risk items / decisions for next planner

- **InternVL2 dependency decision:** prefer removing `torchvision` use from runner over changing RunPod install to keep/install torchvision.
- **Evaluation correctness:** current metrics can understate row-count failures. Decide whether breadth reconnaissance should only smoke-run models or should first fix scoring semantics.
- **Full-set vs historical comparability:** full current test set is 22 pages with many more rows and lbs examples; do not compare full RunPod metrics directly to `data/eval_results.json` without noting the dataset difference.
- **Donut dependency:** if RunPod load fails, add `sentencepiece` and lock it; if load succeeds, parser/zero-shot behavior remains the main issue.
