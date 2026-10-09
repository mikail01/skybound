"""Tiny stand-in for the GitHub API + codeload used by tests/sync.

Serves from a directory:
  commits/<ref>.json   (ref with '/' replaced by '__') -> /repos/<repo>/commits/<ref>
  order.txt            commit SHAs oldest..newest      -> /repos/<repo>/compare/<a>...<b>
  zips/<sha>.zip                                       -> /<repo>/zip/<sha>
Anything else is a 404.
"""

import http.server
import json
import os
import sys

ROOT = sys.argv[1]
PORT = int(sys.argv[2])


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        parts = path.strip("/").split("/")
        if parts[:1] == ["repos"] and len(parts) >= 5 and parts[3] == "commits":
            ref = "__".join(parts[4:])
            file = os.path.join(ROOT, "commits", ref + ".json")
            if os.path.exists(file):
                return self.send(200, open(file, "rb").read(), "application/json")
            return self.send(404, b'{"message":"Not Found"}', "application/json")
        if parts[:1] == ["repos"] and len(parts) == 5 and parts[3] == "compare":
            a, b = parts[4].split("...")
            order = open(os.path.join(ROOT, "order.txt")).read().split()
            if a not in order or b not in order:
                return self.send(404, b'{"message":"Not Found"}', "application/json")
            status = "ahead" if order.index(b) > order.index(a) else ("identical" if a == b else "behind")
            return self.send(200, json.dumps({"status": status}).encode(), "application/json")
        if len(parts) == 4 and parts[2] == "zip":
            file = os.path.join(ROOT, "zips", parts[3] + ".zip")
            if os.path.exists(file):
                return self.send(200, open(file, "rb").read(), "application/zip")
        return self.send(404, b"Not Found", "text/plain")


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
