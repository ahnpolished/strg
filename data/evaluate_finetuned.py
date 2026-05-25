"""
Post-fine-tune evaluation and iteration script (HUM-1302).

Evaluates both fine-tuned models against the 90% accuracy target and
produces a final W&B report comparing baseline → fine-tuned delta.

Usage:
  # Run full comparison (requires checkpoints from HUM-1300 and HUM-1301)
  uv run python data/evaluate_finetuned.py \
    --server-checkpoint checkpoints/internvl2/best \
    --local-checkpoint checkpoints/phi35/best \
    --baseline-results data/eval_results.json

  # Dry-run using saved prediction directories (no checkpoint needed)
  uv run python data/evaluate_finetuned.py \
    --server-preds data/predictions/finetuned/internvl2 \
    --local-preds data/predictions/finetuned/phi35 \
    --baseline-results data/eval_results.json
"""
import argparse
import json
from pathlib import Path

import wandb

from common.schema import WorkoutPage, load_page
from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT, _load_dotenv
from evaluation.metrics import FIELDS, evaluate_pages

TARGET_FIELD_ACC = 0.90
TARGET_CER = 0.10
GT_DIR = Path("data/test")


def evaluate_predictions(pred_dir: Path, model_name: str) -> dict:
    all_cer, per_field = [], {f: [] for f in FIELDS}
    parse_errors = 0

    for gt_path in sorted(GT_DIR.glob("*.json")):
        pred_path = pred_dir / gt_path.name
        if not pred_path.exists():
            continue
        reference = load_page(gt_path)
        predicted = load_page(pred_path)
        if not predicted.entries:
            parse_errors += 1
            continue
        result = evaluate_pages(gt_path.stem, predicted, reference)
        all_cer.append(result["avg_cer"])
        for f in FIELDS:
            per_field[f].extend([r["match"] for r in result["rows"] if r["field"] == f])

    n = len(all_cer)
    avg_cer = sum(all_cer) / n if n else 1.0
    field_acc = {f: sum(v) / len(v) if v else 0.0 for f, v in per_field.items()}
    macro = sum(field_acc.values()) / len(FIELDS)
    return {
        "model": model_name,
        "avg_cer": round(avg_cer, 4),
        "macro_field_acc": round(macro, 4),
        "parse_errors": parse_errors,
        **{f"acc_{f}": round(field_acc[f], 3) for f in FIELDS},
    }


def run_model_inference(checkpoint: Path, model_name: str, out_dir: Path) -> Path:
    """Run the appropriate fine-tuned model on the test set and return prediction dir."""
    import torch
    from PIL import Image

    pred_dir = out_dir / model_name
    pred_dir.mkdir(parents=True, exist_ok=True)

    if model_name == "internvl2":
        from transformers import AutoModel, AutoTokenizer
        from peft import PeftModel
        from models_server.prompt import EXTRACTION_PROMPT

        tokenizer = AutoTokenizer.from_pretrained(checkpoint, trust_remote_code=True)
        base = AutoModel.from_pretrained(
            "OpenGVLab/InternVL2-8B",
            torch_dtype=torch.bfloat16,
            device_map="auto",
            trust_remote_code=True,
        ).eval()
        model = PeftModel.from_pretrained(base, checkpoint).merge_and_unload()

    elif model_name == "phi35":
        from transformers import AutoModelForCausalLM, AutoProcessor
        from peft import PeftModel
        from models_local.prompt import EXTRACTION_PROMPT

        processor = AutoProcessor.from_pretrained(checkpoint, trust_remote_code=True, num_crops=4)
        base = AutoModelForCausalLM.from_pretrained(
            "microsoft/Phi-3.5-vision-instruct",
            trust_remote_code=True,
            torch_dtype=torch.float32,
            _attn_implementation="eager",
        )
        model = PeftModel.from_pretrained(base, checkpoint).merge_and_unload().eval()

    for img_path in sorted(GT_DIR.glob("*.jpg")):
        try:
            image = Image.open(img_path).convert("RGB")
            if model_name == "internvl2":
                import torchvision.transforms as T
                from torchvision.transforms.functional import InterpolationMode
                transform = T.Compose([
                    T.Resize((448, 448), interpolation=InterpolationMode.BICUBIC),
                    T.ToTensor(),
                    T.Normalize(mean=(0.485, 0.456, 0.406), std=(0.229, 0.224, 0.225)),
                ])
                pixel_values = transform(image).unsqueeze(0).to(torch.bfloat16)
                response = model.chat(tokenizer, pixel_values, EXTRACTION_PROMPT, {"max_new_tokens": 512})
            else:
                msgs = [{"role": "user", "content": f"<|image_1|>\n{EXTRACTION_PROMPT}"}]
                prompt = processor.tokenizer.apply_chat_template(msgs, tokenize=False, add_generation_prompt=True)
                inputs = processor(prompt, [image], return_tensors="pt")
                out = model.generate(**inputs, max_new_tokens=512)
                response = processor.batch_decode(out[:, inputs["input_ids"].shape[1]:], skip_special_tokens=True)[0]

            page = WorkoutPage.model_validate_json(response.strip())
        except Exception as e:
            print(f"  [WARN] {img_path.stem}: {e}")
            page = WorkoutPage()

        from common.schema import dump_page
        dump_page(page, pred_dir / f"{img_path.stem}.json")

    return pred_dir


def print_comparison(baseline: dict, finetuned: dict, model_name: str) -> None:
    print(f"\n{'='*50}")
    print(f"  {model_name} — Baseline vs Fine-tuned")
    print(f"{'='*50}")
    b = baseline.get(model_name, {})
    f = finetuned
    print(f"  CER:        {b.get('avg_cer','?'):>8} → {f['avg_cer']:>8}  (target ≤{TARGET_CER})")
    print(f"  FieldAcc:   {b.get('macro_field_acc','?'):>8} → {f['macro_field_acc']:>8}  (target ≥{TARGET_FIELD_ACC})")
    print(f"  ParseErr:   {b.get('parse_errors','?'):>8} → {f['parse_errors']:>8}")

    meets_target = f["avg_cer"] <= TARGET_CER and f["macro_field_acc"] >= TARGET_FIELD_ACC
    print(f"\n  {'✓ TARGET MET' if meets_target else '✗ TARGET NOT MET — see failure modes below'}")

    if not meets_target:
        print("\n  Worst fields:")
        field_scores = {k.replace("acc_", ""): v for k, v in f.items() if k.startswith("acc_")}
        for field, acc in sorted(field_scores.items(), key=lambda x: x[1]):
            flag = " ← " if acc < TARGET_FIELD_ACC else ""
            print(f"    {field:<12}: {acc:.3f}{flag}")
        print("\n  Remediation checklist:")
        print("    1. Collect more labeled samples for the worst-performing fields")
        print("    2. Adjust prompt (add examples for ambiguous fields like 'notes')")
        print("    3. Increase LoRA rank (r=32) or fine-tune more layers")
        print("    4. Check annotation quality — low GT accuracy contaminates training")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server-checkpoint", type=Path)
    parser.add_argument("--local-checkpoint", type=Path)
    parser.add_argument("--server-preds", type=Path)
    parser.add_argument("--local-preds", type=Path)
    parser.add_argument("--baseline-results", type=Path, default=Path("data/eval_results.json"))
    parser.add_argument("--output-dir", type=Path, default=Path("data/predictions/finetuned"))
    args = parser.parse_args()

    baseline = {}
    if args.baseline_results.exists():
        raw = json.loads(args.baseline_results.read_text())
        baseline = {
            "internvl2": raw.get("server/internvl2", {}),
            "phi35": raw.get("local/phi35", {}),
        }

    # Server model
    if args.server_preds:
        server_results = evaluate_predictions(args.server_preds, "internvl2")
    elif args.server_checkpoint:
        pred_dir = run_model_inference(args.server_checkpoint, "internvl2", args.output_dir)
        server_results = evaluate_predictions(pred_dir, "internvl2")
    else:
        print("[SKIP] No server checkpoint or predictions provided")
        server_results = None

    # Local model
    if args.local_preds:
        local_results = evaluate_predictions(args.local_preds, "phi35")
    elif args.local_checkpoint:
        pred_dir = run_model_inference(args.local_checkpoint, "phi35", args.output_dir)
        local_results = evaluate_predictions(pred_dir, "phi35")
    else:
        print("[SKIP] No local checkpoint or predictions provided")
        local_results = None

    # Print comparison
    if server_results:
        print_comparison(baseline, server_results, "internvl2")
    if local_results:
        print_comparison(baseline, local_results, "phi35")

    # Log to W&B
    _load_dotenv()
    run = wandb.init(
        entity=WANDB_ENTITY,
        project=WANDB_PROJECT,
        name="post-finetune-comparison",
        tags=["phase:post-finetune", "report"],
    )
    if server_results:
        run.log({f"server_finetuned/{k}": v for k, v in server_results.items() if isinstance(v, (int, float))})
        run.log({f"server_baseline/{k}": v for k, v in baseline.get("internvl2", {}).items() if isinstance(v, (int, float))})
    if local_results:
        run.log({f"local_finetuned/{k}": v for k, v in local_results.items() if isinstance(v, (int, float))})
        run.log({f"local_baseline/{k}": v for k, v in baseline.get("phi35", {}).items() if isinstance(v, (int, float))})
    run.finish()
    print("\nW&B report logged.")


if __name__ == "__main__":
    main()
