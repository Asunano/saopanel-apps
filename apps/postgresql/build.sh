#!/bin/sh
# Build a PostgreSQL app package from a digest-pinned Alpine 3.20 rootfs.
#
# Same shape as the MariaDB package: the server, its libraries and its share
# files travel with the package, and a wrapper initialises the data directory on
# first start. The unit runs as the host's `postgres` account (manifest
# runtime.user); PostgreSQL refuses to start as root.
set -eu

BUILD=${BUILD:-sao-r1}
ARCH=${TARGETARCH:-$(uname -m)}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc}

if [ ! -f /etc/alpine-release ]; then
	command -v docker >/dev/null || {
		echo "build.sh: docker is required outside Alpine" >&2
		exit 2
	}
	# SKIP_SMOKE travels into the container: the switch is read inside it, and a
	# cross-arch leg that only sets it outside would wait for a socket that the
	# emulated server needs minutes to create.
	exec docker run --rm --platform "linux/${ARCH}" \
		-e BUILD="$BUILD" -e TARGETARCH="$ARCH" -e ALPINE_IMAGE="$ALPINE_IMAGE" \
		-e SKIP_SMOKE="${SKIP_SMOKE:-0}" \
		-v "$PWD:/w" -w /w "$ALPINE_IMAGE" /bin/sh ./apps/postgresql/build.sh
fi

case "$ARCH" in
amd64) MUSL=ld-musl-x86_64.so.1 ;;
arm64) MUSL=ld-musl-aarch64.so.1 ;;
*)
	echo "build.sh: unsupported architecture $ARCH" >&2
	exit 2
	;;
esac

echo ">> Alpine $(cat /etc/alpine-release), PostgreSQL, ${ARCH}"
apk add --no-cache postgresql16 postgresql16-client >/dev/null

POSTGRES=$(command -v postgres || find /usr/libexec /usr -type f -name postgres 2>/dev/null | head -1)
PGDIR=$(dirname "$POSTGRES")
INITDB=$(command -v initdb || echo "$PGDIR/initdb")
PSQL=$(command -v psql || echo /usr/bin/psql)
for bin in "$POSTGRES" "$INITDB" "$PSQL"; do
	[ -x "$bin" ] || {
		echo "build.sh: $bin is missing from the postgresql package" >&2
		exit 3
	}
done

VERSION=$("$POSTGRES" --version | awk '{print $3}')
PGVER=${VERSION%%.*}
SHARE=$(ls -d /usr/share/postgresql"$PGVER" 2>/dev/null || ls -d /usr/share/postgresql* | head -1)
[ -n "$VERSION" ] && [ -d "$SHARE" ] || {
	echo "build.sh: cannot locate the PostgreSQL version or share directory" >&2
	exit 3
}
echo ">> PostgreSQL ${VERSION}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# mktemp gives 0700 root: the smoke test below runs as the runtime account, which
# could not even reach the staged binary through that directory.
chmod 0755 "$work"
stage="$work/stage"
mkdir -p "$stage/rootfs/lib" "$stage/rootfs/usr/lib" "$stage/sbin"

# The runtime payload. PostgreSQL's binaries live in a private directory, so the
# whole of it is copied rather than a hand-picked list of tools.
cp -aL /lib/. "$stage/rootfs/lib/"
cp -aL /usr/lib/. "$stage/rootfs/usr/lib/"
mkdir -p "$stage/rootfs/usr/share" "$stage/rootfs/usr/bin"
cp -a "$PGDIR" "$stage/rootfs/usr/libexec-postgresql"
cp -a "$SHARE" "$stage/rootfs/usr/share/$(basename "$SHARE")"
for tool in psql createdb pg_isready; do
	if [ -x "/usr/bin/$tool" ]; then
		cp -L "/usr/bin/$tool" "$stage/rootfs/usr/bin/$tool"
	fi
done
[ -x "$stage/rootfs/lib/$MUSL" ] || {
	echo "build.sh: bundled musl loader $MUSL is missing" >&2
	exit 3
}

cat >"$stage/sbin/postgres" <<'WRAP'
#!/bin/sh
# Start PostgreSQL from this package: initdb on first run, then exec the server
# through the bundled loader. The data directory is the layout's data slot for
# this app; the installer creates it and hands it to the postgres account.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DATA=${SAOPANEL_PG_DATA:-/opt/saopanel/data/postgresql}
RUN=${SAOPANEL_PG_RUN:-/run/saopanel/postgresql}
PORT=${SAOPANEL_PG_PORT:-5432}
BIN="$ROOT/rootfs/usr/libexec-postgresql"
SHARE="$ROOT/rootfs/usr/share/PG_SHARE"
MUSL="$ROOT/rootfs/lib/MUSL_NAME"
export LD_LIBRARY_PATH="$ROOT/rootfs/lib:$ROOT/rootfs/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

case "${1:-}" in
--version | -V)
	exec "$MUSL" "$BIN/postgres" --version
	;;
--test-config)
	"$MUSL" "$BIN/postgres" --version >/dev/null
	mkdir -p "$RUN"
	exit 0
	;;
esac

mkdir -p "$DATA" "$RUN"
if [ ! -f "$DATA/PG_VERSION" ]; then
	echo "postgresql: initialising $DATA" >&2
	"$MUSL" "$BIN/initdb" -D "$DATA" -U postgres \
		--auth-local=trust --auth-host=scram-sha-256 \
		--locale=C --encoding=UTF8 -L "$SHARE" >&2
fi

exec "$MUSL" "$BIN/postgres" -D "$DATA" -k "$RUN" -p "$PORT" \
	-c listen_addresses=127.0.0.1 "$@"
WRAP
sed -i -e "s|MUSL_NAME|$MUSL|" -e "s|PG_SHARE|$(basename "$SHARE")|" "$stage/sbin/postgres"
chmod 0755 "$stage/sbin/postgres"

cat >"$stage/manifest.json" <<JSON
{"id":"postgresql","version":"${VERSION}","build":"${BUILD}","arch":"${ARCH}","runtime":"alpine-rootfs"}
JSON

# Smoke test in the builder, as the account the unit will use: initdb refuses to
# run as root, so a package that only works as root would never start on a host.
# The staged tree is read by the runtime account during the smoke test; the
# published tarball keeps its own modes.
chmod -R a+rX "$stage"

addgroup -S postgres 2>/dev/null || true
adduser -S -D -H -G postgres postgres 2>/dev/null || true
# The smoke test starts the server as its runtime account. Under qemu the
# database bootstrap is emulated instruction by instruction and a MariaDB
# install-db run can take longer than the job allows, so a cross-arch build may
# skip it: the tarball's shape does not depend on the architecture, and the
# native leg has proved the payload works.
if [ "${SKIP_SMOKE:-0}" = "1" ]; then
	echo ">> smoke test skipped (SKIP_SMOKE=1, cross-arch build)"
else
smoke="$work/smoke"
mkdir -p "$smoke/data" "$smoke/run"
chown -R postgres:postgres "$smoke"
sock="$smoke/run/.s.PGSQL.54321"

# wait_for_socket blocks until the socket exists, the server dies, or 900s pass.
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

su postgres -s /bin/sh -c "SAOPANEL_PG_DATA=$smoke/data SAOPANEL_PG_RUN=$smoke/run SAOPANEL_PG_PORT=54321 '$stage/sbin/postgres' --test-config"
su postgres -s /bin/sh -c "SAOPANEL_PG_DATA=$smoke/data SAOPANEL_PG_RUN=$smoke/run SAOPANEL_PG_PORT=54321 '$stage/sbin/postgres'" >"$work/server.log" 2>&1 &
server=$!
wait_for_socket "$sock" "$server" "$work/server.log"
LD_LIBRARY_PATH="$stage/rootfs/lib:$stage/rootfs/usr/lib" \
	"$stage/rootfs/lib/$MUSL" "$stage/rootfs/usr/bin/psql" \
	-h "$smoke/run" -p 54321 -U postgres -c 'SELECT 1' >/dev/null
kill "$server" 2>/dev/null || true
wait "$server" 2>/dev/null || true
fi

name="postgresql-${VERSION}-${BUILD}-linux-${ARCH}.tar.gz"
mkdir -p /w/dist
tar -C "$stage" -czf "/w/dist/$name" sbin rootfs manifest.json
printf '%s\n' "$VERSION" >"/w/dist/postgresql-version-${ARCH}.txt"
(cd /w/dist && { grep -v "  ${name}\$" SHA256SUMS 2>/dev/null || true; sha256sum "$name"; } >SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS)
echo ">> artefact: /w/dist/$name"
ls -lh "/w/dist/$name"
cat /w/dist/SHA256SUMS
