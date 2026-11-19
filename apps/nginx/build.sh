#!/bin/sh
# Build a static nginx for saopanel (managed install, no distro packages).
#
# The build runs inside Alpine/musl with the image pinned by digest: a moving
# :3.20 tag would make two builds of the same source produce different bytes
# with no way to tell why. When the script is not already inside that image it
# re-executes itself there, so there is one description of the build.
#
# Output: nginx-<version>-<build>-linux-<arch>.tar.gz with a layout the panel
# installer understands:
#   sbin/nginx           static binary
#   conf/nginx.conf      managed config (the panel passes -c)
#   conf/mime.types
#   test.conf            used by the self-check (nginx -t -c)
#   manifest.json        what this build reports about itself
set -eu

VERSION=${NGINX_VERSION:-1.31.9}
BUILD=${BUILD:-sao-r1}
ARCH=${TARGETARCH:-$(uname -m)}
SRC="https://nginx.org/download/nginx-${VERSION}.tar.gz"
# Measured locally with `sha256sum nginx-${VERSION}.tar.gz` on the release
# tarball, never copied from a website: this is the only thing standing between
# the build and a swapped upstream.
SRC_SHA256=${SRC_SHA256:-a11c5eeee2e257f4478f0e649f84b0040787d277d2d3e5233952aa6b6dcb80ad}

# Pinned by digest. CI resolves the digest and exports it (see build-app.yml);
# a local run has to pin it too. There is no :3.20 fallback on purpose - a
# floating tag means the bytes change without this file changing.
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.20@sha256:REPLACE_WITH_DIGEST}

if [ ! -f /etc/alpine-release ]; then
  case "$ALPINE_IMAGE" in
    *REPLACE_WITH_DIGEST*)
      echo "build.sh: pin ALPINE_IMAGE first (docker buildx imagetools inspect alpine:3.20)" >&2
      exit 2
      ;;
  esac
  command -v docker >/dev/null || { echo "build.sh: docker is required outside Alpine" >&2; exit 2; }
  exec docker run --rm --platform "linux/${ARCH}" \
    -e NGINX_VERSION="$VERSION" -e BUILD="$BUILD" -e TARGETARCH="$ARCH" \
    -e SRC_SHA256="$SRC_SHA256" -v "$PWD:/w" -w /w "$ALPINE_IMAGE" /bin/sh ./apps/nginx/build.sh
fi

echo ">> apt free, package-manager free: this is Alpine $(cat /etc/alpine-release)"
apk add --no-cache build-base pcre2-dev zlib-dev openssl-dev linux-headers curl tar coreutils >/dev/null

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

echo ">> fetching ${SRC}"
curl -fsSL -o nginx.tar.gz "$SRC"
echo "${SRC_SHA256}  nginx.tar.gz" | sha256sum -c -
tar -xzf nginx.tar.gz

cd "nginx-${VERSION}"
./configure \
  --prefix=/apps/nginx \
  --with-threads \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_realip_module \
  --with-http_stub_status_module \
  --with-http_gzip_static_module \
  --with-stream \
  --with-stream_ssl_module \
  --with-cc-opt="-O2 -static" \
  --with-ld-opt="-static" >/dev/null
make -j"$(nproc)" >/dev/null
make install DESTDIR="$work/root" >/dev/null

stage="$work/stage"
mkdir -p "$stage/sbin" "$stage/conf"
cp "$work/root/apps/nginx/sbin/nginx" "$stage/sbin/nginx"
cp /w/apps/nginx/mime.types "$stage/conf/mime.types"
cp /w/apps/nginx/test.conf "$stage/test.conf"
cat > "$stage/conf/nginx.conf" <<'CONF'
# Managed configuration. The panel always starts nginx with -c pointing here,
# so nothing in /etc/nginx is ever read or written.
worker_processes auto;
pid /run/saopanel-nginx.pid;
error_log stderr warn;
events { worker_connections 1024; }
http {
  include mime.types;
  default_type application/octet-stream;
  access_log off;
  client_body_temp_path /var/lib/saopanel/apps/nginx/tmp/body;
  proxy_temp_path /var/lib/saopanel/apps/nginx/tmp/proxy;
  fastcgi_temp_path /var/lib/saopanel/apps/nginx/tmp/fastcgi;
  uwsgi_temp_path /var/lib/saopanel/apps/nginx/tmp/uwsgi;
  scgi_temp_path /var/lib/saopanel/apps/nginx/tmp/scgi;
  include /var/lib/saopanel/site-conf/*.conf;

  # First boot has no site config yet, so the binary must answer for itself or
  # the installer's probe would fail on a machine that is working perfectly.
  server {
    listen 80 default_server;
    server_name _;
    location = /healthz { return 200 "ok\n"; }
    location = /__health { return 200 "ok\n"; }
    location = /nginx_status { stub_status; }
    location / { return 404; }
  }
}
CONF

cat > "$stage/manifest.json" <<JSON
{"id":"nginx","version":"${VERSION}","build":"${BUILD}","arch":"${ARCH}","built_by":"saopanel-apps"}
JSON

# Three self-checks; any failure and nothing is published.
echo ">> self-check: static"
file "$stage/sbin/nginx"
if ! file "$stage/sbin/nginx" | grep -q "statically linked"; then
  echo "build.sh: nginx is not statically linked" >&2
  exit 3
fi
echo ">> self-check: ldd"
ldd_out=$(ldd "$stage/sbin/nginx" 2>&1 || true)
echo "$ldd_out"
# musl's ldd prints one line for a static binary; a dynamic one always names a
# resolved library with "=>".
case "$ldd_out" in
  *"=>"*)
    echo "build.sh: ldd resolved a dynamic dependency" >&2
    exit 4
    ;;
esac
echo ">> self-check: nginx -t"
"$stage/sbin/nginx" -t -c "$stage/test.conf" -p "$stage"

out="nginx-${VERSION}-${BUILD}-linux-${ARCH}.tar.gz"
mkdir -p /w/dist
tar -C "$stage" -czf "/w/dist/${out}" .
( cd /w/dist && sha256sum "$out" > SHA256SUMS )
echo ">> built /w/dist/${out}"
ls -l "/w/dist/${out}"
cat /w/dist/SHA256SUMS
