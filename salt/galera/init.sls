{%- from "galera/map.jinja" import galera with context %}
include:
  - galera.packages
  - galera.config
  - galera.service
{%- if galera.nodes[grains['id']].bootstrap %}
  - galera.users
{%- endif %}
