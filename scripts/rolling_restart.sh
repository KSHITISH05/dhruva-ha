#!/usr/bin/env bash
# Roll a MariaDB restart (e.g. after a config change) through the VM lab, ONE node
# at a time, waiting for each node to be Synced again before touching the next.
# The current writer goes last, so HAProxy fails writes over only once.
#
#   scripts/rolling_restart.sh            # order: db3 db2 db1
#   ORDER="db2 db3 db1" scripts/rolling_restart.sh
set -euo pipefail

ORDER=${ORDER:-"db3 db2 db1"}
declare -A IP=([db1]=192.168.56.11 [db2]=192.168.56.12 [db3]=192.168.56.13)
TIMEOUT=${TIMEOUT:-300}

for node in $ORDER; do
  echo ">> restarting mariadb on $node"
  vagrant ssh "$node" -c "sudo systemctl restart mariadb"
  start=$SECONDS
  # galera_health.py answers 200 only when the node is Synced + Primary
  until vagrant ssh "$node" -c "curl -fs http://${IP[$node]}:9200/" >/dev/null 2>&1; do
    if (( SECONDS - start > TIMEOUT )); then
      echo "!! $node did not return to Synced in ${TIMEOUT}s - stopping the roll here"; exit 1
    fi
    sleep 3
  done
  echo "   $node Synced after $((SECONDS - start))s"
done
echo "rolling restart complete"
