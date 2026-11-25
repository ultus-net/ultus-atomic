#!/usr/bin/env bash
# Boot the server image under QEMU and prove the headless behaviour end to end.
#
# Needs qemu-system-x86_64, edk2-ovmf, and a second disk carrying an ext4
# filesystem labelled ultus-data (tests/vm/make-disk.sh with SERVER_DISK=1).
#
#   SERVER_DATA_DISK=output/qcow2/data.qcow2 QEMU_NO_REBOOT=0 \
#     tests/vm/boot-smoke-server.sh [disk.qcow2] [boot.log]
#
# The guest needs outbound HTTPS for the two workload image pulls. The reboot
# stage needs QEMU to survive a guest reboot, so QEMU_NO_REBOOT=0 is required;
# the snapshot stays on, which keeps the guest's writes across that reboot and
# still leaves the source disk untouched.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=tests/vm/lib/qemu.sh
source "$repo_root/tests/vm/lib/qemu.sh"

disk=${1:-$repo_root/output/qcow2/disk.qcow2}
log=${2:-$repo_root/.vm/server-boot.log}
timeout_s=${BOOT_TIMEOUT:-1800}
test_user=${TEST_USER:-dux}
test_password=${TEST_PASSWORD:-dux-test}
data_disk=${SERVER_DATA_DISK:-}
run_dir=$(dirname -- "$log")
mkdir -p "$run_dir"

[[ -f $data_disk ]] || {
  echo "missing data disk: ${data_disk:-SERVER_DATA_DISK is unset}" >&2
  echo "build one with: sudo SERVER_DISK=1 tests/vm/make-disk.sh <image> <output>" >&2
  exit 2
}
[[ ${QEMU_NO_REBOOT:-1} == 0 ]] || {
  echo "this test reboots the guest; set QEMU_NO_REBOOT=0" >&2
  exit 2
}

# Devbox is pinned here rather than read from the image, because the probe must
# not change when a workload digest moves. Keep it equal to opencode.service.
devbox_image=ghcr.io/ultus-net/devbox@sha256:8649976df3ebbd38f8b6b323b2a8522cb7de6021e969f836ed57c0cf4ab5e81a

# The log is appended once per stage, so a wait after the guest reboots must
# look only at lines the reboot wrote. Without the offset the old login prompt
# matches instantly and the test types into a booting console.
log_mark=0
mark_log() { log_mark=$(wc -l <"$log" 2>/dev/null || printf 0); }
wait_for_new() {
  local pattern=$1 deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    # grep -c, not -q: -q exits at the first match, and `set -o pipefail` then
    # reports tail's SIGPIPE as the pipeline status. A match early in a long
    # tail, like the login shell prompt after the reboot, would read as absent.
    if [[ -f $log ]] && tail -n "+$((log_mark + 1))" "$log" | grep -cE "$pattern" >/dev/null; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "qemu exited while waiting for: $pattern" >&2
      return 1
    fi
    sleep 2
  done
  return 1
}

# Podman holds the guest console while a container runs, so a line typed during
# a probe is never processed. Send one probe, wait for its marker, then send the
# next.
probe() {
  local marker=$1 budget=$2 command=$3
  mark_log
  serial_write "$command"
  if ! wait_for_new "$marker" "$budget"; then
    echo "boot failed: ${marker} was not reported within ${budget}s" >&2
    tail -30 "$log" >&2 || true
    exit 1
  fi
}

dump_workloads() {
  echo "collecting workload diagnostics on the serial console" >&2
  serial_write 'echo ULTUS_DIAG_BEGIN'
  # The containers are rootless, so their logs live in the agents user's storage
  # and rootful podman would report no such container. The probes also cannot
  # start from the test account's 0700 home.
  serial_write 'cd /var/tmp'
  serial_write 'systemctl --no-pager status opencode.service hermes.service | head -40'
  serial_write 'journalctl -u opencode -u hermes --no-pager | tail -40'
  serial_write 'sudo -u agents env HOME=/var/lib/agents XDG_RUNTIME_DIR=/run/user/1000 podman logs opencode 2>&1 | tail -20'
  serial_write 'sudo -u agents env HOME=/var/lib/agents XDG_RUNTIME_DIR=/run/user/1000 podman logs hermes 2>&1 | tail -20'
  serial_write 'printf "ULTUS_DIAG_END:%s\n" ok'
  wait_for_new 'ULTUS_DIAG_END:ok' 120 || echo "diagnostics did not finish in 120s" >&2
  sleep 2
}

# The test account holds a password and is in wheel. sudo -S reads the password
# from its input, so prime the timestamp and then run commands uninterrupted.
prime_sudo() {
  # One prime per boot, and stage two writes a fresh log file. Mark here so the
  # marker must come from this attempt, not from the previous boot's sudo.
  mark_log
  serial_write "printf '%s\n' '$test_password' | sudo -S -v && printf 'ULTUS_SUDO:%s\n' ok"
  wait_for_new 'ULTUS_SUDO:ok' 60 || { echo "sudo did not accept the test password" >&2; exit 1; }
}

# Stage one: the data disk is present, so the mount, the rootless write, the
# isolation canaries, the backup and the restart-after-reboot all have a subject.
qemu_extra_drives+=(-drive "file=$data_disk,if=virtio,format=raw")
vm_start

if ! serial_login; then
  tail -20 "$log" >&2 || true
  exit 1
fi

prime_sudo

# The probes run as `agents`, and sudo keeps the caller's directory. The login
# lands in the test account's 0700 home, so `agents` cannot enter it and every
# probe dies before podman starts. Move to a directory both users can traverse.
probe 'ULTUS_CWD:ok' 60 'cd /var/tmp && printf "ULTUS_CWD:%s\n" ok'

# The workspace marker comes from a probe on the guest, not from a process
# check: a unit that is active while it serves nothing still fails here.
probe 'ULTUS_MOUNT:(ok|missing)' 60 'mountpoint -q /var/srv && printf "ULTUS_MOUNT:%s\n" ok || printf "ULTUS_MOUNT:%s\n" missing'
probe 'ULTUS_LINGER:(yes|no)' 60 'printf "ULTUS_LINGER:%s\n" "$(loginctl show-user agents -p Linger --value)"'
# The image entrypoint is the workload itself, so a probe that wants a shell has
# to name one. The owner check runs as root because the mounted directory is
# 0700 agents and the test account cannot stat inside it. The image pull happens
# inside this probe, so its budget is the boot budget.
probe 'ULTUS_OWNER:[0-9]+' "$timeout_s" "sudo -u agents env HOME=/var/lib/agents XDG_RUNTIME_DIR=/run/user/1000 podman run --rm --userns=keep-id -u 1000 --entrypoint /bin/sh -v /var/srv/opencode/share:/state:z $devbox_image -c 'touch /state/probe' && sudo stat -c 'ULTUS_OWNER:%u' /var/srv/opencode/share/probe"
# The image ships an empty /home, so the canary is the host's own account: that
# path exists only if the container can see the host filesystem.
probe 'ULTUS_CANARY_END:ok' "$timeout_s" "for p in /home/$test_user /root/.ssh /run/podman/podman.sock /dev/kvm; do sudo -u agents env HOME=/var/lib/agents XDG_RUNTIME_DIR=/run/user/1000 podman run --rm --userns=keep-id -u 1000 --read-only --entrypoint /bin/sh $devbox_image -c \"test -e \$p\" && printf 'ULTUS_CANARY:%s:readable\n' \"\$p\"; done; printf 'ULTUS_CANARY_END:%s\n' ok"
probe 'ULTUS_LISTEN:(wide|loopback)' 60 'ss -ltnH | awk "{print \$4}" | grep -vE "^(\[?::1\]?|127\.[0-9.]+)(%[^:]+)?:" | grep -q . && printf "ULTUS_LISTEN:%s\n" wide || printf "ULTUS_LISTEN:%s\n" loopback'
probe 'ULTUS_PROBE_END:ok' 60 'printf "ULTUS_PROBE_END:%s\n" ok'

for marker in 'ULTUS_CWD:ok' 'ULTUS_MOUNT:ok' 'ULTUS_LINGER:yes' 'ULTUS_OWNER:1000' 'ULTUS_CANARY_END:ok' 'ULTUS_LISTEN:loopback'; do
  if ! grep -qF "$marker" "$log"; then
    echo "boot failed: ${marker} was not reported" >&2
    grep -a 'ULTUS_' "$log" >&2 || true
    exit 1
  fi
done
# The console echoes the probe, and that echo carries the printf format. Match a
# concrete path so the echo cannot satisfy this check on its own.
if grep -qE 'ULTUS_CANARY:/[^[:space:]]*:readable' "$log"; then
  echo "boot failed: a workload container read a host-only path" >&2
  grep -a 'ULTUS_CANARY:' "$log" >&2 || true
  exit 1
fi
if grep -q 'ULTUS_OWNER:0' "$log"; then
  echo "boot failed: the container's write landed owned by root" >&2
  exit 1
fi

# Secrets, the backup repository and a canary file the backup must contain. The
# files are written as the test account and installed as root, because sudo -S
# would otherwise consume the piped content as its password.
probe 'ULTUS_SECRETS:ok' 60 "printf '%s\n' 'OPENCODE_PASSWORD=server-secret' 'API_SERVER_KEY=api-key' 'OPENROUTER_API_KEY=provider-key' 'TZ=UTC' > /tmp/secrets.txt && sudo install -m 0600 /tmp/secrets.txt /var/srv/ultus/secrets.env && printf 'ULTUS_SECRETS:%s\n' ok"
probe 'ULTUS_BACKUP_ENV:ok' 60 "printf '%s\n' 'RESTIC_REPOSITORY=/var/srv/ultus/restic-test' 'RESTIC_PASSWORD_FILE=/var/srv/ultus/restic-password' > /tmp/backup.txt && sudo install -m 0600 /tmp/backup.txt /var/srv/ultus/backup.env && printf 'ULTUS_BACKUP_ENV:%s\n' ok"
probe 'ULTUS_RESTIC_PASS:ok' 60 "printf '%s\n' 'restic-test-password' > /tmp/restic-pass.txt && sudo install -m 0600 /tmp/restic-pass.txt /var/srv/ultus/restic-password && printf 'ULTUS_RESTIC_PASS:%s\n' ok"
probe 'ULTUS_CANARY_FILE:ok' 60 "printf '%s\n' 'canary-payload' > /tmp/canary.txt && sudo install -m 0640 -o agents -g agents /tmp/canary.txt /var/srv/repos/canary.txt && printf 'ULTUS_CANARY_FILE:%s\n' ok"
probe 'ULTUS_ENV:ok' "$timeout_s" 'sudo systemctl start ultus-data-prepare.service opencode-env.service hermes-env.service && printf "ULTUS_ENV:%s\n" ok'
# A fresh repository has no config, and restic refuses to back up into one, so
# the operator creates it once before the first window. The test does the same
# so the unit's own path is what gets exercised.
probe 'ULTUS_REPO:ok' 120 'sudo env RESTIC_REPOSITORY=/var/srv/ultus/restic-test RESTIC_PASSWORD_FILE=/var/srv/ultus/restic-password restic init >/dev/null && printf "ULTUS_REPO:%s\n" ok'
probe 'ULTUS_BACKUP:[0-9]+' "$timeout_s" 'sudo systemctl start ultus-backup.service; printf "ULTUS_BACKUP:%s\n" "$?"'
probe 'ULTUS_RESTORE_RUN:ok' "$timeout_s" 'sudo env RESTIC_REPOSITORY=/var/srv/ultus/restic-test RESTIC_PASSWORD_FILE=/var/srv/ultus/restic-password restic restore latest --target /var/srv/restore-check >/dev/null && printf "ULTUS_RESTORE_RUN:%s\n" ok'
probe 'ULTUS_RESTORE:(ok|missing)' 60 'sudo test -f /var/srv/restore-check/var/srv/repos/canary.txt && printf "ULTUS_RESTORE:%s\n" ok || printf "ULTUS_RESTORE:%s\n" missing'
probe 'ULTUS_BACKUP_PROBE_END:ok' 60 'printf "ULTUS_BACKUP_PROBE_END:%s\n" ok'

for marker in 'ULTUS_SECRETS:ok' 'ULTUS_BACKUP_ENV:ok' 'ULTUS_RESTIC_PASS:ok' 'ULTUS_CANARY_FILE:ok' 'ULTUS_ENV:ok' 'ULTUS_REPO:ok' 'ULTUS_BACKUP:0' 'ULTUS_RESTORE_RUN:ok' 'ULTUS_RESTORE:ok'; do
  if ! grep -qF "$marker" "$log"; then
    echo "boot failed: ${marker} was not reported" >&2
    grep -a 'ULTUS_' "$log" >&2 || true
    exit 1
  fi
done

# The workloads pull their images on the first start. A pull can outlast the
# unit's TimeoutStartSec on TCG, and Restart=on-failure retries it, so start
# without waiting and poll instead.
probe 'ULTUS_ACTIVE_END:ok' "$timeout_s" 'sudo systemctl start --no-block opencode.service hermes.service; for i in $(seq 1 240); do if systemctl is-active --quiet opencode.service && systemctl is-active --quiet hermes.service; then printf "ULTUS_ACTIVE:%s\n" ok; break; fi; sleep 5; done; printf "ULTUS_ACTIVE_END:%s\n" ok'
if ! grep -qF 'ULTUS_ACTIVE:ok' "$log"; then
  echo "boot failed: a workload did not become active within its budget" >&2
  dump_workloads
  exit 1
fi

# The reboot stage proves the data disk survives, that the workloads come back
# from their enabled units, and that nothing depended on the test's session.
mark_log
serial_write "printf '%s\n' 'reboot-marker' > /tmp/reboot-marker.txt && sudo install -m 0644 /tmp/reboot-marker.txt /var/srv/ultus/reboot-marker && sudo systemctl reboot"
if ! wait_for_new '^[A-Za-z0-9._-]+ login: ' "$timeout_s"; then
  echo "boot failed: the guest did not come back from the reboot" >&2
  tail -30 "$log" >&2 || true
  exit 1
fi
serial_write "$test_user"
if ! wait_for_new 'Password:' 60; then
  echo "login failed: no password prompt after the reboot" >&2
  exit 1
fi
serial_write "$test_password"
if ! wait_for_new "${test_user}@" 180; then
  echo "login failed: no shell prompt after the reboot" >&2
  exit 1
fi

prime_sudo
probe 'ULTUS_REBOOT_MARKER:(ok|missing)' 60 'sudo test -f /var/srv/ultus/reboot-marker && printf "ULTUS_REBOOT_MARKER:%s\n" ok || printf "ULTUS_REBOOT_MARKER:%s\n" missing'
probe 'ULTUS_REBOOT_END:ok' "$timeout_s" 'for i in $(seq 1 120); do if systemctl is-active --quiet opencode.service && systemctl is-active --quiet hermes.service; then printf "ULTUS_REBOOT_ACTIVE:%s\n" ok; break; fi; sleep 5; done; printf "ULTUS_REBOOT_END:%s\n" ok'
for marker in 'ULTUS_REBOOT_MARKER:ok' 'ULTUS_REBOOT_ACTIVE:ok'; do
  if ! grep -qF "$marker" "$log"; then
    echo "boot failed after the reboot: ${marker} was not reported" >&2
    grep -a 'ULTUS_' "$log" >&2 || true
    dump_workloads
    exit 1
  fi
done

# Stage two: the same disk with no data drive. /var/srv is then a plain
# directory on the OS disk, and the whole point of the mount gate is that no
# workload starts and nothing is written there.
first_log=$log
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
kill "$reader_pid" 2>/dev/null || true
exec 7>&-

log=$run_dir/server-boot-nodisk.log
qemu_extra_drives=()
QEMU_NO_REBOOT=1
vm_start

if ! serial_login; then
  tail -20 "$log" >&2 || true
  exit 1
fi
prime_sudo
# Same working-directory reason as the first stage: the container query runs as
# `agents` and cannot start from the test account's 0700 home.
# The premise first: /var/srv is not a mountpoint at all here, so a unit that
# stayed down did so for the right reason.
probe 'ULTUS_NODISK_MOUNT:(absent|present)' 60 'mountpoint -q /var/srv && printf "ULTUS_NODISK_MOUNT:%s\n" present || printf "ULTUS_NODISK_MOUNT:%s\n" absent'
# An inactive unit could also be a unit that crashed. RequiresMountsFor= adds an
# implicit mount condition, and systemd reports ConditionResult=no when it
# refused the start because the mount was missing. That is the gate, not the
# absence of a crash.
probe 'ULTUS_NODISK_CONDITION:(yes|no)' 60 'test "$(systemctl show opencode.service -p ConditionResult --value)" = no && test "$(systemctl show hermes.service -p ConditionResult --value)" = no && printf "ULTUS_NODISK_CONDITION:%s\n" no || printf "ULTUS_NODISK_CONDITION:%s\n" yes'
probe 'ULTUS_NODISK_OPENCODE:(active|inactive)' 60 'cd /var/tmp || exit 1; systemctl is-active --quiet opencode.service && printf "ULTUS_NODISK_OPENCODE:%s\n" active || printf "ULTUS_NODISK_OPENCODE:%s\n" inactive'
probe 'ULTUS_NODISK_HERMES:(active|inactive)' 60 'systemctl is-active --quiet hermes.service && printf "ULTUS_NODISK_HERMES:%s\n" active || printf "ULTUS_NODISK_HERMES:%s\n" inactive'
probe 'ULTUS_NODISK_CONTAINER:(present|absent)' "$timeout_s" 'containers=$(sudo -u agents env HOME=/var/lib/agents XDG_RUNTIME_DIR=/run/user/1000 podman ps -a --format "{{.Names}}" 2>/dev/null || true); case "$containers" in *opencode*|*hermes*) printf "ULTUS_NODISK_CONTAINER:%s\n" present ;; *) printf "ULTUS_NODISK_CONTAINER:%s\n" absent ;; esac'
probe 'ULTUS_NODISK_TREE:(present|absent)' 60 'test -e /var/srv/ultus && printf "ULTUS_NODISK_TREE:%s\n" present || printf "ULTUS_NODISK_TREE:%s\n" absent'
probe 'ULTUS_NODISK_END:ok' 60 'printf "ULTUS_NODISK_END:%s\n" ok'

for marker in 'ULTUS_NODISK_MOUNT:absent' 'ULTUS_NODISK_CONDITION:no' 'ULTUS_NODISK_OPENCODE:inactive' 'ULTUS_NODISK_HERMES:inactive' 'ULTUS_NODISK_CONTAINER:absent' 'ULTUS_NODISK_TREE:absent'; do
  if ! grep -qF "$marker" "$log"; then
    echo "boot failed without a data disk: ${marker} was not reported" >&2
    grep -a 'ULTUS_' "$log" >&2 || true
    exit 1
  fi
done

echo "server boot ok: mount, rootless write, canaries, backup restore, reboot and the failed-mount path"
echo "log: $first_log"
echo "log: $log"
