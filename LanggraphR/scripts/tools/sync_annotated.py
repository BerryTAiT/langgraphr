# sync_annotated.py - refresh every annotated Markdown code block from the
# current real file. Use this after hand-refining a generated file so the
# annotated sources stay in sync; afterwards extract_code.py is a no-op for
# those files. (One-time migration tool for the LanggraphR restructure.)
from pathlib import Path

repo_root = Path(__file__).resolve().parents[3]
pkg_dir = repo_root / "LanggraphR"
annotated_dir = pkg_dir / "00-project" / "annotated"


def find_target(text: str) -> str | None:
    marker = "<!-- TARGET:"
    pos = text.find(marker)
    if pos == -1:
        return None
    end = text.find("-->", pos)
    return text[pos + len(marker):end].strip()


def resolve_target(target: str) -> Path:
    if target.startswith(("langgraphr/", "LanggraphR/")):
        return pkg_dir / target.split("/", 1)[1]
    if target.startswith(("scripts/", "projects/scripts/")):
        rest = (target.split("/", 1)[1]
                if target.startswith("scripts/")
                else target[len("projects/scripts/"):])
        return pkg_dir / "scripts" / rest
    return repo_root / target


def main() -> None:
    updated = 0
    for md in sorted(annotated_dir.rglob("*.md")):
        text = md.read_text(encoding="utf-8")
        target = find_target(text)
        if target is None:
            continue
        src = resolve_target(target)
        if not src.exists():
            print(f"SKIP (missing source): {target}")
            continue
        lines = text.splitlines(keepends=True)
        fence_idxs = [i for i, ln in enumerate(lines) if ln.startswith("```")]
        if len(fence_idxs) < 2:
            print(f"SKIP (no fenced block): {md.name}")
            continue
        open_i, close_i = fence_idxs[0], fence_idxs[1]
        code = src.read_text(encoding="utf-8")
        if not code.endswith("\n"):
            code += "\n"
        new_text = "".join(lines[:open_i + 1] + [code] + lines[close_i:])
        if new_text != text:
            md.write_text(new_text, encoding="utf-8", newline="\n")
            print(f"updated {md.relative_to(pkg_dir)} <- {src.name}")
            updated += 1
    print(f"Done: {updated} annotated files refreshed.")


if __name__ == "__main__":
    main()
