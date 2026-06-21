#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f config.yaml ]]; then
  echo "ERROR: config.yaml is missing. Run: cp config-example.yaml config.yaml" >&2
  exit 1
fi

LAT=$(yq -r '.latitude' config.yaml)
LON=$(yq -r '.longitude' config.yaml)
RADIUS=$(yq -r '.radius_km' config.yaml)

PORT="${PIXLET_PORT:-8080}"
HOST="${PIXLET_HOST:-127.0.0.1}"
BROWSER_HOST="${PIXLET_BROWSER_HOST:-localhost}"

cat <<EOF

Pixlet serving on ${HOST}:${PORT}. Hot-reloads on main.star changes.

Open ONE of these URLs in your browser:

  Pre-filled preview (recommended):
    http://${BROWSER_HOST}:${PORT}/legacy?latitude=${LAT}&longitude=${LON}&radius_km=${RADIUS}

  Raw rendered frame as WebP:
    http://${BROWSER_HOST}:${PORT}/api/v1/preview.webp?latitude=${LAT}&longitude=${LON}&radius_km=${RADIUS}

  React SPA (schema form):
    http://${BROWSER_HOST}:${PORT}/

Ctrl-C to stop.

EOF

exec pixlet serve -i "${HOST}" -p "${PORT}" main.star
