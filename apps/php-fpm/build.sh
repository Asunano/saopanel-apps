#!/bin/sh
# Build a PHP 8.3 FPM app package from a digest-pinned Alpine 3.20 rootfs.
#
# The package is not chrooted: the php-fpm executable is patched to use the
# bundled musl interpreter, and a small wrapper gives it the bundled library
# path. That keeps the systemd unit running as the host's `saopanel` account,
# which is also the account nginx workers use, so the shared Unix socket can
# be 0660 saopanel:saopanel without a UID translation layer.
set -eu

BUILD=${BUILD:-sao-r3}
ARCH=${TARGETARCH:-$(uname -m)}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc}

if [ ! -f /etc/alpine-release ]; then
	command -v docker >/dev/null || {
		echo "build.sh: docker is required outside Alpine" >&2
		exit 2
	}
	exec docker run --rm --platform "linux/${ARCH}" \
		-e BUILD="$BUILD" -e TARGETARCH="$ARCH" -e ALPINE_IMAGE="$ALPINE_IMAGE" \
		-v "$PWD:/w" -w /w "$ALPINE_IMAGE" /bin/sh ./apps/php-fpm/build.sh
fi

case "$ARCH" in
amd64) MUSL=ld-musl-x86_64.so.1 ;;
arm64) MUSL=ld-musl-aarch64.so.1 ;;
*)
	echo "build.sh: unsupported architecture $ARCH" >&2
	exit 2
	;;
esac

echo ">> Alpine $(cat /etc/alpine-release), PHP-FPM 8.3, ${ARCH}"
apk add --no-cache \
	php83 php83-fpm php83-opcache php83-curl php83-mbstring php83-xml \
	php83-sqlite3 php83-zip php83-gd php83-intl php83-mysqli \
	php83-pdo_mysql php83-sodium php83-session php83-ctype php83-iconv \
	php83-openssl php83-simplexml php83-dom php83-fileinfo php83-tokenizer >/dev/null

VERSION=$(php83 -r 'echo PHP_VERSION;')
case "$VERSION" in
8.3.*) ;;
*)
	echo "build.sh: expected PHP 8.3, got $VERSION" >&2
	exit 3
	;;
esac

for ext in mysqli pdo_mysql mbstring zip gd sodium curl xml intl session ctype \
	iconv openssl simplexml dom fileinfo tokenizer; do
	php83 -m | grep -qix "$ext" || {
		echo "build.sh: PHP extension $ext is missing" >&2
		exit 3
	}
done

# The build container needs the account only for php-fpm -t. The target host
# creates the same account in install.sh; nothing about it ships in the tar.
addgroup -S saopanel 2>/dev/null || true
adduser -S -D -H -G saopanel saopanel 2>/dev/null || true

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage="$work/stage"
mkdir -p "$stage/rootfs" "$stage/sbin" "$stage/etc/php83/conf.d" "$stage/etc/php83/php-fpm.d"

# The rootfs contains the musl loader, PHP libraries and extensions. It is a
# runtime payload, not a machine root: no package manager or shell is shipped.
mkdir -p "$stage/rootfs/lib" "$stage/rootfs/usr/lib"
cp -aL /lib/. "$stage/rootfs/lib/"
cp -aL /usr/lib/. "$stage/rootfs/usr/lib/"
mkdir -p "$stage/rootfs/usr/sbin" "$stage/rootfs/usr/bin"
cp -L /usr/sbin/php-fpm83 "$stage/rootfs/usr/sbin/php-fpm83"
cp -L /usr/bin/php83 "$stage/rootfs/usr/bin/php83"
cp -aL /usr/lib/php83/. "$stage/rootfs/usr/lib/php83/"
[ -x "$stage/rootfs/lib/$MUSL" ] || {
	echo "build.sh: bundled musl loader $MUSL is missing" >&2
	exit 3
}

# Configuration is generated here, not copied from the image, so every path
# is explicit and the package does not depend on Alpine's /etc layout.
cat >"$stage/etc/php83/php.ini" <<INI
[PHP]
expose_php = Off
memory_limit = 128M
upload_max_filesize = 16M
post_max_size = 16M
max_execution_time = 30
date.timezone = UTC
log_errors = On
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
sys_temp_dir = "/tmp"
session.save_path = "/tmp"
opcache.enable = 1
opcache.memory_consumption = 32
opcache.validate_timestamps = 1
INI

for ini in /etc/php83/conf.d/*.ini; do
	[ -f "$ini" ] || continue
	cp "$ini" "$stage/etc/php83/conf.d/"
done

cat >"$stage/sbin/php-fpm" <<'WRAP'
#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export LD_LIBRARY_PATH="$ROOT/rootfs/lib:$ROOT/rootfs/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PHPRC="$ROOT/etc/php83"
export PHP_INI_SCAN_DIR="$ROOT/etc/php83/conf.d"
exec "$ROOT/rootfs/lib/MUSL_LOADER" "$ROOT/rootfs/usr/sbin/php-fpm83" \
	-d "extension_dir=$ROOT/rootfs/usr/lib/php83/modules" "$@"
WRAP
sed -i "s|MUSL_LOADER|$MUSL|" "$stage/sbin/php-fpm"
chmod 0755 "$stage/sbin/php-fpm"

cat >"$stage/etc/php83/php-fpm.conf" <<'CONF'
[global]
error_log = /var/log/saopanel/php-fpm83-error.log
daemonize = no

[saopanel]
user = saopanel
group = saopanel
listen = /run/saopanel/php/php-fpm83.sock
listen.owner = saopanel
listen.group = saopanel
listen.mode = 0660
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 10s
pm.max_requests = 500
chdir = /
catch_workers_output = yes
clear_env = yes
security.limit_extensions = .php
php_admin_flag[log_errors] = on
CONF

cat >"$stage/manifest.json" <<JSON
{"id":"php-fpm","version":"${VERSION}","build":"${BUILD}","arch":"${ARCH}","runtime":"alpine-rootfs","extensions":["opcache","curl","mbstring","xml","sqlite3","zip","gd","intl","mysqli","pdo_mysql","sodium"]}
JSON

# The package's own config test runs exactly as the unit will: the wrapper,
# the bundled interpreter and the shared socket directory.
mkdir -p /var/lib/saopanel/apps/php-fpm
ln -sfn "$stage" /var/lib/saopanel/apps/php-fpm/current
mkdir -p /var/run/saopanel/php /var/log/saopanel
"$stage/sbin/php-fpm" -t -y "$stage/etc/php83/php-fpm.conf" >/dev/null || {
	echo "build.sh: bundled php-fpm rejected its configuration" >&2
	exit 3
}
rm -f /var/lib/saopanel/apps/php-fpm/current

name="php-fpm-${VERSION}-${BUILD}-linux-${ARCH}.tar.gz"
mkdir -p /w/dist
tar -C "$stage" -czf "/w/dist/$name" \
	sbin rootfs etc manifest.json
printf '%s\n' "$VERSION" >"/w/dist/php-fpm-version-${ARCH}.txt"
(cd /w/dist && { grep -v "  ${name}\$" SHA256SUMS 2>/dev/null || true; sha256sum "$name"; } >SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS)
echo ">> artefact: /w/dist/$name"
ls -lh "/w/dist/$name"
cat /w/dist/SHA256SUMS
