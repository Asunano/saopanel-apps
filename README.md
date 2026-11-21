# saopanel-apps

Application packages for [saopanel](https://github.com/<org>/saopanel). Each app
is built from source, statically, inside a digest-pinned Alpine image, and
published as a tarball plus SHA256SUMS. The panel never runs a package manager:
it downloads one of these tarballs, verifies the checksum, and manages the
service itself.

## Naming

    tag      nginx-v1.31.9-sao-r1
    artefact nginx-1.31.9-sao-r1-linux-amd64.tar.gz
             nginx-1.31.9-sao-r1-linux-arm64.tar.gz
    build    sao-r<n> — bump r for every rebuild of the same upstream version,
             never reuse one; a new upstream version restarts at r1.

## Building

    APP_ORG=<github-org> apps/release.sh          # both arches, then the manifest

`apps/release.sh` builds every architecture, measures the tarballs it just
produced, and renders `dist/apps/nginx.yaml` with those checksums and sizes.
Nothing in the manifest is typed by hand: a checksum that is copied from
somewhere else is a checksum that will disagree with the bytes on the customer's
machine.

A single architecture is refused unless `--allow-partial` is passed, and that
flag exists for local drills only — a published release that covers one
architecture fails on every machine of the other one.

Building one architecture directly is still possible:

    TARGETARCH=amd64 sh apps/nginx/build.sh

Releases are cut by pushing a tag (`nginx-v*`); `.github/workflows/build-app.yml`
builds both architectures, renders the manifest, and publishes the tarballs,
`SHA256SUMS`, `nginx-V-<arch>.txt` and the manifest as release assets.

### Networks that cannot reach the sources

`build.sh` fetches nginx, zlib and OpenSSL and verifies each against a pinned
sha256. Two overrides exist for hosts that cannot reach them, and neither
weakens the check:

    SRC_DIR=/path/to/tarballs   # use openssl-3.3.2.tar.gz etc. from here, no network
    APK_MIRROR=https://mirrors.aliyun.com   # apk mirror; packages stay signature-checked
    ALPINE_IMAGE=docker.m.daocloud.io/library/alpine:3.20@sha256:d9e853e8…

The digest is the same on every registry (it hashes the manifest list, not a
tag), so a mirror is only a different route to the same bytes.

## Layout of a package

    sbin/nginx      static binary (checked with file and ldd before publishing)
    conf/nginx.conf managed config, always passed with -c
    conf/mime.types
    test.conf       the self-check configuration
    manifest.json   id/version/build/arch of this build
