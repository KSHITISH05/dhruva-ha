#!/usr/bin/env bash
# Run the whole 3-node lab on ONE Linux host (the CI runner, or any Ubuntu VM),
# configured by the Salt states in this repo in masterless mode.
#
#   sudo scripts/single_host_lab.sh up          # Salt apply, bootstrap db1, join db2/db3, health + HAProxy
#   sudo scripts/single_host_lab.sh status      # wsrep state per node + HAProxy backend view
#   sudo scripts/single_host_lab.sh kill db1    # SIGKILL a node (power-cut simulation)
#   sudo scripts/single_host_lab.sh start db1   # start a node as a joiner (IST/SST from a donor)
#   sudo scripts/single_host_lab.sh idempotent  # re-apply Salt; fail if anything changes
#   sudo scripts/single_host_lab.sh down        # stop everything and delete the lab data
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT=/srv/galera-lab
HEALTH="$REPO/salt/healthcheck/files/galera_health.py"
export LAB_PILLAR=single_host

LAB_STATES=common,galera.packages,galera.single_host,haproxy.single_host,firewall

salt_call() {
  PYTHONWARNINGS=ignore::DeprecationWarning \
  salt-call --local --retcode-passthrough --log-level=warning \
    --file-root="$REPO/salt" --pillar-root="$REPO/pillar" "$@"
}

# Single source of truth for node names/ports: the Salt pillar.
nodes_json() { salt_call --out=json pillar.get galera:nodes | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["local"]))'; }
node_field() { python3 -c "import json; print(json.load(open('$ROOT/nodes.json'))['$1'].get('$2', ''))"; }
node_names() { python3 -c "import json; print(' '.join(sorted(json.load(open('$ROOT/nodes.json')))))"; }

sock() { echo "$ROOT/$1/run/mysqld.sock"; }

wait_synced() {   # wait until galera_health says the node is Synced + Primary
  local n=$1 timeout=${2:-180} t=0
  until python3 "$HEALTH" --socket "$(sock "$n")" >/dev/null 2>&1; do
    sleep 2; t=$((t + 2))
    if (( t >= timeout )); then
      echo "!! $n not synced after ${timeout}s"; tail -n 40 "$ROOT/$n/log/error.log" || true; return 1
    fi
  done
  echo "   $n is Synced ($(python3 "$HEALTH" --socket "$(sock "$n")"))"
}

start_node() {    # start_node <name> [extra mariadbd args]
  local n=$1; shift
  echo ">> starting $n $*"
  nohup mariadbd --defaults-file="$ROOT/$n/my.cnf" "$@" >>"$ROOT/$n/log/stdout.log" 2>&1 &
}

start_health() {
  local n=$1 port
  port=$(node_field "$n" health_port)
  nohup python3 "$HEALTH" --serve "$port" --bind 127.0.0.1 --socket "$(sock "$n")" \
    >>"$ROOT/$n/log/health.log" 2>&1 &
  echo $! >"$ROOT/$n/run/health.pid"
}

stop_distro_services() {
  # Package installs start the stock services; they would grab port 3306.
  for svc in mariadb mysql haproxy; do
    (systemctl stop "$svc" || service "$svc" stop) >/dev/null 2>&1 || true
  done
  # Ubuntu may ship an enforcing AppArmor profile that blocks our /srv data dirs.
  if [ -f /etc/apparmor.d/usr.sbin.mariadbd ] && command -v apparmor_parser >/dev/null; then
    apparmor_parser -R /etc/apparmor.d/usr.sbin.mariadbd >/dev/null 2>&1 || true
  fi
}

cmd_up() {
  echo ">> salt: packages, firewall, per-node configs, data dirs, HAProxy config"
  salt_call state.apply "$LAB_STATES"
  stop_distro_services
  mkdir -p "$ROOT" && nodes_json >"$ROOT/nodes.json"

  local boot joiners=()
  for n in $(node_names); do
    if [ "$(node_field "$n" bootstrap)" = "True" ]; then boot=$n; else joiners+=("$n"); fi
  done

  start_node "$boot" --wsrep-new-cluster
  wait_synced "$boot"

  local u p db
  u=$(salt_call --out=newline_values_only pillar.get app_user:name)
  p=$(salt_call --out=newline_values_only pillar.get app_user:password)
  db=$(salt_call --out=newline_values_only pillar.get app_user:database)
  mysql --socket="$(sock "$boot")" <<SQL
CREATE DATABASE IF NOT EXISTS \`$db\`;
CREATE USER IF NOT EXISTS '$u'@'%' IDENTIFIED BY '$p';
GRANT ALL PRIVILEGES ON \`$db\`.* TO '$u'@'%';
SQL

  for n in "${joiners[@]}"; do start_node "$n"; wait_synced "$n" 300; done
  for n in $(node_names); do start_health "$n"; done

  echo ">> starting HAProxy"
  haproxy -f "$ROOT/haproxy.cfg" -D
  for _ in $(seq 1 30); do
    curl -fs "http://127.0.0.1:8404/;csv" | grep -q '^galera_single_writer,db.*,UP,' && break
    sleep 1
  done
  cmd_status
}

cmd_status() {
  for n in $(node_names); do
    printf '%-4s %s\n' "$n" "$(python3 "$HEALTH" --socket "$(sock "$n")" || true)"
  done
  echo "HAProxy backend (server,status):"
  curl -fs "http://127.0.0.1:8404/;csv" | awk -F, '$1=="galera_single_writer" && $2!="BACKEND" {print "   " $2 "," $18}' || true
}

cmd_kill() {
  local n=$1
  echo ">> SIGKILL $n (mariadbd pid $(cat "$ROOT/$n/run/mysqld.pid"))"
  kill -9 "$(cat "$ROOT/$n/run/mysqld.pid")"
}

cmd_start() {
  local n=$1
  start_node "$n"
  wait_synced "$n" 300
}

cmd_idempotent() {
  # A second run of the same states on a converged host must change nothing.
  local changed
  changed=$(salt_call --out=json state.apply "$LAB_STATES" | python3 -c '
import json, sys
ret = json.load(sys.stdin)["local"]
changed = [k.split("_|-")[1] for k, v in ret.items() if v.get("changes")]
print("\n".join(changed))')
  if [ -n "$changed" ]; then
    echo "!! not idempotent, these states changed on the second run:"; echo "$changed"; return 1
  fi
  echo "idempotent: second Salt run changed nothing"
}

cmd_down() {
  pkill -f "galera_health.py --serve" || true
  if [ -f "$ROOT/haproxy.pid" ]; then kill "$(cat "$ROOT/haproxy.pid")" 2>/dev/null || true; fi
  pkill -f "mariadbd --defaults-file=$ROOT" || true
  sleep 2
  rm -rf "$ROOT"
  echo "lab removed"
}

case "${1:-}" in
  up)     cmd_up ;;
  status) cmd_status ;;
  kill)   cmd_kill "${2:?node}" ;;
  start)  cmd_start "${2:?node}" ;;
  idempotent) cmd_idempotent ;;
  down)   cmd_down ;;
  *) sed -n '2,11p' "$0"; exit 1 ;;
esac
