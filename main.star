"""Nearest upwind wildfire for Tidbyt.

Fetches active US wildfires from NIFC's WFIGS feature service and current
wind direction from Open-Meteo. Filters to fires within ±45° of the wind's
source direction (the windward sector) and shows the nearest one — the
fire most likely to send smoke and ash this way.

See ./design-notes.md for the upwind-only design rationale, ArcGIS schema,
and threat-level thresholds.
"""

load("render.star", "render")
load("http.star", "http")
load("encoding/json.star", "json")
load("schema.star", "schema")
load("math.star", "math")

WFIGS_URL = (
    "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/" +
    "WFIGS_Incident_Locations_Current/FeatureServer/0/query"
)
OPEN_METEO_URL = "https://api.open-meteo.com/v1/forecast"

WFIGS_TTL_S = 600     # 10 min
WIND_TTL_S = 1800     # 30 min — wind doesn't change minute-to-minute

# Threat-level thresholds for the *single nearest upwind fire*.
DANGER_DISTANCE_KM = 50
CAUTION_DISTANCE_KM = 100
LARGE_FIRE_ACRES = 500

# Upwind tolerance is *distance-dependent* — close fires need to be tightly
# aligned with the wind to send smoke our way (plumes are still concentrated);
# distant fires have had time to disperse laterally so a wider angular sector
# can still hit us. Simple linear model: base degrees at 0 km, growing by
# `_GROWTH_PER_KM` per km of distance, capped at `_MAX_DEG`.
#
# At the defaults:
#     0 km →  20°       100 km → 35°        300 km → 65°
#    50 km →  27.5°     200 km → 50°        500 km → 90° (capped)
UPWIND_TOLERANCE_BASE_DEG = 20.0
UPWIND_TOLERANCE_GROWTH_PER_KM = 0.15
UPWIND_TOLERANCE_MAX_DEG = 90.0

GREEN_BG = "#00E400"
YELLOW_BG = "#FFFF00"
ORANGE_BG = "#FF7E00"
DARK_RED_BG = "#7E0023"
FG_BLACK = "#000000"
FG_WHITE = "#FFFFFF"
LABEL_COLOR = "#000080"  # navy — same accent used by the Tor app

COMPASS_16 = [
    "N", "NNE", "NE", "ENE",
    "E", "ESE", "SE", "SSE",
    "S", "SSW", "SW", "WSW",
    "W", "WNW", "NW", "NNW",
]

# Right panel alternates between the info screen and the centroid map.
# Pixlet renders Animation children at 20 fps (50 ms each), so these are
# dwell times in 50 ms units. ~8 s/cycle fits comfortably inside Tidbyt's
# ~15 s app slot, and 5 s of info time lets the name marquee scroll a
# typical wildfire name end-to-end.
INFO_FRAMES = 100
MAP_FRAMES = 60

# Centroid map sized to the right panel. The map's true geometric
# center is between pixels because both MAP_W and MAP_H are even, so
# we project around the floating-point midpoint (MAP_CX_F, MAP_CY_F)
# and draw the crosshair as a 2 x 2 center block plus 2-wide arms —
# that way the crosshair straddles the true center symmetrically
# instead of sitting half a pixel off in one corner.
MAP_W = 36
MAP_H = 32
MAP_CX_F = (MAP_W - 1) / 2.0  # 17.5
MAP_CY_F = (MAP_H - 1) / 2.0  # 15.5
MAP_HALF_PX = 15

# Map decoration: a faint trumpet-shaped wedge fills the windward sector
# (apex at the map's geometric center, flaring with distance via
# _upwind_tolerance_deg), and a small 2x2 anchor dot marks the
# configured location. Replaces the old chunky-cross crosshair — the
# wedge shows which fires are upwind without overlaying every map; the
# anchor keeps a positive "you are here" marker so the location is
# still legible when nothing is upwind.
WEDGE_COLOR = "#16242E"  # very dim cyan-gray, distinct from black, won't compete with fire dots
ANCHOR_COLOR = "#006688"  # same cyan the old crosshair used

# Anchor dot: 2 x 2 block straddling the map's true (17.5, 15.5)
# geometric center. Without it the wedge alone implies the apex by
# convergence, but a positive "you are here" marker is more legible
# (especially when no fires are present or the wedge is narrow).
ANCHOR_PIXELS = [
    (17, 15), (18, 15),
    (17, 16), (18, 16),
]

# NWCG size classes A-G folded to 6 colors: A+B (<10 ac) share one dim
# swatch since they sit below the smoke-impact threshold at this zoom;
# C-G get distinct punchy colors. The index doubles as the bigger-wins
# rank used to resolve pixel collisions.
SIZE_CLASS_COLORS = [
    "#555555",  # 0: <10 ac      (A/B)
    "#FFFF00",  # 1: C 10-99 ac
    "#FFAA00",  # 2: D 100-299 ac
    "#FF6600",  # 3: E 300-999 ac
    "#FF0000",  # 4: F 1k-5k ac
    "#FF00FF",  # 5: G 5k+ ac     megafire
]

def fetch_fires(lat, lon, radius_km):
    if lat == None or lon == None:
        print("[fetch] WFIGS SKIP (missing coords)")
        return None
    params = (
        "geometry=" + str(lon) + "," + str(lat) +
        "&geometryType=esriGeometryPoint&inSR=4326" +
        "&distance=" + str(radius_km) +
        "&units=esriSRUnit_Kilometer" +
        "&where=IncidentTypeCategory%3D%27WF%27" +
        "&outFields=IncidentName,IncidentSize,PercentContained,POOState,POOCounty" +
        "&returnGeometry=true&f=json&resultRecordCount=100" +
        "&orderByFields=IncidentSize+DESC"
    )
    url = WFIGS_URL + "?" + params
    print("[fetch] GET %s ttl=%d" % (url, WFIGS_TTL_S))
    r = http.get(url, ttl_seconds = WFIGS_TTL_S)
    print("[fetch] WFIGS HTTP=%d bytes=%d" % (r.status_code, len(r.body())))
    if r.status_code != 200:
        return None
    feats = (r.json() or {}).get("features", [])
    print("[fetch] WFIGS features=%d" % len(feats))
    return feats

def fetch_wind(lat, lon):
    """Returns wind_direction_deg (the direction the wind is coming FROM,
    Open-Meteo's convention; 0=N, 90=E, 180=S, 270=W) or None on error.

    Uses 700 hPa (~3 km AGL) rather than 10 m surface wind. Lofted
    smoke from a large fire follows mid-troposphere transport, not the
    surface boundary layer — and on the Front Range the surface wind
    is dominated by orographic upslope/drainage cycles that frequently
    disagree with the actual smoke direction (the synoptic westerlies
    that move fire plumes show up cleanly at 700 hPa but get masked at
    the surface). Empirically verified 2026-06-26 at the user's
    coordinates: surface read 62° (ENE upslope), 700 hPa read 269° (W
    westerly — the real transport direction)."""
    url = (
        OPEN_METEO_URL +
        "?latitude=" + str(lat) +
        "&longitude=" + str(lon) +
        "&current=wind_direction_700hPa,wind_speed_700hPa"
    )
    print("[fetch] GET %s ttl=%d" % (url, WIND_TTL_S))
    r = http.get(url, ttl_seconds = WIND_TTL_S)
    print("[fetch] Open-Meteo HTTP=%d bytes=%d" % (r.status_code, len(r.body())))
    if r.status_code != 200:
        return None
    body = r.json() or {}
    cur = body.get("current") or {}
    wind_dir = cur.get("wind_direction_700hPa")
    wind_speed = cur.get("wind_speed_700hPa")
    print("[fetch] wind dir=%s speed=%s (700 hPa)" % (wind_dir, wind_speed))
    return wind_dir

def _haversine_km(lat1, lon1, lat2, lon2):
    R = 6371.0
    rad = math.pi / 180.0
    la1 = lat1 * rad
    la2 = lat2 * rad
    sdla = math.sin((lat2 - lat1) * rad / 2)
    sdlo = math.sin((lon2 - lon1) * rad / 2)
    h = sdla * sdla + math.cos(la1) * math.cos(la2) * sdlo * sdlo
    return 2 * R * math.asin(math.sqrt(h))

def _bearing_deg(lat1, lon1, lat2, lon2):
    """Initial compass bearing from (lat1,lon1) to (lat2,lon2). 0=N, 90=E."""
    rad = math.pi / 180.0
    la1 = lat1 * rad
    la2 = lat2 * rad
    dlo = (lon2 - lon1) * rad
    y = math.sin(dlo) * math.cos(la2)
    x = math.cos(la1) * math.sin(la2) - math.sin(la1) * math.cos(la2) * math.cos(dlo)
    b = math.atan2(y, x) / rad
    if b < 0:
        b = b + 360
    return b

def _angular_diff(a, b):
    """Smallest absolute angular distance between two compass bearings (0..180)."""
    d = a - b
    # Reduce to [-180, 180]
    for _ in range(4):
        if d > 180:
            d = d - 360
        elif d < -180:
            d = d + 360
        else:
            break
    if d < 0:
        d = -d
    return d

def _compass(degrees):
    if degrees == None:
        return "?"
    idx = int((degrees + 11.25) / 22.5) % 16
    return COMPASS_16[idx]

def _enrich(features, ref_lat, ref_lon):
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
            "bearing_deg": _bearing_deg(ref_lat, ref_lon, flat, flon),
        })
    return out

def _upwind_tolerance_deg(distance_km):
    """Distance-dependent windward-sector half-angle. See module-level
    constants and design-notes.md for the model."""
    t = UPWIND_TOLERANCE_BASE_DEG + distance_km * UPWIND_TOLERANCE_GROWTH_PER_KM
    if t > UPWIND_TOLERANCE_MAX_DEG:
        return UPWIND_TOLERANCE_MAX_DEG
    return t

def _filter_upwind(fires, wind_from_deg):
    """A fire is roughly upwind if its bearing from us is within the
    distance-dependent windward-sector half-angle of the wind's source
    direction. Returns sorted by ascending distance."""
    out = []
    for f in fires:
        if _angular_diff(f["bearing_deg"], wind_from_deg) <= _upwind_tolerance_deg(f["dist_km"]):
            out.append(f)
    return sorted(out, key = lambda x: x["dist_km"])

def _threat(fire):
    contained = fire.get("contained") or 0
    size = fire.get("size") or 0
    dist = fire.get("dist_km") or 0
    if dist <= DANGER_DISTANCE_KM and contained < 50 and size >= LARGE_FIRE_ACRES:
        return DARK_RED_BG, FG_WHITE
    if dist <= CAUTION_DISTANCE_KM and contained < 75:
        return ORANGE_BG, FG_BLACK
    return YELLOW_BG, FG_BLACK

def _format_acres(ac):
    if ac == None or ac <= 0:
        return "0"
    if ac >= 1000000:
        v = int(ac / 100000 + 0.5)
        whole = v // 10
        frac = v - whole * 10
        return str(whole) + "." + str(frac) + "M"
    if ac >= 1000:
        return str(int(ac / 1000 + 0.5)) + "k"
    return str(int(ac + 0.5))

def _format_pct(p):
    """Just the integer portion. The '%' glyph is rendered as a separate
    Text widget in the row (see `_compass_pct_row`) so any subtle font /
    width / clipping issue at the column edge can't drop it.
    Missing data renders as '-' (hyphen) rather than '?' — tom-thumb's
    '?' glyph reads like a '7' at LED-matrix resolution."""
    if p == None:
        return "-"
    return str(int(p + 0.5))

def _compass_pct_row(compass, contained_value):
    """Compass on the left in tb-8 (wider, clearer N/W/E/S glyphs than
    tom-thumb's tight 4x6), integer containment + standalone '%' glyph on
    the right in tom-thumb (the column is too narrow for the full row to
    use tb-8). Mixed font heights — the row is 8 px tall, the others stay
    at 6 px — but vertical centering hides the mismatch."""
    return render.Row(
        expanded = True,
        main_align = "space_between",
        cross_align = "center",
        children = [
            render.Text(compass, color = FG_WHITE, font = "tb-8"),
            render.Row(
                cross_align = "center",
                children = [
                    render.Text(contained_value, color = FG_WHITE, font = "tom-thumb"),
                    render.Text("%", color = FG_WHITE, font = "tom-thumb"),
                ],
            ),
        ],
    )

def _kv_row(label, value):
    return render.Row(
        expanded = True,
        main_align = "space_between",
        cross_align = "center",
        children = [
            render.Text(label, color = FG_WHITE, font = "tom-thumb"),
            render.Text(value, color = FG_WHITE, font = "tom-thumb"),
        ],
    )

def _name_row(name):
    """Fire name across the full right-column width. Marquee scrolls if the
    name overflows; static otherwise. Color is the navy accent so the name
    reads as a header rather than another data row."""
    return render.Marquee(
        width = 32,
        child = render.Text(name, color = LABEL_COLOR, font = "tom-thumb"),
    )

def _fire_icon():
    """Stylized pixel flame, 5 px wide × 7 px tall. Same flame the sibling
    AQ Tidbyt app uses for its smoke badge — keeps the visual vocabulary
    consistent across this user's devices."""
    return render.Column(
        cross_align = "center",
        children = [
            render.Box(width = 1, height = 1, color = "#FFEE00"),
            render.Box(width = 3, height = 1, color = "#FFAA00"),
            render.Box(width = 3, height = 1, color = "#FF7700"),
            render.Box(width = 5, height = 1, color = "#FF4400"),
            render.Box(width = 5, height = 2, color = "#FF1100"),
            render.Box(width = 3, height = 1, color = "#AA0000"),
        ],
    )

def _big_tile(count, wind_compass, bg, fg):
    """Left tile: total fires-in-range count in 6x13 with a pixel-art
    flame icon appended, wind source compass below. The number matches
    what a user would tally by counting dots on the map frame. The
    background color encodes upwind threat level — green when nothing
    is blowing this way (regardless of how many fires are in range)."""
    return render.Box(
        width = 28,
        height = 32,
        color = bg,
        child = render.Column(
            expanded = True,
            main_align = "space_evenly",
            cross_align = "center",
            children = [
                render.Row(
                    cross_align = "center",
                    children = [
                        render.Text(str(count), color = fg, font = "6x13"),
                        render.Padding(pad = (2, 0, 0, 0), child = _fire_icon()),
                    ],
                ),
                render.Text(wind_compass, color = fg, font = "6x13"),
            ],
        ),
    )

def _right_text(text, color = FG_WHITE):
    """Single value, right-justified within the column width."""
    return render.Row(
        expanded = True,
        main_align = "end",
        children = [render.Text(text, color = color, font = "tom-thumb")],
    )

def _fire_right_col(fire):
    """Right column when an upwind fire is present: name (marquee) / acres
    right-justified / fire-compass left + containment % right / distance
    right-justified."""
    fire_compass = _compass(fire["bearing_deg"])
    return render.Padding(
        pad = (2, 0, 2, 0),
        child = render.Column(
            expanded = True,
            main_align = "space_evenly",
            children = [
                _name_row(fire["name"]),
                _right_text(_format_acres(fire["size"]) + " ac"),
                _compass_pct_row(fire_compass, _format_pct(fire["contained"])),
                _right_text(str(int(fire["dist_km"] + 0.5)) + "km"),
            ],
        ),
    )

def _clear_right_col():
    """Right column when nothing upwind. The big tile is already green
    and shows the in-range count, so this column is reduced to a single
    muted '—' centered — a subtle 'no threat' marker without the visual
    weight of the old 'ALL CLEAR' headline."""
    return render.Padding(
        pad = (2, 0, 2, 0),
        child = render.Column(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [
                render.Text("—", color = "#666666", font = "6x13"),
            ],
        ),
    )

def _round_signed(v):
    # int(x + 0.5) rounds positives correctly but truncates negatives
    # toward zero in Starlark, which skews south/west projections.
    if v >= 0:
        return int(v + 0.5)
    return -int(-v + 0.5)

def _size_class_idx(acres):
    """NWCG-style size-class rank (0..5), with A+B (<10 ac) merged."""
    if acres == None or acres < 10:
        return 0
    if acres < 100:
        return 1
    if acres < 300:
        return 2
    if acres < 1000:
        return 3
    if acres < 5000:
        return 4
    return 5

def _project(flat, flon, ref_lat, ref_lon, km_per_px):
    """Equirectangular projection. At <=300 km it differs from great-
    circle by well under one pixel, so the simple form is fine.
    Reference is the panel's floating-point geometric midpoint so
    fires are placed symmetrically around the visual anchor dot."""
    lat_rad = ref_lat * math.pi / 180.0
    dx_km = (flon - ref_lon) * 111.32 * math.cos(lat_rad)
    dy_km = (flat - ref_lat) * 110.574
    return (
        _round_signed(MAP_CX_F + dx_km / km_per_px),
        _round_signed(MAP_CY_F - dy_km / km_per_px),
    )

def _wedge_pixels(wind_dir, km_per_px):
    """Map pixels inside the distance-dependent windward sector. Apex
    at the map's geometric midpoint; the sector half-angle grows with
    distance via _upwind_tolerance_deg (20 deg at the apex, capped at
    90 deg by ~466 km), so the shape is a trumpet rather than a
    triangle — the wedge visualizes the same plume-widening model the
    upwind filter uses to pick which fires count as threats."""
    rad_to_deg = 180.0 / math.pi
    pixels = []
    for py in range(MAP_H):
        for px in range(MAP_W):
            dx = float(px) - MAP_CX_F
            dy = MAP_CY_F - float(py)
            if dx == 0.0 and dy == 0.0:
                continue
            dist_km = math.sqrt(dx * dx + dy * dy) * km_per_px
            bearing = math.atan2(dx, dy) * rad_to_deg
            if bearing < 0:
                bearing = bearing + 360
            if _angular_diff(bearing, wind_dir) <= _upwind_tolerance_deg(dist_km):
                pixels.append((px, py))
    return pixels

def _map_right_col(fires, ref_lat, ref_lon, radius_km, wind_dir):
    """Right-panel map: black background, a faint cyan-gray wedge
    showing the upwind sector, a 2x2 cyan anchor dot at the center,
    and one pixel per fire centroid colored by NWCG size class. Fire
    dots top everything else (largest wins on collision); the anchor
    yields to fires; the wedge yields to both."""
    km_per_px = float(radius_km) / float(MAP_HALF_PX)

    cells = {}
    for f in fires:
        px, py = _project(f["lat"], f["lon"], ref_lat, ref_lon, km_per_px)
        if px < 0 or px >= MAP_W or py < 0 or py >= MAP_H:
            continue
        cls = _size_class_idx(f["size"])
        key = (px, py)
        if key not in cells or cls > cells[key]:
            cells[key] = cls

    anchor_set = {p: True for p in ANCHOR_PIXELS}

    children = []
    # Wedge first so anchor and fires draw on top.
    for px, py in _wedge_pixels(wind_dir, km_per_px):
        if (px, py) in cells or (px, py) in anchor_set:
            continue
        children.append(render.Padding(
            pad = (px, py, 0, 0),
            child = render.Box(width = 1, height = 1, color = WEDGE_COLOR),
        ))

    # Anchor next so fires can overdraw it where they land on top.
    for px, py in ANCHOR_PIXELS:
        if (px, py) in cells:
            continue
        children.append(render.Padding(
            pad = (px, py, 0, 0),
            child = render.Box(width = 1, height = 1, color = ANCHOR_COLOR),
        ))

    # Fire dots on top.
    for key, cls in cells.items():
        children.append(render.Padding(
            pad = (key[0], key[1], 0, 0),
            child = render.Box(width = 1, height = 1, color = SIZE_CLASS_COLORS[cls]),
        ))

    return render.Box(
        width = MAP_W,
        height = MAP_H,
        color = "#000000",
        child = render.Stack(children = children),
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
    lat_s = config.get("latitude", "")
    lon_s = config.get("longitude", "")
    radius_s = config.get("radius_km", "200")

    if not lat_s or not lon_s:
        return _error_view("NO LOCATION")

    lat = float(lat_s)
    lon = float(lon_s)
    radius = int(radius_s) if radius_s else 200

    feats = fetch_fires(lat, lon, radius)
    if feats == None:
        return _error_view("WFIGS ERR")

    wind_dir = fetch_wind(lat, lon)
    if wind_dir == None:
        return _error_view("WIND ERR")

    all_fires = _enrich(feats, lat, lon)
    upwind = _filter_upwind(all_fires, wind_dir)
    wind_compass = _compass(wind_dir)

    print("[compute] wind_dir=%s compass=%s all_fires=%d upwind=%d" % (
        wind_dir, wind_compass, len(all_fires), len(upwind),
    ))

    if len(upwind) == 0:
        big = _big_tile(len(all_fires), wind_compass, GREEN_BG, FG_BLACK)
        info_col = _clear_right_col()
        print("[render] state=ALL_CLEAR fires_in_range=%d" % len(all_fires))
    else:
        nearest = upwind[0]
        bg, fg = _threat(nearest)
        big = _big_tile(len(all_fires), wind_compass, bg, fg)
        info_col = _fire_right_col(nearest)
        print("[render] nearest=%s dist=%dkm bearing=%s size=%s contained=%s threat_bg=%s" % (
            nearest["name"],
            int(nearest["dist_km"] + 0.5),
            _compass(nearest["bearing_deg"]),
            nearest["size"],
            nearest["contained"],
            bg,
        ))

    # Right panel cycles info -> map. Box-wrapping the info column gives
    # Animation a definite frame size to match the map view.
    info_view = render.Box(width = MAP_W, height = MAP_H, child = info_col)
    map_view = _map_right_col(all_fires, lat, lon, radius, wind_dir)
    right_anim = render.Animation(
        children = [info_view] * INFO_FRAMES + [map_view] * MAP_FRAMES,
    )

    return render.Root(
        child = render.Box(
            color = "#000000",
            child = render.Row(
                expanded = True,
                children = [big, right_anim],
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
