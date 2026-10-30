{#- Pick the environment with LAB_PILLAR (default: the 3-VM lab). #}
base:
  '*':
    - {{ salt['environ.get']('LAB_PILLAR', 'lab_vms') }}
