# Cleanroom Kernels

Build and publish managed kernel assets used by Cleanroom backends.

This repository currently owns the experimental Apple Silicon `darwin-vz`
minimal Linux kernels used by Cleanroom and SporeVM smoke tests. It produces
the same release asset names and manifest shape that Cleanroom already resolves
from GitHub Releases.

## Build

Requirements:

- Docker
- `python3`
- `git`
- `tar`
- ARM64 Docker execution support only when overriding
  `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_DOCKER_PLATFORM=linux/arm64` on a
  non-ARM64 host, for example `qemu-user-static` plus `binfmt-support` on
  Ubuntu

Build the release assets locally:

```sh
scripts/build-release-assets.sh dist/kernels
```

The default build writes the Cleanroom `rootfs` and `initrd` profiles, plus
separate SporeVM kernel assets:

- `cleanroom-darwin-vz-minimal-rootfs-arm64-linux-<version>-Image`
- `cleanroom-darwin-vz-minimal-rootfs-arm64-linux-<version>-Image.config`
- `cleanroom-darwin-vz-minimal-rootfs-arm64-linux-<version>-Image.sha256`
- `cleanroom-darwin-vz-minimal-rootfs-arm64-linux-<version>.manifest.json`
- `cleanroom-darwin-vz-minimal-initrd-arm64-linux-<version>-Image`
- `cleanroom-darwin-vz-minimal-initrd-arm64-linux-<version>-Image.config`
- `cleanroom-darwin-vz-minimal-initrd-arm64-linux-<version>-Image.sha256`
- `cleanroom-darwin-vz-minimal-initrd-arm64-linux-<version>.manifest.json`
- `sporevm-arm64-linux-<version>-Image`
- `sporevm-arm64-linux-<version>-Image.config`
- `sporevm-arm64-linux-<version>-Image.sha256`
- `sporevm-arm64-linux-<version>.manifest.json`
- `sporevm-run-arm64-linux-<version>-Image`
- `sporevm-run-arm64-linux-<version>-Image.config`
- `sporevm-run-arm64-linux-<version>-Image.sha256`
- `sporevm-run-arm64-linux-<version>.manifest.json`

The legacy SporeVM kernel is based on the minimal initrd profile and enables
`/dev/mem` so SporeVM's diskless fork smoke helper can access its fixed
generation MMIO window. The SporeVM run kernel combines the minimal initrd
profile with virtio-blk, ext4, multiuser, System V IPC, POSIX timers, and
script interpreter support so `spore run` can use the same kernel for minimal
initrd commands and read-only rootfs execution, including rootfs init systems
that drop privileges, PostgreSQL workloads, and Ruby/Bundler binstubs. It also
enables the Docker-oriented kernel facilities needed for a warm in-guest Docker
daemon and Docker Compose workloads: namespaces, cgroups, seccomp, POSIX
message queues, keys, `overlayfs`, `veth`, bridge netfilter, NAT, iptables and
nftables compatibility, `tun`, `macvlan`, `ipvlan`, and `vxlan`. Neither is a
Cleanroom runtime profile.

## CI Contract

The pipeline can run:

```sh
scripts/ci-build-release-assets.sh
```

That writes direct release assets under `dist/kernels/`, creates
`dist/kernels.tar.gz`, and uploads both as Buildkite artifacts through
`buildkite-agent` when it is available.

Tagged Buildkite builds then run:

```sh
scripts/ci-publish-release.sh
```

That downloads `dist/kernels.tar.gz`, creates the matching GitHub Release in
`buildkite/cleanroom-kernels` when needed, and uploads the individual kernel
assets plus the bundled `kernels.tar.gz`.

## Release

Tag and push the next conventional version:

```sh
mise run release
```

The task runs local checks, fetches tags, uses `svu next` to calculate the next
version, tags the current commit, and pushes the tag. Buildkite publishes
GitHub Release assets from tagged builds.

## Configuration

Useful environment variables:

- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_VERSION`, default `6.1.155`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_PROFILES`, default `rootfs initrd`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_PROFILE`, optional single-profile
  override for local builds
- `CLEANROOM_KERNELS_INCLUDE_SPOREVM`, default `1`; set to `0` to skip SporeVM
  kernel assets in `scripts/build-release-assets.sh`
- `SPOREVM_KERNEL_ASSET_BASE`, default `sporevm-<arch>-linux-<version>`
- `SPOREVM_RUN_KERNEL_ASSET_BASE`, default
  `sporevm-run-<arch>-linux-<version>`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_ARCH`, default `arm64`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_DOCKER_IMAGE`, default `ubuntu:22.04`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_DOCKER_PLATFORM`, default `linux/amd64`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_CROSS_COMPILE`, default
  `aarch64-linux-gnu-` when building arm64 from a non-arm64 Docker platform
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_TARBALL_SHA256`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_ASSET_BASE`
- `CLEANROOM_KERNELS_GITHUB_REPOSITORY`, default `buildkite/cleanroom-kernels`
- `CLEANROOM_KERNELS_RELEASE_TAG`, default empty unless `BUILDKITE_TAG` is set
- `CLEANROOM_KERNELS_GITHUB_RELEASE_TOKEN`, used by tagged release publishing

## Cleanroom Handoff

Cleanroom still expects managed kernel assets on the Cleanroom release today.
The intended integration is:

1. This repo builds and releases kernel artifacts with manifest checksums.
2. Cleanroom release jobs fetch a pinned kernel artifact set from this repo.
3. Cleanroom either preserves current runtime behavior by re-publishing those
   verified files on its own releases, or migrates runtime resolution to read
   `buildkite/cleanroom-kernels` releases directly.
