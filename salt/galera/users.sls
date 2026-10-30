{#- Application database + user, created once on the bootstrap node (Galera replicates it). #}
{%- set app = salt['pillar.get']('app_user', {}) %}

galera-app-user:
  cmd.run:
    - name: >-
        mysql -e "CREATE DATABASE IF NOT EXISTS \`{{ app.database }}\`;
        CREATE USER IF NOT EXISTS '{{ app.name }}'@'%' IDENTIFIED BY '{{ app.password }}';
        GRANT ALL PRIVILEGES ON \`{{ app.database }}\`.* TO '{{ app.name }}'@'%';"
    - unless: mysql -N -e "SELECT 1 FROM mysql.user WHERE user = '{{ app.name }}'" | grep -q 1
    - require:
      - service: mariadb-service
