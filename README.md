# ultus-atomic

[![ci](https://github.com/ultus-net/ultus-atomic/actions/workflows/ci.yml/badge.svg)](https://github.com/ultus-net/ultus-atomic/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Two Fedora bootc images from one tree. The desktop image is a niri and Dux Modular Shell workstation. The server image is a headless host that runs coding agents in rootless containers, backs itself up and publishes its surfaces over a tailnet.

Both are atomic OS images. `bootc upgrade` moves a host forward, `bootc rollback` moves it back, and a host that will not boot is reinstalled rather than repaired. Fedora signs the kernel, so Secure Boot needs no per-machine enrolment.

## One tree, two roles

| | Desktop | Server |
| --- | --- | --- |
| Build file | `Containerfile` | `Containerfile.server` |
| Extra packages | `manifests/packages-desktop.txt` | `manifests/packages-server.txt` |
| Role module | `modules/desktop/` | `modules/server/` |
| Ships | niri, Dux Modular Shell, Dux Greeter, Ghostty, an Xfce fallback, Steam | rootless agent workloads, a tailnet join and its three serve mounts, a nightly backup, an update window |
| Accounts in the image | none | `agents`, uid 1000, for the workloads |
| Image gate | `tests/verify-image.sh` | `tests/verify-image.sh --server` |

`Containerfile.nvidia` builds the desktop image with the NVIDIA akmod set for the host that carries an RTX 3070. Every image pins `fedora-bootc:45` by digest and carries `tailscale` from the shared manifest, so each host runs one image and joins the tailnet as its own node.

The shared trees are `build/` (the build scripts), `overlay/` (files every role gets), and `tests/` (the gates and the VM harness). A role adds a module under `modules/` and a manifest, and the build script names the module's own build step.

## What this is for

- **Disposable hosts with one drive.** Each host carries the OS partitions plus one `ultus-data` partition. Nothing on the OS disk is worth rescuing: a host comes back from a reinstall and a restic restore.
- **Agents never run on the host.** Hermes and OpenCode run in rootless Podman containers as `agents`, read-only, with no host namespace, no capabilities and no container socket.
- **One route in.** The workloads publish on `127.0.0.1` only, and `tailscale serve` publishes the three surfaces the operator uses. `sshd` stays disabled.
- **Updates inside a window.** On the server, bootc's own timer only downloads; a nightly timer drains the workloads, applies the staged deployment and reboots. A failed apply restarts the workloads and leaves the host up.

## Status

| Area | State |
| --- | --- |
| Base | Fedora `fedora-bootc:45`, pinned by digest, with Dependabot watching for a bump |
| Desktop image | Builds, boots to the greeter in a VM, and provisions the desktop on first login |
| Server image | Builds, verifies, and boots with a data disk in its own CI job: rootless workloads, tailnet, backup and update window ([detail](docs/server.md)) |
| NVIDIA variant | Builds and verifies in an advisory job. The gaming dogfood is still manual |
| Agents | OpenCode and Hermes run as rootless containers. Each image reference is a digest-pinned default the operator can override from the data disk |
| Tailnet | Every image carries `tailscale`, and the server ships the join plus the three `serve` mounts. `tailscaled` is not yet enabled at boot, so a host runs `systemctl enable --now tailscaled` once until [#151](https://github.com/ultus-net/ultus-atomic/issues/151) lands |
| Publishing | CI signs every published digest with cosign keyless OIDC and attests the SBOM. `:latest` moves only on a manual promotion |
| Dotfiles | The [dotfiles repository](https://github.com/ultus-net/dotfiles) stays authoritative for shell and user configuration |

## Quick start

```bash
just ci-local          # static gate, desktop build, image lint
just disk              # qcow2 with a test account; needs rootful podman
just boot              # boots that disk under QEMU
```

The server is the same shape with its own build file and its role verifier:

```bash
podman build -f Containerfile.server -t localhost/ultus-atomic-server:dev .
tests/verify-image.sh --server localhost/ultus-atomic-server:dev
```

[Build](docs/build.md) covers the build inputs and the hook order. [Testing](docs/testing.md) covers the VM runs and the server boot test. [Headless server](docs/server.md) covers first boot, secrets, backup and recovery.

## Documentation

- [Build](docs/build.md)
- [Install](docs/install.md)
- [Headless server](docs/server.md)
- [First login](docs/first-login.md)
- [Desktop](docs/desktop.md)
- [Applications](docs/applications.md)
- [Developer and sysadmin tooling](docs/developer-tooling.md)
- [Testing](docs/testing.md)
- [Laptop hardware: Dell Pro 14 PC14250](docs/hardware/dell-pro-14-pc14250.md)
- [CI and publishing](docs/ci.md)
- [Known gaps before promotion](docs/known-gaps.md)
- [Roadmap](docs/superpowers/plans/2026-11-14-tooling-and-platform-roadmap.md)
- [Approved design](docs/superpowers/specs/2026-11-09-dux-atomic-design.md)
- [Headless server design](docs/superpowers/specs/2026-11-20-headless-server-image-design.md)
- [Headless server plan, part 1](docs/superpowers/plans/2026-11-20-headless-server-part-1-base-and-image.md)
- [Headless server plan, part 2](docs/superpowers/plans/2026-11-20-headless-server-part-2-server-behaviour.md)
- [Agent container profile](docs/agent-container.md)
- [Microsoft Agent Framework study plan](docs/learning/2026-11-14-microsoft-agent-framework-12-stage-plan.md)
