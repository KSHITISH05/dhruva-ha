{#-
  Render the three node configs on ONE host (CI runner / laptop VM).
  Uses the exact template the VM lab uses; only paths and ports differ.
  Processes are started by scripts/single_host_lab.sh (no init system needed).
-#}
{%- from "galera/map.jinja" import galera with context %}

{%- for name, n in galera.nodes | dictsort %}

galera-lab-{{ name }}-dirs:
  file.directory:
    - names:
      - {{ galera.lab_root }}/{{ name }}/data
      - {{ galera.lab_root }}/{{ name }}/run
      - {{ galera.lab_root }}/{{ name }}/log
    - user: mysql
    - group: mysql
    - makedirs: True
    - require:
      - pkg: galera-packages

galera-lab-{{ name }}-config:
  file.managed:
    - name: {{ n.cnf }}
    - source: salt://galera/files/galera.cnf.jinja
    - template: jinja
    - context:
        node: {{ name }}
    - mode: '0644'
    - require:
      - file: galera-lab-{{ name }}-dirs

galera-lab-{{ name }}-initdb:
  cmd.run:
    - name: mariadb-install-db --defaults-file={{ n.cnf }} --user=mysql --skip-test-db > {{ galera.lab_root }}/{{ name }}/log/install-db.log 2>&1
    - creates: {{ n.datadir }}/mysql
    - require:
      - file: galera-lab-{{ name }}-config
{%- endfor %}
