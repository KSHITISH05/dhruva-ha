{%- from "galera/map.jinja" import galera with context %}

common-packages:
  pkg.installed:
    - pkgs:
      - rsync          # Galera SST
      - socat
      - lsof
      - iproute2
      - curl
      - python3
{%- if not galera.single_host %}
      - chrony         # Galera nodes need consistent clocks for sane logs/metrics

# Database nodes must not swap; HAProxy on the keepalived pair must be able to
# bind the VIP even while the VIP lives on the other node.
galera-sysctl:
  file.managed:
    - name: /etc/sysctl.d/60-galera-lab.conf
    - contents: |
        # Managed by Salt (common/init.sls)
        vm.swappiness = 1
        net.ipv4.ip_nonlocal_bind = 1
        net.ipv4.tcp_keepalive_time = 60
        net.ipv4.tcp_keepalive_intvl = 10
        net.ipv4.tcp_keepalive_probes = 6

galera-sysctl-apply:
  cmd.run:
    - name: sysctl -p /etc/sysctl.d/60-galera-lab.conf
    - onchanges:
      - file: galera-sysctl
{%- endif %}
