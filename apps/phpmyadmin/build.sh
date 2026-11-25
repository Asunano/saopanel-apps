#!/bin/sh
# Build the phpMyAdmin Web App package. The payload is architecture
# independent; the artefact name carries the target architecture so the app
# store's manifest shape stays the same as a native package.
set -eu

VERSION=${VERSION:-5.2.2}
BUILD=${BUILD:-sao-r1}
ARCH=${TARGETARCH:-$(uname -m)}
DIST_DIR=${DIST_DIR:-/w/dist}
case "$ARCH" in
amd64 | arm64) ;;
*)
	echo "build.sh: unsupported architecture $ARCH" >&2
	exit 2
	;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
archive="$work/phpmyadmin.tar.gz"
base="https://files.phpmyadmin.net/phpMyAdmin/${VERSION}"
name="phpMyAdmin-${VERSION}-all-languages"

echo ">> phpMyAdmin ${VERSION}, ${ARCH}"
curl -fsSL --retry 3 -o "$archive" "$base/${name}.tar.gz"
if [ -n "${PHPMYADMIN_SHA256:-}" ]; then
	want=$PHPMYADMIN_SHA256
else
	curl -fsSL --retry 3 -o "$archive.sha256" "$base/${name}.tar.gz.sha256"
	want=$(cut -d' ' -f1 <"$archive.sha256")
fi
got=$(sha256sum "$archive" | cut -d' ' -f1)
[ -n "$want" ] || {
	echo "build.sh: no phpMyAdmin checksum" >&2
	exit 3
}
[ "$got" = "$want" ] || {
	echo "build.sh: checksum mismatch: $got, want $want" >&2
	exit 3
}

stage="$work/stage"
mkdir -p "$stage/payload"
tar -xzf "$archive" -C "$work"
src="$work/$name"
[ -d "$src" ] || {
	echo "build.sh: archive did not contain $name" >&2
	exit 3
}
cp -a "$src"/. "$stage/payload/"
# The setup wizard is an unauthenticated configuration surface. The panel
# renders config.inc.php itself, so it is never shipped either.
rm -rf "$stage/payload/setup" "$stage/payload/config.inc.php" "$stage/payload/.git"

cat >"$stage/manifest.json" <<JSON
{"id":"phpmyadmin","name":"phpMyAdmin","version":"${VERSION}","build":"${BUILD}","arch":"${ARCH}","kind":"webapp","php":"8.3"}
JSON

out="phpmyadmin-${VERSION}-${BUILD}-linux-${ARCH}.tar.gz"
mkdir -p "$DIST_DIR"
tar -C "$stage" -czf "$DIST_DIR/$out" payload manifest.json
printf '%s\n' "$VERSION" >"$DIST_DIR/phpmyadmin-version-${ARCH}.txt"
(cd "$DIST_DIR" && { grep -v "  ${out}\$" SHA256SUMS 2>/dev/null || true; sha256sum "$out"; } >SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS)
echo ">> artefact: $DIST_DIR/$out"
ls -lh "$DIST_DIR/$out"

