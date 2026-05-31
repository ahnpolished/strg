import os
from pathlib import Path

import wandb

WANDB_ENTITY = "ahnpolished-ahnpolished"
WANDB_PROJECT = "strg-model"


def init_run(
    model_name: str,
    phase: str,
    config: dict | None = None,
    tags: list[str] | None = None,
) -> wandb.sdk.wandb_run.Run:
    _load_dotenv()
    return wandb.init(
        entity=WANDB_ENTITY,
        project=WANDB_PROJECT,
        name=f"{model_name}-{phase}",
        config=config or {},
        tags=(tags or []) + [f"phase:{phase}", f"model:{model_name}"],
    )


def log_prediction_table(
    run: wandb.sdk.wandb_run.Run,
    rows: list[dict],
) -> None:
    columns = ["photo_id", "field", "predicted", "ground_truth", "match"]
    table = wandb.Table(columns=columns, data=[[r[c] for c in columns] for r in rows])
    run.log({"predictions": table})


def _load_dotenv() -> None:
    env_path = Path(__file__).parents[5] / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))
