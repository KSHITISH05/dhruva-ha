#!/usr/bin/env bash
# Vagrant provisioner: install Salt (onedir build) and apply the highstate for this node.
set -euo pipefail
NODE="$1"

if ! command -v salt-call >/dev/null 2>&1; then
  curl -fsSL -o /tmp/bootstrap-salt.sh \
    https://github.com/saltstack/salt-bootstrap/releases/latest/download/bootstrap-salt.sh
  # -X: install only, don't start the minion daemon (we run masterless)
  sh /tmp/bootstrap-salt.sh -X stable 3007
fi

echo "$NODE" >/etc/salt/minion_id
salt-call --local --id "$NODE" --retcode-passthrough \
  --file-root=/vagrant/salt --pillar-root=/vagrant/pillar \
  state.apply
