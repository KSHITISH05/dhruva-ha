#!/usr/bin/env python3
"""Galera-aware health check.

A node is healthy only when it is:
  * Synced            (wsrep_local_state = 4)
  * ready for queries (wsrep_ready = ON)
  * in the Primary component (wsrep_cluster_status = Primary)

Two ways to run it:
  --serve PORT   tiny HTTP endpoint for HAProxy `option httpchk` (200 / 503)
  (no --serve)   one-shot check with Nagios-style exit codes, for cron/monitoring:
                 0 = OK, 1 = WARNING (donor/desynced), 2 = CRITICAL

Uses only the Python standard library and the `mysql` client, so it can be
dropped onto any database host.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

QUERY = (
    "SHOW GLOBAL STATUS WHERE Variable_name IN ("
    "'wsrep_local_state','wsrep_local_state_comment','wsrep_ready',"
    "'wsrep_cluster_status','wsrep_cluster_size','wsrep_connected')"
)

SYNCED, DONOR = "4", "2"


def node_status(socket_path: str, timeout: float = 2.0, available_when_donor: bool = False) -> dict:
    """Query wsrep status over the local socket and classify the node."""
    try:
        out = subprocess.run(
            ["mysql", f"--socket={socket_path}", "--connect-timeout=2", "-N", "-B", "-e", QUERY],
            capture_output=True, text=True, timeout=timeout, check=False,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return {"healthy": False, "level": 2, "reason": f"query failed: {exc}"}
    if out.returncode != 0:
        return {"healthy": False, "level": 2, "reason": out.stderr.strip()[:200] or "mysql exited non-zero"}

    st = dict(line.split("\t", 1) for line in out.stdout.strip().splitlines() if "\t" in line)
    state = st.get("wsrep_local_state")
    result = {
        "state": st.get("wsrep_local_state_comment"),
        "ready": st.get("wsrep_ready"),
        "cluster_status": st.get("wsrep_cluster_status"),
        "cluster_size": int(st.get("wsrep_cluster_size", 0) or 0),
    }
    if st.get("wsrep_cluster_status") != "Primary":
        result.update(healthy=False, level=2, reason="not in Primary component (split brain?)")
    elif st.get("wsrep_ready") != "ON":
        result.update(healthy=False, level=2, reason="wsrep not ready")
    elif state == SYNCED or (state == DONOR and available_when_donor):
        result.update(healthy=True, level=0, reason="synced")
    else:
        result.update(healthy=False, level=1, reason=f"not synced ({result['state']})")
    return result


def serve(port: int, bind: str, socket_path: str, available_when_donor: bool) -> None:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            status = node_status(socket_path, available_when_donor=available_when_donor)
            body = json.dumps(status).encode()
            self.send_response(200 if status["healthy"] else 503)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):  # HAProxy polls every second; keep logs quiet
            pass

    ThreadingHTTPServer((bind, port), Handler).serve_forever()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--socket", default="/run/mysqld/mysqld.sock")
    ap.add_argument("--serve", type=int, metavar="PORT", help="run the HTTP endpoint on PORT")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--available-when-donor", action="store_true",
                    help="treat an SST donor as healthy (only safe with non-blocking SST like mariabackup)")
    args = ap.parse_args()

    if args.serve:
        serve(args.serve, args.bind, args.socket, args.available_when_donor)
        return 0

    status = node_status(args.socket, available_when_donor=args.available_when_donor)
    print(json.dumps(status))
    return status["level"]


if __name__ == "__main__":
    sys.exit(main())
