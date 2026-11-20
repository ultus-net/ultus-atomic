#!/usr/bin/env bash
# The server's isolation contract, asserted by parsing the units that will run.
# A static check is cheap enough to run on every push; the VM test proves the
# runtime side with canary reads.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
units=$repo_root/modules/server/usr/lib/systemd/system
fixture=$repo_root/tests/fixtures/server-units

required=(
  'User=agents'
  '--userns=keep-id'
  '--cap-drop=all'
  '--security-opt no-new-privileges'
  '--read-only'
  'RequiresMountsFor=/var/srv'
)
forbidden=(
  '--privileged'
  '--network=host'
  '--network host'
  '--pid=host'
  '--ipc=host'
  '--userns=host'
  '--cap-add'
  'label=disable'
  '--device'
  # A host-home or root-home mount is the escape. The workloads do mount paths
  # under /home/dev inside the container, so the token has to name the host
  # side: '/home:' matches '-v /home:/host' and not '-v /var/srv/x:/home/dev/x'.
  '/home:'
  '/root'
  '.ssh'
  'podman.sock'
  'docker.sock'
)

failures=0
check_dir() {
  local dir=$1 strict=$2 unit text token publish
  for unit in "$dir"/*.service; do
    [[ -f $unit ]] || continue
    text=$(cat "$unit")
    for token in "${forbidden[@]}"; do
      if [[ $text == *"$token"* ]]; then
        echo "FAIL ${unit##*/} carries the rejected token '$token'" >&2
        failures=$((failures + 1))
      fi
    done
    # A publish without a loopback address binds every interface. This runs for
    # every unit, including the fixture, so the fixture proves the check fires.
    while IFS= read -r publish; do
      [[ -z $publish ]] && continue
      if [[ $publish != *'127.0.0.1:'* ]]; then
        echo "FAIL ${unit##*/} publishes outside loopback: $publish" >&2
        failures=$((failures + 1))
      fi
    done < <(grep -oE '(-p|--publish)[= ][^ ]+' "$unit" | sed -E 's/^(-p|--publish)[= ]//')
    [[ $strict == 1 ]] || continue
    case ${unit##*/} in
      opencode.service | hermes.service) ;;
      *) continue ;;
    esac
    for token in "${required[@]}"; do
      if [[ $text != *"$token"* ]]; then
        echo "FAIL ${unit##*/} is missing '$token'" >&2
        failures=$((failures + 1))
      fi
    done
  done
}

# The parser must reject the fixture first, or a green run on the real units
# proves nothing.
check_dir "$fixture" 0
if ((failures == 0)); then
  echo "FAIL the isolation parser accepted the widened fixture" >&2
  exit 1
fi
echo "ok   the parser rejects the widened fixture ($failures findings)"

# An empty directory would make the strict pass below vacuous.
for unit in opencode.service hermes.service; do
  [[ -f $units/$unit ]] || { echo "FAIL $units/$unit is missing, so the strict pass proves nothing" >&2; exit 1; }
done

failures=0
check_dir "$units" 1
((failures == 0)) || exit 1
echo "ok   every server unit is loopback-only and neither workload can reach the host"

# A workload that publishes nothing is not a server, and a missing port means the
# tailnet serves nothing.
for pair in 'opencode.service:4096' 'hermes.service:8642:9119'; do
  unit=${pair%%:*}
  ports=${pair#*:}
  for port in ${ports//:/ }; do
    grep -q -- "-p 127.0.0.1:${port}:${port}" "$units/$unit" || {
      echo "FAIL ${unit} does not publish 127.0.0.1:${port}" >&2
      exit 1
    }
  done
done
echo "ok   each workload publishes its own loopback ports"
echo "server isolation checks passed"
