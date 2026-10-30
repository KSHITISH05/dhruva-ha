{%- from "galera/map.jinja" import galera with context %}
{%- set n = galera.nodes[grains['id']] %}

galera-config:
  file.managed:
    - name: {{ n.cnf }}
    - source: salt://galera/files/galera.cnf.jinja
    - template: jinja
    - context:
        node: {{ n.name }}
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - pkg: galera-packages
