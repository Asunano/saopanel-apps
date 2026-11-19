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

## Building locally

    TARGETARCH=amd64 sh apps/nginx/build.sh     # needs docker + a pinned digest

`ALPINE_IMAGE` must carry a digest; the script refuses to run with the
placeholder, because an unpinned base image makes two builds of the same tag
differ with no way to explain it.

## Layout of a package

    sbin/nginx      static binary (checked with file and ldd before publishing)
    conf/nginx.conf managed config, always passed with -c
    conf/mime.types
    test.conf       the self-check configuration
    manifest.json   id/version/build/arch of this build
