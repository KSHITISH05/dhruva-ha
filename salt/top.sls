# VM lab: every node runs MariaDB/Galera, the firewall and the health endpoint.
# db1 and db2 also run HAProxy + keepalived and share the floating VIP.
base:
  'db*':
    - common
    - firewall
    - galera
    - healthcheck
  'db1,db2':
    - match: list
    - haproxy
    - keepalived
