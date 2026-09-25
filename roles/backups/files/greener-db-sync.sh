#!/usr/bin/env bash
# Replicate the encrypted dumps to Google Drive, verify them, and report as Prometheus metrics.
#
# The one decision worth reading before changing anything here: this uses `rclone copy`, NEVER
# `rclone sync`. Local retention is 7 days, the Drive window is 30 — a `sync` would mirror the
# local rotation's deletions onto Drive every run and collapse the off-site history back to 7
# days, quietly undoing the entire point of keeping a longer one. Pruning Drive is a separate,
# age-based pass at the bottom.
set -euo pipefail

usage() {
	echo "usage: $0 --dir DIR --config FILE --remote REMOTE:PATH --state FILE \\" >&2
	echo "          --metrics FILE --retention-days N [--retries N] [--umask MASK]" >&2
	exit 64
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dir) src_dir="$2"; shift 2 ;;
		--config) config="$2"; shift 2 ;;
		--remote) remote="$2"; shift 2 ;;
		--state) state_file="$2"; shift 2 ;;
		--metrics) metrics_file="$2"; shift 2 ;;
		--retention-days) retention_days="$2"; shift 2 ;;
		--retries) retries="$2"; shift 2 ;;
		--umask) file_umask="$2"; shift 2 ;;
		*) usage ;;
	esac
done

: "${src_dir:?}" "${config:?}" "${remote:?}" "${state_file:?}" "${metrics_file:?}"
: "${retention_days:?}"
umask "${file_umask:-027}"

started=$(date +%s)
rc_bin=(rclone --config "$config" --retries "${retries:-3}" --log-level NOTICE)

# Only the dumps. A .partial from a dump that was killed outright must never reach Drive: it
# is a truncated file that looks exactly like a good one once it is off this host.
include=(--include "*.sql.gz.gpg")

remote_count() {
	"${rc_bin[@]}" size --json "$remote" 2>/dev/null \
		| sed -n 's/.*"count":[[:space:]]*\([0-9]*\).*/\1/p' | head -n1
}
remote_bytes() {
	"${rc_bin[@]}" size --json "$remote" 2>/dev/null \
		| sed -n 's/.*"bytes":[[:space:]]*\([0-9]*\).*/\1/p' | head -n1
}

# Same split as the dump job: three gauges describe the last SUCCESSFUL sync and are read back
# from the state file, one describes the run that just happened. A failed run must report its
# failure without erasing when the last good replication was — that timestamp is what the
# staleness alert reads, and it is the only thing standing between a dead sync and a silent
# "the VPS is the only copy again".
write_metrics() {
	local rc="$1" tmp

	if [ -f "$state_file" ]; then
		# shellcheck disable=SC1090  # a plain KEY=value file this script wrote itself
		. "$state_file"
	fi

	tmp="$(mktemp "${metrics_file}.XXXXXX")"
	{
		echo '# HELP greener_backup_sync_last_success_timestamp_seconds Unix time of the last replication that copied and verified cleanly.'
		echo '# TYPE greener_backup_sync_last_success_timestamp_seconds gauge'
		echo "greener_backup_sync_last_success_timestamp_seconds ${sync_last_success_ts:-0}"
		echo '# HELP greener_backup_sync_last_duration_seconds Wall-clock seconds taken by that last successful replication.'
		echo '# TYPE greener_backup_sync_last_duration_seconds gauge'
		echo "greener_backup_sync_last_duration_seconds ${sync_last_duration_seconds:-0}"
		echo '# HELP greener_backup_sync_files_transferred Dumps uploaded by that last successful replication.'
		echo '# TYPE greener_backup_sync_files_transferred gauge'
		echo "greener_backup_sync_files_transferred ${sync_last_transferred:-0}"
		echo '# HELP greener_backup_sync_last_exit_code Exit code of the most recent run, successful or not. 0 is healthy.'
		echo '# TYPE greener_backup_sync_last_exit_code gauge'
		echo "greener_backup_sync_last_exit_code ${rc}"
		echo '# HELP greener_backup_sync_remote_files Dumps currently held off-site.'
		echo '# TYPE greener_backup_sync_remote_files gauge'
		echo "greener_backup_sync_remote_files ${sync_remote_files:-0}"
		echo '# HELP greener_backup_sync_remote_bytes Bytes currently held off-site.'
		echo '# TYPE greener_backup_sync_remote_bytes gauge'
		echo "greener_backup_sync_remote_bytes ${sync_remote_bytes:-0}"
	} >"$tmp"
	chmod 0644 "$tmp"
	mv "$tmp" "$metrics_file"
}

on_exit() {
	local rc=$?
	write_metrics "$rc"
	if [ "$rc" -ne 0 ]; then
		echo "sync FAILED (exit ${rc}) after $(( $(date +%s) - started ))s" >&2
	fi
	exit "$rc"
}
trap on_exit EXIT

if [ ! -d "$src_dir" ]; then
	echo "backup directory ${src_dir} does not exist" >&2
	exit 1
fi

before="$(remote_count)"
before="${before:-0}"

# --checksum, not the default size+mtime: Drive rewrites modification times on upload, so a
# comparison that trusts mtime re-uploads files that are already there, every single run.
"${rc_bin[@]}" copy "$src_dir" "$remote" "${include[@]}" --checksum

# The AC's "checksum validé après transfert", done by rclone rather than by hand: Drive
# publishes an MD5 per file, so this compares real hashes on both sides. --one-way because
# the remote legitimately holds more than the source — that is the whole point of a 30-day
# window over a 7-day one.
"${rc_bin[@]}" check "$src_dir" "$remote" "${include[@]}" --one-way

after="$(remote_count)"
after="${after:-0}"
bytes="$(remote_bytes)"
bytes="${bytes:-0}"
transferred=$(( after - before ))
# A negative difference means the retention pass of a previous run removed more than this one
# uploaded. Reporting it as a negative "files transferred" would be nonsense.
if [ "$transferred" -lt 0 ]; then
	transferred=0
fi
duration=$(( $(date +%s) - started ))

tmp_state="$(mktemp "${state_file}.XXXXXX")"
{
	echo "sync_last_success_ts=$(date +%s)"
	echo "sync_last_duration_seconds=${duration}"
	echo "sync_last_transferred=${transferred}"
	echo "sync_remote_files=${after}"
	echo "sync_remote_bytes=${bytes}"
} >"$tmp_state"
chmod 0600 "$tmp_state"
mv "$tmp_state" "$state_file"

echo "sync ok: ${transferred} uploaded, ${after} dumps off-site (${bytes} bytes, ${duration}s)"

# --- Drive retention ------------------------------------------------------------------------
# Deliberately last, and deliberately age-based rather than a mirror of the local rotation.
# 30 days off-site against 7 on disk is the whole reason `copy` is used above: a corruption
# noticed after a fortnight is only recoverable if the two copies do not forget together.
"${rc_bin[@]}" delete "$remote" "${include[@]}" --min-age "${retention_days}d" \
	|| { echo "drive retention pass failed — the upload itself is fine" >&2; exit 1; }
