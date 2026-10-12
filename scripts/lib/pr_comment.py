#!/usr/bin/env python3
"""Create or update the pull request comment that starts with a marker.

Usage: pr_comment.py MARKER BODY_FILE

Reads GITHUB_API_URL, GITHUB_REPOSITORY, GITHUB_TOKEN and PR_NUMBER from the
environment. Updates the comment that the workflow's token posted and that
starts with MARKER, or creates one. It calls only GitHub's issue comments API.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from typing import NoReturn

# The account that posts with a workflow's GitHub token.
BOT_LOGIN = "github-actions[bot]"
# The REST API version the requests are written for.
API_VERSION = "2022-11-28"
# The largest page GitHub returns.
PAGE_SIZE = 100
# How long one request may take before the action gives up.
REQUEST_TIMEOUT_SECONDS = 30
# The statuses GitHub answers when the token may not comment.
PERMISSION_STATUSES = frozenset({401, 403})
# How much of GitHub's answer an error message shows.
ERROR_EXCERPT_CHARS = 300


def fail(message: str) -> NoReturn:
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        fail(f"{name} is not set. Run this action inside a GitHub Actions job.")
    return value


def call(method: str, url: str, token: str, body: dict | None = None):
    data = None if body is None else json.dumps(body).encode()
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": API_VERSION,
    }
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code in PERMISSION_STATUSES:
            fail(f"GitHub refused the comment request with HTTP {error.code}. Check 'permissions: pull-requests: write'.")
        answer = " ".join(error.read().decode(errors="replace").split())[:ERROR_EXCERPT_CHARS]
        fail(f"GitHub refused the comment request with HTTP {error.code}: {answer}")
    except (urllib.error.URLError, TimeoutError) as error:
        fail(f"Could not reach GitHub: {getattr(error, 'reason', error)}.")


def find_comment(comments_url: str, token: str, marker: str) -> int | None:
    page = 1
    while True:
        comments = call("GET", f"{comments_url}?per_page={PAGE_SIZE}&page={page}", token)
        for comment in comments:
            if comment["user"]["login"] == BOT_LOGIN and comment["body"].startswith(marker):
                return comment["id"]
        if len(comments) < PAGE_SIZE:
            return None
        page += 1


def main() -> None:
    if len(sys.argv) != 3:
        fail("Usage: pr_comment.py MARKER BODY_FILE")
    marker, body_file = sys.argv[1], sys.argv[2]
    api = env("GITHUB_API_URL").rstrip("/")
    repository = env("GITHUB_REPOSITORY")
    token = env("GITHUB_TOKEN")
    number = env("PR_NUMBER")
    with open(body_file, encoding="utf-8") as file:
        body = f"{marker}\n{file.read()}"

    comments_url = f"{api}/repos/{repository}/issues/{number}/comments"
    existing = find_comment(comments_url, token, marker)
    if existing is None:
        call("POST", comments_url, token, {"body": body})
        print("Posted the preview comment.")
    else:
        call("PATCH", f"{api}/repos/{repository}/issues/comments/{existing}", token, {"body": body})
        print("Updated the preview comment.")


if __name__ == "__main__":
    main()
