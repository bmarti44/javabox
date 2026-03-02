#!/usr/bin/env python3
"""
build/serve.py — Dev server for JavaBox WASM output.

Serves the c2w output directory with the required COOP/COEP headers so that
SharedArrayBuffer is available (needed for QEMU multi-threaded JIT).

Usage:
  python3 build/serve.py [output-dir] [port]
  python3 build/serve.py ~/javabox-wasm 3000

Defaults: output-dir=~/javabox-wasm  port=3000
"""

import http.server
import os
import sys

REQUIRED_HEADERS = {
    "Cross-Origin-Opener-Policy":   "same-origin",
    "Cross-Origin-Embedder-Policy": "require-corp",
}

class COOPHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        for k, v in REQUIRED_HEADERS.items():
            self.send_header(k, v)
        super().end_headers()

    def guess_type(self, path):
        # Emscripten pthread workers do import('./qemu-system-x86_64')
        # (no extension). Serve it as JS so the dynamic import succeeds.
        base = os.path.basename(path)
        if base == 'qemu-system-x86_64':
            return 'application/javascript'
        return super().guess_type(path)

    # Silence the access log unless an error occurs
    def log_message(self, fmt, *args):
        code = args[1] if len(args) > 1 else "???"
        if str(code).startswith(("4", "5")):
            super().log_message(fmt, *args)

def main():
    args = sys.argv[1:]
    output_dir = os.path.expanduser(args[0]) if args else os.path.expanduser("~/javabox-wasm")
    port = int(args[1]) if len(args) > 1 else 3000

    if not os.path.isdir(output_dir):
        print(f"ERROR: directory not found: {output_dir}", file=sys.stderr)
        sys.exit(1)

    os.chdir(output_dir)
    print(f"Serving {output_dir}")
    print(f"  http://localhost:{port}/")
    print(f"  COOP: same-origin")
    print(f"  COEP: require-corp")
    print(f"  Press Ctrl-C to stop.\n")

    server = http.server.HTTPServer(("", port), COOPHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")

if __name__ == "__main__":
    main()
