# ultus-atomic image definition.
#
# Layout follows the Universal Blue image-template
# (https://github.com/ublue-os/image-template): a ctx stage exposes the build
# scripts to one RUN, and a build script performs the installs.
#
# The base is Fedora's own bootc image rather than a Universal Blue desktop
# image. Fedora signs the kernel and its modules, so a Secure Boot machine
# trusts the whole chain with no per-machine MOK enrollment, and the base
# carries no desktop environment to strip (#59). Every package the image needs
# is named in a manifest under manifests/; the desktop's set is
# manifests/packages-desktop.txt, the rest is the headless baseline, and the
# desktop's files live under modules/desktop/.

# Allow build scripts to be referenced without being copied into the final image.
FROM scratch AS ctx
COPY build /build
COPY manifests /manifests
COPY overlay /overlay
COPY modules/desktop /modules/desktop

# The base is pinned to a digest, and the tag stays for readers. The pin is a
# literal rather than an ARG: Dependabot reads a file whose name matches
# containerfile|dockerfile, and never expands an ARG into FROM.
# tests/test-static.sh asserts the tag+digest form and the registry: quay deletes
# the previous daily digest, Fedora's registry keeps it.
FROM registry.fedoraproject.org/fedora-bootc:45@sha256:f387c5f622d2f095e23b1587c97a4d4659231df6c8a649329839a9336a99c5e4

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    bash /ctx/build/common.sh

# Verify the final image and contents are correct.
RUN bootc container lint
