# Testing

## Headless boot test

```bash
sudo pacman -S --needed qemu-full edk2-ovmf
podman save localhost/ultus-atomic:dev | sudo podman load
sudo tests/vm/make-disk.sh
tests/vm/boot-smoke.sh
```

`make-disk.sh` runs bootc-image-builder as root. The builder image follows `:latest` because it shapes a disposable disk rather than the artifact; set `BIB_IMAGE` to a digest to reproduce an old disk. It adds one test account (`dux` / `dux-test` by default, override with `TEST_USER` and `TEST_PASSWORD`, skip with `NO_TEST_USER=1`) because the image ships no interactive user. Credentials reject quotes, backslashes, and newlines, which would break the generated TOML. It also sets `systemd.default_device_timeout_sec=180` on the test disk only: a TCG boot can run at half speed and miss the shipped 45s device timeout before `/boot` appears. The builder intermittently fails its first step with `cpio: premature end of archive` on an initramfs that is byte-identical on disk (#173), so the script retries that signature once and fails every other error immediately.

### A promoted digest

Test the digest the registry promoted, not the tag, because the tag can move between the pull and the boot:

```bash
digest=$(skopeo inspect docker://ghcr.io/ultus-net/ultus-atomic:latest --format '{{.Digest}}')
sudo podman pull ghcr.io/ultus-net/ultus-atomic@"$digest"
rm -rf output
sudo tests/vm/make-disk.sh ghcr.io/ultus-net/ultus-atomic@"$digest" output
```

`make-disk.sh` refuses an image that is not in rootful podman storage, hence the explicit pull. The `skopeo inspect` call is the same one the promotion record uses, so this digest matches the recorded one. `output/` holds only bootc-image-builder output and is gitignored, and `make-disk.sh` does not clear it, so `rm -rf output` drops an earlier candidate's disk that later commands on this page would otherwise boot.

`boot-smoke.sh` boots the qcow2 headless, asserts that `greetd` starts, treats the greeter session line on the serial console as the fast signal, warns when `graphical.target` is not reported, then logs in as that account and asserts the live greeter session through `loginctl`. When the login probe finds no greeter session, it prints process wait channels, the `greetd` unit state, sessions, the `/dev/dri` entries, and failed units to the console, because the unprivileged test account cannot read the journal. It then starts the two first-login units the way `graphical-session-pre.target` does, and checks the niri config, the DMS binds, the dark session seed, the per-user `dms.service` link, the image-level `niri.service` binding, the preset enablement, and the greeter seed.

```bash
export TEST_USER=dux TEST_PASSWORD=dux-test
sudo --preserve-env=TEST_USER,TEST_PASSWORD tests/vm/make-disk.sh
VIRTIO_GL=1 tests/vm/boot-smoke.sh
```

sudo resets the environment by default, so pass the two variables through `--preserve-env`. The login stage needs the same credentials the disk was built with. Pass `BOOT_LOGIN=0` for a disk built with `NO_TEST_USER=1`, which runs the boot assertions only.

QEMU's `virtio-vga` exposes a render node, so the greeter session starts even on a host without GL. That does not prove the greeter painted. Set `VIRTIO_GL=1` on a host with a GPU to render with GL; the test then also asserts `/dev/dri/renderD128`. Check the rendered greeter on real hardware for the final confirmation.

## Graphical dogfood

The headless smoke test proves the greeter session starts, not that the desktop looks right. Boot the candidate disk with a real GL display and log in through the greeter:

```bash
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd /tmp/dux-vars.fd
qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 4096 -smp 2 -snapshot \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=/tmp/dux-vars.fd \
  -drive file=output/qcow2/disk.qcow2,if=virtio,format=qcow2 \
  -nic user,model=virtio-net-pci \
  -device virtio-vga-gl -display gtk,gl=on
```

Log in with the test account (`dux` / `dux-test` by default). The DMS bar, the dark background, and the DMS keybinds come from the first-login setup described in [First login](first-login.md).

`.vm/dogfood_login.py` drives that login and asserts the session instead of leaving it to the eye:

```bash
DOGFOOD_PROBE=7 python3 .vm/dogfood_login.py .vm/dogfood-7 output/qcow2/disk.qcow2
```

Probe 7 logs in on the serial console, clicks through the greeter's user picker, types the password, then polls `niri.service` and `dms.service` as the user. It exits 0 only when both report `active`, and it writes screenshots to the run directory, so give each candidate its own directory. The driver is local and untracked: `.gitignore` excludes `.vm/`, so a fresh clone has the procedure but not the driver.

The image disables Plymouth (`plymouth.enable=0`), so both the VM and real hardware show the text boot instead of a splash.

## Hardware install and UAT

No build of this image has run on physical hardware. Physical runs use the HP EliteDesk 800 G4 Mini for both roles: the generic image for the GUI checks below, then the server image for the headless set. The `nvidia` image needs the RTX 3070 host, because the mini has no NVIDIA hardware. The VM covers the greeter session and the first-login units and nothing else: it never logs in through the greeter's picker, never starts the Xfce fallback or a second session, and never renders the desktop ([Known gaps](known-gaps.md)). This section is the order that closes those gaps, and the evidence to keep for each check.

### Record the machine first

Four answers decide how the rest of the run goes, and they belong in the UAT record below before the disk is touched:

| Fact | Command | Why it decides |
| --- | --- | --- |
| Machine and firmware | `dmidecode -s system-product-name`, `bootctl status` | Secure Boot state has never been recorded on either target (#54) |
| GPU | `lspci -nn \| grep -Ei 'vga\|3d'` | The desktop on the RTX 3070 host needs the NVIDIA variant (#94) and a MOK enrollment (#95); the mini's UHD 630 takes the generic image |
| Target disk | `lsblk -o NAME,SIZE,MODEL,TRAN` | `bootc install to-disk --wipe` erases the whole device, including the data partition on the same drive; the data comes back from restic |
| Network at install | `curl -sI https://ghcr.io/v2/` | The installer pulls the image; anonymous GHCR access is enough |

The laptop's model, device IDs, version floor, and boot-path facts are recorded in [Laptop hardware: Dell Pro 14 PC14250](hardware/dell-pro-14-pc14250.md).

The install leaves no encrypted root on either machine, by policy (#54). The disk is wiped and the data on it is unprotected at rest, which is accepted rather than overlooked.

### Install

The image must exist under the reference the install records. `:latest` moves only on a manual promotion (`docs/ci.md`), so set `ref` to the promoted tag, or to the `sha-<commit>` tag before the first promotion, and pass that same reference as `--target-imgref` so day-2 updates follow it.

```bash
ref=ghcr.io/ultus-net/ultus-atomic:latest
lsblk
sudo podman run --rm --privileged --pid=host --ipc=host \
  -v /var/lib/containers:/var/lib/containers \
  -v /dev:/dev \
  --security-opt label=type:unconfined_t \
  "$ref" \
  bootc install to-disk --wipe --filesystem btrfs \
  --target-imgref "$ref" \
  /dev/nvme0n1
```

The image ships no account and locks root, so the install ends with no login at all. Create the first account before the first graphical login: the debug-shell route in [Install](install.md#the-first-account), or an `anaconda-iso` build, which creates it during the install and is the route Universal Blue takes ([Install](install.md#alternative-an-installer-iso)). Then reboot into the greeter.

### The checks

Each row earns its place because the VM cannot reach it. A pass means the evidence named beside it exists, not that the screen looked right.

| Check | How | Evidence to keep |
| --- | --- | --- |
| Secure Boot boot | Boot with firmware Secure Boot on | `bootctl status` showing `SecureBoot: enabled`, and the boot completing to the greeter |
| Greeter | Pick the account in the user picker and log in | Screenshot of the picker and of the session after login |
| First login provisioning | `systemctl --user status ultus-atomic-desktop.service` | Unit `active`, completion marker present, `~/.config/niri/config.kdl` written, `dms.service` `active` |
| Desktop | Bar, launcher, Ghostty, a screenshot | Screenshot, and `systemctl --user is-active dms.service` |
| Xfce fallback | Log out, choose the Xfce X11 session | Session runs, and `niri.service` and `dms.service` are absent from it |
| Second session | Start a second session while one runs | Both sessions listed by `loginctl list-sessions`, no crash |
| Screen sharing | Share a screen from a browser | A live share, plus `systemctl --user status xdg-desktop-portal` |
| Applications | Flathub set present, Steam launches one game | Screenshot of the game, and `lsmod | grep ntsync` |
| Developer tooling | `node --version`, `npm --version`, then the dotfiles bootstrap | Bootstrap exit 0 and a provisioned shell (#96) |
| Update and rollback | `bootc upgrade`, reboot, then `bootc rollback`, reboot | `bootc status` before and after each step |
| Snapshots | Confirm absence | No btrbk package, timer, or config, matching #68 |

### The UAT record

One row per run, filled from the checks above. Keep the digest, because a rebuild moves the image under the same tag.

| Date | Machine | Image digest | Secure Boot | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| | | | | | |

## Signing policy tests

`tests/test-signing.sh` proves the signature policy itself, not GitHub's identity. It needs `podman`, `skopeo`, `curl`, and cosign v2 on `PATH`, plus a free `127.0.0.1:5000`; set `REGISTRY_PORT` when that port is taken. It runs a throwaway `registry:2`, pushes two payload tags with different digests, signs the trusted tag with one fixture key and signs the untrusted tag with a second key outside the policy, and asserts four cases through `skopeo copy --policy`: a signed tag and a signed digest are accepted, an unsigned tag is rejected for the missing signature, and the untrusted key's signature is rejected for the failed verification. Its keys, policy, `registries.d` file and logs live in a temp dir removed on exit, and it never contacts GitHub or a signing service. It needs network only for the two digest-pinned image pulls, and podman's storage keeps those images after the run. CI's `signing` job runs it after `static`.

```bash
tests/test-signing.sh
```

## Image gates

| Gate | What it asserts |
| --- | --- |
| `tests/verify-image.sh --server` | No desktop package is installed; `var-srv.mount` is present and enabled; `tailscale` and `restic` are installed; the `agents` user has uid and gid 1000, one `100000:65536` subordinate range in each of `/etc/subuid` and `/etc/subgid`, and the linger flag; every unit this part ships is enabled; every unit passes `systemd-analyze verify`; the download-only drop-in replaces bootc's stock update command; no Flathub remote is seeded; and the third-party set matches `manifests/packages-server.lock`. |
| `tests/test-server-env.sh` | Runs `ultus-env` in the pinned base against two fixture secrets files: each derived file is `0600 agents:agents`, the OpenCode file carries no Hermes key, each Hermes key is present, and a missing required key fails closed. It needs podman or docker and pulls the base image the `Containerfile` pins. |
| `tests/test-server-isolation.sh` | Parses every unit in `modules/server/usr/lib/systemd/system/` and rejects `--privileged`, host namespaces, `--cap-add`, `--device`, `label=disable`, a host home or root home mount, a Podman or Docker socket, and any publish without `127.0.0.1`. It first runs against `tests/fixtures/server-units/widened.service`, which carries every rejected spelling, so a parser that stops matching reds here instead of passing quietly. |

The server boot test is not a gate on its own; CI runs it inside `image-server`.

## Server boot test

`tests/vm/boot-smoke-server.sh` boots the server image with a second disk labelled `ultus-data` and asserts the role end to end, from the guest's own console:

| Marker | Asserts |
| --- | --- |
| `ULTUS_MOUNT:ok` | `/var/srv` is a mountpoint |
| `ULTUS_SRV:ok` | `/srv` resolves to `/var/srv`, that path is on the data disk's filesystem, and the data disk is not the OS disk; the marker prints all four values |
| `ULTUS_LINGER:yes` | `agents` lingers, so rootless Podman has a runtime directory |
| `ULTUS_OWNER:1000` | A container's write under `/var/srv/opencode/share` lands owned by `agents`, not root |
| no `ULTUS_CANARY:*:readable` | A workload container cannot read `/home/<test account>`, `/root/.ssh`, the Podman socket or `/dev/kvm` |
| `ULTUS_LISTEN:loopback` | Every listener is on loopback (`127.0.0.0/8` or `::1`) |
| `ULTUS_REPO:ok` | The one-time `restic init` succeeds, so the backup unit has a repository to write into |
| `ULTUS_BACKUP:0` | The backup unit exits 0, so a window really wrote a snapshot |
| `ULTUS_RESTORE:ok` | The snapshot restores a canary file, so the repository holds the tree rather than an empty mount |
| `ULTUS_SERVICE_PASSWORD:ok` | `service.json` on the data disk carries the operator's `OPENCODE_PASSWORD`, so `serve --service` accepts the documented password instead of a generated one |
| `ULTUS_SESSION:ok` | The OpenCode server answers on `127.0.0.1:4096/api/session` with that password and creates a session; the guest keeps its id on the data disk |
| `ULTUS_SESSION_READ:ok` | After the reboot the guest reads that id back and the server returns the session with the `pre-window` title it was created with, so the workload resumes client work |
| `ULTUS_REBOOT_MARKER:ok`, `ULTUS_REBOOT_ACTIVE:ok` | The data disk and both workloads survive a guest reboot |
| `ULTUS_NODISK_*` | With no data drive, `var-srv.mount` refuses the start (`UNIT:refused` reports `ConditionResult=no` and a non-active state, not a crash), `/var/srv` is not a mountpoint, systemd refused both workload starts (`CONDITION:no`), no container is left behind, and `/var/srv/ultus` is not created on the OS disk |
| `ULTUS_NOLABEL_*` | With a drive whose label is `ultus-data-wrong`, the guest sees that label and udev publishes it under by-label (`PREMISE:seen`, `WRONG:present`), `var-srv.mount` names `/dev/disk/by-label/ultus-data` (`WHAT:matches`), no device carries that label (`LABEL:none`), so the unit refused the start (`UNIT:refused`, `ConditionResult=no`) and both workloads stay down with nothing written to the OS disk |

On a hosted runner the guest runs under QEMU TCG, which cannot execute every instruction OpenCode's runtime emits: run 45780444809's second boot aborted the server with `trap invalid opcode`, so the two session markers read `skipped-tcg` there rather than failing the job. A skip marker records that the probe did not run, not that the API passed. The KVM run and the hardware UAT in #149 carry that proof.

It builds its own disk inputs:

```bash
sudo SERVER_DISK=1 tests/vm/make-disk.sh localhost/ultus-atomic-server:dev
sudo SERVER_DISK=1 DATA_ONLY=1 SERVER_DATA_LABEL=ultus-data-wrong \
  SERVER_DATA_FILE=data-unlabelled.qcow2 \
  tests/vm/make-disk.sh localhost/ultus-atomic-server:dev
SERVER_DATA_DISK=$PWD/output/qcow2/data.qcow2 QEMU_NO_REBOOT=0 \
  sudo -E tests/vm/boot-smoke-server.sh output/qcow2/disk.qcow2 .vm/server-boot.log
```

`SERVER_DISK=1` adds the test account to `wheel`, because the probes drive system units, and writes `output/qcow2/data.qcow2`: a sparse 8 GiB file carrying an ext4 filesystem labelled `ultus-data`. It refuses to run with `NO_TEST_USER=1`. `SERVER_DATA_LABEL` and `SERVER_DATA_FILE` name the label and the file, and `DATA_ONLY=1` writes that data file without rebuilding the OS disk, which is how the unlabelled control is made. The boot test refuses to run without both disks, because either one going missing would turn a stage into a weaker test.

`QEMU_NO_REBOOT=0` is required: the script reboots the guest and logs in again, and QEMU must survive that. The snapshot stays on, so the guest's writes survive the reboot inside the run and the source disk is untouched. The script then starts a second QEMU with no data drive, and a third with the unlabelled disk.

The test boots the guest four times: with the data disk, after a reboot inside that run, with no data disk, and with the unlabelled disk. It pulls both workload images from inside the guest, so it needs outbound HTTPS to `ghcr.io` and `docker.io` and a larger budget than the desktop boot. On a host without `/dev/kvm`, set `BOOT_TIMEOUT=2700`. It needs a provider key only for the Hermes unit, not for the session it opens: the OpenCode server creates a session without calling a model.

## CI boot test

GitHub-hosted runners have no `/dev/kvm`, so the boot test runs on QEMU TCG and is headless: it asserts the greeter session and the first-login units, not rendered pixels. The guest still gets a DRM render node from virtio-gpu. The workflow gives the boot 900s, `greetd` 300s, and the login shell prompt at least 60s to appear, and `make-disk.sh` raises the test disk's device timeout to 180s because TCG throughput varies run to run. Run the graphical dogfood locally before promotion. See [CI](ci.md).
