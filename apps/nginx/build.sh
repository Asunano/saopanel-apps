#!/bin/sh
# Build a fully static nginx for the panel's app store.
#
# The shebang is /bin/sh and the first thing the script does is install bash and
# re-exec itself: the build needs `set -o pipefail` to tell a failed compile from
# a failed tee, and Alpine has no bash until you install it. Docker is invoked
# with /bin/sh for the same reason - `docker run alpine /bin/bash` fails before
# the script that would install bash ever runs.
#
# What lands in the tarball:
#   sbin/nginx           static binary (musl, no shared objects)
#   conf/nginx.conf      managed config (the panel always passes -c here)
#   conf/mime.types
#   test.conf            used by this script's own -t check
#   manifest.json        what this build reports about itself
#
# Why zlib and OpenSSL are built here instead of coming from apk: `--with-ld-opt
# -static` needs libz.a and libssl.a, and Alpine's zlib-dev ships neither .a for
# zlib nor any static OpenSSL at all. The first version of this script linked
# against the distro's shared libraries and died at configure with
#     ./configure: error: SSL modules require the OpenSSL library.
#
# Every build step keeps its output. A build that fails has to say why: the
# first version sent configure and make to /dev/null and reported a bare exit 1.
set -eu

# Bootstrap: inside Alpine, get bash and re-exec. Outside Alpine this is a no-op.
if [ -f /etc/alpine-release ] && [ "${SAO_BASH:-0}" != "1" ]; then
	apk add --no-cache bash >/dev/null
	exec env SAO_BASH=1 bash "$0" "$@"
fi
set -o pipefail

VERSION=${NGINX_VERSION:-1.31.9}
BUILD=${BUILD:-sao-r1}
ARCH=${TARGETARCH:-$(uname -m)}
SRC="https://nginx.org/download/nginx-${VERSION}.tar.gz"
# Measured locally with sha256sum on the release tarball (1,388,470 bytes), never
# copied from a website: this is the only thing between the build and a swapped
# upstream.
SRC_SHA256=${SRC_SHA256:-a11c5eeee2e257f4478f0e649f84b0040787d277d2d3e5233952aa6b6dcb80ad}
ZLIB_VERSION=${ZLIB_VERSION:-1.3.1}
OPENSSL_VERSION=${OPENSSL_VERSION:-3.3.2}

# Pinned by digest. CI resolves it (see build-app.yml) and exports ALPINE_IMAGE;
# a local run has to pin it too. There is deliberately no floating-tag fallback:
# a tag means the toolchain can change without this file changing.
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.20@sha256:REPLACE_WITH_DIGEST}

if [ ! -f /etc/alpine-release ]; then
	case "$ALPINE_IMAGE" in
	*REPLACE_WITH_DIGEST*)
		echo "build.sh: pin ALPINE_IMAGE first (docker buildx imagetools inspect alpine:3.20)" >&2
		exit 2
		;;
	esac
	command -v docker >/dev/null || {
		echo "build.sh: docker is required outside Alpine" >&2
		exit 2
	}
	exec docker run --rm --platform "linux/${ARCH}" \
		-e NGINX_VERSION="$VERSION" -e BUILD="$BUILD" -e TARGETARCH="$ARCH" \
		-e SRC_SHA256="$SRC_SHA256" -e ZLIB_VERSION="$ZLIB_VERSION" \
		-e OPENSSL_VERSION="$OPENSSL_VERSION" \
		-v "$PWD:/w" -w /w "$ALPINE_IMAGE" /bin/sh ./apps/nginx/build.sh
fi

echo ">> package-manager free build: this is Alpine $(cat /etc/alpine-release)"
apk add --no-cache build-base pcre2-dev linux-headers curl tar coreutils perl >/dev/null

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
mkdir -p "$work/log"

# run_step <name> <logfile> <command...>
#
# Runs one build step with its output both on the console and in a log, and on
# failure prints the last 50 lines before giving up. This is the portable
# equivalent of `set -o pipefail | tee`: the exit status is the command's, not
# tee's, and nothing is swallowed.
run_step() {
	local name=$1 logf=$2
	shift 2
	echo ">> ${name}"
	if "$@" 2>&1 | tee "$logf"; then
		return 0
	fi
	local rc=${PIPESTATUS[0]}
	echo "build.sh: ${name} failed (exit ${rc}); last 50 lines of ${logf}:" >&2
	tail -50 "$logf" >&2 || true
	return "$rc"
}

echo ">> zlib ${ZLIB_VERSION} (static)"
curl -fsSL -o zlib.tar.gz "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
tar -xzf zlib.tar.gz
(
	cd "zlib-${ZLIB_VERSION}"
	run_step "zlib configure" "$work/log/zlib.log" ./configure --static --prefix="$work/zlib"
	run_step "zlib make" "$work/log/zlib.log" make -j"$(nproc)"
	run_step "zlib install" "$work/log/zlib.log" make install
)

echo ">> openssl ${OPENSSL_VERSION} (static, no-shared)"
curl -fsSL -o openssl.tar.gz "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
tar -xzf openssl.tar.gz
(
	cd "openssl-${OPENSSL_VERSION}"
	run_step "openssl config" "$work/log/openssl.log" ./config no-shared no-tests no-async --prefix="$work/ossl" --libdir=lib
	run_step "openssl make" "$work/log/openssl.log" make -j"$(nproc)"
	run_step "openssl install" "$work/log/openssl.log" make install_sw
)

echo ">> fetching ${SRC}"
curl -fsSL -o nginx.tar.gz "$SRC"
echo "${SRC_SHA256}  nginx.tar.gz" | sha256sum -c -
tar -xzf nginx.tar.gz

cd "nginx-${VERSION}"
run_step "nginx configure" "$work/log/configure.log" ./configure \
	--prefix=/apps/nginx \
	--with-threads \
	--with-http_ssl_module \
	--with-http_v2_module \
	--with-http_realip_module \
	--with-http_stub_status_module \
	--with-http_gzip_static_module \
	--with-stream \
	--with-stream_ssl_module \
	--with-zlib="$work/zlib-${ZLIB_VERSION}" \
	--with-openssl="$work/openssl-${OPENSSL_VERSION}" \
	--with-openssl-opt="no-shared no-tests" \
	--with-cc-opt="-O2 -static" \
	--with-ld-opt="-static"
run_step "nginx make" "$work/log/nginx.log" make -j"$(nproc)"
run_step "nginx install" "$work/log/nginx.log" make install DESTDIR="$work/root"

stage="$work/stage"
mkdir -p "$stage/sbin" "$stage/conf"
cp "$work/root/apps/nginx/sbin/nginx" "$stage/sbin/nginx"
cp /w/apps/nginx/mime.types "$stage/conf/mime.types"
cp /w/apps/nginx/test.conf "$stage/test.conf"
# The managed config. No `user` directive: the unit runs nginx as saopanel and
# grants CAP_NET_BIND_SERVICE, so nginx never has privileges to drop and never
# needs the account named twice. daemon off keeps it in the foreground, which is
# what Type=simple expects. pid and temp paths are relative to -p (the version
# directory the panel passes), so an upgrade cannot collide with the old tree;
# the only absolute path is the log, because it outlives the version directory.
cat >"$stage/conf/nginx.conf" <<'CONF'
# Managed configuration. The panel always starts nginx with -c pointing here and
# -p pointing at the version directory, so nothing in /etc/nginx is read or
# written and every relative path below lives inside that directory.
daemon off;
worker_processes auto;
pid run/nginx.pid;
error_log /var/log/saopanel/nginx-error.log warn;
events { worker_connections 1024; }
http {
  include mime.types;
  default_type application/octet-stream;
  access_log off;
  client_body_temp_path tmp/client_body;
  proxy_temp_path tmp/proxy;
  fastcgi_temp_path tmp/fastcgi;
  uwsgi_temp_path tmp/uwsgi;
  scgi_temp_path tmp/scgi;
  include /var/lib/saopanel/site-conf/*.conf;

  # A fresh install has no site config yet, so the binary has to answer for
  # itself or the panel's probe would fail on a machine that is working.
  server {
    listen 80 default_server;
    server_name _;
    location = /healthz { return 200 "ok\n"; }
    location = /nginx_status { stub_status; }
    location / { return 404; }
  }
}
CONF

cat >"$stage/manifest.json" <<JSON
{"id":"nginx","version":"${VERSION}","build":"${BUILD}","arch":"${ARCH}","built_by":"saopanel-apps","zlib":"${ZLIB_VERSION}-static","openssl":"${OPENSSL_VERSION}-static"}
JSON

echo ">> self-check: static"
file "$stage/sbin/nginx"
if ! file "$stage/sbin/nginx" | grep -q "statically linked"; then
	echo "build.sh: nginx is not statically linked" >&2
	exit 3
fi
echo ">> self-check: ldd"
ldd_out=$(ldd "$stage/sbin/nginx" 2>&1 || true)
echo "$ldd_out"
case "$ldd_out" in
*"=>"*)
	echo "build.sh: ldd resolved a dynamic dependency" >&2
	exit 4
	;;
esac
echo ">> self-check: nginx -t"
"$stage/sbin/nginx" -t -c "$stage/test.conf" -p "$stage"

mkdir -p /w/dist
name="nginx-${VERSION}-${BUILD}-linux-${ARCH}.tar.gz"
tar -C "$stage" -czf "/w/dist/$name" --owner=0 --group=0 --numeric-owner \
	sbin/nginx conf/nginx.conf conf/mime.types test.conf manifest.json
(cd /w/dist && sha256sum "$name" >SHA256SUMS)
echo ">> artefact: /w/dist/$name"
ls -l "/w/dist/$name"
cat /w/dist/SHA256SUMS
