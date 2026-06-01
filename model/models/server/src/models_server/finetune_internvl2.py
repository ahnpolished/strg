"""
QLoRA fine-tuning for InternVL2-8B on the workout journal dataset (HUM-1300).

Usage:
  uv run python -m models_server.finetune_internvl2 \
    --train-dir data/train \
    --val-dir data/train/val \
    --output-dir checkpoints/internvl2 \
    --epochs 5 \
    --eval-steps 50

Requirements: GPU with >=20GB VRAM (A100/H100 recommended), bitsandbytes, peft.
"""

import argparse
from pathlib import Path

import torch
import wandb
from common.schema import WorkoutPage, load_page
from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT, _load_dotenv
from peft import LoraConfig, TaskType, get_peft_model
from PIL import Image
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModel, AutoTokenizer, BitsAndBytesConfig

from models_server.prompt import EXTRACTION_PROMPT

MODEL_ID = "OpenGVLab/InternVL2-8B"
LORA_CONFIG = LoraConfig(
    task_type=TaskType.CAUSAL_LM,
    r=16,
    lora_alpha=32,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
    lora_dropout=0.05,
    bias="none",
)


class WorkoutDataset(Dataset):
    def __init__(self, data_dir: Path, tokenizer, processor) -> None:
        self.samples = []
        for img_path in sorted(data_dir.glob("**/*.jpg")):
            json_path = img_path.with_suffix(".json")
            if json_path.exists():
                self.samples.append((img_path, json_path))
        self._tokenizer = tokenizer
        self._processor = processor

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, idx: int) -> dict:
        img_path, json_path = self.samples[idx]
        page = load_page(json_path)
        image = Image.open(img_path).convert("RGB")
        target_json = page.model_dump_json()

        import torchvision.transforms as T
        from torchvision.transforms.functional import InterpolationMode

        transform = T.Compose(
            [
                T.Resize((448, 448), interpolation=InterpolationMode.BICUBIC),
                T.ToTensor(),
                T.Normalize(mean=(0.485, 0.456, 0.406), std=(0.229, 0.224, 0.225)),
            ]
        )
        pixel_values = transform(image).to(torch.bfloat16)

        prompt = f"{EXTRACTION_PROMPT}\n\nAnswer: {target_json}"
        encoding = self._tokenizer(prompt, truncation=True, max_length=512, return_tensors="pt")
        return {
            "pixel_values": pixel_values,
            "input_ids": encoding["input_ids"].squeeze(0),
            "attention_mask": encoding["attention_mask"].squeeze(0),
            "labels": encoding["input_ids"].squeeze(0).clone(),
        }


def evaluate(model, tokenizer, val_loader, device) -> dict:
    from evaluation.metrics import FIELDS, evaluate_pages

    model.eval()
    all_cer, per_field = [], {f: [] for f in FIELDS}
    with torch.no_grad():
        for batch in val_loader:
            pixel_values = batch["pixel_values"].to(device, torch.bfloat16)
            generation_config = {"max_new_tokens": 512, "do_sample": False}
            try:
                response = model.chat(tokenizer, pixel_values, EXTRACTION_PROMPT, generation_config)
                predicted = WorkoutPage.model_validate_json(response)
                reference = WorkoutPage.model_validate_json(
                    tokenizer.decode(batch["labels"][0], skip_special_tokens=True).split(
                        "Answer: "
                    )[-1]
                )
                result = evaluate_pages("val", predicted, reference)
                all_cer.append(result["avg_cer"])
                for f in FIELDS:
                    per_field[f].extend([r["match"] for r in result["rows"] if r["field"] == f])
            except Exception:
                all_cer.append(1.0)
    model.train()
    avg_cer = sum(all_cer) / len(all_cer) if all_cer else 1.0
    field_acc = {f: sum(v) / len(v) if v else 0.0 for f, v in per_field.items()}
    return {
        "avg_cer": avg_cer,
        "macro_field_acc": sum(field_acc.values()) / len(FIELDS),
        **field_acc,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--train-dir", required=True, type=Path)
    parser.add_argument("--val-dir", required=True, type=Path)
    parser.add_argument("--output-dir", default=Path("checkpoints/internvl2"), type=Path)
    parser.add_argument("--epochs", type=int, default=5)
    parser.add_argument("--lr", type=float, default=2e-4)
    parser.add_argument("--batch-size", type=int, default=2)
    parser.add_argument("--grad-accum", type=int, default=8)
    parser.add_argument("--eval-steps", type=int, default=50)
    parser.add_argument("--patience", type=int, default=3)
    args = parser.parse_args()

    _load_dotenv()
    run = wandb.init(
        entity=WANDB_ENTITY,
        project=WANDB_PROJECT,
        name="internvl2-finetune",
        config=vars(args),
        tags=["phase:finetune", "model:internvl2"],
    )

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_use_double_quant=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16,
    )
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, trust_remote_code=True)
    model = AutoModel.from_pretrained(
        MODEL_ID,
        quantization_config=bnb_config,
        device_map="auto",
        trust_remote_code=True,
    )
    model = get_peft_model(model, LORA_CONFIG)
    model.print_trainable_parameters()

    train_ds = WorkoutDataset(args.train_dir, tokenizer, None)
    val_ds = WorkoutDataset(args.val_dir, tokenizer, None)
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
            pixel_values = batch["pixel_values"].to(device, torch.bfloat16)
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

            if global_step > 0 and global_step % args.eval_steps == 0:
                metrics = evaluate(model, tokenizer, val_loader, device)
                run.log({f"val/{k}": v for k, v in metrics.items()}, step=global_step)
                print(
                    f"Step {global_step}: val CER={metrics['avg_cer']:.4f}"
                    f" FieldAcc={metrics['macro_field_acc']:.4f}"
                )

                if metrics["macro_field_acc"] > best_field_acc:
                    best_field_acc = metrics["macro_field_acc"]
                    patience_counter = 0
                    ckpt_dir = args.output_dir / "best"
                    model.save_pretrained(ckpt_dir)
                    tokenizer.save_pretrained(ckpt_dir)
                    art = wandb.Artifact("internvl2-checkpoint", type="model")
                    art.add_dir(str(ckpt_dir))
                    run.log_artifact(art)
                    print(f"  New best: {best_field_acc:.4f} → saved to {ckpt_dir}")
                else:
                    patience_counter += 1
                    if patience_counter >= args.patience:
                        print(f"Early stopping at step {global_step}")
                        run.finish()
                        return

        print(f"Epoch {epoch + 1}/{args.epochs} loss={epoch_loss / len(train_loader):.4f}")

    run.finish()
    print(f"Training complete. Best field accuracy: {best_field_acc:.4f}")


if __name__ == "__main__":
    main()
