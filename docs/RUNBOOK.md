# Runbook: Galera cluster

Procedures for the failure modes this lab is built to rehearse. Commands are for
the VM lab (`vagrant ssh dbN`); on the single-host lab use
`sudo scripts/single_host_lab.sh status | kill | start`.

## Quick health check

```bash
curl -s http://192.168.56.11:9200/        # 200 + JSON when Synced/Primary, 503 otherwise
mysql -e "SHOW GLOBAL STATUS WHERE Variable_name IN
  ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment','wsrep_ready')"
```

Healthy: `wsrep_cluster_size = 3`, `wsrep_cluster_status = Primary`,
`wsrep_local_state_comment = Synced`, `wsrep_ready = ON`.
HAProxy stats: `http://192.168.56.100:8404/`.

## 1. One node is down

**Impact:** none if it was a standby. If it was the writer, HAProxy marks it DOWN
after 2 failed health checks (~2 s) and sends writes to the next node. The
survivors pause writes until Galera evicts the dead member (see section 6).

1. Confirm the other two still report `cluster_size = 2` and `Primary`.
2. Find out why it died: `journalctl -u mariadb -n 100`, `/var/log/mysql/error.log`, disk space, OOM killer (`dmesg | grep -i kill`).
3. Start it: `sudo systemctl start mariadb`. It rejoins and catches up with an
   **IST** (incremental, from gcache) if it was not gone too long, otherwise a full **SST**.
4. Wait for `Synced` (health endpoint returns 200) before calling it resolved.

## 2. Whole cluster went down (power cut, all nodes stopped)

Never run `galera_new_cluster` on a random node: you may bootstrap from a node
that is missing the last transactions and silently lose them.

1. On every node: `sudo cat /var/lib/mysql/grastate.dat`
2. Bootstrap from the node with `safe_to_bootstrap: 1`. If none has it (hard
   crash), pick the node with the **highest `seqno`**. If seqno is -1 everywhere, run
   `sudo mariadbd --wsrep-recover` on each node and compare the recovered positions.
3. On that node only: set `safe_to_bootstrap: 1` if needed, then `sudo galera_new_cluster`.
4. Start the other nodes normally: `sudo systemctl start mariadb`.

## 3. Split brain / no Primary component

Symptom: nodes answer `wsrep_cluster_status = non-Primary` and refuse queries
(`WSREP has not yet prepared node for application use`). Galera does this on
purpose when a node cannot see a majority of the cluster.

1. Fix the network first (`ip a`, `iptables -S LAB-INPUT`, can the nodes reach each other on 4567?).
2. If the partition with the most up-to-date data must serve traffic before
   the network is fixed, on ONE node of that partition:
   `SET GLOBAL wsrep_provider_options='pc.bootstrap=YES';`
3. The other nodes rejoin and resync when the network heals.

## 4. Applying a config change (rolling restart)

Salt manages the config file but intentionally does **not** restart MariaDB on
change: restarting every node at once would take the whole cluster down.

```bash
vagrant ssh db1 -c "sudo salt-call --local --file-root=/vagrant/salt --pillar-root=/vagrant/pillar state.apply galera.config"   # repeat per node
scripts/rolling_restart.sh       # db3 -> db2 -> db1, waits for Synced between nodes
```

The writer (db1) goes last, so writes fail over once, not three times.

## 5. Writes failing with deadlock errors

`ERROR 1213 Deadlock found` on a Galera cluster is usually a **certification
conflict**: two nodes accepted conflicting writes. HAProxy here sends all writes to
a single node (`backup` servers) to avoid this. Check that nothing bypasses
HAProxy and writes to a node directly.

## 6. Failure-detection tuning (measured)

When a node dies without warning, the survivors keep the dead member in the
cluster view until `evs.suspect_timeout` expires, and writes stall until it is
evicted. Measured with `scripts/failover_drill.py` (single-host lab, writes every 50 ms,
writer killed with SIGKILL):

| Setting | Write interruption | Acknowledged writes lost |
|---|---|---|
| Galera defaults (`suspect_timeout` 5 s) | 6.2 s | 0 |
| `suspect_timeout` 2 s, `inactive_timeout` 4 s, `keepalive_period` 0.5 s | 3.2 s | 0 |

Trade-off: a lower suspect timeout evicts a healthy node faster during a short
network hiccup, which then needs an IST/SST to rejoin. On a flaky network, raise it.
Galera enforces `keepalive_period < suspect_timeout / 3` and refuses to start otherwise.

## 7. Durability note

`innodb_flush_log_at_trx_commit = 2` skips the per-commit fsync because a commit
is only acknowledged once the write-set has been replicated to the other nodes.
Losing data would need all nodes to crash within ~1 s of each other. If that risk
is not acceptable (single-rack, shared power), set it back to `1`.
