#!/usr/bin/env bash
# Reclaim Docker disk space without ever touching a tagged image or a running container.
set -euo pipefail

while [ $# -gt 0 ]; do
	case "$1" in
		--builder-keep) builder_keep="$2"; shift 2 ;;
		*) echo "usage: $0 --builder-keep DURATION" >&2; exit 64 ;;
	esac
done

: "${builder_keep:?}"

avail_bytes() {
	df --output=avail --block-size=1 / | tail -n 1 | tr -d ' '
}

before=$(avail_bytes)

# `image prune` without -a: untagged images only, and never one a container still
# references — a stopped container is enough to protect its image.
docker image prune -f
docker builder prune -f --filter "until=${builder_keep}"

after=$(avail_bytes)

# The journal is the report: Alloy ships it, so the run is queryable in Grafana.
printf 'reclaimed %d MiB, %d MiB now available on /\n' \
	"$(((after - before) / 1048576))" "$((after / 1048576))"
