import shutil
from pathlib import Path

import wandb

ENTITY = "ahnpolished-ahnpolished"
PROJECT = "strg-model"
ARTIFACT = f"{ENTITY}/{PROJECT}/strg-test-data:v0"

run = wandb.init(
    entity=ENTITY,
    project=PROJECT,
    job_type="download-dataset",
    name="download-test-data-v0",
)

artifact = run.use_artifact(ARTIFACT, type="dataset")
artifact_dir = Path(artifact.download(root="artifacts/strg-test-data-v0"))

src = artifact_dir / "test"
dst = Path("data/test")
dst.mkdir(parents=True, exist_ok=True)

for p in src.iterdir():
    if p.is_file():
        shutil.copy2(p, dst / p.name)

run.finish()

print("Copied files to", dst)
print(
    "images:",
    len(list(dst.glob(".jpg"))) + len(list(dst.glob(".jpeg"))) + len(list(dst.glob("*.png"))),
)
print("json:", len(list(dst.glob("*.json"))))
