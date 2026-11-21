#!/bin/sh
# Build a fully static nginx for the panel's app store.
#
# The shebang is /bin/sh and the second thing the script does (after `set -eu`,
# which every shell has) is re-exec itself under bash: the build needs
# `set -o pipefail` to tell a failed compile from a failed tee. Two environments
# have to be handled, and the first version handled only one of them:
#   - Alpine has no bash until it is installed, so it installs it first;
#   - Debian/Ubuntu (the CI runners, and any laptop) have bash but run
#     `sh build.sh` under dash, where `set -o pipefail` is a hard error. That
#     version died at line 32 on a runner with bash sitting right there.
# Docker is entered with /bin/sh for the same reason - `docker run alpine
# /bin/bash` fails before the script that would install bash ever runs.
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

# Bootstrap: get a bash and re-exec under it, once. Inside Alpine that means
# installing it first; anywhere else bash is simply present and dash is not the
# shell this script is written for.
if [ "${SAO_BASH:-0}" != "1" ]; then
	if ! command -v bash >/dev/null && [ -f /etc/alpine-release ]; then
		apk add --no-cache bash >/dev/null
	fi
	if command -v bash >/dev/null; then
		exec env SAO_BASH=1 bash "$0" "$@"
	fi
	echo "build.sh: bash is required (set -o pipefail); install it and re-run" >&2
	exit 2
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

# Where the two static dependencies come from, and what they must hash to.
#
# Both URLs were changed after the first real run of this script failed on them
# with the network it had:
#   - zlib used github.com/madler/zlib/releases, which is a redirect to
#     objects.githubusercontent.com. zlib.net serves the same bytes directly and
#     is the project's own host, so there is one less redirect between the build
#     and the source.
#   - openssl's /source/ directory only holds the current release; 3.3.2 has
#     moved to /source/old/3.3/, and the old path is served by openssl.org
#     itself instead of redirecting to a GitHub release asset.
# The sha256 of openssl is the one published in the release's own .sha256
# sidecar; zlib's was measured on the tarball from zlib.net.
ZLIB_URL=${ZLIB_URL:-https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz}
ZLIB_SHA256=${ZLIB_SHA256:-9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23}
OPENSSL_URL=${OPENSSL_URL:-https://www.openssl.org/source/old/3.3/openssl-${OPENSSL_VERSION}.tar.gz}
OPENSSL_SHA256=${OPENSSL_SHA256:-2e8a40b01979afe8be0bbfb3de5dc1c6709fedb46d6c89c10da114ab5fc3d281}

# Pinned by digest, index digest of alpine:3.20 (the same digest on every
# registry: it is a hash of the manifest list, not of a tag). CI re-resolves it
# on every run and exports ALPINE_IMAGE, so a retagged upstream base changes
# nothing here. A local run in a network where registry-1.docker.io is blocked
# passes the mirror name explicitly:
#   ALPINE_IMAGE=docker.m.daocloud.io/library/alpine:3.20@sha256:d9e853e8... \
#     sh apps/nginx/build.sh
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc}

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
	# SRC_DIR is mounted at /src and the container reads the cache from there;
	# without it the container downloads, exactly as CI does.
	set -- -e NGINX_VERSION="$VERSION" -e BUILD="$BUILD" -e TARGETARCH="$ARCH" \
		-e SRC_SHA256="$SRC_SHA256" -e ZLIB_VERSION="$ZLIB_VERSION" \
		-e OPENSSL_VERSION="$OPENSSL_VERSION" -e ZLIB_URL="$ZLIB_URL" \
		-e ZLIB_SHA256="$ZLIB_SHA256" -e OPENSSL_URL="$OPENSSL_URL" \
		-e OPENSSL_SHA256="$OPENSSL_SHA256" \
		-v "$PWD:/w" -w /w
	if [ -n "${SRC_DIR:-}" ]; then
		set -- "$@" -v "$SRC_DIR:/src:ro" -e SRC_DIR=/src
	fi
	if [ -n "${APK_MIRROR:-}" ]; then
		set -- "$@" -e APK_MIRROR="$APK_MIRROR"
	fi
	exec docker run --rm --platform "linux/${ARCH}" "$@" "$ALPINE_IMAGE" /bin/sh ./apps/nginx/build.sh
fi

echo ">> package-manager free build: this is Alpine $(cat /etc/alpine-release)"
# Optional apk mirror: the host that stands in for dl-cdn.alpinelinux.org, so
# APK_MIRROR=https://mirrors.aliyun.com turns .../alpine/v3.20/main into
# .../alpine/v3.20/main. Packages stay signature-verified against Alpine's keys,
# so this changes how fast the toolchain arrives, not what it is. It exists
# because the CDN delivered ~100KB/s on the network this script was first run
# on, which turned a six-minute build into an afternoon.
if [ -n "${APK_MIRROR:-}" ]; then
	sed -i "s|https://dl-cdn.alpinelinux.org|${APK_MIRROR%/}|g" /etc/apk/repositories
fi
apk add --no-cache build-base pcre2-dev linux-headers curl tar coreutils perl >/dev/null

# The binary is compiled with --user=saopanel --group=saopanel (see the configure
# step), and nginx resolves that name at config-test time whenever it runs as
# root. This self-check runs as root, so the account has to exist here too — with
# the same name the panel's installer creates on the target. It exists only in
# this throwaway container; nothing about it ships.
addgroup -S saopanel 2>/dev/null || true
adduser -S -D -H -G saopanel saopanel 2>/dev/null || true

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

# fetch_verified <file> <url> <sha256>
#
# Downloads one source and refuses to continue unless it hashes to the pinned
# value. Every dependency goes through here, including the ones whose URL is
# overridden, so "the mirror was different" can never mean "the bytes were
# different".
#
# SRC_DIR is an offline cache: if it holds a file by the same name, that file is
# used and no network is touched. It is mounted into the container by the docker
# branch below, which is how a build runs on a host whose network cannot reach
# the sources at all (this project's first dry-run had exactly that problem).
fetch_verified() {
	local file=$1 url=$2 want=$3 cached=""
	if [ -n "${SRC_DIR:-}" ]; then
		# The cache keeps upstream file names; the build uses short local ones.
		for candidate in "${SRC_DIR}/${file}" "${SRC_DIR}/$(basename "$url")"; do
			[ -f "$candidate" ] && cached=$candidate && break
		done
	fi
	if [ -n "$cached" ]; then
		echo ">> ${file} <- ${cached} (offline cache)"
		cp "$cached" "${file}.part"
	else
		echo ">> ${file} <- ${url}"
		curl -fsSL --retry 3 -o "${file}.part" "$url"
	fi
	if ! echo "${want}  ${file}.part" | sha256sum -c - >/dev/null; then
		echo "build.sh: ${file} does not hash to ${want}" >&2
		echo "build.sh: got $(sha256sum "${file}.part" | cut -d' ' -f1)" >&2
		exit 3
	fi
	mv "${file}.part" "$file"
}

echo ">> zlib ${ZLIB_VERSION} (static)"
fetch_verified zlib.tar.gz "$ZLIB_URL" "$ZLIB_SHA256"
tar -xzf zlib.tar.gz
(
	cd "zlib-${ZLIB_VERSION}"
	run_step "zlib configure" "$work/log/zlib.log" ./configure --static --prefix="$work/zlib"
	run_step "zlib make" "$work/log/zlib.log" make -j"$(nproc)"
	run_step "zlib install" "$work/log/zlib.log" make install
)

echo ">> openssl ${OPENSSL_VERSION} (static, no-shared)"
fetch_verified openssl.tar.gz "$OPENSSL_URL" "$OPENSSL_SHA256"
tar -xzf openssl.tar.gz
(
	cd "openssl-${OPENSSL_VERSION}"
	run_step "openssl config" "$work/log/openssl.log" ./config no-shared no-tests no-async --prefix="$work/ossl" --libdir=lib
	run_step "openssl make" "$work/log/openssl.log" make -j"$(nproc)"
	run_step "openssl install" "$work/log/openssl.log" make install_sw
)

echo ">> fetching ${SRC}"
fetch_verified nginx.tar.gz "$SRC" "$SRC_SHA256"
tar -xzf nginx.tar.gz

cd "nginx-${VERSION}"
# --error-log-path is the one path nginx opens before it has read a directive, at
# the default <prefix>/logs/error.log. The panel starts nginx with -p <version
# dir>, which belongs to root and is never written to, so every start logged
# "[alert] could not open error log file" into the journal and then used the log
# the managed conf names. Compiling the same path in means the first open
# succeeds, and a fresh install's journal shows the service starting, not
# complaining. The directory is created and chowned by install.sh; the managed
# conf names the same file, so both agree.
# --user/--group: nginx's compiled default worker account is "nobody", and it
# resolves that name at config-test time whenever it is run as root — which is
# how the agent runs `nginx -t`. Debian has the user "nobody" but the *group*
# "nogroup", so on a clean Debian with the panel's own nginx every site apply
# failed with `getgrnam("nobody") failed`. Naming the account the unit already
# runs as removes the distro dependency: the installer creates saopanel:saopanel
# before any app can be installed, and a non-root master ignores the directive
# without a warning (unlike writing `user` into the config, which warns).
run_step "nginx configure" "$work/log/configure.log" ./configure \
	--prefix=/apps/nginx \
	--user=saopanel \
	--group=saopanel \
	--error-log-path=/var/log/saopanel/nginx-error.log \
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
# The compiled-in error log is /var/log/saopanel/nginx-error.log; create it here
# too so the build's own -t does not open a path that does not exist yet.
mkdir -p /var/log/saopanel
"$stage/sbin/nginx" -t -c "$stage/test.conf" -p "$stage"

# What this binary actually is, in its own words. The release publishes this
# verbatim: "it has http_v2 and stream" has to be checkable by whoever installs
# it, not a claim in a changelog. The three modules below are the ones the
# manifest's capabilities promise, so a build that lost one fails here instead
# of at the customer's first `listen 443 ssl`.
echo ">> self-check: nginx -V"
mkdir -p /w/dist
"$stage/sbin/nginx" -V >"/w/dist/nginx-V-${ARCH}.txt" 2>&1
cat "/w/dist/nginx-V-${ARCH}.txt"
for mod in --with-http_v2_module --with-stream --with-http_realip_module; do
	if ! grep -q -- "$mod" "/w/dist/nginx-V-${ARCH}.txt"; then
		echo "build.sh: nginx -V does not mention ${mod}" >&2
		exit 5
	fi
done

name="nginx-${VERSION}-${BUILD}-linux-${ARCH}.tar.gz"
tar -C "$stage" -czf "/w/dist/$name" --owner=0 --group=0 --numeric-owner \
	sbin/nginx conf/nginx.conf conf/mime.types test.conf manifest.json
# One line per architecture: a local run builds both in the same directory and
# must end up with a checksum file that covers both.
(cd /w/dist && { grep -v "  ${name}\$" SHA256SUMS 2>/dev/null || true; sha256sum "$name"; } >SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS)
echo ">> artefact: /w/dist/$name"
ls -l "/w/dist/$name"
cat /w/dist/SHA256SUMS
