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

pixlet render main.star \
  "latitude=${LAT}" \
  "longitude=${LON}" \
  "radius_km=${RADIUS}" \
  -o out.webp
echo "Rendered: $PWD/out.webp"
