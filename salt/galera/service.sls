{#-
  Start MariaDB as a Galera member.

  Deliberately NOT using `watch` on the config file: if Salt restarted mariadb
  on every node at once after a config change, the whole cluster would go down
  together. Config changes are rolled out with scripts/rolling_restart.sh, one
  node at a time, waiting for each to return to Synced (see docs/RUNBOOK.md).
-#}
{%- from "galera/map.jinja" import galera with context %}
{%- set n = galera.nodes[grains['id']] %}
{#- grastate.dat holds a real cluster UUID once the node has been part of a cluster #}
{%- set joined = "grep -Eq '^uuid:[[:space:]]+[0-9a-f]{8}-' " ~ n.datadir ~ "/grastate.dat && ! grep -q '00000000-0000-0000-0000-000000000000' " ~ n.datadir ~ "/grastate.dat" %}

{%- if n.bootstrap %}
# First boot of the first node: start a brand-new cluster.
galera-bootstrap:
  cmd.run:
    - name: systemctl stop mariadb && galera_new_cluster
    - unless: {{ joined | yaml_squote }}
    - require:
      - file: galera-config
{%- else %}
# First boot of a joiner: restart with the Galera config so it joins (SST from a donor).
galera-join:
  cmd.run:
    - name: systemctl restart mariadb
    - unless: {{ joined | yaml_squote }}
    - timeout: 600
    - require:
      - file: galera-config
{%- endif %}

mariadb-service:
  service.running:
    - name: mariadb
    - enable: True
    - require:
      - cmd: {{ 'galera-bootstrap' if n.bootstrap else 'galera-join' }}
