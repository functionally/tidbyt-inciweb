# InciWeb (WFIGS) wildfire-near-me Tidbyt app

A Pixlet app for the Tidbyt that shows active US wildfires within a configurable radius of a reference point. Data comes from [NIFC's WFIGS feature service](https://data-nifc.opendata.arcgis.com/) — the canonical source for active US wildfire incidents (the legacy InciWeb `/api/v1/` endpoint the project is informally named after went 404).

See [design-notes.md](./design-notes.md) for layout choices, threat thresholds, and the ArcGIS field map. Licensed under [MIT](./LICENSE) — © 2026 Brian W Bush.

## What it shows

The nearest active wildfire **that is roughly upwind** of the configured point — the fire most likely to send smoke and ash this way. "Roughly upwind" = bearing from your point within a *distance-dependent* windward sector of where the wind is currently coming from (close fires need tight alignment; distant fires get a wider sector because their plumes have had more lateral spread).

```
┌────────────┬──────────────────┐
│            │ Morrill          │   ← fire name (marquee-scrolls if long)
│  3 🔥      │           642k ac│   ← upwind fire count + flame icon
│            │ WNW         100% │   ← compass to fire (left), containment (right)
│   W        │             287km│   ← distance to fire, right-justified
│  (color)   │                  │
└────────────┴──────────────────┘
```

When nothing is upwind:

```
┌────────────┬──────────────────┐
│            │                  │
│    0       │     ALL          │
│            │    CLEAR         │
│    W       │  (3 in range)    │   ← total active fires in range (for context)
│  (green)   │                  │
└────────────┴──────────────────┘
```

- **Big tile:** number of *upwind* fires (top) and the wind source compass at your location (bottom). Threat-colored background — green when zero, otherwise the worst threat among the upwind set.
- **Threat color** (left tile background):
  - **green** — no fires upwind
  - **yellow** — upwind fire(s) present but distant or well-contained
  - **orange** — nearest upwind fire is within 100 km and < 75% contained
  - **dark red** — nearest upwind fire is large (≥ 500 ac), uncontained (< 50%), and within 50 km
- **Right column** when an upwind fire is present (4 rows): name in navy (marquees if long), size with `ac` suffix and `k`/`M` magnitude prefix, compass-to-fire + containment %, and distance in km.

## Data sources

Two endpoints, both free and unauthenticated:

```
GET https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/
    WFIGS_Incident_Locations_Current/FeatureServer/0/query
    ?geometry={lon},{lat}&geometryType=esriGeometryPoint&inSR=4326
    &distance={radius_km}&units=esriSRUnit_Kilometer
    &where=IncidentTypeCategory='WF'
    &outFields=IncidentName,IncidentSize,PercentContained,POOState,POOCounty
    &returnGeometry=true&f=json&resultRecordCount=100
    &orderByFields=IncidentSize+DESC

GET https://api.open-meteo.com/v1/forecast
    ?latitude={lat}&longitude={lon}
    &current=wind_direction_10m,wind_speed_10m
```

NIFC's WFIGS refreshes every few minutes; we poll every 10 minutes (`ttl_seconds=600`). Open-Meteo's surface wind is cached for 30 minutes (`ttl_seconds=1800`) since wind doesn't change minute-to-minute.

## Setup

1. **Enter the dev shell:**
   ```
   nix develop
   ```
2. **Create config.yaml:**
   ```
   cp config-example.yaml config.yaml
   ${EDITOR:-vi} config.yaml
   ```
   The default location is 766 S Martin St, Longmont (matches the AQ app). Adjust `latitude`, `longitude`, and `radius_km` to taste. 200 km covers the Front Range plus the adjacent plains and foothills (the 2020 Cameron Peak / East Troublesome fires reached ~80 km).
3. **Sanity-check** before deploying:
   ```
   ./scripts/check.sh
   ```
   Verifies WFIGS responds, lists each fire in range sorted by distance with size and containment, and reports which threat-color tile the app would render.
4. **One-shot push:**
   ```
   ./scripts/deploy.sh
   ```
5. **Daemon (container):**
   ```
   ./scripts/build-container.sh
   podman kube play --replace inciweb.yaml
   podman logs -f inciweb-tidbyt
   ```

## Files

| | |
| --- | --- |
| `main.star` | The Pixlet app (Starlark). Two-tile layout, same shape as the AQ + Tor apps. |
| `flake.nix` | Nix dev shell + pixlet derivation + container image. |
| `config-example.yaml` | Template. Copy to `config.yaml` (gitignored). |
| `scripts/check.sh` | Pre-deploy sanity check. |
| `scripts/preview.sh` | `pixlet serve` for browser preview. |
| `scripts/render.sh` | Render one frame to `out.webp`. |
| `scripts/deploy.sh` | Render and `pixlet push` once. |
| `scripts/build-container.sh` | Build the OCI image with config baked in. |
| `scripts/run-container.sh` | Run the push-daemon container with `podman run`. |
| `inciweb.yaml` | Podman kube spec for the daemon pod. |
| `design-notes.md` | Layout rationale, threshold values, ArcGIS schema. |

## Notes and caveats

- **US wildfires only.** WFIGS is the federal inter-agency layer. Canadian / Mexican fires don't appear, even if their smoke is reaching you.
- **WFIGS lag.** The feature service refreshes every few minutes for active incidents; reported fire size is typically the last reliable on-the-ground measure, not real-time.
- **`PercentContained` can be null.** Brand-new fires often have no containment field yet — we treat null as "?" in the display but ignore it for color logic (treat as 0%).
- **Wind is surface (10 m).** Open-Meteo's `wind_direction_10m` is what the smoke at ground level should follow. Upper-level smoke transport can differ; if you see haze from a fire that the app says is downwind, that's why.
- **Windward sector grows with distance.** At the defaults: 20° at 0 km, 35° at 100 km, 50° at 200 km, capped at 90° beyond ~470 km. Close fires need to be tightly aligned with the wind; distant fires get a wider sector because their plumes disperse laterally as they travel. See [design-notes.md](./design-notes.md) for the model and tuning constants.
- **Wind direction filters before distance.** A 5 km fire to the south won't show as the "nearest upwind" if the wind is from the west — instead a 200 km western fire will. That's the design: smoke transport matters more than proximity.
