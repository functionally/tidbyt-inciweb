"""Wildfire incidents near a configured location, for Tidbyt.

Sources active US wildfire incidents from NIFC's WFIGS_Incident_Locations_Current
ArcGIS feature service. The legacy InciWeb API the project is named after went
404 — WFIGS is the authoritative replacement.

See ./design-notes.md for layout choices, threat-level thresholds, and the
ArcGIS field map.
"""

load("render.star", "render")
load("http.star", "http")
load("encoding/json.star", "json")
load("schema.star", "schema")
load("math.star", "math")

# NIFC WFIGS — active US wildfire incidents. ArcGIS feature service.
WFIGS_URL = (
    "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/" +
    "WFIGS_Incident_Locations_Current/FeatureServer/0/query"
)
FETCH_TTL_S = 600  # 10 min — WFIGS refreshes every few minutes during active incidents

# Threat thresholds. Hardcoded; documented in design-notes.md.
DANGER_DISTANCE_KM = 50      # close enough to consider evacuation routes
CAUTION_DISTANCE_KM = 100    # close enough for smoke + ash awareness
LARGE_FIRE_ACRES = 500       # "large" for threat-color escalation

# AQI-style palette, matches the sibling AQ / Tor apps.
GREEN_BG = "#00E400"
YELLOW_BG = "#FFFF00"
ORANGE_BG = "#FF7E00"
DARK_RED_BG = "#7E0023"
GREEN_DOT = "#00C800"
YELLOW_DOT = "#FFEE00"
ORANGE_DOT = "#FF7E00"
RED_DOT = "#FF0000"
FG_BLACK = "#000000"
FG_WHITE = "#FFFFFF"

# Dark-navy accent (same constant used in the Tor relay app for the family
# label). Only the B channel — maximally distinct from the warm category
# backgrounds (G / Y / O / DR).
LABEL_COLOR = "#000080"

def fetch_fires(lat, lon, radius_km):
    """Fetch active US wildfires within radius_km of (lat, lon).
    Returns a list of WFIGS feature dicts, or None on transport error."""
    if lat == None or lon == None:
        return None
    params = (
        "geometry=" + str(lon) + "," + str(lat) +
        "&geometryType=esriGeometryPoint" +
        "&inSR=4326" +
        "&distance=" + str(radius_km) +
        "&units=esriSRUnit_Kilometer" +
        "&where=IncidentTypeCategory%3D%27WF%27" +
        "&outFields=IncidentName,FireDiscoveryDateTime,IncidentSize,PercentContained,POOState,POOCounty" +
        "&returnGeometry=true" +
        "&f=json" +
        "&resultRecordCount=50" +
        "&orderByFields=IncidentSize+DESC"
    )
    url = WFIGS_URL + "?" + params
    r = http.get(url, ttl_seconds = FETCH_TTL_S)
    if r.status_code != 200:
        return None
    body = r.json() or {}
    return body.get("features", [])

def _haversine_km(lat1, lon1, lat2, lon2):
    """Great-circle distance in km. math module gives sin/cos/asin/sqrt/pi."""
    R = 6371.0
    rad = math.pi / 180.0
    la1 = lat1 * rad
    la2 = lat2 * rad
    sdla = math.sin((lat2 - lat1) * rad / 2)
    sdlo = math.sin((lon2 - lon1) * rad / 2)
    h = sdla * sdla + math.cos(la1) * math.cos(la2) * sdlo * sdlo
    return 2 * R * math.asin(math.sqrt(h))

def _enrich(features, ref_lat, ref_lon):
    """Drop features missing geometry, attach computed distance, sort by it."""
    out = []
    for f in features:
        attrs = f.get("attributes") or {}
        geom = f.get("geometry") or {}
        flat = geom.get("y")
        flon = geom.get("x")
        if flat == None or flon == None:
            continue
        out.append({
            "name": attrs.get("IncidentName") or "?",
            "size": attrs.get("IncidentSize") or 0,
            "contained": attrs.get("PercentContained"),
            "state": attrs.get("POOState") or "",
            "county": attrs.get("POOCounty") or "",
            "lat": flat,
            "lon": flon,
            "dist_km": _haversine_km(ref_lat, ref_lon, flat, flon),
        })
    return sorted(out, key = lambda x: x["dist_km"])

def _threat(fires):
    """Background+foreground for the count tile based on the worst threat
    present. Green if zero. Yellow for any active in range. Orange when at
    least one is within CAUTION_DISTANCE_KM and <75% contained. Dark red
    when at least one is within DANGER_DISTANCE_KM, <50% contained, and
    larger than LARGE_FIRE_ACRES."""
    if len(fires) == 0:
        return GREEN_BG, FG_BLACK
    has_danger = False
    has_caution = False
    for f in fires:
        contained = f.get("contained") or 0
        size = f.get("size") or 0
        dist = f.get("dist_km") or 0
        if dist <= DANGER_DISTANCE_KM and contained < 50 and size >= LARGE_FIRE_ACRES:
            has_danger = True
        if dist <= CAUTION_DISTANCE_KM and contained < 75:
            has_caution = True
    if has_danger:
        return DARK_RED_BG, FG_WHITE
    if has_caution:
        return ORANGE_BG, FG_BLACK
    return YELLOW_BG, FG_BLACK

def _fire_dot_color(fire):
    contained = fire.get("contained")
    if contained == None:
        return RED_DOT  # missing data — assume worst
    if contained >= 100:
        return GREEN_DOT
    if contained >= 50:
        return YELLOW_DOT
    if contained >= 1:
        return ORANGE_DOT
    return RED_DOT

def _format_dist(dist_km):
    if dist_km == None:
        return "—"
    if dist_km < 1000:
        return str(int(dist_km + 0.5)) + "km"
    # 4-digit km values get a 'k' suffix on the km, e.g., 1290 → 1.3Mm (rare)
    return str(int(dist_km / 100 + 0.5) * 100) + "km"

def _format_acres(ac):
    """Compact acres: '500', '15k', '642k', '1.2M'."""
    if ac == None or ac <= 0:
        return "0"
    if ac >= 1000000:
        # X.X M
        v = int(ac / 100000 + 0.5)
        whole = v // 10
        frac = v - whole * 10
        return str(whole) + "." + str(frac) + "M"
    if ac >= 1000:
        return str(int(ac / 1000 + 0.5)) + "k"
    return str(int(ac + 0.5))

def _kv_row(label, value, value_color = "#FFFFFF"):
    return render.Row(
        expanded = True,
        main_align = "space_between",
        cross_align = "center",
        children = [
            render.Text(label, color = FG_WHITE, font = "tom-thumb"),
            render.Text(value, color = value_color, font = "tom-thumb"),
        ],
    )

def _dots_row(fires):
    """One 4x4 colored square per fire, 1px gap. Up to 7 fit in 36 px; a
    '+' caps any overflow."""
    children = []
    cap = 7
    for f in fires[:cap]:
        children.append(render.Padding(
            pad = (0, 0, 1, 0),
            child = render.Box(width = 4, height = 4, color = _fire_dot_color(f)),
        ))
    if len(fires) > cap:
        children.append(render.Text("+", color = FG_WHITE, font = "tom-thumb"))
    return render.Row(cross_align = "center", children = children)

def _big_tile(count, bg, fg):
    """Left tile: small 'FIRES' label in navy on top, big count below in
    the category foreground."""
    return render.Box(
        width = 28,
        height = 32,
        color = bg,
        child = render.Column(
            expanded = True,
            main_align = "space_evenly",
            cross_align = "center",
            children = [
                render.Text("FIRES", color = LABEL_COLOR, font = "tb-8"),
                render.Text(str(count), color = fg, font = "6x13"),
            ],
        ),
    )

def _error_view(msg):
    return render.Root(
        child = render.Box(
            color = "#222222",
            child = render.Column(
                expanded = True,
                main_align = "center",
                cross_align = "center",
                children = [render.Text(msg, color = FG_WHITE, font = "tom-thumb")],
            ),
        ),
    )

def main(config):
    lat_s = config.get("latitude", "40.147796")
    lon_s = config.get("longitude", "-105.088271")
    radius_s = config.get("radius_km", "200")

    if not lat_s or not lon_s:
        return _error_view("NO LOCATION")

    lat = float(lat_s)
    lon = float(lon_s)
    radius = int(radius_s) if radius_s else 200

    feats = fetch_fires(lat, lon, radius)
    if feats == None:
        return _error_view("WFIGS ERR")

    fires = _enrich(feats, lat, lon)
    bg, fg = _threat(fires)

    if len(fires) == 0:
        right_col = render.Padding(
            pad = (2, 0, 0, 0),
            child = render.Column(
                expanded = True,
                main_align = "space_evenly",
                children = [
                    _kv_row("NEAR", "—"),
                    _kv_row("MAX", "0"),
                    render.Text(str(radius) + "km", color = "#888888", font = "tom-thumb"),
                ],
            ),
        )
    else:
        closest = fires[0]
        largest = fires[0]
        for f in fires:
            if (f.get("size") or 0) > (largest.get("size") or 0):
                largest = f
        right_col = render.Padding(
            pad = (2, 0, 0, 0),
            child = render.Column(
                expanded = True,
                main_align = "space_evenly",
                children = [
                    _kv_row("NEAR", _format_dist(closest["dist_km"])),
                    _kv_row("MAX", _format_acres(largest["size"])),
                    _dots_row(fires),
                ],
            ),
        )

    return render.Root(
        child = render.Box(
            color = "#000000",
            child = render.Row(
                expanded = True,
                children = [
                    _big_tile(len(fires), bg, fg),
                    right_col,
                ],
            ),
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(id = "latitude", name = "Latitude", desc = "Reference latitude (decimal degrees).", icon = "locationDot"),
            schema.Text(id = "longitude", name = "Longitude", desc = "Reference longitude (decimal degrees).", icon = "locationDot"),
            schema.Text(id = "radius_km", name = "Radius (km)", desc = "Search distance for active wildfires.", icon = "circleNodes"),
        ],
    )
