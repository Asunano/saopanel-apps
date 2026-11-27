#!/bin/sh
# Build a MariaDB app package from a digest-pinned Alpine 3.20 rootfs.
#
# The server ships with the musl loader and the libraries it needs, so the host
# does not have to be Alpine, glibc-compatible, or have MariaDB installed. The
# unit runs as the host's `mysql` account (manifest runtime.user); the package
# never creates an account itself.
#
# The wrapper (sbin/mariadb) does two things the manifest language cannot: it
# initialises the data directory on first start (mariadb-install-db), and it
# execs the real server through the bundled loader. Both are the package's own
# business — the panel only ever passes a fixed argv.
set -eu

BUILD=${BUILD:-sao-r1}
ARCH=${TARGETARCH:-$(uname -m)}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc}

if [ ! -f /etc/alpine-release ]; then
	command -v docker >/dev/null || {
		echo "build.sh: docker is required outside Alpine" >&2
		exit 2
	}
	exec docker run --rm --platform "linux/${ARCH}" \
		-e BUILD="$BUILD" -e TARGETARCH="$ARCH" -e ALPINE_IMAGE="$ALPINE_IMAGE" \
		-v "$PWD:/w" -w /w "$ALPINE_IMAGE" /bin/sh ./apps/mariadb/build.sh
fi

case "$ARCH" in
amd64) MUSL=ld-musl-x86_64.so.1 ;;
arm64) MUSL=ld-musl-aarch64.so.1 ;;
*)
	echo "build.sh: unsupported architecture $ARCH" >&2
	exit 2
	;;
esac

echo ">> Alpine $(cat /etc/alpine-release), MariaDB, ${ARCH}"
apk add --no-cache mariadb mariadb-client >/dev/null

MARIADBD=$(command -v mariadbd || echo /usr/sbin/mariadbd)
INSTALL_DB=$(command -v mariadb-install-db || echo /usr/bin/mariadb-install-db)
CLIENT=$(command -v mariadb || echo /usr/bin/mariadb)
ADMIN=$(command -v mariadb-admin || echo /usr/bin/mariadb-admin)
for bin in "$MARIADBD" "$INSTALL_DB" "$CLIENT" "$ADMIN"; do
	[ -x "$bin" ] || {
		echo "build.sh: $bin is missing from the mariadb package" >&2
		exit 3
	}
done

VERSION=$("$MARIADBD" --version | sed -n 's/.*Ver \([0-9][0-9.]*\).*/\1/p' | head -1)
[ -n "$VERSION" ] || {
	echo "build.sh: cannot read the MariaDB version" >&2
	exit 3
}
echo ">> MariaDB ${VERSION}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# mktemp gives 0700 root: the smoke test below runs as the runtime account, which
# could not even reach the staged binary through that directory.
chmod 0755 "$work"
stage="$work/stage"
mkdir -p "$stage/rootfs/lib" "$stage/rootfs/usr/lib" "$stage/sbin"

# The runtime payload: loader, libraries, the server and its support files. No
# package manager and no shell are shipped; the wrapper uses the host's /bin/sh.
cp -aL /lib/. "$stage/rootfs/lib/"
cp -aL /usr/lib/. "$stage/rootfs/usr/lib/"
mkdir -p "$stage/rootfs/usr/libexec-mariadb" "$stage/rootfs/usr/bin" "$stage/rootfs/usr/share"
cp -L "$MARIADBD" "$stage/rootfs/usr/libexec-mariadb/mariadbd"
cp -L "$INSTALL_DB" "$stage/rootfs/usr/bin/mariadb-install-db"
for tool in mariadb mariadb-admin mariadb-dump; do
	src=$(command -v "$tool" || echo "/usr/bin/$tool")
	[ -x "$src" ] && cp -L "$src" "$stage/rootfs/usr/libexec-mariadb/$tool"
done
for helper in my_print_defaults resolveip perror; do
	src=$(command -v "$helper" || echo "/usr/bin/$helper")
	[ -x "$src" ] && cp -L "$src" "$stage/rootfs/usr/libexec-mariadb/$helper"
done

# Every name in usr/bin is a shim: it execs the real binary through the bundled
# loader with the bundled libraries. A musl binary run directly on a glibc host
# fails with "Not a valid dynamic program", and mariadb-install-db is a shell
# script that expects to find its server at <basedir>/bin/mariadbd.
for name in mariadbd mariadb mariadb-admin mariadb-dump my_print_defaults resolveip perror; do
	[ -f "$stage/rootfs/usr/libexec-mariadb/$name" ] || continue
	cat >"$stage/rootfs/usr/bin/$name" <<SHIM
#!/bin/sh
set -eu
ROOT=\$(CDPATH= cd -- "\$(dirname -- "\$0")/../.." && pwd)
LD_LIBRARY_PATH="\$ROOT/lib:\$ROOT/usr/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" \\
	exec "\$ROOT/lib/MUSL_NAME" "\$ROOT/usr/libexec-mariadb/$name" "\$@"
SHIM
	chmod 0755 "$stage/rootfs/usr/bin/$name"
	sed -i "s|MUSL_NAME|$MUSL|" "$stage/rootfs/usr/bin/$name"
done
cp -a /usr/share/mariadb "$stage/rootfs/usr/share/mariadb"
[ -x "$stage/rootfs/lib/$MUSL" ] || {
	echo "build.sh: bundled musl loader $MUSL is missing" >&2
	exit 3
}

cat >"$stage/sbin/mariadb" <<'WRAP'
#!/bin/sh
# Start MariaDB from this package: initialise the data directory on first run,
# then exec the server through the bundled loader. Arguments reach the server
# unchanged, so the manifest's test_args can ask for --version.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DATA=${SAOPANEL_MARIADB_DATA:-/opt/saopanel/data/mariadb}
RUN=${SAOPANEL_MARIADB_RUN:-/run/saopanel/mariadb}
PORT=${SAOPANEL_MARIADB_PORT:-3306}
export LD_LIBRARY_PATH="$ROOT/rootfs/lib:$ROOT/rootfs/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

case "${1:-}" in
--version | -V)
	exec "$ROOT/rootfs/usr/bin/mariadbd" --version
	;;
--test-config)
	# What ExecStartPre runs: the binaries load and the config parses, without
	# touching the data directory.
	"$ROOT/rootfs/usr/bin/mariadbd" --version >/dev/null
	mkdir -p "$RUN"
	exit 0
	;;
esac

mkdir -p "$DATA" "$RUN"
if [ ! -d "$DATA/mysql" ]; then
	echo "mariadb: initialising $DATA" >&2
	sh "$ROOT/rootfs/usr/bin/mariadb-install-db" \
		--basedir="$ROOT/rootfs/usr" --datadir="$DATA" \
		--auth-root-authentication-method=normal --skip-test-db >&2
fi

exec "$ROOT/rootfs/usr/bin/mariadbd" \
	--datadir="$DATA" \
	--basedir="$ROOT/rootfs/usr" \
	--plugin-dir="$ROOT/rootfs/usr/lib/mariadb/plugin" \
	--lc-messages-dir="$ROOT/rootfs/usr/share/mariadb" \
	--socket="$RUN/mysqld.sock" \
	--pid-file="$RUN/mysqld.pid" \
	--port="$PORT" \
	--bind-address=127.0.0.1 \
	--skip-name-resolve \
	--character-set-server=utf8mb4 \
	--collation-server=utf8mb4_general_ci \
	"$@"
WRAP
sed -i "s|MUSL_NAME|$MUSL|" "$stage/sbin/mariadb"
chmod 0755 "$stage/sbin/mariadb"

cat >"$stage/manifest.json" <<JSON
{"id":"mariadb","version":"${VERSION}","build":"${BUILD}","arch":"${ARCH}","runtime":"alpine-rootfs"}
JSON

# Smoke test in the builder, as the account the unit will use: a root-run
# mariadbd refuses to start, and a package that cannot initialise its own data
# directory has no business being published.
# The staged tree is read by the runtime account during the smoke test; the
# published tarball keeps its own modes.
chmod -R a+rX "$stage"

addgroup -S mysql 2>/dev/null || true
adduser -S -D -H -G mysql mysql 2>/dev/null || true
smoke="$work/smoke"
mkdir -p "$smoke/data" "$smoke/run"
chown -R mysql:mysql "$smoke"
sock="$smoke/run/mysqld.sock"

# wait_for_socket blocks until the socket exists, the server dies, or 300s pass.
# Under qemu the first start (initdb / install-db through the emulated server)
# takes minutes rather than seconds, so the deadline is generous and a dead
# server is reported with its own log instead of a bare timeout.
wait_for_socket() {
	sock=$1 server=$2 log=$3 i=0
	while [ ! -S "$sock" ]; do
		i=$((i + 1))
		if ! kill -0 "$server" 2>/dev/null; then
			echo "build.sh: the bundled server exited during startup:" >&2
			cat "$log" >&2
			exit 3
		fi
		if [ "$i" -ge 900 ]; then
			echo "build.sh: the bundled server did not open its socket in 900s:" >&2
			cat "$log" >&2
			kill "$server" 2>/dev/null || true
			exit 3
		fi
		if [ "$((i % 60))" -eq 0 ]; then
			echo "build.sh: still waiting for $sock (${i}s)" >&2
		fi
		sleep 1
	done
}

su mysql -s /bin/sh -c "SAOPANEL_MARIADB_DATA=$smoke/data SAOPANEL_MARIADB_RUN=$smoke/run SAOPANEL_MARIADB_PORT=33061 '$stage/sbin/mariadb' --test-config"
su mysql -s /bin/sh -c "SAOPANEL_MARIADB_DATA=$smoke/data SAOPANEL_MARIADB_RUN=$smoke/run SAOPANEL_MARIADB_PORT=33061 '$stage/sbin/mariadb'" >"$work/server.log" 2>&1 &
server=$!
wait_for_socket "$sock" "$server" "$work/server.log"
"$stage/rootfs/usr/bin/mariadb" --socket="$sock" -uroot -e 'SELECT 1' >/dev/null
kill "$server" 2>/dev/null || true
wait "$server" 2>/dev/null || true

name="mariadb-${VERSION}-${BUILD}-linux-${ARCH}.tar.gz"
mkdir -p /w/dist
tar -C "$stage" -czf "/w/dist/$name" sbin rootfs manifest.json
printf '%s\n' "$VERSION" >"/w/dist/mariadb-version-${ARCH}.txt"
(cd /w/dist && { grep -v "  ${name}\$" SHA256SUMS 2>/dev/null || true; sha256sum "$name"; } >SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS)
echo ">> artefact: /w/dist/$name"
ls -lh "/w/dist/$name"
cat /w/dist/SHA256SUMS
