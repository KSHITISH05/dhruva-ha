haproxy-package:
  pkg.installed:
    - name: haproxy

haproxy-config:
  file.managed:
    - name: /etc/haproxy/haproxy.cfg
    - source: salt://haproxy/files/haproxy.cfg.jinja
    - template: jinja
    - check_cmd: haproxy -c -f    # refuse to install a config HAProxy can't parse
    - require:
      - pkg: haproxy-package

haproxy-service:
  service.running:
    - name: haproxy
    - enable: True
    - reload: True                # reload keeps existing connections alive
    - watch:
      - file: haproxy-config
