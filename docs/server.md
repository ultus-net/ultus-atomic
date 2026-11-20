# Headless server

The server image carries the same Fedora bootc base as the desktop, adds `manifests/packages-server.txt`, and ships `modules/server/` in place of `modules/desktop/`. It has no desktop, no greeter and no Flathub remote. The box it targets is an HP EliteDesk 800 G4 Mini with one drive: the OS partitions, plus one ext4 partition labelled `ultus-data` that mounts at `/var/srv`.

The agents run in rootless containers as the `agents` user (uid and gid 1000), never on the host. `podman` is the only runtime they use, and the host's own tooling is not on their mounts.

## What owns what

| Layer | Owner |
| --- | --- |
| OS, units, image | the image build, from `modules/server/` |
| The data partition | the operator, once: create, format ext4, label `ultus-data` |
| The subtree under `/var/srv` | `ultus-data-prepare.service`, at every boot |
| The secrets | the operator, in `/var/srv/ultus/secrets.env` |

Nothing in the image formats, partitions or relabels a device. If the partition is absent, `var-srv.mount` fails, `ultus-data-prepare.service` is skipped, and every workload stays down. That is deliberate: the fallback would put agent state on the OS disk, which `/proc` reports as a normal directory and which a backup would then store as an empty tree.

## First boot

The image ships no account and no password, and `sshd` is disabled, so the first account comes from a one-time boot with `systemd.debug_shell` on the kernel command line. [Install](install.md#the-first-account) carries the exact GRUB edit and the `useradd` line.

Then confirm the data disk before anything else:

```bash
findmnt /var/srv
systemctl status var-srv.mount ultus-data-prepare.service
```

`findmnt` prints the partition's source and `ultus-data`. `ultus-data-prepare.service` creates `/var/srv/ultus` as `0700 root:root`, `/var/srv/{opencode,hermes,repos}` as `0750 agents:agents`, and one state directory per workload as `0700 agents:agents`. A unit that is `inactive (dead)` with result `condition failed` means the mount is absent, not that the unit is broken.

## The secrets file

Write `/var/srv/ultus/secrets.env` as root, mode `0600`, owned `root:root`. The file is data: `ultus-env` parses it and never sources it, so a value cannot execute anything. Quotes around a value are optional and are stripped when present.

| Key | Read by | Meaning |
| --- | --- | --- |
| `OPENCODE_PASSWORD` | both | The password `opencode serve` requires. Required. |
| `API_SERVER_KEY` | Hermes | Hermes' own API key. Required. |
| `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY` | Hermes | Model provider keys. At least one is required. |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `..._PASSWORD`, `..._SECRET` | Hermes | Dashboard login. Optional. |
| `TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN` | Hermes | Chat gateway. Optional. |
| `TZ` | both | Container timezone. Optional. |

Each workload gets its own file and no other workload's keys:

```bash
systemctl restart opencode-env.service hermes-env.service
ls -l /run/ultus
```

`/run/ultus/<workload>.env` is mode `0600`, owned `agents:agents`, and lives on tmpfs, so it is regenerated at every boot and never reaches the data disk or the backup. The file is replaced atomically, so a workload never reads a half-written copy.

A missing required key stops the unit with the key's name in the journal:

```bash
journalctl -u opencode-env.service
```

The workload unit requires its env unit, so a workload does not start with a partial environment.

## Workloads

| Unit | Sees | Publishes on loopback | Image default |
| --- | --- | --- | --- |
| `opencode.service` | `/var/srv/repos`, `/var/srv/opencode/{share,config,state}` | `4096` | `ghcr.io/ultus-net/devbox@sha256:8649976d…` |
| `hermes.service` | `/var/srv/hermes/data` | `8642`, `9119` | `docker.io/nousresearch/hermes-agent@sha256:41468459…` |

Both run as `agents` with `--userns=keep-id`, a read-only root filesystem, `--cap-drop=all`, `no-new-privileges`, and one loopback publish per port. The tailnet is the only route in, so a `0.0.0.0` publish is a second door that no test permits.

Each image reference is a build-time default in its unit. To move a digest without rebuilding, write `/var/srv/ultus/workloads.env` as root with `OPENCODE_IMAGE=` or `HERMES_IMAGE=`; the unit reads that file after the derived env file, so the override wins. The file is on the data disk, and only root can write it.

```bash
systemctl status ultus-network.service opencode.service hermes.service
sudo -u agents env XDG_RUNTIME_DIR=/run/user/1000 podman ps --format '{{.Names}} {{.Status}}'
```

A new mount, device or capability in either unit is a change to `tests/test-server-isolation.sh` in the same commit. The test parses the shipped units, first against a fixture that carries every rejected spelling, and then against the real ones, so a parser that stops matching fails rather than passing quietly.

## Recovery

`/etc` and the OS come from the image, so a broken host is rebuilt rather than repaired: reinstall, then restore the data disk from the backup. For a bad upgrade on a host that still boots, revert the deployment:

```bash
sudo bootc rollback --apply
```

[Install](install.md#after-first-boot) carries the upgrade and rollback detail, and `docs/known-gaps.md` records what is still unproven.
