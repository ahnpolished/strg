"""
QLoRA fine-tuning for Qwen2-VL-7B on the workout journal dataset.

Usage:
  uv run python -m models_server.finetune_qwen2_vl \
    --train-dir data/train \
    --val-dir data/val \
    --output-dir checkpoints/qwen2-vl \
    --epochs 3

Requirements: GPU with >=20GB VRAM; bitsandbytes, peft.
"""

import os

# Disable PyTorch compile/inductor to avoid background workers eating CPU.
os.environ.setdefault("TORCH_COMPILE", "0")
os.environ.setdefault("TORCHDYNAMO_ASYNC_COMPILATION", "0")
os.environ.setdefault("TORCHINDUCTOR_COMPILE_ONCE", "0")
os.environ.setdefault("PYTORCH_JIT", "0")
os.environ.setdefault("TORCH_COMPILE_DEBUG", "0")

import argparse
from pathlib import Path

import torch
from common.schema import WorkoutPage, load_page
from common.wandb_utils import WANDB_ENTITY, WANDB_PROJECT, _load_dotenv
from peft import LoraConfig, get_peft_model
from PIL import Image
from torch.utils.data import DataLoader, Dataset
from transformers import AutoProcessor, BitsAndBytesConfig, Qwen2VLForConditionalGeneration

import wandb
from models_server.prompt import EXTRACTION_PROMPT

MODEL_ID = "Qwen/Qwen2-VL-7B-Instruct"
LORA_CONFIG = LoraConfig(
    r=8,
    lora_alpha=16,
    target_modules=["q_proj", "k_proj", "v_proj", "o_proj"],
    lora_dropout=0.05,
    bias="none",
)


class WorkoutDataset(Dataset):
    def __init__(self, data_dir: Path, processor) -> None:
        self.samples = []
        for img_path in sorted(data_dir.glob("*.jpg")):
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
        target = page.model_dump_json()

        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "image", "image": image},
                    {"type": "text", "text": EXTRACTION_PROMPT},
                ],
            },
            {"role": "assistant", "content": target},
        ]
        text = self._processor.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=False
        )
        inputs = self._processor(text=[text], images=[image], return_tensors="pt", padding=True)
        input_ids = inputs["input_ids"].squeeze(0)
        labels = input_ids.clone()
        # Mask the prompt tokens so loss is only on the assistant answer
        prompt_only = self._processor.apply_chat_template(
            messages[:1], tokenize=False, add_generation_prompt=True
        )
        prompt_ids = self._processor(text=[prompt_only], return_tensors="pt")["input_ids"].squeeze(
            0
        )
        labels[: len(prompt_ids)] = -100
        return {
            "input_ids": input_ids,
            "attention_mask": inputs["attention_mask"].squeeze(0),
            "pixel_values": inputs["pixel_values"],
            "image_grid_thw": inputs.get("image_grid_thw"),
            "labels": labels,
        }


def collate_fn(batch):
    from torch.nn.utils.rnn import pad_sequence

    input_ids = pad_sequence([b["input_ids"] for b in batch], batch_first=True, padding_value=0)
    attention_mask = pad_sequence(
        [b["attention_mask"] for b in batch], batch_first=True, padding_value=0
    )
    labels = pad_sequence([b["labels"] for b in batch], batch_first=True, padding_value=-100)
    pixel_values = torch.cat([b["pixel_values"] for b in batch], dim=0)
    image_grid_thw = (
        torch.cat([b["image_grid_thw"] for b in batch], dim=0)
        if batch[0]["image_grid_thw"] is not None
        else None
    )
    return {
        "input_ids": input_ids,
        "attention_mask": attention_mask,
        "pixel_values": pixel_values,
        "image_grid_thw": image_grid_thw,
        "labels": labels,
    }


def evaluate(model, processor, val_loader, device) -> dict:
    from evaluation.metrics import FIELDS, evaluate_pages
    from models_server.qwen2_vl import _extract_json, _normalize_entries

    model.eval()
    all_cer, per_field = [], {f: [] for f in FIELDS}
    with torch.no_grad():
        for batch in val_loader:
            pixel_values = batch["pixel_values"].to(device, torch.bfloat16)
            image_grid_thw = batch["image_grid_thw"]
            if image_grid_thw is not None:
                image_grid_thw = image_grid_thw.to(device)
            # labels==-100 marks prompt tokens; slice only the prompt for generation
            # so we don't leak the ground-truth answer to the model
            labels = batch["labels"]
            prompt_mask = labels[0] == -100
            prompt_len = prompt_mask.sum().item()
            prompt_ids = batch["input_ids"][0, :prompt_len].unsqueeze(0).to(device)
            prompt_attn = batch["attention_mask"][0, :prompt_len].unsqueeze(0).to(device)
            try:
                output_ids = model.generate(
                    input_ids=prompt_ids,
                    attention_mask=prompt_attn,
                    pixel_values=pixel_values,
                    image_grid_thw=image_grid_thw,
                    max_new_tokens=1024,
                    do_sample=False,
                )
                generated = processor.batch_decode(
                    output_ids[:, prompt_ids.shape[1] :], skip_special_tokens=True
                )[0]
                data = _extract_json(generated)
                data = _normalize_entries(data)
                predicted = WorkoutPage.model_validate(data)
                # Reference: decode only the label tokens (the ground-truth answer)
                label_ids = labels[0][labels[0] != -100]
                reference_json = processor.decode(label_ids, skip_special_tokens=True)
                reference = WorkoutPage.model_validate_json(reference_json)
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
    parser.add_argument("--output-dir", default=Path("checkpoints/qwen2-vl"), type=Path)
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--lr", type=float, default=2e-4)
    parser.add_argument("--batch-size", type=int, default=1)
    parser.add_argument("--grad-accum", type=int, default=8)
    # With 100 images, batch_size=1, grad_accum=8 → ~13 gradient updates/epoch
    # eval_steps=100 means eval never fires during short training runs (<39 steps),
    # avoiding the slow val-set generation (20 images × ~1min each on A40).
    # The final eval at end-of-training (see main()) handles checkpoint saving.
    parser.add_argument("--eval-steps", type=int, default=100)
    parser.add_argument("--patience", type=int, default=5)
    args = parser.parse_args()

    _load_dotenv()
    run = wandb.init(
        entity=WANDB_ENTITY,
        project=WANDB_PROJECT,
        name="qwen2-vl-finetune",
        config=vars(args),
        tags=["phase:finetune", "model:qwen2-vl"],
    )

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_use_double_quant=True,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_compute_dtype=torch.bfloat16,
    )
    # Use fewer visual tokens during training to avoid CUDA OOM on A40 (44GB).
    # 256 min/max = minimum resolution; enough for synthetic training images.
    processor = AutoProcessor.from_pretrained(
        MODEL_ID, min_pixels=256 * 28 * 28, max_pixels=256 * 28 * 28
    )
    model = Qwen2VLForConditionalGeneration.from_pretrained(
        MODEL_ID,
        quantization_config=bnb_config,
        device_map="auto",
        torch_dtype=torch.bfloat16,
    )
    model.enable_input_require_grads()
    model.gradient_checkpointing_enable()
    model = get_peft_model(model, LORA_CONFIG)
    model.print_trainable_parameters()

    train_ds = WorkoutDataset(args.train_dir, processor)
    val_ds = WorkoutDataset(args.val_dir, processor)
    train_loader = DataLoader(
        train_ds, batch_size=args.batch_size, shuffle=True, collate_fn=collate_fn
    )
    val_loader = DataLoader(val_ds, batch_size=1, collate_fn=collate_fn)

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
            kwargs = (
                {"image_grid_thw": batch["image_grid_thw"].to(device)}
                if batch["image_grid_thw"] is not None
                else {}
            )

            outputs = model(
                input_ids=input_ids,
                attention_mask=attention_mask,
                pixel_values=pixel_values,
                labels=labels,
                **kwargs,
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
                metrics = evaluate(model, processor, val_loader, device)
                run.log({f"val/{k}": v for k, v in metrics.items()}, step=global_step)
                print(
                    f"Step {global_step}: val CER={metrics['avg_cer']:.4f} FieldAcc={metrics['macro_field_acc']:.4f}"
                )

                if metrics["macro_field_acc"] > best_field_acc:
                    best_field_acc = metrics["macro_field_acc"]
                    patience_counter = 0
                    ckpt_dir = args.output_dir / "best"
                    model.save_pretrained(ckpt_dir)
                    processor.save_pretrained(ckpt_dir)
                    art = wandb.Artifact("qwen2-vl-checkpoint", type="model")
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

    # Final eval + save at end of training (safety net if eval_steps never aligned)
    if global_step > 0 and (global_step % args.eval_steps != 0 or best_field_acc == 0.0):
        metrics = evaluate(model, processor, val_loader, device)
        run.log({f"val/{k}": v for k, v in metrics.items()}, step=global_step)
        print(
            f"Final eval: val CER={metrics['avg_cer']:.4f} FieldAcc={metrics['macro_field_acc']:.4f}"
        )
        if metrics["macro_field_acc"] > best_field_acc:
            best_field_acc = metrics["macro_field_acc"]
            ckpt_dir = args.output_dir / "best"
            model.save_pretrained(ckpt_dir)
            processor.save_pretrained(ckpt_dir)
            art = wandb.Artifact("qwen2-vl-checkpoint", type="model")
            art.add_dir(str(ckpt_dir))
            run.log_artifact(art)
            print(f"Final best: {best_field_acc:.4f} → saved to {ckpt_dir}")
        elif not (args.output_dir / "best").exists():
            # Still save something even if eval failed
            ckpt_dir = args.output_dir / "best"
            model.save_pretrained(ckpt_dir)
            processor.save_pretrained(ckpt_dir)
            print(f"No best checkpoint from eval — saving fallback to {ckpt_dir}")

    run.finish()
    print(f"Training complete. Best field accuracy: {best_field_acc:.4f}")


if __name__ == "__main__":
    main()
