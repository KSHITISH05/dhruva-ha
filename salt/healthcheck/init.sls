{%- from "galera/map.jinja" import galera with context %}
{%- set n = galera.nodes[grains['id']] %}

galera-health-script:
  file.managed:
    - name: /usr/local/bin/galera_health.py
    - source: salt://healthcheck/files/galera_health.py
    - mode: '0755'

galera-health-unit:
  file.managed:
    - name: /etc/systemd/system/galera-health.service
    - contents: |
        # Managed by Salt (healthcheck/init.sls)
        [Unit]
        Description=Galera-aware health endpoint for HAProxy
        After=mariadb.service

        [Service]
        ExecStart=/usr/local/bin/galera_health.py --serve {{ n.health_port }} --bind {{ n.address }} --socket {{ n.socket }}
        Restart=always
        RestartSec=2

        [Install]
        WantedBy=multi-user.target

galera-health-service:
  service.running:
    - name: galera-health
    - enable: True
    - watch:
      - file: galera-health-script
      - file: galera-health-unit
