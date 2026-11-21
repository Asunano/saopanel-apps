#!/usr/bin/env bash
#
# apps/publish.sh — everything after the build that a machine without
# credentials cannot do for you.
#
#   REMOTE_URL=git@github.com:<org>/saopanel-apps.git apps/publish.sh
#
# It refuses to push a tree with uncommitted changes (the tag would not describe
# what is on disk), refuses to push a tag it cannot find, and then pushes the
# branch and the tag. The tag push is what triggers .github/workflows/build-app.yml:
# two architectures, then `apps/release.sh --from-existing` to render the manifest
# from the tarballs that were just built.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

REMOTE_URL=${REMOTE_URL:-}
BRANCH=${BRANCH:-main}
TAG=${TAG:-nginx-v${APP_VERSION:-1.31.9}-${BUILD:-sao-r1}}

[ -n "$REMOTE_URL" ] || {
	echo "publish.sh: set REMOTE_URL to the apps repository, e.g." >&2
	echo "  REMOTE_URL=git@github.com:myorg/saopanel-apps.git apps/publish.sh" >&2
	exit 2
}
[ -z "$(git status --porcelain)" ] || {
	echo "publish.sh: working tree is dirty; commit first so the tag describes what ships" >&2
	git status --short >&2
	exit 3
}
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || {
	echo "publish.sh: tag ${TAG} does not exist (git tag -a ${TAG} -m ...)" >&2
	exit 3
}

git remote get-url origin >/dev/null 2>&1 || git remote add origin "$REMOTE_URL"

echo ">> pushing ${BRANCH} and ${TAG} to ${REMOTE_URL}"
git push -u origin "HEAD:${BRANCH}"
git push origin "refs/tags/${TAG}"

echo
echo ">> workflows:"
echo "   $(dirname "$REMOTE_URL" | sed 's|git@github.com:|https://github.com/|;s|\.git$||')/actions"
