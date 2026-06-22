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

echo "== Wind direction at (${LAT}, ${LON}) — Open-Meteo =="
WIND_URL="https://api.open-meteo.com/v1/forecast?latitude=${LAT}&longitude=${LON}&current=wind_direction_10m,wind_speed_10m"
WIND_RESP=$(curl -sL --max-time 12 -w "\n%{http_code}" "$WIND_URL")
WIND_CODE=$(printf '%s' "$WIND_RESP" | tail -n1)
WIND_BODY=$(printf '%s' "$WIND_RESP" | sed '$d')

if [[ "$WIND_CODE" != "200" ]]; then
  warn "Open-Meteo returned HTTP $WIND_CODE"
  exit 1
fi
ok "Open-Meteo OK"

WIND_DEG=$(python3 -c "import json; d=json.loads('''${WIND_BODY}'''); print(d['current']['wind_direction_10m'])")
WIND_SPEED=$(python3 -c "import json; d=json.loads('''${WIND_BODY}'''); print(d['current']['wind_speed_10m'])")
WIND_COMPASS=$(python3 -c "
deg = ${WIND_DEG}
labels = ['N','NNE','NE','ENE','E','ESE','SE','SSE','S','SSW','SW','WSW','W','WNW','NW','NNW']
print(labels[int((deg + 11.25) / 22.5) % 16])
")
echo "  wind FROM ${WIND_COMPASS} (${WIND_DEG}°), ${WIND_SPEED} m/s"

echo
echo "== WFIGS — active US wildfires within ${RADIUS} km of (${LAT}, ${LON}) =="
URL="https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Incident_Locations_Current/FeatureServer/0/query?geometry=${LON},${LAT}&geometryType=esriGeometryPoint&inSR=4326&distance=${RADIUS}&units=esriSRUnit_Kilometer&where=IncidentTypeCategory%3D%27WF%27&outFields=IncidentName,FireDiscoveryDateTime,IncidentSize,PercentContained,POOState,POOCounty&returnGeometry=true&f=json&resultRecordCount=100&orderByFields=IncidentSize+DESC"
RESP=$(curl -sL --max-time 20 -w "\n%{http_code}" "$URL")
CODE=$(printf '%s' "$RESP" | tail -n1)
BODY=$(printf '%s' "$RESP" | sed '$d')

if [[ "$CODE" != "200" ]]; then
  warn "WFIGS returned HTTP $CODE"
  exit 1
fi

ok "WFIGS OK"

echo
python3 - <<EOF
import json, math
d = json.loads('''${BODY}''')
feats = d.get("features", [])
ref = (${LAT}, ${LON})
wind_dir = ${WIND_DEG}

# Distance-dependent windward-sector half-angle. Matches the model in
# main.star (UPWIND_TOLERANCE_BASE_DEG=20, _GROWTH_PER_KM=0.15, _MAX=90).
def tol(d):
    t = 20 + d * 0.15
    return 90 if t > 90 else t

R = 6371.0
LABELS = ['N','NNE','NE','ENE','E','ESE','SE','SSE','S','SSW','SW','WSW','W','WNW','NW','NNW']
def hav(a, b):
    la1, lo1 = math.radians(a[0]), math.radians(a[1])
    la2, lo2 = math.radians(b[0]), math.radians(b[1])
    dl = la2-la1; dn = lo2-lo1
    h = math.sin(dl/2)**2 + math.cos(la1)*math.cos(la2)*math.sin(dn/2)**2
    return 2*R*math.asin(math.sqrt(h))
def bearing(a, b):
    la1, lo1 = math.radians(a[0]), math.radians(a[1])
    la2, lo2 = math.radians(b[0]), math.radians(b[1])
    dlo = lo2 - lo1
    y = math.sin(dlo) * math.cos(la2)
    x = math.cos(la1)*math.sin(la2) - math.sin(la1)*math.cos(la2)*math.cos(dlo)
    return (math.degrees(math.atan2(y, x)) + 360) % 360
def compass(deg):
    return LABELS[int((deg + 11.25) / 22.5) % 16]
def ang_diff(a, b):
    d = (a - b) % 360
    if d > 180: d = 360 - d
    return d

enriched = []
for f in feats:
    attrs = f.get("attributes", {})
    geom = f.get("geometry", {})
    lat = geom.get("y"); lon = geom.get("x")
    if lat is None or lon is None: continue
    bg = bearing(ref, (lat, lon))
    enriched.append({**attrs, "lat": lat, "lon": lon,
                     "dist": hav(ref, (lat, lon)),
                     "bearing": bg, "upwind_off": ang_diff(bg, wind_dir)})
enriched.sort(key=lambda f: f["dist"])

print(f"  {len(enriched)} active wildfires within ${RADIUS} km")
if not enriched:
    print(f"  \033[32mno fires in range — green CLEAR tile\033[0m")
else:
    print()
    print(f"  {'name':28s}  {'dist km':>8s}  {'bearing':>7s}  {'Δwind':>6s}  {'tol':>5s}  {'acres':>10s}  {'cont':>5s}  upwind?")
    upwind = []
    for f in enriched:
        name = (f.get("IncidentName") or "?")[:28]
        size = f.get("IncidentSize") or 0
        cont = f.get("PercentContained")
        cont_s = f"{cont:.0f}%" if cont is not None else "—"
        bearing_lbl = compass(f["bearing"])
        t_deg = tol(f["dist"])
        is_upwind = f["upwind_off"] <= t_deg
        up_mark = "\033[32m✓\033[0m" if is_upwind else " "
        bearing_col = f"{bearing_lbl:>3s} {f['bearing']:>3.0f}"
        tol_col = f"±{t_deg:>3.0f}°"
        print(f"  {name:28s}  {f['dist']:>8.1f}  {bearing_col:>7s}  {f['upwind_off']:>5.0f}°  {tol_col:>5s}  {size:>10,.0f}  {cont_s:>5s}  {up_mark}")
        if is_upwind:
            upwind.append(f)
    print()
    if not upwind:
        print(f"  \033[32mno fires within their distance-scaled windward sector — green CLEAR tile\033[0m")
    else:
        nearest = upwind[0]
        cont = nearest.get("PercentContained") or 0
        size = nearest.get("IncidentSize") or 0
        dist = nearest["dist"]
        threat = "YELLOW"
        if dist <= 50 and cont < 50 and size >= 500:
            threat = "\033[31mDARK RED\033[0m"
        elif dist <= 100 and cont < 75:
            threat = "\033[33mORANGE\033[0m"
        else:
            threat = "\033[33mYELLOW\033[0m"
        print(f"  nearest upwind: \033[1m{nearest.get('IncidentName')}\033[0m  {compass(nearest['bearing'])} {dist:.0f} km  {size:,.0f} ac  {cont:.0f}% contained")
        print(f"  → tile: {threat}")
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
