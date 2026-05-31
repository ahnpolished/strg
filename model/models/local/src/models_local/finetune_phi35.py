"""
QLoRA fine-tuning for Phi-3.5-Vision-Mini + CoreML export for iOS (HUM-1301).

Usage:
  # Fine-tune
  uv run python -m models_local.finetune_phi35 \
    --train-dir data/train \
    --val-dir data/train/val \
    --output-dir checkpoints/phi35

  # Export to CoreML (after fine-tuning)
  uv run python -m models_local.finetune_phi35 --export \
    --checkpoint checkpoints/phi35/best \
    --output-dir checkpoints/phi35/coreml

Requirements: GPU for fine-tuning; CoreML export works on macOS.
"""

import argparse
from pathlib import Path

import torch
from common.schema import WorkoutPage, load_page
from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT, _load_dotenv
from peft import LoraConfig, PeftModel, TaskType, get_peft_model
from PIL import Image
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForCausalLM, AutoProcessor, BitsAndBytesConfig

import wandb
from models_local.prompt import EXTRACTION_PROMPT

MODEL_ID = "microsoft/Phi-3.5-vision-instruct"
LORA_CONFIG = LoraConfig(
    task_type=TaskType.CAUSAL_LM,
    r=16,
    lora_alpha=32,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
    lora_dropout=0.05,
    bias="none",
)


class WorkoutDataset(Dataset):
    def __init__(self, data_dir: Path, processor) -> None:
        self.samples = []
        for img_path in sorted(data_dir.glob("**/*.jpg")):
            json_path = img_path.with_suffix(".json")
            if json_path.exists():
                self.samples.append((img_path, json_path))
        self._processor = processor

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, idx: int) -> dict:
        img_path, json_path = self.samples[idx]
        page = load_page(json_path)
        image = Image.open(img_path).convert("RGB")
        target_json = page.model_dump_json()
        prompt_text = f"<|image_1|>\n{EXTRACTION_PROMPT}\nAnswer: {target_json}"
        messages = [{"role": "user", "content": prompt_text}]
        full_prompt = self._processor.tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=False
        )
        encoding = self._processor(full_prompt, [image], return_tensors="pt")
        input_ids = encoding["input_ids"].squeeze(0)
        return {
            "pixel_values": encoding["pixel_values"].squeeze(0),
            "input_ids": input_ids,
            "attention_mask": encoding["attention_mask"].squeeze(0),
            "labels": input_ids.clone(),
        }


def train(args: argparse.Namespace) -> None:
    _load_dotenv()
    run = wandb.init(
        entity=WANDB_ENTITY,
        project=WANDB_PROJECT,
        name="phi35-finetune",
        config=vars(args),
        tags=["phase:finetune", "model:phi35"],
    )

    device = torch.device(
        "cuda"
        if torch.cuda.is_available()
        else "mps"
        if torch.backends.mps.is_available()
        else "cpu"
    )
    bnb_config = (
        BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_compute_dtype=torch.bfloat16,
        )
        if torch.cuda.is_available()
        else None
    )

    processor = AutoProcessor.from_pretrained(MODEL_ID, trust_remote_code=True, num_crops=4)
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID,
        trust_remote_code=True,
        quantization_config=bnb_config,
        torch_dtype=torch.bfloat16 if torch.cuda.is_available() else torch.float32,
        device_map="auto" if torch.cuda.is_available() else None,
        _attn_implementation="eager",
    )
    if not torch.cuda.is_available():
        model = model.to(device)

    model = get_peft_model(model, LORA_CONFIG)
    model.print_trainable_parameters()

    train_ds = WorkoutDataset(args.train_dir, processor)
    val_ds = WorkoutDataset(args.val_dir, processor)
    train_loader = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True)
    val_loader = DataLoader(val_ds, batch_size=1)

    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=len(train_loader) * args.epochs
    )

    best_field_acc = 0.0
    patience_counter = 0
    global_step = 0
    args.output_dir.mkdir(parents=True, exist_ok=True)

    for epoch in range(args.epochs):
        model.train()
        epoch_loss = 0.0
        optimizer.zero_grad()

        for step, batch in enumerate(train_loader):
            input_ids = batch["input_ids"].to(device)
            attention_mask = batch["attention_mask"].to(device)
            pixel_values = batch["pixel_values"].to(device)
            labels = batch["labels"].to(device)

            outputs = model(
                input_ids=input_ids,
                attention_mask=attention_mask,
                pixel_values=pixel_values,
                labels=labels,
            )
            loss = outputs.loss / args.grad_accum
            loss.backward()
            epoch_loss += loss.item() * args.grad_accum

            if (step + 1) % args.grad_accum == 0:
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()
                scheduler.step()
                optimizer.zero_grad()
                global_step += 1
                run.log({"train/loss": epoch_loss / (step + 1)}, step=global_step)

        # Eval at end of epoch
        metrics = _quick_eval(model, processor, val_loader, device)
        run.log({f"val/{k}": v for k, v in metrics.items()}, step=global_step)
        print(
            f"Epoch {epoch + 1}: val CER={metrics['avg_cer']:.4f}"
            f" FieldAcc={metrics['macro_field_acc']:.4f}"
        )

        if metrics["macro_field_acc"] > best_field_acc:
            best_field_acc = metrics["macro_field_acc"]
            patience_counter = 0
            ckpt = args.output_dir / "best"
            model.save_pretrained(ckpt)
            processor.save_pretrained(ckpt)
            art = wandb.Artifact("phi35-checkpoint", type="model")
            art.add_dir(str(ckpt))
            run.log_artifact(art)
        else:
            patience_counter += 1
            if patience_counter >= args.patience:
                print("Early stopping")
                break

    run.finish()
    print(f"Training done. Best field accuracy: {best_field_acc:.4f}")


def _quick_eval(model, processor, val_loader, device) -> dict:
    from evaluation.metrics import FIELDS, evaluate_pages

    model.eval()
    all_cer, per_field = [], {f: [] for f in FIELDS}
    with torch.no_grad():
        for batch in val_loader:
            try:
                input_ids = batch["input_ids"].to(device)
                pixel_values = batch["pixel_values"].to(device)
                out = model.generate(
                    input_ids=input_ids, pixel_values=pixel_values, max_new_tokens=512
                )
                text = processor.batch_decode(
                    out[:, input_ids.shape[1] :], skip_special_tokens=True
                )[0]
                predicted = WorkoutPage.model_validate_json(text.strip())
                ref_text = processor.tokenizer.decode(batch["labels"][0], skip_special_tokens=True)
                reference = WorkoutPage.model_validate_json(ref_text.split("Answer: ")[-1])
                result = evaluate_pages("val", predicted, reference)
                all_cer.append(result["avg_cer"])
                for f in FIELDS:
                    per_field[f].extend([r["match"] for r in result["rows"] if r["field"] == f])
            except Exception:
                all_cer.append(1.0)
    model.train()
    avg_cer = sum(all_cer) / len(all_cer) if all_cer else 1.0
    field_acc = {f: sum(v) / len(v) if v else 0.0 for f, v in per_field.items()}
    return {"avg_cer": avg_cer, "macro_field_acc": sum(field_acc.values()) / len(FIELDS)}


def export_coreml(args: argparse.Namespace) -> None:
    """Merge LoRA weights and export to CoreML for iOS deployment."""
    try:
        import coremltools as ct
    except ImportError:
        raise SystemExit("Install coremltools: uv add coremltools --package models-local")

    print(f"Loading base model + LoRA from {args.checkpoint}...")
    processor = AutoProcessor.from_pretrained(args.checkpoint, trust_remote_code=True, num_crops=4)
    base = AutoModelForCausalLM.from_pretrained(
        MODEL_ID, trust_remote_code=True, torch_dtype=torch.float32, _attn_implementation="eager"
    )
    model = PeftModel.from_pretrained(base, args.checkpoint)
    model = model.merge_and_unload()
    model.eval()
    print("LoRA weights merged.")

    # Trace the vision encoder for CoreML export
    sample_img = Image.new("RGB", (448, 448), color=(240, 240, 240))
    msgs = [{"role": "user", "content": "<|image_1|>\nTest"}]
    prompt = processor.tokenizer.apply_chat_template(
        msgs, tokenize=False, add_generation_prompt=True
    )
    inputs = processor(prompt, [sample_img], return_tensors="pt")
    pixel_values = inputs["pixel_values"]

    class VisionWrapper(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, x):
            return self.m.model.vision_embed_tokens(x)

    wrapper = VisionWrapper(model)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, pixel_values)

    coreml_model = ct.convert(
        traced,
        inputs=[ct.TensorType(name="pixel_values", shape=pixel_values.shape)],
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.iOS17,
    )
    out_path = args.output_dir / "phi35_vision_encoder.mlpackage"
    args.output_dir.mkdir(parents=True, exist_ok=True)
    coreml_model.save(str(out_path))
    print(f"CoreML model saved to {out_path}")
    print(
        "Note: full autoregressive text decoding must run via the HuggingFace model"
        " on-device or via CoreML LLM pipeline."
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--export", action="store_true")
    parser.add_argument("--train-dir", type=Path)
    parser.add_argument("--val-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("checkpoints/phi35"))
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--epochs", type=int, default=5)
    parser.add_argument("--lr", type=float, default=2e-4)
    parser.add_argument("--batch-size", type=int, default=2)
    parser.add_argument("--grad-accum", type=int, default=8)
    parser.add_argument("--patience", type=int, default=3)
    args = parser.parse_args()

    if args.export:
        export_coreml(args)
    else:
        train(args)


if __name__ == "__main__":
    main()
