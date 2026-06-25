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

64 × 32 RGB pixels. Same two-tile structure as the sibling apps. The display is **upwind-prioritized** — the tile *color* and the right-column *fire details* both focus on the nearest upwind fire (bearing within the distance-scaled windward sector), so a calm green tile means "nothing is currently blowing smoke this way." The tile *number* and the map frame, by contrast, show every fire in the configured radius — that's the situational awareness layer that lets a user count nearby fires at a glance and match the tile number to the dot count on the map.

### Why the threat color is upwind-only

The earlier iteration colored the tile by the worst fire in range regardless of bearing. Spatial truth: at any given moment, almost all of those fires aren't relevant to *your* air. A 600 k acre contained fire 290 km downwind is interesting but irrelevant. A 5 k acre uncontained fire 80 km upwind is the one you care about.

Filtering to the windward sector (distance-scaled, ±20° at 0 km growing to ±90° at 500 km — see "Plume widening" below) cuts the *threat* signal down to "fires whose smoke is heading my way." Distance among those tells you how soon. The map frame still plots every fire in radius so the all-around situational picture isn't lost — just demoted out of the at-a-glance threat color.

### Layout — upwind fire present

```
┌────────────┬─────────────────────────────────┐
│            │ Morrill                         │
│    3       │                       642k ac   │
│            │ WNW                     100%    │
│    W       │                        287km    │
│ (color bg) │                                 │
└────────────┴─────────────────────────────────┘
  28×32 left      34×32 right (incl. 2 px pad)
```

- Big tile, top: number of fires *in range* (regardless of bearing) in `6x13` font, with a 5×7 pixel-art flame appended (same flame the sibling AQ app uses for its smoke badge — keeps the visual vocabulary consistent across devices). 2 px of horizontal padding between the count and the icon. The number is deliberately the *all-in-radius* tally, not the upwind subset, so a user who counts dots on the map frame gets the same number. The tile *color* still encodes upwind threat — green when nothing is blowing this way, yellow / orange / dark red as the nearest upwind fire's threat tier rises — so a green tile with "5" reads as "5 fires nearby, none blowing my way" and a red "5" reads as "5 nearby, at least one is a real upwind threat".
- Big tile, bottom: wind source compass at the local site in `6x13` (was `tb-8`; switched up for cleaner N/W/E/S glyphs at LED resolution).
- Background = threat color (green / yellow / orange / dark red).
- Right column, 4 rows in `tom-thumb`:
  1. Fire name in navy `#000080`, wrapped in `render.Marquee(width=32)` so long names scroll horizontally and short ones sit static.
  2. Size right-justified, with `k` (kilo) or `M` (mega) magnitude prefix and an `ac` unit suffix (`999 ac`, `15k ac`, `642k ac`, `1.5M ac`).
  3. Compass-to-the-fire on the left in `tb-8` (wider glyphs read more cleanly at this size than `tom-thumb`'s tight 4x6), containment % right-justified in `tom-thumb`. The row is 8 px tall — taller than the other rows, but the `tom-thumb` percent stays vertically centered within it via `cross_align="center"`.
  4. Distance in km, right-justified, with `km` unit suffix.

Row 3 lays the fire's compass next to its containment so the reader sees *which direction this fire is in and how contained it is* on a single line. Combined with the wind compass on the big tile, the user can immediately verify the upwind filter is doing what it should — the row-3 compass should be within one or two 22.5° steps of the wind compass on the tile (within the distance-scaled sector).

### Layout — clear (no upwind fires)

```
┌────────────┬─────────────────────────────────┐
│            │                                 │
│    3       │              —                  │
│            │                                 │
│    W       │                                 │
│  (green)   │                                 │
└────────────┴─────────────────────────────────┘
```

- Big tile keeps the same shape as the active case — count on top (now `len(all_fires)`, so `3` here even though none are upwind), wind compass on bottom, green background. The structure of the display doesn't visibly reshuffle when the threat clears, only the colors and right-column content change.
- Right column is reduced to a single muted `—` in `6x13` `#666666`, centered — a subtle "no upwind threat" marker. The tile already conveys the count and the wind direction, so a prominent `ALL CLEAR` headline would just repeat what the tile is showing.

### Threat-level thresholds (and why)

Thresholds apply to the **nearest upwind fire**, not the global worst.

| Condition | Background | Color name |
| --- | --- | --- |
| No upwind fires | `#00E400` green | "all clear" |
| Upwind fire(s), but all distant or well-contained | `#FFFF00` yellow | "awareness" |
| Nearest upwind fire within 100 km and < 75% contained | `#FF7E00` orange | "caution" |
| Nearest upwind fire is large (≥ 500 ac), uncontained (< 50%), within 50 km | `#7E0023` dark red | "danger" |

The numbers come from rough Front Range experience:

- **50 km** is the radius within which a wind-driven fire can produce evacuation orders within a single afternoon (2020 Marshall Fire was wind-driven and grew to evacuation distance within hours).
- **100 km** is the radius for serious smoke + ash exposure even without direct fire threat. 2020 East Troublesome's smoke hit the Front Range from ~120 km away.
- **500 acres** is roughly where Type-3 Incident Management transitions to Type-2 — i.e., the operationally-defined "this is a serious incident" line.
- **50% contained** — below this, the perimeter is still actively growing on at least one flank.

These thresholds are constants in `main.star`. Tune for different geography.

### Right column (34×32, incl. 2 px pad) — content map

In `tom-thumb`, distributed via `space_evenly`. (See diagrams above for the visual; this list keeps the data-to-row map explicit.)

When an upwind fire is present (4 rows):

1. Fire name in navy `#000080`, marquee-wrapped.
2. Size + `ac`, right-justified.
3. Direction-to-fire (left) + containment % (right).
4. Distance + `km`, right-justified.

When clear (1 row):

1. Muted `—` in `6x13` `#666666`, centered — single character, no `ALL CLEAR` headline. The big tile's number already carries the in-range count, so the right column only needs to whisper "nothing's blowing this way".

### Map frame (36×32) — second half of the right-column animation

The right column alternates between the info view above (≈5 s, `INFO_FRAMES = 100`) and a centroid map (≈3 s, `MAP_FRAMES = 60`). The map shows **every fire in range** (not just the upwind subset), so the number on the big tile matches the dot count on the map exactly.

```
┌─────────────────────────────────┐
│                              ·  │  ← pink: G-class megafire upper-right
│                                 │
│              ┼┼                 │  ← chunky cyan "+" = configured location
│              ┼┼                 │
│       ·                         │  ← orange: smaller fire lower-left
└─────────────────────────────────┘
```

Geometry:

- Both `MAP_W = 36` and `MAP_H = 32` are even, so the true geometric center is *between* pixels at `(17.5, 15.5)`. The projection uses `MAP_CX_F = 17.5` and `MAP_CY_F = 15.5` as the floating-point reference, then rounds; fire dots therefore sit symmetrically around the visual midpoint regardless of whether they fall just east or just west of it.
- The crosshair is drawn from a fixed `CROSSHAIR_PIXELS` list — a 2 × 2 center block at pixels `(17, 15)..(18, 16)` plus 2-wide arms extending one pixel in each cardinal direction. 12 pixels total, in dim cyan `#006688`. We use a 2 × 2 center (not a single pixel) so the cross straddles the true center on both axes; a single-pixel center can't sit on `(17.5, 15.5)` and ends up looking visibly upper-left of center at this size.
- A fire dot at the same pixel as a crosshair pixel wins — the crosshair is an orientation aid, not the primary signal.

Projection is equirectangular (`dx_km = (lon - ref_lon) * 111.32 * cos(ref_lat)`, `dy_km = (lat - ref_lat) * 110.574`), which differs from the great-circle distance by well under one pixel at the 300 km default radius. `km_per_px = radius_km / MAP_HALF_PX` with `MAP_HALF_PX = 15`, so at 200 km that's ~13 km/px and at 300 km ~20 km/px.

Color is by **NWCG size class A-G**, folded into six punchy LED-friendly colors. The index doubles as the bigger-wins rank for pixel-collision resolution: when two fires project to the same cell, the larger one's color survives.

| Class | Acres | Color | Hex |
| --- | --- | --- | --- |
| A/B | < 10 | dim grey | `#555555` |
| C | 10–99 | yellow | `#FFFF00` |
| D | 100–299 | orange | `#FFAA00` |
| E | 300–999 | red-orange | `#FF6600` |
| F | 1k–5k | bright red | `#FF0000` |
| G | 5k+ (megafire) | magenta | `#FF00FF` |

## Bearing and "roughly upwind" math

Wind direction at 10 m above ground (`wind_direction_10m`) is given in Open-Meteo's response as **the direction the wind is coming FROM**, in degrees. So:

- `0°` = wind from the north (blowing south)
- `90°` = wind from the east (blowing west)
- `270°` = wind from the west (blowing east)

A fire is "upwind" if its bearing from us is in the same direction as the wind's source — i.e., we look toward the fire by looking in the same direction the wind is coming from. The app uses a **distance-dependent** tolerance, not a fixed ±45°.

### Plume widening — why tolerance grows with distance

Physical fact: as a smoke plume travels downwind, it disperses laterally. Turbulent mixing, wind shear at boundaries between air masses, and atmospheric instability all spread the plume sideways over time and distance. So:

- A fire 5 km upwind has a *concentrated* plume. For its smoke to reach me, the wind needs to be pointing very close to me. Tight tolerance.
- A fire 500 km upwind has a *spread-out* plume that may be tens of km wide by the time it gets close. The wind can be 60–90° off the fire-to-me bearing and the plume still drifts onto my point. Wide tolerance.

The app models this as a linear growth:

```
tolerance_deg(d) = clamp(BASE + GROWTH_PER_KM × d, 0, MAX)
```

with `BASE = 20°`, `GROWTH_PER_KM = 0.15°/km`, `MAX = 90°`. At the defaults:

| Distance | Tolerance |
| --- | --- |
| 0 km | 20° |
| 50 km | 27.5° |
| 100 km | 35° |
| 200 km | 50° |
| 300 km | 65° |
| 470 km | 90° (cap) |

The exact numbers are a coarse approximation — real dispersion follows Gaussian-plume models that depend on atmospheric stability class. The linear form here errs toward "include more candidates" because under-counting upwind fires is the bigger usability failure (missing a fire that's actually hitting you with smoke is worse than incorrectly flagging one that isn't).

Bearing from us to a fire is the standard great-circle initial bearing:

```
y = sin(Δλ) · cos(φ₂)
x = cos(φ₁)·sin(φ₂) − sin(φ₁)·cos(φ₂)·cos(Δλ)
θ = atan2(y, x)
```

where φ is latitude, λ is longitude.

The Pixlet `math` module provides `pi`, `sin`, `cos`, `atan2`, `asin`, `sqrt` — enough for both haversine and bearing without external dependencies.

## Caching and cadence

Two upstream APIs, two cache windows:

- WFIGS: `http.get(url, ttl_seconds=600)` — refreshes every few minutes during active incidents; 10 min is plenty.
- Open-Meteo wind: `http.get(url, ttl_seconds=1800)` — surface wind doesn't change minute-to-minute; 30 min cache reduces upstream calls by 3× vs WFIGS without losing meaningful resolution.

Push cadence: 10 minutes by default (`PUSH_INTERVAL_S=600`). During an active local event you could drop to 300 (5 min) for faster reaction; outside fire season the data barely changes. Wall-clock alignment isn't useful here since neither API has a fixed publication schedule.

## Diagnostics

Every render emits a structured trace via Starlark `print()` (Pixlet routes these to stderr; the container loop captures both streams into `podman logs`). Per-render lines:

- `[fetch] GET <url> ttl=<seconds>` — every HTTP call before it goes out, with TTL.
- `[fetch] WFIGS HTTP=<status> bytes=<n>` / `[fetch] WFIGS features=<n>` — feature service response.
- `[fetch] Open-Meteo HTTP=<status> bytes=<n>` / `[fetch] wind dir=<deg> speed=<m/s>` — wind response and parsed values.
- `[compute] wind_dir=<deg> compass=<NNE> all_fires=<n> upwind=<n>` — the windward filter's inputs and result count.
- `[render] state=ALL_CLEAR fires_in_range=<n>` — when nothing is upwind.
- `[render] nearest=<name> dist=<km>km bearing=<NNE> size=<acres> contained=<pct> threat_bg=<hex>` — when something is upwind; includes the chosen tile color so the threat-level decision is auditable from the log alone.

Replay: `podman logs inciweb | grep -E '^\[(fetch|compute|render)\]'`, slice by the surrounding `[<iso-ts>] push ok` envelopes from the bash loop.

## Starlark gotchas (carried from sibling projects)

- `%` operator has no precision specifier — no `%.4f`. Format manually.
- No `while` loop — use `for x in range(n)` or string multiplication.
- `math` module provides `pi`, `sin`, `cos`, `asin`, `sqrt` — enough for haversine.

## Open questions / stretch ideas

- **Acreage sparkline for the upwind fire.** WFIGS exposes a history per incident — could render a small line chart under the right column showing whether *that specific fire* is growing or shrinking over the last 24 h.
- **Multi-level winds.** 10 m surface wind drives ground-level smoke; 700 mb / 500 mb winds steer the smoke plume aloft. The app uses surface only; on days with significant directional shear (chinook, frontal passage) upper-level smoke can come from a different direction than the surface wind suggests.
- **Smoke layer overlay.** NOAA HMS produces smoke polygons. Could downgrade the tile to yellow even when no fires are upwind, if smoke is overhead from an out-of-region source.
- **Wind speed as a signal.** Calm winds (< 2 m/s) mean smoke barely transports — the "upwind" filter is misleading because nothing is upwind in any meaningful sense. Could grey the tile under calm conditions.
- **Multi-region support.** The threat thresholds are tuned for Front Range; an `imperial` flag could swap km for miles, but the geographic semantics are the harder part.
- **Discord / ntfy alert hook.** When the tile flips green → orange, send a notification. Out of scope for the display itself.
