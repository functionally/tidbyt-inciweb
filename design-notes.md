# InciWeb (WFIGS) Tidbyt — design notes

## Why "InciWeb" but actually WFIGS

InciWeb is the user-facing brand for active US wildfire incident information (operated by NWCG). The legacy `inciweb.nwcg.gov/api/v1/incidents` JSON endpoint that older code used now returns 404 — the data moved to NIFC's WFIGS (Wildland Fire Interagency Geospatial Services) ArcGIS feature service. WFIGS is the same inter-agency source that powers the InciWeb website itself, just exposed as ArcGIS REST rather than a custom JSON API.

The project keeps the folder name **InciWeb** because that's how the user-facing brand is recognized; the actual data path is WFIGS. Both names appear in the README so anyone searching for either finds the right project.

## Data source: WFIGS

```
GET https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/
    WFIGS_Incident_Locations_Current/FeatureServer/0/query
```

Key query parameters:

- `geometry=<lon>,<lat>&geometryType=esriGeometryPoint&inSR=4326` — point geometry in WGS84
- `distance=<km>&units=esriSRUnit_Kilometer` — radius filter (note `distance` is from the *query* geometry to the *feature* geometry)
- `where=IncidentTypeCategory='WF'` — restrict to wildfire incidents (excludes `RX` prescribed burns, `CX` complexes, etc.)
- `outFields=...` — only the fields we use, to keep the response small
- `returnGeometry=true` — we need the point coordinates to compute precise distances client-side (the ArcGIS server filters to the radius but doesn't return a distance value)
- `orderByFields=IncidentSize+DESC` — biggest first, in case we want a "top N by size" view in v2

Per-feature shape (truncated to the fields we use):

```json
{
  "attributes": {
    "IncidentName": "Morrill",
    "FireDiscoveryDateTime": 1741875253000,
    "IncidentSize": 642029.0,
    "PercentContained": 100.0,
    "POOState": "US-NE",
    "POOCounty": "Garden"
  },
  "geometry": { "x": -102.8, "y": 41.9 }
}
```

Notes on the fields:

- **`IncidentSize`** is in acres. Can be null for brand-new fires (treat as 0).
- **`PercentContained`** can be null (no perimeter yet); treated as 0% for color logic.
- **`FireDiscoveryDateTime`** is milliseconds since epoch UTC (ArcGIS convention).
- **`POOState`** uses ISO 3166-2 (`US-CO`, `US-NM`, etc.), not the plain two-letter abbreviation.
- **Geometry** is in `wkid: 4269` (NAD83). Within CONUS that's within meters of WGS84; close enough for distance display.

## Layout

64 × 32 RGB pixels. Same two-tile structure as the sibling apps.

```
┌────────────┬─────────────────────────────────┐
│   FIRES    │ NEAR    287km                   │
│            │ MAX     642k                    │
│    3       │ ●●●                             │
│ (color bg) │                                 │
└────────────┴─────────────────────────────────┘
  28×32 left      34×32 right (incl. 2 px pad)
```

### Big tile (28×32)

- **Top:** small `FIRES` label in navy `#000080`, `tb-8` font. Same color/font as the Tor relay app's family ID — a maximally-distinct cue against any of the warm tile backgrounds.
- **Bottom:** active-fire count in `6x13`. 1–3-digit counts fit comfortably; high-fire-season counts like `27` look right.
- Background color encodes the worst threat present (see thresholds below).

### Threat-level thresholds (and why)

| Condition | Background | Color name |
| --- | --- | --- |
| 0 fires in range | `#00E400` green | "all clear" |
| Active fires in range, but all distant or well-contained | `#FFFF00` yellow | "awareness" |
| ≥1 fire within 100 km and < 75% contained | `#FF7E00` orange | "caution" |
| ≥1 large (≥ 500 ac) uncontained (< 50%) fire within 50 km | `#7E0023` dark red | "danger" |

The numbers come from rough Front Range experience:

- **50 km** is the radius within which a wind-driven fire can produce evacuation orders within a single afternoon (2020 Marshall Fire was wind-driven and grew to evacuation distance within hours).
- **100 km** is the radius for serious smoke + ash exposure even without direct fire threat. 2020 East Troublesome's smoke hit the Front Range from ~120 km away.
- **500 acres** is roughly where Type-3 Incident Management transitions to Type-2 — i.e., the operationally-defined "this is a serious incident" line.
- **50% contained** — below this, the perimeter is still actively growing on at least one flank.

These thresholds are constants in `main.star`. Tune for different geography.

### Right column (34×32, incl. 2 px pad)

Three rows in `tom-thumb`:

1. `NEAR` ⋯ distance to the closest fire (km).
2. `MAX` ⋯ size of the largest fire in range, formatted with `k`/`M` suffix (`642k`, `1.2M`).
3. Per-fire dots — one 4×4 colored box per fire, 1 px gap, capped at 7 with a `+` if more.

Per-dot color (containment):

| Containment | Color | Hex |
| --- | --- | --- |
| 100% | green | `#00C800` |
| ≥ 50% | yellow | `#FFEE00` |
| 1–49% | orange | `#FF7E00` |
| 0% / unknown | red | `#FF0000` |

### Why these specific numbers in the right column

For a glanceable display, the two questions an operator-of-stuff cares about are:

- "How close?" (NEAR — distance to closest)
- "How big?" (MAX — largest fire size)

Total acres burning would be technically more correct but less actionable. A 600,000 acre contained fire in Nebraska doesn't matter to a Front Range resident; a 5,000 acre uncontained fire 30 km west does. Per-fire dots carry the containment context so the user can correlate.

## Caching and cadence

- HTTP cache: `http.get(url, ttl_seconds=600)`. WFIGS refreshes every few minutes during active incidents; 10 minutes is plenty for ambient awareness.
- Push cadence: 10 minutes by default (`PUSH_INTERVAL_S=600`). During an active local event you could drop to 300 (5 min) for faster reaction; outside fire season the data barely changes.
- WFIGS updates more often than once per hour, so we don't need the Tor-relay app's wall-clock-aligned schedule — a simple sleep loop is fine.

## Starlark gotchas (carried from sibling projects)

- `%` operator has no precision specifier — no `%.4f`. Format manually.
- No `while` loop — use `for x in range(n)` or string multiplication.
- `math` module provides `pi`, `sin`, `cos`, `asin`, `sqrt` — enough for haversine.

## Open questions / stretch ideas

- **Wind direction overlay.** A fire is qualitatively more dangerous when it's upwind. NWS gridpoint forecast (`api.weather.gov/gridpoints/.../forecast`) has wind direction; could nudge the threat color one step warmer when an in-range fire is upwind.
- **Acreage sparkline.** WFIGS exposes a history per incident — could render a small line chart showing whether the largest fire is growing or shrinking over the last 24 h. Tight at tom-thumb sizes.
- **Smoke layer.** NOAA HMS smoke shapefiles overlay the actual smoke plume position. Could turn the tile yellow even with zero in-range fires if smoke is overhead.
- **Multi-region support.** The threat thresholds are tuned for Front Range; an `imperial` flag could swap km for miles, but the geographic semantics are the harder part.
- **Discord / ntfy alert hook.** When the tile flips green → orange, send a notification. Out of scope for the display itself.
