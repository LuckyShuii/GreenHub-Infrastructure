#!/usr/bin/env bash
# Reclaim Docker disk space without ever touching a tagged image or a running container.
set -euo pipefail

usage() {
	echo "usage: $0 --builder-keep DURATION --warn-above MIB" >&2
	exit 64
}

while [ $# -gt 0 ]; do
	case "$1" in
		--builder-keep) builder_keep="$2"; shift 2 ;;
		--warn-above) warn_above_mib="$2"; shift 2 ;;
		*) usage ;;
	esac
done

: "${builder_keep:?}" "${warn_above_mib:?}"

# Priority prefixes are how a oneshot unit gets its level into the journal: journald reads
# `<4>` off the front of the line and records the entry as a warning, which is what makes
# `journalctl -p warning -u greener-docker-prune` and the Grafana level filter agree. Only
# under systemd — INVOCATION_ID is set per unit invocation — so a run by hand stays readable.
log() {
	local prio="$1"; shift
	if [ -n "${INVOCATION_ID:-}" ]; then
		printf '<%s>%s\n' "$prio" "$*"
	else
		printf '%s\n' "$*"
	fi
}

avail_bytes() {
	df --output=avail --block-size=1 / | tail -n 1 | tr -d ' '
}

started=$(date +%s)
before=$(avail_bytes)

# Runs on every exit path, `set -e` aborts included. A prune that dies mid-way leaves no
# trace of its own otherwise: the abort message belongs to whichever docker command failed,
# and the unit result alone does not say which step or how far in.
on_exit() {
	local rc=$?
	if [ "$rc" -ne 0 ]; then
		log 3 "prune FAILED (exit ${rc}) after $(( $(date +%s) - started ))s"
	fi
	exit "$rc"
}
trap on_exit EXIT

# `image prune` without -a: untagged images only, and never one a container still
# references — a stopped container is enough to protect its image.
docker image prune -f
docker builder prune -f --filter "until=${builder_keep}"

after=$(avail_bytes)
reclaimed_mib=$(((after - before) / 1048576))

# The journal is the report: Alloy ships it, so the run is queryable in Grafana.
#
# A large reclaim is not good news, it is a backlog that was already there: between two
# weekly runs nothing should accumulate gigabytes, so this fires when something orphaned an
# image outside the deploy path that normally prunes its own leftovers.
if [ "$reclaimed_mib" -gt "$warn_above_mib" ]; then
	log 4 "prune reclaimed ${reclaimed_mib} MiB, ABNORMAL (above ${warn_above_mib} MiB);" \
		"$((after / 1048576)) MiB now available on /"
else
	log 6 "prune reclaimed ${reclaimed_mib} MiB, $((after / 1048576)) MiB now available on /"
fi
