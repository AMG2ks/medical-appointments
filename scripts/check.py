#!/usr/bin/env python3
"""Quality gate for the whole repo: backend + mobile. Stdlib only, works offline.

Usage: python scripts/check.py

Runs every step even after a failure, prints PASS/FAIL/SKIP per step and
exits 1 if any step failed. Backend commands use the Python interpreter that
runs this script, so activate the backend virtualenv first.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BACKEND = ROOT / "backend"
MOBILE = ROOT / "mobile"
ARB_DIR = MOBILE / "lib" / "l10n"
TEMPLATE_ARB = "app_en.arb"  # reference locale; every other app_*.arb must match it

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"


def run(cmd: list[str], cwd: Path) -> tuple[str, str]:
    """Run a command with output streamed to the terminal."""
    print(f"$ {' '.join(cmd)}   (in {cwd.relative_to(ROOT)})", flush=True)
    exe = shutil.which(cmd[0]) if cmd[0] != sys.executable else cmd[0]
    if exe is None:
        return FAIL, f"'{cmd[0]}' not found on PATH"
    try:
        code = subprocess.run([exe, *cmd[1:]], cwd=cwd).returncode
    except OSError as exc:
        return FAIL, str(exc)
    return (PASS, "") if code == 0 else (FAIL, f"exit code {code}")


def check_arb_parity() -> tuple[str, str]:
    """Every message key in the template ARB must exist in every other ARB, and vice versa."""
    template = ARB_DIR / TEMPLATE_ARB
    if not template.is_file():
        return FAIL, f"{template.relative_to(ROOT)} not found"

    def keys(path: Path) -> set[str]:
        data = json.loads(path.read_text(encoding="utf-8"))
        return {k for k in data if not k.startswith("@")}  # @key = metadata, @@locale = header

    reference = keys(template)
    problems: list[str] = []
    others = sorted(p for p in ARB_DIR.glob("app_*.arb") if p.name != TEMPLATE_ARB)
    if not others:
        return FAIL, "no other app_*.arb file to compare with the template"
    for path in others:
        try:
            current = keys(path)
        except (OSError, ValueError) as exc:
            problems.append(f"{path.name}: unreadable ({exc})")
            continue
        for key in sorted(reference - current):
            problems.append(f"{path.name}: missing key '{key}'")
        for key in sorted(current - reference):
            problems.append(f"{path.name}: extra key '{key}' (not in {TEMPLATE_ARB})")
    for line in problems:
        print(f"  {line}")
    return (FAIL, f"{len(problems)} problem(s)") if problems else (PASS, "")


def dart_format_targets() -> list[str]:
    found = [d for d in ("lib", "test", "integration_test") if (MOBILE / d).is_dir()]
    return found or ["."]


def build_steps() -> list[tuple[str, str, object]]:
    """(group, name, callable | None). A None callable with a reason string is a skip."""
    py = sys.executable
    steps: list[tuple[str, str, object]] = []

    if (BACKEND / "manage.py").is_file():
        backend = [
            ("ruff check", lambda: run([py, "-m", "ruff", "check", "."], BACKEND)),
            ("ruff format --check", lambda: run([py, "-m", "ruff", "format", "--check", "."], BACKEND)),
            ("pytest", lambda: run([py, "-m", "pytest"], BACKEND)),
            (
                "makemigrations --check",
                lambda: run([py, "manage.py", "makemigrations", "--check", "--dry-run"], BACKEND),
            ),
        ]
        steps += [("backend", name, fn) for name, fn in backend]
    else:
        steps += [("backend", n, "backend/ not scaffolded yet (no backend/manage.py)") for n in (
            "ruff check", "ruff format --check", "pytest", "makemigrations --check")]

    if (MOBILE / "pubspec.yaml").is_file():
        mobile = [
            ("ARB completeness (fr/en)", check_arb_parity),
            ("flutter gen-l10n", lambda: run(["flutter", "gen-l10n"], MOBILE)),
            (
                "dart format",
                lambda: run(
                    ["dart", "format", "--output=none", "--set-exit-if-changed", *dart_format_targets()],
                    MOBILE,
                ),
            ),
            ("flutter analyze", lambda: run(["flutter", "analyze"], MOBILE)),
            ("flutter test", lambda: run(["flutter", "test"], MOBILE)),
        ]
        steps += [("mobile", name, fn) for name, fn in mobile]
    else:
        steps += [("mobile", n, "mobile/ not scaffolded yet (no mobile/pubspec.yaml)") for n in (
            "ARB completeness (fr/en)", "flutter gen-l10n", "dart format", "flutter analyze", "flutter test")]
    return steps


def main() -> int:
    results: list[tuple[str, str, str]] = []
    for group, name, fn in build_steps():
        label = f"{group}: {name}"
        print(f"\n=== {label}", flush=True)
        if isinstance(fn, str):  # skip reason
            status, detail = SKIP, fn
            print(f"SKIP: {detail}", flush=True)
        else:
            status, detail = fn()
        results.append((label, status, detail))

    print("\n=== Summary")
    width = max(len(label) for label, _, _ in results)
    for label, status, detail in results:
        print(f"{status:<4}  {label:<{width}}  {detail}".rstrip())
    failed = [label for label, status, _ in results if status == FAIL]
    ran = sum(1 for _, status, _ in results if status != SKIP)
    print(f"\n{ran - len(failed)}/{ran} steps passed, {len(failed)} failed, {len(results) - ran} skipped.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
