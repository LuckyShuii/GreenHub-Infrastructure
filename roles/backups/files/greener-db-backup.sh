#!/usr/bin/env bash
# Dump PostgreSQL, compress, encrypt, and report the result as Prometheus metrics.
#
# `pipefail` is not decoration here: in `pg_dump | gzip | gpg`, bash reports only the LAST
# command's status by default, so a pg_dump that dies mid-stream produces a perfectly valid
# .sql.gz.gpg holding half a database — and exits 0. That is the failure this whole script
# is shaped around, which is also why the size floor and the atomic rename exist.
set -euo pipefail

# Everything this script creates holds, or describes, the contents of the database: the dump
# itself, the temp file it is built in, the state file. gpg --output obeys the umask like any
# other program, and the inherited 022 left the dumps world-readable (0644) on the first
# production run — invisible while the directory is 0700, and wrong the moment a file is
# copied anywhere else. The one deliberate exception is the metrics file, chmod'd back to
# 0644 below because the exporter has to read it.
umask 077

usage() {
	echo "usage: $0 --dir DIR --prefix NAME --project NAME --service NAME \\" >&2
	echo "          --passphrase-file FILE --gnupg-home DIR --state FILE \\" >&2
	echo "          --metrics FILE --min-size BYTES" >&2
	exit 64
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dir) dest_dir="$2"; shift 2 ;;
		--prefix) prefix="$2"; shift 2 ;;
		--project) project="$2"; shift 2 ;;
		--service) service="$2"; shift 2 ;;
		--passphrase-file) passphrase_file="$2"; shift 2 ;;
		--gnupg-home) gnupg_home="$2"; shift 2 ;;
		--state) state_file="$2"; shift 2 ;;
		--metrics) metrics_file="$2"; shift 2 ;;
		--min-size) min_size="$2"; shift 2 ;;
		*) usage ;;
	esac
done

: "${dest_dir:?}" "${prefix:?}" "${project:?}" "${service:?}"
: "${passphrase_file:?}" "${gnupg_home:?}" "${state_file:?}" "${metrics_file:?}" "${min_size:?}"

started=$(date +%s)
dump_file=""

# --- Metrics ------------------------------------------------------------------------------
# Three of the four describe the last SUCCESSFUL dump and are read back from the state file;
# only the exit code describes the run that just happened. That split is what lets a failed
# run report its failure without erasing the evidence of when the last good backup was —
# which is precisely the value the alert rule reads.
write_metrics() {
	local rc="$1" tmp

	if [ -f "$state_file" ]; then
		# shellcheck disable=SC1090  # a plain KEY=value file this script wrote itself
		. "$state_file"
	fi

	tmp="$(mktemp "${metrics_file}.XXXXXX")"
	{
		echo '# HELP greener_backup_last_success_timestamp_seconds Unix time of the last dump that completed and passed its size check.'
		echo '# TYPE greener_backup_last_success_timestamp_seconds gauge'
		echo "greener_backup_last_success_timestamp_seconds ${last_success_ts:-0}"
		echo '# HELP greener_backup_last_duration_seconds Wall-clock seconds taken by that last successful dump.'
		echo '# TYPE greener_backup_last_duration_seconds gauge'
		echo "greener_backup_last_duration_seconds ${last_duration_seconds:-0}"
		echo '# HELP greener_backup_last_size_bytes Size on disk of that last successful dump, encrypted.'
		echo '# TYPE greener_backup_last_size_bytes gauge'
		echo "greener_backup_last_size_bytes ${last_size_bytes:-0}"
		echo '# HELP greener_backup_last_exit_code Exit code of the most recent run, successful or not. 0 is healthy.'
		echo '# TYPE greener_backup_last_exit_code gauge'
		echo "greener_backup_last_exit_code ${rc}"
	} >"$tmp"
	chmod 0644 "$tmp"
	mv "$tmp" "$metrics_file"
}

# Runs on every exit path, including `set -e` aborts. A half-written dump is deleted rather
# than left behind: the off-site sync copies whatever it finds in this directory, and a
# truncated file that reached Drive would look exactly like a good one.
on_exit() {
	local rc=$?
	if [ -n "$dump_file" ] && [ -f "$dump_file" ]; then
		rm -f "$dump_file"
	fi
	write_metrics "$rc"
	if [ "$rc" -ne 0 ]; then
		echo "backup FAILED (exit ${rc}) after $(( $(date +%s) - started ))s" >&2
	fi
	exit "$rc"
}
trap on_exit EXIT

# --- Locate the database ------------------------------------------------------------------
# By compose label, not by container name: names are derived from the project directory and
# change the day it moves.
container="$(docker ps --quiet --no-trunc \
	--filter "label=com.docker.compose.project=${project}" \
	--filter "label=com.docker.compose.service=${service}" | head -n1)"

if [ -z "$container" ]; then
	echo "no running container for ${project}/${service}" >&2
	exit 1
fi

install -d -m 0700 "$dest_dir"
stamp="$(date +%Y%m%d_%H%M%S)"
final="${dest_dir}/${prefix}_${stamp}.sql.gz.gpg"
# Built under a name the off-site sync ignores, then renamed into place once it is
# known-good, so a partial file never exists under the final name even for a moment.
dump_file="${final}.partial"

# --- Dump, compress, encrypt --------------------------------------------------------------
# pg_dump runs INSIDE the container: the database publishes no port, the host has no
# PostgreSQL client, and going through the container's own local socket means the client
# version always matches the server and no credential ever has to reach the host — the user
# and database names are read from the environment the container already has.
#
# --pinentry-mode loopback is mandatory, not belt-and-braces: without it gpg 2.x ignores
# --passphrase-file entirely and tries to open a pinentry prompt, which under a systemd
# service means it fails with no useful message.
export GNUPGHOME="$gnupg_home"
docker exec "$container" sh -c 'exec pg_dump --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
	| gzip -9 \
	| gpg --batch --yes --quiet --no-tty \
		--pinentry-mode loopback \
		--passphrase-file "$passphrase_file" \
		--symmetric --cipher-algo AES256 \
		--output "$dump_file"

# --- Prove it is a backup -----------------------------------------------------------------
size="$(stat -c %s "$dump_file")"
if [ "$size" -lt "$min_size" ]; then
	echo "dump is ${size} bytes, below the ${min_size} floor — refusing to keep it" >&2
	exit 1
fi

mv "$dump_file" "$final"
dump_file=""
duration=$(( $(date +%s) - started ))

tmp_state="$(mktemp "${state_file}.XXXXXX")"
{
	echo "last_success_ts=$(date +%s)"
	echo "last_size_bytes=${size}"
	echo "last_duration_seconds=${duration}"
} >"$tmp_state"
chmod 0600 "$tmp_state"
mv "$tmp_state" "$state_file"

echo "backup ok: ${final} (${size} bytes, ${duration}s)"
