# Cleanroom Kernels

Build and publish managed kernel assets used by Cleanroom backends.

This repository currently owns the experimental Apple Silicon `darwin-vz`
minimal rootfs-profile Linux kernel. It produces the same release asset names
and manifest shape that Cleanroom already resolves from GitHub Releases.

## Build

Requirements:

- Docker
- `python3`
- `git`
- `tar`
- ARM64 Docker execution support when building on a non-ARM64 host, for example
  `qemu-user-static` plus `binfmt-support` on Ubuntu

Build the release assets locally:

```sh
scripts/build-release-assets.sh dist/kernels
```

The build writes:

- `cleanroom-darwin-vz-minimal-rootfs-arm64-linux-<version>-Image`
- `cleanroom-darwin-vz-minimal-rootfs-arm64-linux-<version>-Image.config`
- `cleanroom-darwin-vz-minimal-rootfs-arm64-linux-<version>-Image.sha256`
- `cleanroom-darwin-vz-minimal-rootfs-arm64-linux-<version>.manifest.json`

## CI Contract

The pipeline can run:

```sh
scripts/ci-build-release-assets.sh
```

That writes direct release assets under `dist/kernels/`, creates
`dist/kernels.tar.gz`, and uploads both through `buildkite-agent` when it is
available.

## Configuration

Useful environment variables:

- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_VERSION`, default `6.1.155`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_PROFILE`, default `rootfs`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_ARCH`, default `arm64`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_DOCKER_IMAGE`, default `ubuntu:22.04`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_DOCKER_PLATFORM`, default `linux/arm64`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_TARBALL_SHA256`
- `CLEANROOM_DARWIN_VZ_MINIMAL_KERNEL_ASSET_BASE`
- `CLEANROOM_KERNELS_GITHUB_REPOSITORY`, default `buildkite/cleanroom-kernels`
- `CLEANROOM_KERNELS_RELEASE_TAG`, default empty unless `BUILDKITE_TAG` is set

## Cleanroom Handoff

Cleanroom still expects managed kernel assets on the Cleanroom release today.
The intended integration is:

1. This repo builds and releases kernel artifacts with manifest checksums.
2. Cleanroom release jobs fetch a pinned kernel artifact set from this repo.
3. Cleanroom publishes the verified files as direct assets on its own release,
   preserving current runtime resolution behavior.
