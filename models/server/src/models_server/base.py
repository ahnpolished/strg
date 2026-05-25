import time
from abc import ABC, abstractmethod
from pathlib import Path

from common.schema import WorkoutPage, dump_page


class ServerModelRunner(ABC):
    model_id: str

    @abstractmethod
    def load(self) -> None: ...

    @abstractmethod
    def predict(self, image_path: Path) -> WorkoutPage: ...

    def run_batch(
        self,
        image_dir: Path,
        output_dir: Path,
    ) -> list[dict]:
        output_dir.mkdir(parents=True, exist_ok=True)
        results = []
        for img_path in sorted(image_dir.glob("*.jp*g")) + sorted(image_dir.glob("*.png")):
            t0 = time.perf_counter()
            try:
                page = self.predict(img_path)
                parse_error = False
            except Exception as e:
                print(f"[ERROR] {img_path.stem}: {e}")
                page = WorkoutPage()
                parse_error = True
            latency = time.perf_counter() - t0
            out_path = output_dir / f"{img_path.stem}.json"
            dump_page(page, out_path)
            results.append(
                {
                    "photo_id": img_path.stem,
                    "latency_s": latency,
                    "parse_error": parse_error,
                    "entry_count": len(page.entries),
                }
            )
            print(f"  {img_path.stem}: {latency:.2f}s, {len(page.entries)} entries, error={parse_error}")
        return results
