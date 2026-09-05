# extract_code.py - generate the real project files from annotated Markdown.
#
# Every real source file in this repo is pre-written inside
# 00-project/annotated/<family>/<name>.md as a fenced code block. Each MD
# carries an HTML comment that says which file it becomes:
#
#     <!-- TARGET: langgraphr/R/client.R -->
#
# Run this script after editing any annotated MD to regenerate the real files:
#
#     python scripts/tools/extract_code.py
#
# Rule (see 00-project/04-file-tree.md): never hand-edit generated files;
# edit the annotated MD and re-run this script.

# The 'pathlib' module gives us clean cross-platform path handling.
from pathlib import Path

# repo_root is the folder two levels above this script (scripts/tools/.. = repo).
repo_root = Path(__file__).resolve().parents[2]

# annotated_dir is where all the annotated Markdown files live.
annotated_dir = repo_root / "00-project" / "annotated"


def find_target(text: str) -> str | None:
    """Return the TARGET path declared in an HTML comment, or None."""
    # The marker we search for: <!-- TARGET: some/path/file.ext -->.
    marker = "<!-- TARGET:"
    # Look for the marker inside the markdown text.
    pos = text.find(marker)
    # No marker means this MD is not a code file; return None.
    if pos == -1:
        return None
    # Find the end of the comment line (closing -->).
    end = text.find("-->", pos)
    # A malformed comment means we cannot trust the file.
    if end == -1:
        raise ValueError(f"unterminated TARGET comment in {text[:80]!r}")
    # Slice out just the path between the marker and the comment end.
    raw = text[pos + len(marker):end].strip()
    # Return the cleaned target path.
    return raw


def extract_code_block(text: str) -> str:
    """Return the content of the FIRST fenced code block in the text."""
    # Every annotated code MD has exactly one fenced block.
    first = text.find("```")
    # No fence means there is no code to extract.
    if first == -1:
        raise ValueError("no fenced code block found")
    # The fence runs for exactly three backticks; find its end.
    first_end = text.find("\n", first) + 1
    # Locate the closing fence (next ``` sequence).
    closing = text.find("```", first_end)
    # A missing closing fence is a broken MD; fail loudly.
    if closing == -1:
        raise ValueError("unterminated fenced code block")
    # Return everything between the opening and closing fences.
    return text[first_end:closing]


def main() -> None:
    """Walk every annotated MD and write its code block to the target path."""
    # Count how many files we generate (for the summary message).
    generated = 0
    # Recursively find every .md file under the annotated directory.
    for md in sorted(annotated_dir.rglob("*.md")):
        # Read the whole markdown file as text.
        text = md.read_text(encoding="utf-8")
        # Resolve which real file this MD should become.
        target = find_target(text)
        # Skip MD files that are not code carriers (no TARGET marker).
        if target is None:
            continue
        # Compute the absolute output path under the repository root.
        out_path = repo_root / target
        # Extract the fenced code block content.
        code = extract_code_block(text)
        # Create every parent directory of the output file.
        out_path.parent.mkdir(parents=True, exist_ok=True)
        # Write the extracted code to the real file location.
        out_path.write_text(code, encoding="utf-8")
        # Announce what we generated.
        print(f"generated {target}")
        # Count this file.
        generated += 1
    # Print the total number of files generated.
    print(f"Done: {generated} files generated.")


# Run the generator when this script is executed directly.
if __name__ == "__main__":
    main()
