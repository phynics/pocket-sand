#!/bin/sh
# One action, one payload, against a live server.
#
#     scripts/probe-one.sh task.get '{"id":"..."}'
#
# Reads the server from $KANDEV (default http://kandev.local:38429).
set -eu
action="${1:?usage: probe-one.sh <action> [payload-json]}"
payload="${2:-{}}"
printf '[{"action":"%s","payload":%s}]' "$action" "$payload" \
	| swift run --package-path Packages/KandevKit kandev-probe "${KANDEV:-http://kandev.local:38429}"
