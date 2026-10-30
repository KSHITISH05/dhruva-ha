# Three VMs on a private host-only network (see Vagrantfile).
# HAProxy + keepalived run on db1 and db2 and share a floating VIP.
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
  nodes:
    db1: {address: 192.168.56.11, bootstrap: true}
    db2: {address: 192.168.56.12}
    db3: {address: 192.168.56.13}

haproxy:
  bind_address: 192.168.56.100      # the keepalived VIP
  port: 3306
  stats_port: 8404
  writer: db1                       # single-writer; db2/db3 are hot standbys
  lb_nodes: [db1, db2]

keepalived:
  vip: 192.168.56.100/24
  interface: eth1                  # fallback; the template auto-detects the NIC holding the node IP
  virtual_router_id: 51
  priorities: {db1: 150, db2: 100}

firewall:
  admin_cidr: 10.0.2.0/24           # Vagrant NAT network (ssh)
  app_cidr: 192.168.56.0/24         # who may connect to MySQL / the VIP
  default_deny: true                # LAB-INPUT chain ends in DROP

app_user:
  name: app
  password: change-me-in-a-secret-pillar
  database: appdb
