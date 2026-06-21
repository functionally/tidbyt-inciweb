# InciWeb (WFIGS) wildfire-near-me Tidbyt app

A Pixlet app for the Tidbyt that shows active US wildfires within a configurable radius of a reference point. Data comes from [NIFC's WFIGS feature service](https://data-nifc.opendata.arcgis.com/) — the canonical source for active US wildfire incidents (the legacy InciWeb `/api/v1/` endpoint the project is informally named after went 404).

See [design-notes.md](./design-notes.md) for layout choices, threat thresholds, and the ArcGIS field map. Licensed under [MIT](./LICENSE) — © 2026 Brian W Bush.

## What it shows

```
┌────────────┬──────────────────┐
│   FIRES    │ NEAR  287km      │   distance to closest fire
│            │ MAX    642k      │   largest fire size (acres, compact)
│   3        │ ●●●              │   one colored 4×4 dot per fire
│  (color)   │                  │
└────────────┴──────────────────┘
```

- **Big number:** count of active wildfires inside the configured radius.
- **Tile color** (left tile background) encodes the worst threat present:
  - **green** — zero active fires in range
  - **yellow** — active fire(s) in range, but all distant or well-contained
  - **orange** — ≥1 fire within 100 km and < 75% contained
  - **dark red** — ≥1 large (≥ 500 ac) uncontained (< 50%) fire within 50 km
- **Per-fire dots** in the right column, color-coded by containment:
  - green = 100% contained, yellow = ≥ 50%, orange = 1–49%, red = 0% / unknown
- **FIRES label** in navy on top of the count — same maximally-distinct color treatment as the Tor relay app's family label.

## Data source

```
GET https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/
    WFIGS_Incident_Locations_Current/FeatureServer/0/query
    ?geometry={lon},{lat}&geometryType=esriGeometryPoint&inSR=4326
    &distance={radius_km}&units=esriSRUnit_Kilometer
    &where=IncidentTypeCategory='WF'
    &outFields=IncidentName,FireDiscoveryDateTime,IncidentSize,PercentContained,POOState,POOCounty
    &returnGeometry=true&f=json&resultRecordCount=50
    &orderByFields=IncidentSize+DESC
```

NIFC's WFIGS layer refreshes every few minutes during active incidents. We poll every 10 minutes with a matching `ttl_seconds=600` HTTP cache.

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

- **US wildfires only.** WFIGS is the federal inter-agency layer. Canadian / Mexican fires don't appear.
- **WFIGS lag.** The feature service refreshes every few minutes for active incidents; reported fire size is typically the last reliable on-the-ground measure, not real-time.
- **`PercentContained` can be null.** Brand-new fires often have no containment field yet — we treat null as "0%" (uncontained) for color purposes.
- **Radius is straight-line distance.** Doesn't account for wind direction, terrain, or smoke transport. Smoke can travel hundreds of km even when the fire itself is far away.
- **Dot row caps at 7.** Larger counts show a `+` after the seventh dot. If you live in a high-incidence region, raise the threat thresholds rather than try to fit more dots.
