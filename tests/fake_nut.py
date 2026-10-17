#!/usr/bin/env python3
"""Fake NUT server for tests. Answers `GET VAR ups <var>` from a JSON file that is
re-read on every request, so a test can change values between polls.

Usage: fake_nut.py PORT VALUES.json     e.g. {"ups.status": "OB", "battery.charge": "80"}
"""
import json
import socketserver
import sys


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline().decode(errors="ignore").split()
        try:
            with open(sys.argv[2]) as fh:
                values = json.load(fh)
        except (OSError, ValueError):
            values = {}
        if len(line) == 4 and line[:2] == ["GET", "VAR"] and line[3] in values:
            self.wfile.write(('VAR %s %s "%s"\n' % (line[2], line[3], values[line[3]])).encode())
        else:
            self.wfile.write(b"ERR VAR-NOT-SUPPORTED\n")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    Server(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
