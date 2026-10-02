"""Unchanged canary semantics: retain raw SVG artifact; never score it."""
from pathlib import Path
import argparse
def retain(answer: Path, artifact: Path) -> None:
    artifact.write_bytes(answer.read_bytes())
def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("answer", type=Path)
    parser.add_argument("--artifact", type=Path, required=True)
    args = parser.parse_args()
    retain(args.answer, args.artifact)
    print("UNGRADED")
    return 0
if __name__ == "__main__":
    raise SystemExit(main())
