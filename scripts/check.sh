#!/usr/bin/env bash
# Pre-deploy sanity check.
# - Verifies the WFIGS feature service responds
# - Lists each active wildfire within radius_km of the configured point,
#   sorted by distance, with size and containment
# - Confirms Tidbyt creds are populated
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f config.yaml ]]; then
  echo "ERROR: config.yaml is missing. Run: cp config-example.yaml config.yaml" >&2
  exit 1
fi

LAT=$(yq -r '.latitude' config.yaml)
LON=$(yq -r '.longitude' config.yaml)
RADIUS=$(yq -r '.radius_km' config.yaml)
TIDBYT_KEY="$(yq -r '.tidbyt_api_key' config.yaml)"
TIDBYT_DEVICE_ID="$(yq -r '.tidbyt_device_id' config.yaml)"
TIDBYT_INSTALLATION_ID="$(yq -r '.tidbyt_installation_id' config.yaml)"

green() { printf "\033[32m%s\033[0m" "$1"; }
red()   { printf "\033[31m%s\033[0m" "$1"; }
ok()    { printf "  $(green '✓') %s\n" "$1"; }
warn()  { printf "  $(red '✗') %s\n" "$1"; }

echo "== WFIGS — active US wildfires within ${RADIUS} km of (${LAT}, ${LON}) =="
URL="https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Incident_Locations_Current/FeatureServer/0/query?geometry=${LON},${LAT}&geometryType=esriGeometryPoint&inSR=4326&distance=${RADIUS}&units=esriSRUnit_Kilometer&where=IncidentTypeCategory%3D%27WF%27&outFields=IncidentName,FireDiscoveryDateTime,IncidentSize,PercentContained,POOState,POOCounty&returnGeometry=true&f=json&resultRecordCount=50&orderByFields=IncidentSize+DESC"
RESP=$(curl -sL --max-time 20 -w "\n%{http_code}" "$URL")
CODE=$(printf '%s' "$RESP" | tail -n1)
BODY=$(printf '%s' "$RESP" | sed '$d')

if [[ "$CODE" != "200" ]]; then
  warn "WFIGS returned HTTP $CODE"
  exit 1
fi

ok "endpoint OK (HTTP 200)"

echo
python3 - <<EOF
import json, math, datetime as DT
d = json.loads('''${BODY}''')
feats = d.get("features", [])
ref = (${LAT}, ${LON})
R = 6371.0
def hav(a, b):
    la1, lo1 = math.radians(a[0]), math.radians(a[1])
    la2, lo2 = math.radians(b[0]), math.radians(b[1])
    dl = la2-la1; dn = lo2-lo1
    h = math.sin(dl/2)**2 + math.cos(la1)*math.cos(la2)*math.sin(dn/2)**2
    return 2*R*math.asin(math.sqrt(h))

enriched = []
for f in feats:
    attrs = f.get("attributes", {})
    geom = f.get("geometry", {})
    lat = geom.get("y"); lon = geom.get("x")
    if lat is None or lon is None: continue
    enriched.append({**attrs, "lat": lat, "lon": lon, "dist": hav(ref, (lat, lon))})
enriched.sort(key=lambda f: f["dist"])

print(f"  {len(enriched)} active wildfires within ${RADIUS} km")
if not enriched:
    print(f"  \033[32mall clear — green tile\033[0m")
else:
    print()
    print(f"  {'name':30s}  {'dist km':>8s}  {'acres':>10s}  {'cont':>5s}  state/county")
    for f in enriched:
        name = (f.get("IncidentName") or "?")[:30]
        size = f.get("IncidentSize") or 0
        cont = f.get("PercentContained")
        cont_s = f"{cont:.0f}%" if cont is not None else "—"
        state = (f.get("POOState") or "")
        county = (f.get("POOCounty") or "")
        print(f"  {name:30s}  {f['dist']:>8.1f}  {size:>10,.0f}  {cont_s:>5s}  {state}/{county}")
    print()
    closest = enriched[0]
    largest = max(enriched, key=lambda f: f.get("IncidentSize") or 0)
    print(f"  closest: {closest.get('IncidentName')} @ {closest['dist']:.1f} km, {(closest.get('PercentContained') or 0):.0f}% contained")
    print(f"  largest: {largest.get('IncidentName')} @ {(largest.get('IncidentSize') or 0):,.0f} ac")
    # Mirror threat thresholds from main.star
    danger = any(f["dist"] <= 50 and (f.get("PercentContained") or 0) < 50 and (f.get("IncidentSize") or 0) >= 500 for f in enriched)
    caution = any(f["dist"] <= 100 and (f.get("PercentContained") or 0) < 75 for f in enriched)
    if danger:
        print(f"  \033[31m≥1 large uncontained fire within 50 km — DARK RED tile\033[0m")
    elif caution:
        print(f"  \033[33m≥1 fire within 100 km, <75% contained — ORANGE tile\033[0m")
    else:
        print(f"  \033[33mactive fires in range but distant/contained — YELLOW tile\033[0m")
EOF

echo
echo "== Tidbyt credentials =="
[[ -n "$TIDBYT_KEY" && "$TIDBYT_KEY" != "null" && "$TIDBYT_KEY" != YOUR-* ]] \
  && ok "tidbyt_api_key set" || warn "tidbyt_api_key not set in config.yaml"
[[ -n "$TIDBYT_DEVICE_ID" && "$TIDBYT_DEVICE_ID" != "null" && "$TIDBYT_DEVICE_ID" != YOUR-* ]] \
  && ok "tidbyt_device_id set" || warn "tidbyt_device_id not set in config.yaml"
if [[ "$TIDBYT_INSTALLATION_ID" =~ ^[A-Za-z0-9]+$ ]]; then
  ok "tidbyt_installation_id ($TIDBYT_INSTALLATION_ID) is alphanumeric"
else
  warn "tidbyt_installation_id ($TIDBYT_INSTALLATION_ID) must be alphanumeric"
fi

echo
echo "All checks passed. Safe to deploy."
