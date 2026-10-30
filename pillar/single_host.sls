# The same cluster squeezed onto ONE Linux host (CI runner or a laptop VM).
# Each node gets its own ports, data dir and socket; configs come from the
# same Salt templates the VM lab uses.
galera:
  cluster_name: lab_cluster
  sst_method: rsync
  # Failure detection. Galera's default suspect_timeout (5 s) stalls writes on the
  # survivors for ~5 s after a node dies. Lower = faster failover, but more risk of
  # evicting a healthy node during a network blip. Measured impact: docs/RUNBOOK.md.
  provider_tuning:
    evs.suspect_timeout: PT2S
    evs.inactive_timeout: PT4S
    evs.keepalive_period: PT0.5S      # Galera requires keepalive < suspect_timeout / 3
  single_host: true
  lab_root: /srv/galera-lab
  nodes:
    db1: {address: 127.0.0.1, mysql_port: 3311, gcomm_port: 4567, ist_port: 4568, sst_port: 4444, health_port: 9201, bootstrap: true}
    db2: {address: 127.0.0.1, mysql_port: 3312, gcomm_port: 4577, ist_port: 4578, sst_port: 4454, health_port: 9202}
    db3: {address: 127.0.0.1, mysql_port: 3313, gcomm_port: 4587, ist_port: 4588, sst_port: 4464, health_port: 9203}

haproxy:
  bind_address: 127.0.0.1
  port: 3306
  stats_port: 8404
  writer: db1

firewall:
  admin_cidr: 0.0.0.0/0             # never lock the CI runner out of ssh
  app_cidr: 127.0.0.0/8
  default_deny: false               # LAB-INPUT ends in RETURN so the runner keeps its own policy

app_user:
  name: drill
  password: drill-pass
  database: drill
