#!/usr/bin/env bash
#
# apps/release.sh — turn built tarballs into a publishable nginx release.
#
#   dist/nginx-<ver>-<build>-linux-amd64.tar.gz
#   dist/nginx-<ver>-<build>-linux-arm64.tar.gz
#   dist/nginx-V-amd64.txt        `nginx -V` verbatim, from the binary itself
#   dist/nginx-V-arm64.txt
#   dist/SHA256SUMS               one line per tarball
#   dist/apps/nginx.yaml          the manifest, every field filled
#
# Usage:
#   APP_ORG=myorg apps/release.sh                  # build both arches, then render
#   APP_ORG=myorg apps/release.sh --from-existing  # never build; fail if a tarball is missing
#
# Inputs (environment):
#   APP_ORG     GitHub organisation/user that owns the apps repository. Required:
#               the manifest's URLs have to name somewhere the files really are.
#   APP_REPO    repository name, default saopanel-apps.
#   APP_VERSION default 1.31.9, BUILD default sao-r2 (must match build.sh).
#   ARCHES      default "amd64 arm64".
#   DL_BASE     optional CDN base (e.g. https://dl.example.com). When set, a
#               mirror is emitted for it; when empty, no mirror is invented.
#
# Why a script and not a YAML file with placeholders: a manifest's sha256 and
# size are properties of the bytes that were built. Anything that lets them be
# typed by hand lets a release ship a checksum that fails on the customer's
# machine — which is exactly what the panel's loader refuses.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

APP_VERSION=${APP_VERSION:-1.31.9}
BUILD=${BUILD:-sao-r2}
APP_REPO=${APP_REPO:-saopanel-apps}
ARCHES=${ARCHES:-"amd64 arm64"}
DL_BASE=${DL_BASE:-}
# URL_BASE replaces the GitHub release URL entirely: it exists for the install
# drill, where the tarballs are served by a local HTTP server and no release
# exists yet. A manifest rendered this way is for testing only, which is why the
# script says so on stdout.
URL_BASE=${URL_BASE:-}
TAG="nginx-v${APP_VERSION}-${BUILD}"
DIST=${DIST:-dist}

from_existing=0
allow_partial=0
for arg in "$@"; do
	case "$arg" in
	--from-existing) from_existing=1 ;;
	--allow-partial) allow_partial=1 ;;
	*) echo "release.sh: unknown argument $arg" >&2; exit 2 ;;
	esac
done

[ -n "${APP_ORG:-}" ] || {
	echo "release.sh: APP_ORG is required (the GitHub org that owns ${APP_REPO})" >&2
	exit 2
}

# A release is both architectures: a manifest that silently covers one of them
# is a machine that fails at install time, months after the tag was cut.
if [ "$allow_partial" -eq 0 ]; then
	for arch in amd64 arm64; do
		case " $ARCHES " in
		*" $arch "*) ;;
		*) echo "release.sh: ARCHES=${ARCHES} is missing ${arch}; pass --allow-partial for a local drill" >&2; exit 2 ;;
		esac
	done
fi

name_of() { echo "nginx-${APP_VERSION}-${BUILD}-linux-$1.tar.gz"; }
size_of() { wc -c <"$1" | tr -d ' '; }
sha_of() { sha256sum "$1" | cut -d' ' -f1; }

mkdir -p "$DIST"

# 1. Bytes. Either build them, or prove the ones on disk are the ones this
# configuration names — including the version inside the tarball.
if [ "$from_existing" -eq 0 ]; then
	for arch in $ARCHES; do
		echo ">> building ${arch}"
		TARGETARCH="$arch" sh apps/nginx/build.sh
	done
fi

for arch in $ARCHES; do
	f="$DIST/$(name_of "$arch")"
	[ -f "$f" ] || { echo "release.sh: ${f} is missing; run without --from-existing" >&2; exit 3; }
	[ -f "$DIST/nginx-V-${arch}.txt" ] || { echo "release.sh: ${DIST}/nginx-V-${arch}.txt is missing" >&2; exit 3; }
	tar tzf "$f" >/dev/null || { echo "release.sh: ${f} is not a readable tarball" >&2; exit 3; }
done

# 2. The manifest. Every URL is derived from the tag the files will be published
# under, so the manifest cannot promise a path the release does not have.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

: >"$work/artefacts.yaml"
for arch in $ARCHES; do
	f="$DIST/$(name_of "$arch")"
	if [ -n "$URL_BASE" ]; then
		url="${URL_BASE%/}/$(name_of "$arch")"
	else
		url="https://github.com/${APP_ORG}/${APP_REPO}/releases/download/${TAG}/$(name_of "$arch")"
	fi
	{
		echo "    - arch: ${arch}"
		echo "      url: ${url}"
		echo "      sha256: \"$(sha_of "$f")\""
		echo "      size: $(size_of "$f")"
	} >>"$work/artefacts.yaml"
done

# Mirrors are release directories. The gh-proxy one exists because GitHub
# releases are unreachable from mainland networks; a CDN is only listed when the
# operator actually has one. A locally served drill has no mirrors at all: it is
# one machine talking to itself.
: >"$work/mirrors.yaml"
if [ -z "$URL_BASE" ]; then
	echo "    - https://gh-proxy.com/https://github.com/${APP_ORG}/${APP_REPO}/releases/download/${TAG}/" >>"$work/mirrors.yaml"
	if [ -n "$DL_BASE" ]; then
		echo "    - ${DL_BASE%/}/apps/nginx/${APP_VERSION}-${BUILD}/" >>"$work/mirrors.yaml"
	fi
fi

out="$DIST/apps/nginx.yaml"
mkdir -p "$DIST/apps"
# The template's own commentary explains why the file looks the way it does, and
# belongs in the template, not in the artefact a panel reads. Everything before
# `id:` is dropped and a two-line provenance header is put in its place, so
# whoever finds this file on a server knows it is generated.
sed -n '/^id:/,$p' apps/nginx/manifest.yaml.tmpl >"$work/body.yaml"
{
	echo "# Generated by apps/release.sh from apps/nginx/manifest.yaml.tmpl."
	echo "# Do not edit: the next release replaces this file."
	sed -e "s|<version>|${APP_VERSION}|g" \
		-e "s|<build>|${BUILD}|g" \
		-e "s|<org>|${APP_ORG}|g" \
		-e "/^<artefacts>\$/r $work/artefacts.yaml" -e "/^<artefacts>\$/d" \
		-e "/^<mirrors>\$/r $work/mirrors.yaml" -e "/^<mirrors>\$/d" \
		"$work/body.yaml"
} >"$out"

# 3. Refusals. A release with a placeholder, a missing architecture or a
# checksum that does not match the tarball is not a release.
if [ ! -s "$work/mirrors.yaml" ]; then
	# A locally served drill has no mirrors at all; an empty list says so.
	sed -i 's/^  mirrors:$/  mirrors: []/' "$out"
fi
if grep -nE '<[a-z]+>' "$out"; then
	echo "release.sh: ${out} still contains a placeholder" >&2
	exit 4
fi
for arch in $ARCHES; do
	if ! grep -q -- "-linux-${arch}.tar.gz" "$out"; then
		echo "release.sh: ${out} does not mention ${arch}" >&2
		exit 4
	fi
done

# 4. Checksums over what is being published, verified before anyone downloads it.
(cd "$DIST" && sha256sum nginx-*-linux-*.tar.gz >SHA256SUMS)
(cd "$DIST" && sha256sum -c SHA256SUMS)

echo
echo ">> release ${TAG}"
ls -l "$DIST"/*.tar.gz "$DIST"/nginx-V-*.txt "$out" | awk '{printf "   %-58s %s\n", $9, $5}'
echo
cat "$DIST/SHA256SUMS"
echo
echo ">> manifest"
cat "$out"
