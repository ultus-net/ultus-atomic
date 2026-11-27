#!/usr/bin/env bash
# Build a bootable qcow2 from a local image with bootc-image-builder.
#
# Must run as root, because bootc-image-builder writes loop devices:
#   sudo tests/vm/make-disk.sh [image] [output-dir]
#
# The image must be in rootful podman storage. Either build it with sudo
# podman, or copy it across:
#   podman save localhost/ultus-atomic:dev | sudo podman load
#
# The base image ships no interactive user, so the disk is built with one test
# account for the login stage. Override it with TEST_USER and TEST_PASSWORD, or
# skip it with NO_TEST_USER=1. A production install creates the real account
# with useradd or the installer, never through this script.
#
# SERVER_DISK=1 also writes $out/qcow2/data.qcow2, a sparse 8 GiB ext4 file
# labelled ultus-data, because every server workload starts only when /var/srv
# is a mountpoint and the boot test needs that second disk to prove it.
# SERVER_DATA_LABEL and SERVER_DATA_FILE build the boot test's negative control:
# the same disk under a label the mount unit must refuse.

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=${1:-localhost/ultus-atomic:dev}
out=${2:-$repo_root/output}
test_user=${TEST_USER:-dux}
test_password=${TEST_PASSWORD:-dux-test}
# DATA_ONLY=1 writes the data disk and nothing else, so the boot test's negative
# control costs seconds instead of a second bootc-image-builder run.
data_only=${DATA_ONLY:-0}
if [[ $data_only == 1 && ${SERVER_DISK:-0} != 1 ]]; then
  echo "DATA_ONLY=1 needs SERVER_DISK=1" >&2
  exit 2
fi
mkdir -p "$out"
# Podman reads a relative bind source as a named volume, so the argument the
# header documents has to become an absolute path before it reaches -v.
out=$(cd "$out" && pwd)

if [[ $data_only == 0 ]] && ! podman image exists "$image"; then
  echo "image $image is not in rootful podman storage" >&2
  echo "copy it in with: podman save $image | sudo podman load" >&2
  exit 2
fi

with_test_user=1
if [[ ${NO_TEST_USER:-0} == 1 ]]; then
  with_test_user=0
fi

# The server boot test drives system units, so its account needs sudo. A server
# disk without an account cannot run those probes at all.
server_disk=${SERVER_DISK:-0}
if [[ $server_disk == 1 && $with_test_user == 0 ]]; then
  echo "SERVER_DISK=1 needs the test account; drop NO_TEST_USER=1" >&2
  exit 2
fi

if ((with_test_user)); then
  case "$test_user$test_password" in
    *'"'* | *'\'* | *$'\n'*)
      echo "TEST_USER and TEST_PASSWORD must not contain quotes, backslashes, or newlines" >&2
      exit 2
      ;;
  esac
fi

# TCG boots on a shared runner can run at half speed, and udev then misses
# systemd's 45s device timeout before /boot appears. Raise the timeout on the
# test disk only, so the shipped image keeps the stock value. The serial console
# karg lives here for the same reason: a production install gets no serial getty.
config_dir=$(mktemp -d)
trap 'rm -rf "$config_dir"' EXIT
{
  echo '[customizations.kernel]'
  echo 'append = "systemd.default_device_timeout_sec=180 console=ttyS0,115200"'
  if ((with_test_user)); then
    echo '[[customizations.user]]'
    printf 'name = "%s"\n' "$test_user"
    printf 'password = "%s"\n' "$test_password"
    if [[ $server_disk == 1 ]]; then
      echo 'groups = ["wheel"]'
    fi
  fi
} >"$config_dir/config.toml"
config_args=(-v "$config_dir/config.toml:/config.toml:ro")
if ((with_test_user)); then
  if [[ $server_disk == 1 ]]; then
    echo "test account: $test_user (wheel, for the server probes)" >&2
  else
    echo "test account: $test_user (no admin groups)" >&2
  fi
fi

# Follow the moving tag while the project is in development: the builder is
# input to a disposable disk, not part of the artifact, and a digest pin made an
# upstream fix wait for a repo commit. Set BIB_IMAGE to a digest to reproduce an
# old disk; the release path should pin one (#171).
bib_image=${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}

# Podman accepts the SELinux label only on an SELinux host; Ubuntu runners do
# not have it, so pass it conditionally.
security_args=()
if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
  security_args+=(--security-opt label=type:unconfined_t)
fi

if [[ $data_only == 0 ]]; then
  podman run --rm --privileged \
    "${security_args[@]}" \
    "${config_args[@]}" \
    -v "$out:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    "$bib_image" \
    build "$image" --type qcow2 --rootfs btrfs --use-librepo=True --output /output \
    --chown "${SUDO_UID:-0}:${SUDO_GID:-0}"
fi

# The server units are gated on /var/srv being a mountpoint, so the boot test
# needs a second drive carrying the data label. A sparse file plus one ext4
# filesystem costs only the metadata; the guest fills the rest at runtime.
if [[ $server_disk == 1 ]]; then
  data_file=${SERVER_DATA_FILE:-data.qcow2}
  data_label=${SERVER_DATA_LABEL:-ultus-data}
  # The file name is a name, never a path: the disk belongs beside the OS disk.
  if [[ $data_file == */* || -z $data_file ]]; then
    echo "SERVER_DATA_FILE must be a file name, not a path: $data_file" >&2
    exit 2
  fi
  data_disk=$out/qcow2/$data_file
  rm -f "$data_disk"
  truncate -s 8G "$data_disk"
  mkfs.ext4 -q -F -L "$data_label" "$data_disk"
  chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$data_disk"
  label=$(blkid -p -o value -s LABEL "$data_disk")
  fstype=$(blkid -p -o value -s TYPE "$data_disk")
  echo "data disk: $data_disk (label=$label type=$fstype)" >&2
  if [[ $label != "$data_label" || $fstype != ext4 ]]; then
    echo "data disk is not ext4 labelled $data_label" >&2
    exit 1
  fi
fi
