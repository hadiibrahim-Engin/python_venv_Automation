#!/usr/bin/env python3
"""bump-version.py — Conventional-commit based semver bumper for pyproject.toml.

Reads commits since the last vX.Y.Z git tag, applies conventional-commit
bump rules to determine whether to increment the major, minor, or patch
component, writes the new version back into pyproject.toml, and prints the
result.

Bump rules (highest priority wins):
    BREAKING CHANGE in commit body  →  major
    <type>!: prefix                  →  major
    feat:                            →  minor
    fix: / perf: / refactor: /
    docs: / chore: / style: /
    test: / build: / ci:             →  patch
    (no bumpable commits)            →  no-op  (exits 0, sets BUMP_SKIPPED=true)

Usage:
    python scripts/bump-version.py [--dry-run] [--force-bump patch|minor|major]

Options:
    --dry-run          Print what would happen without writing pyproject.toml.
    --force-bump TYPE  Override commit analysis; bump TYPE regardless of commits.

Azure DevOps pipeline integration:
    The script writes the Azure Pipelines variable BUMP_SKIPPED=true when
    nothing needs bumping, allowing the push step to be skipped via a
    condition: and(succeeded(), ne(variables['BUMP_SKIPPED'], 'true'))

Requirements: Python 3.11+ (uses tomllib from stdlib).  No third-party deps.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
PYPROJECT = REPO_ROOT / "pyproject.toml"

# Conventional commit types that trigger a PATCH bump (all lowercase).
# Everything not in this list (and not feat/breaking) is ignored.
PATCH_TYPES = frozenset(
    [
        "fix",
        "perf",
        "refactor",
        "docs",
        "chore",
        "style",
        "test",
        "build",
        "ci",
        "revert",
    ]
)

# Conventional commit types that trigger a MINOR bump.
MINOR_TYPES = frozenset(["feat"])

# Regex: matches "type[!][(scope)]: subject" or "type[!]: subject"
CC_HEADER = re.compile(
    r"^(?P<type>[a-z]+)(?P<scope>\([^)]*\))?(?P<breaking>!)?\s*:\s*(?P<subject>.+)$",
    re.IGNORECASE,
)

BREAKING_FOOTER = re.compile(r"^BREAKING[- ]CHANGE\s*:", re.IGNORECASE | re.MULTILINE)

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------


def _run(cmd: list[str], *, check: bool = True, capture: bool = True) -> str:
    """Run a git command and return stdout (stripped)."""
    result = subprocess.run(
        cmd,
        capture_output=capture,
        text=True,
        cwd=REPO_ROOT,
    )
    if check and result.returncode != 0:
        raise SystemExit(
            f"Command failed: {' '.join(cmd)}\n"
            f"stderr: {result.stderr.strip()}"
        )
    return result.stdout.strip() if capture else ""


def last_version_tag() -> str | None:
    """Return the most recent vX.Y.Z tag reachable from HEAD, or None."""
    try:
        raw = _run(
            ["git", "tag", "--list", "v*", "--sort=-version:refname", "--merged", "HEAD"],
            check=True,
        )
    except SystemExit:
        return None

    for line in raw.splitlines():
        tag = line.strip()
        if re.fullmatch(r"v\d+\.\d+\.\d+", tag):
            return tag
    return None


def commits_since(tag: str | None) -> list[str]:
    """Return full commit messages (subject + body) since *tag* (or all commits)."""
    rev_range = f"{tag}..HEAD" if tag else "HEAD"
    # %x00 is a NUL separator so we can split reliably even on multi-line bodies.
    raw = _run(
        ["git", "log", rev_range, "--format=%B%x00"],
    )
    if not raw:
        return []
    return [msg.strip() for msg in raw.split("\x00") if msg.strip()]


# ---------------------------------------------------------------------------
# Conventional-commit analysis
# ---------------------------------------------------------------------------

BumpLevel = int  # 0=none, 1=patch, 2=minor, 3=major


def classify_commit(message: str) -> BumpLevel:
    """Return the bump level a single commit message implies."""
    lines = message.splitlines()
    if not lines:
        return 0

    header = lines[0].strip()
    body = "\n".join(lines[1:]) if len(lines) > 1 else ""

    # Breaking change anywhere in body/footer
    if BREAKING_FOOTER.search(body):
        return 3

    m = CC_HEADER.match(header)
    if not m:
        return 0  # not a conventional commit — ignore

    # Breaking change indicated by "!" in the header
    if m.group("breaking") == "!":
        return 3

    ctype = m.group("type").lower()
    if ctype in MINOR_TYPES:
        return 2
    if ctype in PATCH_TYPES:
        return 1

    return 0


def determine_bump(messages: list[str]) -> BumpLevel:
    """Return the highest bump level across all commit messages."""
    return max((classify_commit(m) for m in messages), default=0)


# ---------------------------------------------------------------------------
# pyproject.toml version I/O
# ---------------------------------------------------------------------------


def read_version(pyproject: Path = PYPROJECT) -> tuple[str, str]:
    """Return (version_string, source_key) from *pyproject*.

    source_key is one of:
        'project'       — PEP 621 / uv  ([project].version)
        'tool.poetry'   — Poetry         ([tool.poetry].version)
    Raises SystemExit if no version can be found.
    """
    with open(pyproject, "rb") as fh:
        data = tomllib.load(fh)

    # PEP 621 / uv style
    if "project" in data and "version" in data["project"]:
        return data["project"]["version"], "project"

    # Poetry style
    if "tool" in data and "poetry" in data["tool"] and "version" in data["tool"]["poetry"]:
        return data["tool"]["poetry"]["version"], "tool.poetry"

    raise SystemExit(
        f"No version found in {pyproject}.\n"
        "Expected [project].version (PEP 621/uv) or [tool.poetry].version."
    )


def bump_version(version: str, level: BumpLevel) -> str:
    """Return a new semver string with the appropriate component incremented."""
    parts = version.split(".")
    if len(parts) != 3:
        raise SystemExit(
            f"Version '{version}' is not in X.Y.Z semver format. "
            "Please normalise it before running this script."
        )
    major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2])

    if level == 3:  # major
        return f"{major + 1}.0.0"
    if level == 2:  # minor
        return f"{major}.{minor + 1}.0"
    if level == 1:  # patch
        return f"{major}.{minor}.{patch + 1}"

    raise ValueError(f"Invalid bump level: {level}")


# A table header:  [project]   /  [tool.poetry]   (optionally trailing comment)
SECTION_RE = re.compile(r"^\s*\[\s*([^\[\]]+?)\s*\]\s*(?:#.*)?$")
# An array-of-tables header: [[tool.foo]] — never a version target, but it does
# change which table subsequent keys belong to.
ARRAY_SECTION_RE = re.compile(r"^\s*\[\[\s*([^\[\]]+?)\s*\]\]\s*(?:#.*)?$")
# version = "X.Y.Z"   preserving indentation, quote style and trailing comment.
VERSION_LINE_RE = re.compile(
    r"^(?P<prefix>\s*version\s*=\s*)(?P<quote>[\"'])(?P<value>[^\"']*)(?P=quote)(?P<suffix>.*)$"
)


def _replace_version_in_section(text: str, new_version: str, section: str) -> tuple[str, int]:
    """Replace ``version = "..."`` inside *section* only.

    Walks the file line by line tracking the active TOML table, so a
    ``version`` key belonging to ``[build-system]``, ``[tool.uv.sources.*]`` or
    any other table is never touched. Comments, indentation, quote style and
    line endings are preserved. Returns (new_text, replacement_count).
    """
    out: list[str] = []
    current: str | None = None
    count = 0

    for raw_line in text.splitlines(keepends=True):
        # Split the content from its line terminator so CRLF survives intact.
        stripped = raw_line.rstrip("\r\n")
        terminator = raw_line[len(stripped):]

        array_match = ARRAY_SECTION_RE.match(stripped)
        section_match = SECTION_RE.match(stripped)

        if array_match:
            current = None  # array-of-tables is never our target
        elif section_match:
            current = section_match.group(1).strip()
        elif current == section and count == 0:
            version_match = VERSION_LINE_RE.match(stripped)
            if version_match:
                stripped = (
                    f"{version_match.group('prefix')}"
                    f"{version_match.group('quote')}{new_version}{version_match.group('quote')}"
                    f"{version_match.group('suffix')}"
                )
                count += 1

        out.append(stripped + terminator)

    return "".join(out), count


def write_version(
    new_version: str, source_key: str, pyproject: Path = PYPROJECT
) -> None:
    """Write *new_version* into the correct TOML table of *pyproject*.

    Deliberately NOT a global regex replace: the previous implementation swapped
    the first line-anchored ``version =`` in the file, which silently rewrote the
    wrong table whenever another table declared a version first.

    The result is re-parsed and verified before the file is replaced, so a patch
    that would corrupt the TOML or land in the wrong table fails instead of
    leaving a broken pyproject.toml behind.
    """
    # newline="" keeps CRLF intact: Path.read_text/write_text would silently
    # normalise a Windows checkout to LF and produce a whole-file diff.
    with open(pyproject, "r", encoding="utf-8", newline="") as fh:
        text = fh.read()
    new_text, count = _replace_version_in_section(text, new_version, source_key)

    if count == 0:
        raise SystemExit(
            f'Could not find \'version = "..."\' inside [{source_key}] in {pyproject}.'
        )

    # Validate before committing the change to disk.
    try:
        parsed = tomllib.loads(new_text)
    except tomllib.TOMLDecodeError as exc:
        raise SystemExit(f"Refusing to write invalid TOML to {pyproject}: {exc}") from exc

    written = _lookup(parsed, source_key)
    if written != new_version:
        raise SystemExit(
            f"Version patch landed in the wrong place: [{source_key}].version is "
            f"{written!r} after patching, expected {new_version!r}."
        )

    with open(pyproject, "w", encoding="utf-8", newline="") as fh:
        fh.write(new_text)


def _lookup(data: dict, source_key: str) -> str | None:
    """Read ``<source_key>.version`` out of parsed TOML data."""
    node: object = data
    for part in source_key.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    if not isinstance(node, dict):
        return None
    return node.get("version")


# ---------------------------------------------------------------------------
# Azure Pipelines variable helper
# ---------------------------------------------------------------------------


def set_pipeline_variable(name: str, value: str) -> None:
    """Emit an Azure Pipelines logging command to set a variable."""
    print(f"##vso[task.setvariable variable={name}]{value}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

LEVEL_NAMES = {0: "none", 1: "patch", 2: "minor", 3: "major"}
FORCE_MAP   = {"patch": 1, "minor": 2, "major": 3}


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Bump pyproject.toml version based on conventional commits.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would happen without writing pyproject.toml.",
    )
    parser.add_argument(
        "--force-bump",
        choices=["patch", "minor", "major"],
        default=None,
        help="Override commit analysis and apply this bump type.",
    )
    parser.add_argument(
        "--pyproject",
        type=Path,
        default=PYPROJECT,
        help="Path to pyproject.toml (defaults to the repository root).",
    )
    args = parser.parse_args()

    # --- Read current version ---
    current_version, source_key = read_version(args.pyproject)
    print(f"Current version : {current_version}  (source: [{source_key}])")

    # --- Determine bump level ---
    if args.force_bump:
        level = FORCE_MAP[args.force_bump]
        print(f"Forced bump     : {args.force_bump} (--force-bump)")
    else:
        last_tag = last_version_tag()
        print(f"Last version tag: {last_tag or '(none — scanning all commits)'}")

        messages = commits_since(last_tag)
        print(f"Commits analysed: {len(messages)}")

        level = determine_bump(messages)

    print(f"Bump level      : {LEVEL_NAMES[level]}")

    if level == 0:
        print("No bumpable conventional commits found. Nothing to do.")
        set_pipeline_variable("BUMP_SKIPPED", "true")
        sys.exit(0)

    # --- Compute new version ---
    new_version = bump_version(current_version, level)
    print(f"New version     : {new_version}")

    if args.dry_run:
        print("[DRY-RUN] pyproject.toml was NOT modified.")
        sys.exit(0)

    # --- Write new version ---
    write_version(new_version, source_key, args.pyproject)
    print(f"Written         : {args.pyproject}")

    # Expose the new version as a pipeline variable for downstream steps.
    set_pipeline_variable("NEW_VERSION", new_version)
    set_pipeline_variable("BUMP_SKIPPED", "false")


if __name__ == "__main__":
    main()
