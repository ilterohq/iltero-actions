#!/usr/bin/env python3
"""A stand-in for GitHub's issue comments API, for the comment tests.

Usage: fake_github.py PORT_FILE COMMENTS_FILE LOG_FILE

Serves the comments in COMMENTS_FILE (a JSON list) page by page, answers
every POST and PATCH, and logs each request as "METHOD PATH BODY". It writes
its port to PORT_FILE once it listens. FAKE_STATUS, when set, is the status of
every answer.
"""

import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT_FILE, COMMENTS_FILE, LOG_FILE = sys.argv[1:4]


class Handler(BaseHTTPRequestHandler):
    def answer(self, body) -> None:
        status = int(os.environ.get("FAKE_STATUS", "200"))
        if status >= 400:
            body = {"message": "fake failure"}
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log(self, body: str) -> None:
        with open(LOG_FILE, "a", encoding="utf-8") as log:
            log.write(f"{self.command} {self.path} {body}\n")

    def do_GET(self) -> None:
        self.log("")
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        size, page = int(query["per_page"][0]), int(query["page"][0])
        with open(COMMENTS_FILE, encoding="utf-8") as file:
            comments = json.load(file)
        self.answer(comments[(page - 1) * size : page * size])

    def do_POST(self) -> None:
        self.log(self.rfile.read(int(self.headers["Content-Length"])).decode())
        self.answer({"id": 1})

    do_PATCH = do_POST

    def log_message(self, *args) -> None:
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as file:
    file.write(str(server.server_port))
server.serve_forever()
