# W&B and predictions reconnaissance

Read-only reconnaissance performed on 2026-05-27. I did not modify project/source files; this report is the requested output artifact. I intentionally did **not** read or print `.env` contents. Local W&B metadata was summarized without API keys/secrets.

## Executive summary

- W&B project/entity are hard-coded in `packages/common/src/common/wandb_utils.py`: entity `ahnpolished-ahnpolished`, project `strg-model`.
- Evaluation logging is centered on `evaluation.run`: it logs scalar summary metrics plus a W&B Table named `predictions` with rows of `photo_id, field, predicted, ground_truth, match`.
- Inference predictions are normal JSON files written under `data/predictions/...` (or `/workspace/strg/data/predictions/...` on RunPod). W&B Tables duplicate field-level comparisons, but are not the canonical full prediction JSONs.
- Local W&B runs exist under `wandb/` and include multiple evaluation runs with local table JSONs in `wandb/run-*/files/media/table/*.table.json`.
- There is no W&B Trace API instrumentation in this repo; “trace” data available locally is ordinary W&B run metadata/logs plus table artifacts.
- Important caveat: `evaluation.run` currently compares `zip(predicted.entries, reference.entries)`, so missing/extra entries are ignored in per-field rows; empty predictions can produce no rows and `avg_cer=0.0` for that photo. Use raw prediction JSON + entry counts alongside W&B tables when debugging failures.

## W&B utilities and logging paths

### Common W&B helper

`packages/common/src/common/wandb_utils.py`

- Lines 6-7 set `WANDB_ENTITY = "ahnpolished-ahnpolished"` and `WANDB_PROJECT = "strg-model"`.
- Lines 10-23 define `init_run(model_name, phase, config, tags)`:
  - calls `_load_dotenv()`;
  - starts `wandb.init(entity=..., project=..., name=f"{model_name}-{phase}")`;
  - attaches tags `phase:<phase>` and `model:<model_name>`.
- Lines 26-32 define `log_prediction_table(run, rows)`:
  - W&B table columns: `photo_id`, `field`, `predicted`, `ground_truth`, `match`;
  - logs it as key `predictions`.
- Lines 35-44 implement `_load_dotenv()` by reading repo-root `.env` and setting environment variables only if not already present. Treat `.env` as secret material.

### Evaluation logging

`evaluation/src/evaluation/run.py`

- CLI args: `--model`, `--predictions`, `--ground-truth`, `--phase`.
- For each `*.json` in ground truth, it expects a same-named prediction file in `--predictions`.
- Missing prediction file: prints `[WARN] No prediction found for <photo_id>, skipping`.
- It computes:
  - `avg_cer`
  - `macro_field_accuracy`
  - `field_accuracy`
  - `latency_p50`, `latency_p95` for JSON load/eval time only
  - `evaluated_photos`
- Lines 67-70 always initialize W&B, log the `predictions` table, update summary, and finish.

`evaluation/src/evaluation/metrics.py`

- Fields: `date`, `exercise`, `sets`, `reps`, `weight_kg`, `weight_lbs`, `notes`.
- Field matching rules:
  - exact for date/sets/reps/weights;
  - lower/strip normalization for `exercise` and `notes`.
- Rows are generated per matched predicted/reference entry pair via `zip(predicted.entries, reference.entries)`.

### Server/local inference logging

`models/server/src/models_server/run.py`

- Writes predictions to `args.output / args.model`.
- With `--ground-truth`, it launches `python -m evaluation.run ... --predictions <output_dir>` and does not create its own inference W&B summary run.
- Without `--ground-truth`, it logs only inference summary scalars and tags `phase:<phase>`, `model:<model>`, `inference:server`.

`models/local/src/models_local/run.py`

- Same shape as server runner, except model choices are local models and it logs `peak_ram_gb` plus tag `inference:local` when no ground truth is provided.

### RunPod behavior

`infra/runpod/scripts/pod-tests.sh`

- Defaults:
  - `WORKSPACE=/workspace/strg`
  - `STRG_TEST_MODEL=qwen2-vl`
  - `STRG_TEST_IMAGES=/workspace/strg/data/test`
  - `STRG_GROUND_TRUTH=/workspace/strg/data/test`
  - `STRG_PREDICTIONS=/workspace/strg/data/predictions`
- If `WANDB_API_KEY` is unset, it exports `WANDB_MODE=disabled` to avoid interactive login.
- It runs inference first without `--ground-truth`, then explicitly runs `evaluation.run` with `WANDB_SILENT=true` so W&B stdout does not pollute captured metric JSON.
- `infra/runpod/scripts/test-loop.sh` forwards `WANDB_API_KEY` to SSH only if set. Avoid echoing this command or key into shared logs.

## Where predictions are stored

Canonical predictions are `WorkoutPage` JSON files:

```json
{"entries": [{"date": "2026-01-06", "exercise": "Bench Press", "sets": 4, "reps": 8, "weight_kg": 80.0, "weight_lbs": null, "notes": "PR!"}]}
```

Defined by `packages/common/src/common/schema.py`.

Storage rules:

- Server inference: `models_server.run --output data/predictions/server --model qwen2-vl` writes to `data/predictions/server/qwen2-vl/<photo_id>.json`.
- Local inference: `models_local.run --output data/predictions/local --model phi35` writes to `data/predictions/local/phi35/<photo_id>.json`.
- RunPod default: `/workspace/strg/data/predictions/<model>/<photo_id>.json` because `pod-tests.sh` calls server runner with `--output "$PREDICTIONS"` and `MODEL` is a server model name.
- `evaluation.run --predictions` must point at the model-specific directory that directly contains `001.json`, `002.json`, etc.
- `data/predictions/` is gitignored, as is `wandb/`.

Current local prediction dirs found:

| Prediction dir | JSON files | Total entries | Empty pages | Bad JSON |
|---|---:|---:|---:|---:|
| `data/predictions/server/qwen2-vl` | 10 | 28 | 0 | 0 |
| `data/predictions/server/internvl2` | 10 | 28 | 0 | 0 |
| `data/predictions/server/florence2` | 10 | 23 | 2 | 0 |
| `data/predictions/server/donut` | 10 | 16 | 4 | 0 |
| `data/predictions/local/moondream` | 22 | 78 | 2 | 0 |
| `data/predictions/local/smolvlm` | 10 | 26 | 1 | 0 |
| `data/predictions/local/minicpm` | 10 | 28 | 0 | 0 |
| `data/predictions/local/phi35` | 10 | 26 | 1 | 0 |

`data/eval_results.json` is a saved aggregate generated by `data/run_all_evals.py`; it is useful for a quick model comparison but does not include per-image/per-field rows.

## Local W&B metadata/artifacts found

Local W&B root: `wandb/` (gitignored). `latest-run` points to `run-20260527_194232-vb38oepx`.

| Run dir | Program/args | Summary | Local table |
|---|---|---|---|
| `run-20260525_190924-p47bj099` | `-m models_local.run --model moondream --images data/test --output data/predictions/local --phase baseline` | 22 photos, 2 parse errors, p50 latency ~30.73s, p95 ~74.47s, peak RAM ~0.08GB | none |
| `run-20260525_201517-s463opfu` | `scripts/upload_wandb_artifact.py` | dataset artifact upload run | none |
| `run-20260527_194214-0cbfuewm` | `evaluation.run --model server/qwen2-vl --predictions data/predictions/server/qwen2-vl --ground-truth data/test --phase local-audit` | CER 0.1040, macro field acc 0.9082, evaluated 10 | `files/media/table/predictions_0_5933353e9db39a4c356a.table.json` |
| `run-20260527_194218-t1ku3mhn` | `evaluation.run --model server/internvl2 --predictions data/predictions/server/internvl2 --ground-truth data/test --phase local-audit` | CER 0.0599, macro field acc 0.9133, evaluated 10 | `files/media/table/predictions_0_b2ededc97c76c4e12c9f.table.json` |
| `run-20260527_194221-bkvyrt36` | `evaluation.run --model server/florence2 --predictions data/predictions/server/florence2 --ground-truth data/test --phase local-audit` | CER 0.1585, macro field acc 0.7019, evaluated 10 | `files/media/table/predictions_0_1fd98a4c34088bd7e91f.table.json` |
| `run-20260527_194225-y2189jp7` | `evaluation.run --model server/donut --predictions data/predictions/server/donut --ground-truth data/test --phase local-audit` | CER 0.1282, macro field acc 0.6696, evaluated 10 | `files/media/table/predictions_0_d88ba49bddd40715d833.table.json` |
| `run-20260527_194229-p80pqe5n` | `evaluation.run --model local/smolvlm --predictions data/predictions/local/smolvlm --ground-truth data/test --phase local-audit` | CER 0.2368, macro field acc 0.6484, evaluated 10 | `files/media/table/predictions_0_69c6599a4bd9d6aa1576.table.json` |
| `run-20260527_194232-vb38oepx` | `evaluation.run --model local/phi35 --predictions data/predictions/local/phi35 --ground-truth data/test --phase local-audit` | CER 0.0551, macro field acc 0.8846, evaluated 10 | `files/media/table/predictions_0_d4c843cb3e96ee0516c5.table.json` |

The local W&B table JSONs contain only columns/data for field comparisons; they do not contain full images or raw model responses.

### Existing table failure summaries

| Run/model | Rows | Mismatches | Worst fields | Worst photos |
|---|---:|---:|---|---|
| server/qwen2-vl | 196 | 18 | exercise 6, notes 5, weight_kg 4, reps 3 | 009, 007, 004/005/010 |
| server/internvl2 | 196 | 17 | sets 6, reps 4, exercise 3, weight_kg 2, notes 2 | 010, 003, 005/009 |
| server/florence2 | 161 | 48 | sets 12, exercise 10, weight_kg 10, reps 9, notes 7 | 001/002/007/009 |
| server/donut | 112 | 37 | weight_kg 10, reps 8, exercise 7, notes 7, sets 5 | 007, 002, 001 |
| local/smolvlm | 182 | 64 | reps 14, weight_kg 13, notes 13, exercise 12, sets 12 | 003/004/007, 001 |
| local/phi35 | 182 | 21 | reps 7, sets 5, weight_kg 4, notes 4, exercise 1 | 003/004, 001/005/009 |

## How to debug per-image/per-field failures

### In W&B UI

1. Open project `ahnpolished-ahnpolished/strg-model`.
2. Choose a run tagged/selected by model and phase, e.g. `server/internvl2-local-audit` or `local/phi35-local-audit` depending on how W&B renders slash-containing names.
3. Open the `predictions` table.
4. Filter `match == false`.
5. Group/sort by `field` to see systematic failures, or by `photo_id` to identify difficult images.
6. Cross-reference the same `photo_id` in:
   - prediction JSON: `data/predictions/<family>/<model>/<photo_id>.json`
   - ground truth: `data/test/<photo_id>.json`
   - image: `data/test/<photo_id>.jpg|jpeg|png`

### From local W&B table JSONs

Example safe local analysis, no API key needed:

```bash
python - <<'PY'
import json, pathlib, collections
for table in pathlib.Path('wandb').glob('run-*/files/media/table/*.table.json'):
    payload = json.loads(table.read_text())
    rows = [dict(zip(payload['columns'], r)) for r in payload['data']]
    misses = [r for r in rows if not r['match']]
    print('\n', table)
    print('misses by field:', collections.Counter(r['field'] for r in misses))
    print('misses by photo:', collections.Counter(r['photo_id'] for r in misses).most_common(5))
    print('examples:', misses[:5])
PY
```

### From canonical prediction JSONs

Use this when entry counts or parse failures matter:

```bash
python - <<'PY'
import json, pathlib
for d in sorted(pathlib.Path('data/predictions').glob('*/*')):
    if not d.is_dir():
        continue
    files = sorted(d.glob('*.json'))
    empties = []
    for f in files:
        entries = json.loads(f.read_text()).get('entries', [])
        if not entries:
            empties.append(f.stem)
    print(d, 'files=', len(files), 'empty_pages=', empties)
PY
```

## Artifacts and datasets

- `scripts/upload_wandb_artifact.py` uploads `data/test` as W&B artifact `ahnpolished-ahnpolished/strg-model/strg-test-data:v0` with images + ground-truth JSON.
- `scripts/download_wandb_artifact.py` downloads that artifact into `artifacts/strg-test-data-v0` and copies files into `data/test`.
- `data/collect_training.py push --version v1` logs `data/train` as artifact `train-dataset`.
- Fine-tuning scripts log model checkpoint artifacts:
  - `internvl2-checkpoint`
  - `phi35-checkpoint`
- No local `artifacts/` directory was present during this recon.

## Secret-safe W&B usage guidance

- Do not paste or commit `WANDB_API_KEY`. `.env` is gitignored; `.env.example` only contains `WANDB_API_KEY=your_api_key_here`.
- Prefer setting `WANDB_API_KEY` in the environment/secret manager, or use interactive `wandb login` without printing the key.
- On RunPod, let `pod-tests.sh` disable W&B automatically when `WANDB_API_KEY` is absent. For read-only local evals, use `WANDB_MODE=disabled` if you do not want W&B writes.
- Use `WANDB_SILENT=true` when scripts capture stdout JSON, as `pod-tests.sh` already does.
- Do not share raw `wandb/debug*.log`, `wandb-metadata.json`, or `.wandb` binary files without review; local metadata includes hostnames, usernames, filesystem paths, emails, git remotes, and command args. I did not see API keys in the inspected metadata, but logs can contain sensitive environment-derived details.
- W&B tables contain predicted and ground-truth workout content. Treat them as dataset-derived artifacts even though they do not contain API secrets.
- `wandb/`, `data/predictions/`, and `.env` are already gitignored.

## Implementation/validation risks observed

- `evaluation.run` can undercount failure modes because it zips predicted/reference entries and does not penalize missing/extra entries directly.
- Empty prediction pages can result in no field rows and `avg_cer=0.0` from `evaluate_pages`; `data/run_all_evals.py` and `data/evaluate_finetuned.py` are stricter because they count/skip empty pages as parse errors.
- `evaluation.run` does not catch invalid prediction JSON; a malformed prediction can abort the eval instead of being represented as a parse error.
- Latency in `evaluation.run` is JSON load/evaluation latency, not model inference latency. Inference latency is logged by `models_server.run` / `models_local.run` summaries.
- Raw model responses are generally not persisted in W&B tables. Some runners print short `[DEBUG] raw output: ...` snippets during inference, but evaluation runs do not include raw generation text.
