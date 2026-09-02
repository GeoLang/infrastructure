# Earth Observation Architecture

The suite catalogs satellite imagery, serves it as tiles, and computes band
math and time series over it.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     GeoLang EO Stack                     │
├──────────┬──────────┬──────────┬──────────┬──────────────┤
│ STAC API │ COG Tiler│ Band Math│ Time     │ ML Feature   │
│(Ptolemy) │(geoplumb)│(geoplumb)│ Series   │  Extraction  │
│          │          │          │(terrano) │ (Panoptes)   │
├──────────┴──────────┴──────────┴──────────┴──────────────┤
│                    EO Catalog Service                     │
│                (read-only STAC in Ptolemy)                │
├──────────────────────────────────────────────────────────┤
│        Cloud Optimized GeoTIFFs (COG), read from a        │
│          local file or over HTTP range requests           │
└──────────────────────────────────────────────────────────┘
```

## Components

| Component | Repo | What it does |
|-----------|------|--------------|
| **STAC Catalog API** | Ptolemy | Six GET routes under `/api/v1/stac`: `/stac`, `/stac/collections`, `/stac/collections/{id}`, `/stac/collections/{id}/items`, `/stac/collections/{id}/items/{item_id}` and `/stac/search`. Read only |
| **COG Writer** | Terrano | Tiled, overview pyramids, single- and multi-band, u8 through f64 sample formats. CI runs GDAL's `validate_cloud_optimized_geotiff.py --full-check` over the output |
| **COG Tile Server** | geoplumb | The windowed COG source fetches only the tiles a pull touches, over a local file or HTTP range requests, from the overview level nearest the request. `geoplumb-server` serves `/tiles/{layer}/{z}/{x}/{y}.png` and `.tif`. It does not go through Fenestra, whose raster support is WCS over whole GeoTIFFs in `COVERAGE_DIR` |
| **Raster Algebra** | Terrano | Unary and binary ops, reclassify, hillshade, slope, aspect |
| **AI Feature Extraction** | Panoptes | `segment` and `change` subcommands writing GeoJSON. Only the buildings catalog name has published ONNX weights and the rest fall back to a threshold heuristic. There is no object detection |

## Band math

Band math is one expression evaluated per pixel rather than a function per
index. A layer names the `bandmath` op and writes the index itself over the
bands the source pulled, so NDVI is `(b1 - b0) / (b1 + b0)` with `red` and `nir`
listed as the search assets. The parser takes the four arithmetic operators,
unary minus, parentheses, the comparisons `< <= > >= == !=` yielding 1.0 or 0.0,
and `sqrt`, `abs`, `min`, `max`, `pow`, `log`, `exp` and a three-argument
`where`, which covers EVI, SAVI, NBR and a masked index without new code.

```
geoplumb/crates/geoplumb/src/elements/band_math.rs
```

Terrano carries one index helper of its own, `RasterStack::normalized_difference`,
used where a stack is already in memory.

## Time series

```
terrano-core/src/timeseries.rs
```

`RasterStack` holds the layers and their timestamps and computes composites
(mean, median, min, max, standard deviation), a per-pixel linear trend with its
coefficient of determination, change detection over a threshold, a z-score
anomaly against the stack mean, and phenology metrics.

```rust
pub struct RasterStack {
    pub layers: Vec<Raster>,
    pub timestamps: Vec<f64>,
}

impl RasterStack {
    pub fn composite(&self, method: CompositeMethod) -> Raster
    pub fn linear_trend(&self) -> TrendResult
    pub fn change_detection(&self, threshold: f64) -> ChangeResult
    pub fn anomaly_zscore(&self) -> Raster
    pub fn phenology(&self, threshold_fraction: f64) -> PhenologyMetrics
}
```

The served side is geoplumb: a STAC layer composites the items its search
returns over the requested interval, `?t=<start>/<end>` on a tile request picks
that interval, and `POST /zonal/{layer}/series` returns a zonal time series.
Its composites add percentile and count. Mean, min, max, standard deviation and
count fold item by item, so a pull holds one wave, while median and percentile
hold a strip's whole stack under a memory budget.

## External imagery

geoplumb's STAC source searches an external catalog per pulled window, pages to
the end of the results, and reads the assets it finds over HTTP range requests,
so `geoplumb-server` serves tiles from external items with nothing copied and
nothing registered first. Any collection on a STAC API is reachable this way.
The platform stack's `containers/geoplumb/layers.toml` runs that against
`cop-dem-glo-30` and `sentinel-2-l2a` on `earth-search.aws.element84.com`.

A cold window pays its range requests each time it is pulled. geoplumb's memory
and disk caches absorb the repeats.

## Dependencies

geoplumb's expression parser is hand-written. `RasterStack` timestamps are
`f64`, any monotonic sequence, and geoplumb's own `parse_rfc3339` reads the
interval on a request into milliseconds, so neither side carries `chrono`.
geoplumb's HTTP client is `reqwest`.

## Integration points

- **ViewTopia**: geoplumb tiles reach the viewer through the platform proxy's
  `/plumb/*` route, and the timelapse panel drives the `?t=` interval.
