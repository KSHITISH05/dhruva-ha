#!/usr/bin/env python3
"""Failover drill for the Galera cluster behind HAProxy.

What it does:
  1. Writes a row through HAProxy every --interval seconds (a stand-in for
     application traffic) and records which writes were acknowledged.
  2. After --kill-after seconds, hard-kills the node HAProxy is currently
     sending writes to (SIGKILL: no graceful shutdown, like a power cut).
  3. Measures the write interruption: the gap between the last acknowledged
     write before the kill and the first one after it.
  4. Checks every surviving node directly: every acknowledged write must be
     present on all of them (zero lost commits).
  5. Optionally restarts the killed node and checks it rejoins, catches up
     (IST) and holds the same data.

Exit code is non-zero if any acknowledged write is lost, the interruption is
longer than --max-gap, or the node fails to rejoin. Results are printed and can
be written as JSON / Markdown (the Markdown goes into the CI job summary).
"""
from __future__ import annotations

import argparse
import contextlib
import json
import shlex
import subprocess
import sys
import time
import uuid

import pymysql


def connect(host: str, port: int, user: str, password: str, database: str | None = None):
    return pymysql.connect(host=host, port=port, user=user, password=password, database=database,
                           connect_timeout=1, read_timeout=2, write_timeout=2, autocommit=True)


def run(cmd: str) -> None:
    print(f"$ {cmd}", flush=True)
    subprocess.run(cmd, shell=True, check=True)


def parse_node(spec: str) -> tuple[str, str, int]:
    """'db1=127.0.0.1:3311' -> ('db1', '127.0.0.1', 3311)"""
    name, addr = spec.split("=", 1)
    host, port = addr.rsplit(":", 1)
    return name, host, int(port)


def wsrep(conn, var: str) -> str:
    with conn.cursor() as cur:
        cur.execute("SHOW GLOBAL STATUS LIKE %s", (var,))
        row = cur.fetchone()
        return row[1] if row else ""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1", help="HAProxy / VIP address")
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--user", default="drill")
    ap.add_argument("--password", default="drill-pass")
    ap.add_argument("--database", default="drill")
    ap.add_argument("--duration", type=float, default=30.0, help="seconds of write traffic")
    ap.add_argument("--kill-after", type=float, default=8.0)
    ap.add_argument("--interval", type=float, default=0.05)
    ap.add_argument("--kill-cmd", required=True, help="shell command; {node} = node to kill")
    ap.add_argument("--restart-cmd", help="shell command; {node} = node to bring back")
    ap.add_argument("--node", action="append", default=[], metavar="NAME=HOST:PORT",
                    help="direct address of each node, for data checks (repeat)")
    ap.add_argument("--max-gap", type=float, default=15.0, help="fail if writes stop longer than this")
    ap.add_argument("--rejoin-timeout", type=float, default=120.0)
    ap.add_argument("--json-out")
    ap.add_argument("--md-out")
    args = ap.parse_args()

    nodes = {n: (h, p) for n, h, p in map(parse_node, args.node)}
    run_id = str(uuid.uuid4())

    # --- setup -------------------------------------------------------------
    conn = connect(args.host, args.port, args.user, args.password, args.database)
    with conn.cursor() as cur:
        cur.execute("""CREATE TABLE IF NOT EXISTS events (
                         id BIGINT AUTO_INCREMENT PRIMARY KEY,
                         run_id CHAR(36) NOT NULL,
                         seq INT NOT NULL,
                         written_at DOUBLE NOT NULL,
                         UNIQUE KEY run_seq (run_id, seq))""")
        cur.execute("SELECT @@wsrep_node_name")
        victim = cur.fetchone()[0]
    print(f"run {run_id}: HAProxy is sending writes to {victim}", flush=True)

    # --- write loop + kill -------------------------------------------------
    acked: list[tuple[int, float]] = []   # (seq, time) of acknowledged writes
    failed = 0
    seq = 0
    killed_at = None
    start = time.monotonic()
    conn = None
    while (now := time.monotonic()) - start < args.duration:
        if killed_at is None and now - start >= args.kill_after:
            run(args.kill_cmd.format(node=shlex.quote(victim)))
            killed_at = time.monotonic()
        seq += 1
        try:
            if conn is None:
                conn = connect(args.host, args.port, args.user, args.password, args.database)
            with conn.cursor() as cur:
                cur.execute("INSERT INTO events (run_id, seq, written_at) VALUES (%s, %s, %s)",
                            (run_id, seq, time.time()))
            acked.append((seq, time.monotonic()))
        except pymysql.MySQLError:
            failed += 1
            if conn is not None:
                with contextlib.suppress(pymysql.MySQLError, OSError):
                    conn.close()
            conn = None
        time.sleep(args.interval)

    if killed_at is None:
        print("duration ended before the kill; increase --duration", file=sys.stderr)
        return 2

    before = [t for _, t in acked if t < killed_at]
    after = [t for _, t in acked if t >= killed_at]
    gap = (after[0] - before[-1]) if before and after else float("inf")

    with connect(args.host, args.port, args.user, args.password, args.database) as c, c.cursor() as cur:
        cur.execute("SELECT @@wsrep_node_name")
        new_writer = cur.fetchone()[0]

    # --- durability check on every surviving node ---------------------------
    acked_seqs = {s for s, _ in acked}
    survivors = {}
    for name, (host, port) in nodes.items():
        if name == victim:
            continue
        with connect(host, port, args.user, args.password, args.database) as c, c.cursor() as cur:
            cur.execute("SELECT seq FROM events WHERE run_id = %s", (run_id,))
            present = {r[0] for r in cur.fetchall()}
            survivors[name] = {
                "rows": len(present),
                "lost_acked_writes": len(acked_seqs - present),
                "cluster_size": int(wsrep(c, "wsrep_cluster_size") or 0),
            }
    lost = max((s["lost_acked_writes"] for s in survivors.values()), default=0)

    # --- optional rejoin ------------------------------------------------------
    rejoin = None
    if args.restart_cmd and victim in nodes:
        t0 = time.monotonic()
        run(args.restart_cmd.format(node=shlex.quote(victim)))
        host, port = nodes[victim]
        while time.monotonic() - t0 < args.rejoin_timeout:
            try:
                with connect(host, port, args.user, args.password, args.database) as c:
                    if wsrep(c, "wsrep_local_state") == "4" and int(wsrep(c, "wsrep_cluster_size") or 0) == len(nodes):
                        with c.cursor() as cur:
                            cur.execute("SELECT COUNT(*) FROM events WHERE run_id = %s", (run_id,))
                            rows = cur.fetchone()[0]
                        rejoin = {"seconds": round(time.monotonic() - t0, 1), "rows": rows,
                                  "matches_survivors": all(rows == s["rows"] for s in survivors.values())}
                        break
            except pymysql.MySQLError:
                pass
            time.sleep(1)
        if rejoin is None:
            rejoin = {"seconds": None, "rows": None, "matches_survivors": False}

    # --- report ----------------------------------------------------------------
    result = {
        "run_id": run_id,
        "killed_node": victim,
        "new_writer": new_writer,
        "writes_attempted": seq,
        "writes_acknowledged": len(acked),
        "writes_failed": failed,
        "write_interruption_seconds": round(gap, 2),
        "lost_acknowledged_writes": lost,
        "survivors": survivors,
        "rejoin": rejoin,
    }
    ok = lost == 0 and gap <= args.max_gap and (rejoin is None or rejoin["matches_survivors"])
    result["passed"] = ok
    print(json.dumps(result, indent=2))

    if args.json_out:
        with open(args.json_out, "w") as fh:
            json.dump(result, fh, indent=2)
    if args.md_out:
        lines = [
            "## Galera failover drill",
            "",
            "| Metric | Result |",
            "|---|---|",
            f"| Killed node (SIGKILL) | `{victim}` |",
            f"| New writer chosen by HAProxy | `{new_writer}` |",
            f"| Writes acknowledged / attempted | {len(acked)} / {seq} |",
            f"| Write interruption | **{gap:.2f} s** |",
            f"| Acknowledged writes lost | **{lost}** |",
        ]
        if rejoin:
            lines.append(f"| Killed node rejoined (IST) | {rejoin['seconds']} s |")
            lines.append(f"| Rejoined node's data matches survivors | {rejoin['matches_survivors']} |")
        lines += ["", f"**Result: {'PASS' if ok else 'FAIL'}**", ""]
        with open(args.md_out, "w") as fh:
            fh.write("\n".join(lines))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
