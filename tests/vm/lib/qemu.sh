#!/usr/bin/env bash
# Shared QEMU harness for the boot tests.
#
# Sourcing this file defines the helpers but starts nothing. A caller sets its
# variables, fills qemu_extra_drives when the guest needs a second disk, and
# calls vm_start. After that pid, reader_pid, vars, pipe_in and pipe_out are set,
# and fd 7 writes to the guest's serial console.
#
# The caller sets:
#   disk            the primary qcow2
#   log             where the serial output is captured
#   run_dir         where the serial pipes and qemu.err live
#   timeout_s       the login-stage budget
#   test_user, test_password
#   qemu_extra_drives  optional extra -drive arguments, as an array
#
# The caller may set:
#   QEMU_ACCEL      kvm (default) or tcg; falls back to tcg without /dev/kvm
#   QEMU_CPU        defaults to host, or max under tcg
#   QEMU_SNAPSHOT   1 (default) discards the guest's writes on exit
#   QEMU_NO_REBOOT  1 (default) stops QEMU when the guest reboots
#   VNC_DISPLAY     the loopback VNC display, default 1

# Initialised here so a caller that appends to it works under `set -u`.
qemu_extra_drives=()

# The caller's contract, named here so the file is readable on its own and the
# linter sees each name assigned. A caller sets the real values before
# vm_start; an unset one fails the guard inside vm_start or the first wait.
disk=${disk:-}
log=${log:-}
run_dir=${run_dir:-}
timeout_s=${timeout_s:-}
test_user=${test_user:-}
test_password=${test_password:-}
pid=${pid:-}

find_ovmf() {
  local pair code vars
  # Fedora, Arch, and Ubuntu layout the OVMF files differently.
  local -a pairs=(
    "/usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd"
    "/usr/share/edk2/x64/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_VARS.fd"
    "/usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd"
    "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.fd"
    "/usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_VARS_4M.fd"
    "/usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_VARS.fd"
  )
  for pair in "${pairs[@]}"; do
    read -r code vars <<<"$pair"
    if [[ -f $code && -f $vars ]]; then
      echo "$code $vars"
      return 0
    fi
  done
  return 1
}

vm_start() {
  local ovmf_code ovmf_vars display_args

  [[ -f $disk ]] || { echo "missing disk: $disk" >&2; exit 2; }
  [[ -w $disk ]] || {
    echo "disk is not writable: $disk" >&2
    echo "rebuild with make-disk.sh, or copy the disk to a writable path" >&2
    exit 2
  }
  read -r ovmf_code ovmf_vars < <(find_ovmf) || {
    echo "missing OVMF firmware; install edk2-ovmf" >&2
    exit 2
  }

  vars=$(mktemp)
  cp "$ovmf_vars" "$vars"
  rm -f "$log"

  # QEMU does not create the pipe pair, and the reader must exist before the
  # guest writes, or the first console output is lost or blocks.
  pipe_in=$run_dir/serial.in
  pipe_out=$run_dir/serial.out
  rm -f "$pipe_in" "$pipe_out"
  mkfifo "$pipe_in" "$pipe_out"
  cat "$pipe_out" >"$log" &
  reader_pid=$!

  if [[ ${VIRTIO_GL:-0} == 1 ]]; then
    display_args=(-device virtio-vga-gl -display egl-headless)
  else
    display_args=(-vga virtio -display "vnc=127.0.0.1:${VNC_DISPLAY:-1}")
  fi

  # KVM where available; TCG on a hosted runner without /dev/kvm. TCG is slow,
  # so raise BOOT_TIMEOUT for a hosted run. Run 43068532421 measured 275s of guest
  # time at roughly 4.6x wall-clock slowdown, so a hosted boot needs the better
  # part of half an hour before the login prompt appears.
  accel=${QEMU_ACCEL:-kvm}
  if [[ $accel == kvm && ! -e /dev/kvm ]]; then
    echo "no /dev/kvm; falling back to TCG" >&2
    accel=tcg
  fi
  cpu=${QEMU_CPU:-host}
  if [[ $accel == tcg && -z ${QEMU_CPU:-} ]]; then
    cpu=max
  fi

  qemu=()
  qemu+=(qemu-system-x86_64)
  qemu+=(-machine "q35,accel=$accel" -cpu "$cpu" -m 4096 -smp 2)
  if [[ ${QEMU_SNAPSHOT:-1} == 1 ]]; then
    qemu+=(-snapshot)
  fi
  qemu+=(-drive "if=pflash,format=raw,readonly=on,file=$ovmf_code")
  qemu+=(-drive "if=pflash,format=raw,file=$vars")
  if ((${#qemu_extra_drives[@]})); then
    qemu+=("${qemu_extra_drives[@]}")
  fi
  qemu+=(-drive "file=$disk,if=virtio,format=qcow2")
  qemu+=(-nic "user,model=virtio-net-pci")
  qemu+=("${display_args[@]}")
  qemu+=(-serial "pipe:$run_dir/serial")
  # -no-reboot turns a guest reboot into a QEMU exit. A test that reboots the
  # guest clears it so the second boot happens in the same run.
  if [[ ${QEMU_NO_REBOOT:-1} == 1 ]]; then
    qemu+=(-no-reboot)
  fi

  "${qemu[@]}" 2>"$run_dir/qemu.err" &
  pid=$!
  # Open the write side read-write so this never blocks, even if QEMU fails to
  # start (no KVM, EGL, or firmware) and never opens its end of the pipe.
  exec 7<>"$pipe_in"
  trap vm_cleanup EXIT
}

vm_cleanup() {
  status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  kill "$reader_pid" 2>/dev/null || true
  exec 7>&-
  rm -f "$vars" "$pipe_in" "$pipe_out"
  if (( status != 0 )) && [[ -s $run_dir/qemu.err ]]; then
    echo "qemu stderr:" >&2
    tail -20 "$run_dir/qemu.err" >&2 || true
  fi
}

# Contract: only a kernel message that starts with its console timestamp is
# removed, together with the newline that ends it, so a marker the guest wrote
# on both sides of that message rejoins. Guest text on two adjacent lines is
# not joined, and a marker that appears only inside a kernel message is dropped
# rather than counted as guest output. Needs GNU sed for -z; the dev hosts and
# the Ubuntu runner carry it. A caller that prints diagnostics still reads the
# raw log.
normalize_log() {
  sed -z -E 's/\[[[:space:]]*[0-9]+\.[0-9]+\][^\n]*\n?//g'
}

wait_for() {
  local pattern=$1 deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    # systemd colors the unit name, so allow bytes between the words.
    if [[ -f $log ]] && normalize_log <"$log" | grep -cE "$pattern" >/dev/null; then
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

serial_write() {
  printf '%s\n' "$1" >&7
}

serial_login() {
  # Match the hostname-prefixed prompt, not an end-of-line anchor. Run
  # 43068532421 showed the console write the prompt and a kernel message on one
  # line: "fedora login: [  275.126011] clocksource: Watchdog ...". An anchor
  # at `$` never matched it and the login stage waited out its whole budget.
  if ! wait_for '^[A-Za-z0-9._-]+ login: ' "$timeout_s"; then
    echo "login failed: no getty prompt on the serial console" >&2
    return 1
  fi
  serial_write "$test_user"
  if ! wait_for 'Password:' 20; then
    echo "login failed: no password prompt for ${test_user}" >&2
    return 1
  fi
  serial_write "$test_password"
  # Wait for the login shell's prompt instead of a fixed sleep. A missing
  # prompt means the login failed, so do not send probes into an unknown state.
  # The per-user manager start can outlast 20s under TCG; run 42997688206
  # missed the prompt by 0.4s, so allow 60s before treating the login as failed.
  if ! wait_for "${test_user}@" 60; then
    echo "login failed: no shell prompt for ${test_user}" >&2
    return 1
  fi
  return 0
}
