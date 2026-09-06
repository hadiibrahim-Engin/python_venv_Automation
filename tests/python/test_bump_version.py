"""Tests for scripts/bump-version.py — section-aware TOML version writing.

The previous implementation replaced the first line-anchored ``version =`` in
the file with a global regex, which silently rewrote the wrong table whenever
another table declared a version first. These tests pin the corrected
behaviour.
"""

from __future__ import annotations

import importlib.util
import sys
import tomllib
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]


def _load_module():
    spec = importlib.util.spec_from_file_location(
        "bump_version", REPO_ROOT / "scripts" / "bump-version.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


bv = _load_module()


def write(tmp_path: Path, text: str) -> Path:
    p = tmp_path / "pyproject.toml"
    p.write_text(text, encoding="utf-8")
    return p


# ---------------------------------------------------------------------------
# read_version
# ---------------------------------------------------------------------------


def test_read_version_prefers_pep621(tmp_path):
    p = write(tmp_path, '[project]\nname = "d"\nversion = "1.2.3"\n')
    assert bv.read_version(p) == ("1.2.3", "project")


def test_read_version_falls_back_to_poetry(tmp_path):
    p = write(tmp_path, '[tool.poetry]\nname = "d"\nversion = "4.5.6"\n')
    assert bv.read_version(p) == ("4.5.6", "tool.poetry")


def test_read_version_without_any_version_exits(tmp_path):
    p = write(tmp_path, '[project]\nname = "d"\n')
    with pytest.raises(SystemExit):
        bv.read_version(p)


# ---------------------------------------------------------------------------
# write_version — the actual regression
# ---------------------------------------------------------------------------


def test_write_version_targets_the_right_table(tmp_path):
    """A stale [tool.poetry] version must not absorb the [project] bump."""
    p = write(
        tmp_path,
        "[build-system]\n"
        'requires = ["hatchling"]\n'
        "\n"
        "[tool.poetry]\n"
        'name = "demo"\n'
        'version = "9.9.9"\n'
        "\n"
        "[project]\n"
        'name = "demo"\n'
        'version = "1.2.3"\n',
    )
    bv.write_version("1.2.4", "project", p)
    data = tomllib.loads(p.read_text(encoding="utf-8"))
    assert data["project"]["version"] == "1.2.4"
    assert data["tool"]["poetry"]["version"] == "9.9.9"


def test_write_version_targets_poetry_when_asked(tmp_path):
    p = write(
        tmp_path,
        "[project]\n"
        'version = "1.0.0"\n'
        "\n"
        "[tool.poetry]\n"
        'version = "2.0.0"\n',
    )
    bv.write_version("2.0.1", "tool.poetry", p)
    data = tomllib.loads(p.read_text(encoding="utf-8"))
    assert data["tool"]["poetry"]["version"] == "2.0.1"
    assert data["project"]["version"] == "1.0.0"


def test_write_version_ignores_versions_in_other_tables(tmp_path):
    p = write(
        tmp_path,
        "[build-system]\n"
        'version = "0.0.1"\n'
        "\n"
        "[project]\n"
        'version = "1.2.3"\n',
    )
    bv.write_version("1.2.4", "project", p)
    data = tomllib.loads(p.read_text(encoding="utf-8"))
    assert data["build-system"]["version"] == "0.0.1"
    assert data["project"]["version"] == "1.2.4"


def test_write_version_ignores_array_of_tables(tmp_path):
    p = write(
        tmp_path,
        "[project]\n"
        'version = "1.2.3"\n'
        "\n"
        "[[tool.something]]\n"
        'version = "0.0.9"\n',
    )
    bv.write_version("1.3.0", "project", p)
    data = tomllib.loads(p.read_text(encoding="utf-8"))
    assert data["project"]["version"] == "1.3.0"
    assert data["tool"]["something"][0]["version"] == "0.0.9"


def test_write_version_preserves_comments_and_formatting(tmp_path):
    p = write(
        tmp_path,
        "# top comment\n"
        "[project]\n"
        'name = "demo"   # keep me\n'
        '  version   =   "1.2.3"   # the real one\n'
        "\n"
        "# trailing comment\n",
    )
    bv.write_version("1.2.4", "project", p)
    text = p.read_text(encoding="utf-8")
    assert "# top comment" in text
    assert "# trailing comment" in text
    assert '  version   =   "1.2.4"   # the real one' in text
    assert 'name = "demo"   # keep me' in text


def test_write_version_preserves_single_quotes(tmp_path):
    p = write(tmp_path, "[project]\nversion = '1.2.3'\n")
    bv.write_version("1.2.4", "project", p)
    assert "version = '1.2.4'" in p.read_text(encoding="utf-8")


def test_write_version_preserves_crlf(tmp_path):
    p = tmp_path / "pyproject.toml"
    p.write_bytes(b'[project]\r\nversion = "1.2.3"\r\n')
    bv.write_version("1.2.4", "project", p)
    assert p.read_bytes() == b'[project]\r\nversion = "1.2.4"\r\n'


def test_write_version_exits_when_table_has_no_version(tmp_path):
    p = write(tmp_path, '[project]\nname = "demo"\n')
    with pytest.raises(SystemExit):
        bv.write_version("1.0.0", "project", p)


def test_write_version_ignores_commented_out_version(tmp_path):
    p = write(
        tmp_path,
        "[project]\n"
        '# version = "0.0.1"\n'
        'version = "1.2.3"\n',
    )
    bv.write_version("1.2.4", "project", p)
    text = p.read_text(encoding="utf-8")
    assert '# version = "0.0.1"' in text
    assert tomllib.loads(text)["project"]["version"] == "1.2.4"


def test_write_version_only_replaces_first_match_in_target_table(tmp_path):
    p = write(tmp_path, '[project]\nversion = "1.2.3"\n\n[other]\nversion = "1.2.3"\n')
    bv.write_version("1.2.4", "project", p)
    data = tomllib.loads(p.read_text(encoding="utf-8"))
    assert data["project"]["version"] == "1.2.4"
    assert data["other"]["version"] == "1.2.3"


# ---------------------------------------------------------------------------
# bump_version / classify_commit
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("version", "level", "expected"),
    [
        ("1.2.3", 1, "1.2.4"),
        ("1.2.3", 2, "1.3.0"),
        ("1.2.3", 3, "2.0.0"),
        ("0.9.9", 2, "0.10.0"),
    ],
)
def test_bump_version(version, level, expected):
    assert bv.bump_version(version, level) == expected


def test_bump_version_rejects_non_semver():
    with pytest.raises(SystemExit):
        bv.bump_version("1.2", 1)


@pytest.mark.parametrize(
    ("message", "expected"),
    [
        ("feat: add thing", 2),
        ("fix: repair thing", 1),
        ("feat!: breaking thing", 3),
        ("refactor(core)!: breaking scoped", 3),
        ("feat: x\n\nBREAKING CHANGE: gone", 3),
        ("chore: tidy", 1),
        ("random text without a type", 0),
        ("", 0),
    ],
)
def test_classify_commit(message, expected):
    assert bv.classify_commit(message) == expected


def test_determine_bump_takes_the_highest():
    assert bv.determine_bump(["fix: a", "feat: b", "chore: c"]) == 2
    assert bv.determine_bump([]) == 0
