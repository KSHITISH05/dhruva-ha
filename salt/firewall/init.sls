{#-
  Host firewall for Galera nodes, built with Salt's native iptables states.

  All lab rules live in a dedicated LAB-INPUT chain that INPUT jumps to first,
  so we never flush rules owned by something else (Docker, the cloud agent...).
  Every rule is *inserted at a fixed position*: with plain append, a rule added
  to the pillar later would land after the final DROP and silently do nothing.
-#}
{%- from "galera/map.jinja" import galera with context %}
{%- set fw = salt['pillar.get']('firewall', {}) %}
{%- set hap = salt['pillar.get']('haproxy', {}) %}
{%- set persist = not galera.single_host %}

{%- set members = [] %}
{%- set galera_ports = [] %}
{%- set mysql_ports = [hap.get('port', 3306)] %}
{%- for name, n in galera.nodes | dictsort %}
{%-   if n.address not in members %}{% do members.append(n.address) %}{% endif %}
{%-   for p in [n.gcomm_port, n.ist_port, n.sst_port, n.health_port] %}
{%-     if p not in galera_ports %}{% do galera_ports.append(p) %}{% endif %}
{%-   endfor %}
{%-   if n.mysql_port not in mysql_ports %}{% do mysql_ports.append(n.mysql_port) %}{% endif %}
{%- endfor %}

{#- (id, rule) pairs in the order they must appear in LAB-INPUT #}
{%- set rules = [
  ('loopback',    {'if': 'lo', 'jump': 'ACCEPT', 'comment': 'loopback'}),
  ('established', {'connstate': 'RELATED,ESTABLISHED', 'jump': 'ACCEPT', 'comment': 'return traffic'}),
  ('ssh',         {'proto': 'tcp', 'dport': 22, 'source': fw.get('admin_cidr', '0.0.0.0/0'), 'jump': 'ACCEPT', 'comment': 'ssh from admin network'}),
  ('mysql',       {'proto': 'tcp', 'dports': mysql_ports, 'source': fw.get('app_cidr', '127.0.0.0/8'), 'jump': 'ACCEPT', 'comment': 'mysql + haproxy from app network'}),
  ('haproxy-stats', {'proto': 'tcp', 'dport': hap.get('stats_port', 8404), 'source': fw.get('app_cidr', '127.0.0.0/8'), 'jump': 'ACCEPT', 'comment': 'haproxy stats'}),
] %}
{%- for m in members %}
{%-   do rules.append(('galera-' ~ m, {'proto': 'tcp', 'dports': galera_ports, 'source': m, 'jump': 'ACCEPT', 'comment': 'galera repl/IST/SST/health from ' ~ m})) %}
{%-   if not galera.single_host %}
{%-     do rules.append(('vrrp-' ~ m, {'proto': 'vrrp', 'source': m, 'jump': 'ACCEPT', 'comment': 'keepalived VRRP from ' ~ m})) %}
{%-   endif %}
{%- endfor %}
{%- do rules.append(('final', {'jump': 'DROP' if fw.get('default_deny', True) else 'RETURN', 'comment': 'default ' ~ ('deny' if fw.get('default_deny', True) else 'fall through')})) %}

firewall-packages:
  pkg.installed:
    - pkgs:
      - iptables
{%- if persist %}
      - iptables-persistent   # restores /etc/iptables/rules.v4 at boot
{%- endif %}

{%- if persist %}

# Salt compares rules against the saved file when `save: True`; make sure it
# exists even if iptables-persistent was installed without saving anything.
iptables-saved-rules-file:
  file.managed:
    - name: /etc/iptables/rules.v4
    - replace: False
    - makedirs: True
    - require_in:
      - iptables: lab-input-chain
{%- endif %}

lab-input-chain:
  iptables.chain_present:
    - name: LAB-INPUT
    - table: filter
    - require:
      - pkg: firewall-packages

{%- for id, rule in rules %}

lab-input-{{ id }}:
  iptables.insert:
    - table: filter
    - chain: LAB-INPUT
    - position: {{ loop.index }}
{%-   for k, v in rule.items() %}
    - {{ k }}: {{ v | json }}
{%-   endfor %}
    - save: {{ persist }}
    - require:
      - iptables: lab-input-chain
{%- endfor %}

input-jumps-to-lab:
  iptables.insert:
    - table: filter
    - chain: INPUT
    - position: 1
    - jump: LAB-INPUT
    - save: {{ persist }}
    - require:
      - iptables: lab-input-final
