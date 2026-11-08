#!/bin/bash
# Build the reusable 'claude-base' Incus image from Debian 13 cloud.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

IMAGE_ALIAS=${CB_IMAGE:-claude-base}
SOURCE=${CB_SOURCE_IMAGE:-images:debian/13/cloud}
BUILD=cb-base-build

incus info >/dev/null 2>&1 || { echo "Cannot talk to incus. Log out and back in so your session has the incus-admin group (or use ./claude-box setup, which re-runs via sudo -g)"; exit 1; }

incus delete -f "$BUILD" >/dev/null 2>&1 || true
echo ">> Launching $SOURCE as $BUILD"
incus launch "$SOURCE" "$BUILD" -p default -p claude-dev

for _ in $(seq 60); do incus exec "$BUILD" -- true >/dev/null 2>&1 && break; sleep 1; done

incus file push base/provision.sh "$BUILD/root/provision.sh" --mode 0755
incus exec "$BUILD" \
  --env GIT_NAME="$(git config --global user.name 2>/dev/null || true)" \
  --env GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)" \
  -- /root/provision.sh
incus exec "$BUILD" -- rm -f /root/provision.sh

echo ">> Publishing image $IMAGE_ALIAS"
incus stop "$BUILD"
incus image delete "$IMAGE_ALIAS" >/dev/null 2>&1 || true
incus publish "$BUILD" --alias "$IMAGE_ALIAS" description="Claude Code dev box (Debian 13, Docker, Node, build tools)"
incus delete "$BUILD"
echo ">> Done: image '$IMAGE_ALIAS'"
