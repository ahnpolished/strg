import wandb

ENTITY = "ahnpolished-ahnpolished"
PROJECT = "strg-model"

run = wandb.init(
    entity=ENTITY,
    project=PROJECT,
    job_type="upload-dataset",
    name="upload-test-data-v0",
)

artifact = wandb.Artifact(
    name="strg-test-data",
    type="dataset",
    description="STRG handwritten workout journal test set: images + JSON ground truth",
    metadata={
        "split": "test",
        "contains": ["images", "ground_truth_json"],
    },
)

artifact.add_dir("data/test", name="test")
run.log_artifact(artifact, aliases=["v0", "latest"])
run.finish()

print("Uploaded artifact:", f"{ENTITY}/{PROJECT}/strg-test-data:v0")
