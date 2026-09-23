#!/usr/bin/env bash
# Docker health as a Prometheus metric, for the node exporter's textfile collector.
# cAdvisor's container_health_state is read ONCE when it discovers a container and never
# refreshed, so every redeployed container stays pinned at "starting" for ever.
set -euo pipefail

dest="${1:?missing output file}"
tmp="$(mktemp "${dest}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
	echo '# HELP greener_container_health 1 healthy, 0 unhealthy or still starting. No series when the container declares no healthcheck.'
	echo '# TYPE greener_container_health gauge'

	# Names and compose labels only ever hold [A-Za-z0-9_.-], so no escaping is needed.
	docker ps --quiet \
		| xargs --no-run-if-empty docker inspect --format \
			'{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{.Name}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
		| while IFS='|' read -r project service name status; do
			[ "$status" = none ] && continue
			name="${name#/}"
			[ -n "$service" ] || service="$name"
			[ "$status" = healthy ] && value=1 || value=0
			echo "greener_container_health{project=\"${project}\",service=\"${service}\",name=\"${name}\"} ${value}"
		done

	# Freshness, so a collector that died cannot leave the rules reading a frozen file.
	echo '# HELP greener_container_health_updated_seconds Unix time of the last successful collection.'
	echo '# TYPE greener_container_health_updated_seconds gauge'
	echo "greener_container_health_updated_seconds $(date +%s)"
} >"$tmp"

chmod 0644 "$tmp"
mv "$tmp" "$dest"
