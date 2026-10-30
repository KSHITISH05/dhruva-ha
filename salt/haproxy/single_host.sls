{%- from "galera/map.jinja" import galera with context %}

haproxy-package:
  pkg.installed:
    - name: haproxy

haproxy-lab-config:
  file.managed:
    - name: {{ galera.lab_root }}/haproxy.cfg
    - source: salt://haproxy/files/haproxy.cfg.jinja
    - template: jinja
    - makedirs: True
    - check_cmd: haproxy -c -f
    - require:
      - pkg: haproxy-package
