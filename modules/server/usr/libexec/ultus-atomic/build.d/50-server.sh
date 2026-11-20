#!/bin/bash
# Build-time server step. The shared build runs every script under
# /usr/libexec/ultus-atomic/build.d/ in name order, so the server's unit
# enablement travels with the server module and the shared build names none
# of it.
set -ouex pipefail

# The unit file's [Install] section enables nothing by itself, and the base's
# preset scripts do not know this unit. A mount that is not enabled is a data
# disk that never appears, so assert the enabled state at build time rather
# than trust the symlink.
systemctl enable var-srv.mount
enabled=$(systemctl is-enabled var-srv.mount || true)
[[ $enabled == enabled ]] || {
  echo "var-srv.mount is not enabled (got: ${enabled:-nothing}); the data disk would not mount" >&2
  exit 1
}

# The workloads are rootless, so they run as a dedicated user. The uid is fixed
# because container uid 1000 maps to it under --userns=keep-id, and a moved uid
# would leave every state directory owned by nobody. The subordinate range is
# what lets Podman map container users at all.
groupadd -g 1000 agents
# login.defs allocates a second range (524288) by default, which leaves the file
# with two entries and makes which one Podman uses depend on line order. Take the
# allocation out and add the one range the spec names.
useradd -u 1000 -g agents -M -d /var/lib/agents -s /sbin/nologin \
  -K SUB_UID_COUNT=0 -K SUB_GID_COUNT=0 \
  -c "ultus agent workloads" agents
usermod --add-subuids 100000-165535 --add-subgids 100000-165535 agents

# loginctl enable-linger writes this file. The build runs with no systemd as PID
# 1, so loginctl cannot reach a manager here; the file is the whole effect, and
# systemd reads it on the first boot.
install -d -m 0755 /var/lib/systemd/linger
touch /var/lib/systemd/linger/agents
chmod 0644 /var/lib/systemd/linger/agents

# Every unit this module ships is enabled here and asserted in the same pass. A
# unit that is installed but not enabled never runs, and the failure stays silent
# until the first boot needs it.
units=(
  ultus-data-prepare.service
  opencode-env.service
  hermes-env.service
  ultus-network.service
  opencode.service
  hermes.service
)
systemctl enable "${units[@]}"
for unit in "${units[@]}"; do
  enabled=$(systemctl is-enabled "$unit" || true)
  [[ $enabled == enabled ]] || {
    echo "$unit is not enabled (got: ${enabled:-nothing}); it would never run on the host" >&2
    exit 1
  }
done
