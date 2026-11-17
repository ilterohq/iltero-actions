#!/usr/bin/env python3
"""Pin the Iltero CLI that the `setup` action installs.

Run this from the repository root when moving to another CLI commit:

    scripts/lock-cli.py CLI_CHECKOUT SCHEMAS_COMMIT

CLI_CHECKOUT is a checkout of iltero-cli at the commit to pin. The script
reads the lock file of that commit, as committed, so a change in the working
tree is never locked. SCHEMAS_COMMIT is the iltero-schemas commit that CLI
commit is tested against.

The script writes two files under setup/:

- cli-sources.txt: the two commits the action installs from source.
- cli-requirements.txt: every other package the CLI needs at run time,
  including the packages of its cloud extras, plus the build backend for the
  two source installs, each with its version and the SHA-256 hashes from the
  CLI's own lock file.
"""

import re
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import NoReturn

SETUP_DIR = Path(__file__).resolve().parent.parent / "setup"
COMMIT = re.compile(r"[0-9a-f]{40}")
# The source installs are built with this backend, so it and its
# dependencies are locked as well.
BUILD_BACKEND = "hatchling"
REQUIREMENT_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
# The CLI's optional groups that setup installs too: the cloud clients that
# keep a run's records in its artifact store.
EXTRAS = frozenset({"aws"})
# Installed from source at a pinned commit, not from the lock.
SOURCE_PACKAGES = frozenset({"iltero-schemas"})


def fail(message: str) -> NoReturn:
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def head_commit(checkout: Path) -> str:
    """Return the commit at HEAD of the CLI checkout, or stop when there is none."""
    result = subprocess.run(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], capture_output=True, text=True, check=False
    )
    commit = result.stdout.strip()
    if result.returncode != 0 or not COMMIT.fullmatch(commit):
        fail(f"{checkout} is not a git checkout with a commit at HEAD")
    return commit


def committed_lock(checkout: Path, commit: str) -> str:
    """Return the CLI's lock file as COMMIT holds it, so the hashes belong to the commit that is pinned."""
    result = subprocess.run(
        ["git", "-C", str(checkout), "show", f"{commit}:pdm.lock"], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        fail("the commit at HEAD has no pdm.lock")
    return result.stdout


def normalized_name(name: str) -> str:
    """Return a package name as pip compares it: lower case, with each run of '-', '_' and '.' as one '-'."""
    return re.sub(r"[-_.]+", "-", name).lower()


def locked_packages(lock: dict) -> dict[str, dict]:
    """Return the lock file's packages by normalized name.

    The lock file repeats a package for each set of extras it is installed with, with the same version, files
    and marker. A repeat adds its groups and dependencies to the first entry. Any other second entry for a name
    is refused.
    """
    packages: dict[str, dict] = {}
    for package in lock["package"]:
        name = normalized_name(package["name"])
        first = packages.get(name)
        if first is None:
            packages[name] = package
            continue
        same_files = {entry["hash"] for entry in first.get("files", [])} == {
            entry["hash"] for entry in package.get("files", [])
        }
        if package["version"] != first["version"] or not same_files or package.get("marker") != first.get("marker"):
            fail(f"the lock file has two different entries for {package['name']}")
        first["groups"] = sorted({*first.get("groups", []), *package.get("groups", [])})
        first["dependencies"] = list(dict.fromkeys([*first.get("dependencies", []), *package.get("dependencies", [])]))
    return packages


def requirement_lines(package: dict) -> list[str]:
    hashes = sorted(entry["hash"] for entry in package.get("files", []))
    if not hashes:
        fail(f"{package['name']} has no hashes in the lock file")
    marker = package.get("marker")
    head = f"{package['name']}=={package['version']}"
    if marker:
        head += f" ; {marker}"
    return [f"{head} \\"] + [f"    --hash={value} \\" for value in hashes[:-1]] + [f"    --hash={hashes[-1]}"]


def with_dependencies(root: str, packages: dict[str, dict]) -> set[str]:
    """Return the name of a locked package and of every locked package it needs."""
    found: set[str] = set()
    pending = [root]
    while pending:
        name = pending.pop()
        if name in found:
            continue
        if name not in packages:
            fail(f"the lock file has no entry for {name}")
        found.add(name)
        for requirement in packages[name].get("dependencies", []):
            match = REQUIREMENT_NAME.match(requirement)
            if match is None:
                fail(f"cannot read the requirement '{requirement}' of {name}")
            dependency = normalized_name(match.group(0))
            # A dependency limited to another Python version may be absent from the lock.
            if dependency in packages or ";" not in requirement:
                pending.append(dependency)
    return found


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: scripts/lock-cli.py CLI_CHECKOUT SCHEMAS_COMMIT")
    checkout = Path(sys.argv[1])
    schemas_commit = sys.argv[2]
    if not COMMIT.fullmatch(schemas_commit):
        fail("SCHEMAS_COMMIT must be a full 40-character commit")
    cli_commit = head_commit(checkout)

    packages = locked_packages(tomllib.loads(committed_lock(checkout, cli_commit)))
    build = with_dependencies(BUILD_BACKEND, packages)
    selected = [
        package
        for name, package in packages.items()
        if name not in SOURCE_PACKAGES
        and (not {"default", *EXTRAS}.isdisjoint(package.get("groups", [])) or name in build)
    ]

    # Only cli-sources.txt names the pinned commits.
    lines = ["# Generated by scripts/lock-cli.py. Do not edit."]
    for package in sorted(selected, key=lambda entry: entry["name"]):
        lines.extend(requirement_lines(package))
    (SETUP_DIR / "cli-requirements.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (SETUP_DIR / "cli-sources.txt").write_text(
        f"iltero-schemas {schemas_commit}\niltero-cli {cli_commit}\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
