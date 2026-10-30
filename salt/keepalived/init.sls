keepalived-package:
  pkg.installed:
    - name: keepalived

keepalived-config:
  file.managed:
    - name: /etc/keepalived/keepalived.conf
    - source: salt://keepalived/files/keepalived.conf.jinja
    - template: jinja
    - mode: '0640'
    - require:
      - pkg: keepalived-package

keepalived-service:
  service.running:
    - name: keepalived
    - enable: True
    - watch:
      - file: keepalived-config
