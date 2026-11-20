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

## The tailnet

The box joins the tailnet as `ultus-server` and publishes three surfaces over HTTPS. Nothing else is reachable: no container port binds a wired interface, and `sshd` is disabled.

| URL | Serves |
| --- | --- |
| `https://ultus-server.<tailnet>.ts.net` | OpenCode on `127.0.0.1:4096` |
| `https://ultus-server.<tailnet>.ts.net:8443` | The Hermes dashboard on `127.0.0.1:9119` |
| `https://ultus-server.<tailnet>.ts.net:10000` | The Hermes API server on `127.0.0.1:8642` |

Write the join key to `/var/srv/ultus/tailscale-authkey`, mode `0600` owned `root:root`, before the first boot, or write it and run `systemctl restart ultus-tailnet.service` afterwards. The script joins once, deletes the key whatever the outcome, and turns on Tailscale SSH, which authenticates by tailnet identity and needs no `authorized_keys`. An already-joined node skips the join and only refreshes the mounts.

```bash
systemctl status ultus-tailnet.service
tailscale serve status
tailscale status
```

A new surface is three things in one commit: the workload publishes on `127.0.0.1`, `ultus-tailnet` adds a `tailscale serve --bg --https=<port>` line, and `tests/test-server-isolation.sh` runs.

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

## Health

`ultus-health.timer` probes both workloads every minute. A unit that is active but not answering is restarted:

| Probe | Healthy answers |
| --- | --- |
| `http://127.0.0.1:4096/api/info` | `200`, or `401` for a server asking for credentials |
| `http://127.0.0.1:8642/health` | `200`, or `401` for a server asking for credentials |

A restart is logged rather than silent:

```bash
journalctl -t ultus-health
systemctl list-timers 'ultus-*'
```

The probe runs only against a unit systemd already reports active. A unit that crashed or is stopped is left to its own `Restart=on-failure`, so the timer does not resurrect a workload the operator stopped on purpose.

## Backup

The nightly backup runs at 02:30 with the workloads stopped, so restic reads a quiescent tree.

| Unit | When | Does |
| --- | --- | --- |
| `ultus-backup.timer` | daily 02:30 | Stops both workloads, runs `restic backup`, starts them again on every exit path |
| `ultus-backup-forget.timer` | Sunday 03:30 | Applies `--keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune` |

Both timers are `Persistent=true`, so a window missed while the box was off runs on the next boot. The backup covers `/var/srv/ultus`, `/var/srv/opencode`, `/var/srv/hermes` and `/var/srv/repos`. The secrets file is inside the backup on purpose: the repository is the only way to rebuild after a disk failure.

Credentials live in `/var/srv/ultus/backup.env`, mode `0600` owned `root:root`. The units carry no `EnvironmentFile=`, because systemd publishes a unit's environment to any user through `systemctl show`. `ultus-backup` parses the file itself, exports only the `RESTIC_`, `AWS_` and `B2_` key prefixes, and checks the mode before it reads.

| Key | Required | Meaning |
| --- | --- | --- |
| `RESTIC_REPOSITORY` | yes | The repository URL |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | for S3 | Repository credentials |
| `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY` | for B2 | Repository credentials |
| `RESTIC_PASSWORD_FILE` | no | Defaults to `/var/srv/ultus/restic-password` |

A run by hand takes the same path:

```bash
sudo /usr/libexec/ultus/ultus-backup
sudo /usr/libexec/ultus/ultus-backup forget
```

Retention is automatic. `--keep-*` bounds what `forget` can delete, and `ultus-backup-forget.timer` prunes only weekly, so a wrong policy surfaces in `restic snapshots` before a month of history is gone. To take retention back into your hands, disable the timer:

```bash
sudo systemctl disable --now ultus-backup-forget.timer
```

Restore is a fresh install followed by restic: reinstall from the ISO, create the `ultus-data` partition, then restore into the mounted disk:

```bash
sudo mount /dev/disk/by-label/ultus-data /var/srv
sudo restic restore latest --target / --include /var/srv
sudo systemctl reboot
```

## Updates

The image uses bootc's own update timer, with one change: the stock unit applies and reboots at boot plus one hour. A drop-in replaces that command with `bootc upgrade --download-only --quiet`, so `bootc-fetch-apply-updates.timer` only downloads. Nothing applies outside a window.

`ultus-update-window.timer` runs at 04:00 and is the only thing that applies:

1. It reads `bootc status --format=json` for a staged deployment. With none, it exits and clears its marker.
2. It records the first time it saw the staged deployment in `/var/lib/ultus/staged-since`, and logs a warning once that deployment has waited 14 days.
3. It stops both workloads, then runs `bootc upgrade --from-downloaded --apply`.
4. On a failed apply it restarts the workloads and does not reboot. On success it reboots into the new deployment.

To opt out, disable the timer; the stock `bootc-fetch-apply-updates.timer` keeps downloading but nothing applies:

```bash
sudo systemctl disable --now ultus-update-window.timer
```

```bash
systemctl list-timers 'ultus-*' bootc-fetch-apply-updates.timer
journalctl -t ultus-update-window
```

## Recovery

`/etc` and the OS come from the image, so a broken host is rebuilt rather than repaired: reinstall, then restore the data disk from the backup. For a bad upgrade on a host that still boots, revert the deployment:

```bash
sudo bootc rollback --apply
```

[Install](install.md#after-first-boot) carries the upgrade and rollback detail, and `docs/known-gaps.md` records what is still unproven.
