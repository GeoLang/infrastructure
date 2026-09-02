# Earth Observation (EO) Architecture Plan

## Vision

A cloud-native Earth Observation pipeline for the GeoLang suite, enabling satellite imagery cataloging, analysis, and time-series processing comparable to Google Earth Engine.

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
│                    Object Storage (S3)                    │
│              Cloud Optimized GeoTIFFs (COG)               │
└──────────────────────────────────────────────────────────┘
```

## Components

### Phase 1: Foundation (existing + extensions)

| Component | Repo | Status | Work Needed |
|-----------|------|--------|-------------|
| **STAC Catalog API** | Ptolemy | Read only | `GET /api/v1/stac`, `/stac/collections`, `/stac/collections/{id}`, `/stac/collections/{id}/items`, `/stac/collections/{id}/items/{item_id}` and `/stac/search`. Add collection and item write endpoints |
| **COG Writer** | Terrano | Done | Tiled, overview pyramids, single- and multi-band, u8 through f64 sample formats, and CI runs GDAL's `validate_cloud_optimized_geotiff.py --full-check` over the output |
| **COG Tile Server** | geoplumb | Done | The windowed COG source fetches only the tiles a pull touches, over a local file or HTTP range requests, from the overview level nearest the request. `geoplumb-server` serves `/tiles/{layer}/{z}/{x}/{y}.png` and `.tif`. It did not go through Fenestra, whose raster support is still WCS over whole GeoTIFFs in `COVERAGE_DIR` |
| **Raster Algebra** | Terrano | Done | Has unary/binary ops, reclassify, hillshade, slope, aspect |
| **AI Feature Extraction** | Panoptes | Segmentation and change | `segment` and `change` subcommands writing GeoJSON. Only the buildings catalog name has published ONNX weights and the rest fall back to a threshold heuristic. There is no object detection |

### Phase 2: Spectral Analysis (done, as an expression op in geoplumb)

Band math landed as one expression evaluated per pixel rather than a function
per index. A layer names the `bandmath` op and writes the index itself over the
bands the source pulled, so NDVI is `(b1 - b0) / (b1 + b0)` with `red` and `nir`
listed as the search assets. The parser takes the four arithmetic operators,
unary minus, parentheses, the comparisons `< <= > >= == !=` yielding 1.0 or 0.0,
and `sqrt`, `abs`, `min`, `max`, `pow`, `log`, `exp` and a three-argument
`where`, which is enough for EVI, SAVI, NBR and a masked index without new code.

```
geoplumb/crates/geoplumb/src/elements/band_math.rs
```

Terrano carries one index helper of its own, `RasterStack::normalized_difference`,
used where a stack is already in memory.

There is no `terrano-core/src/spectral.rs` and no named `ndvi`, `ndwi`, `evi` or
`savi` function anywhere.

### Phase 3: Time Series Analysis (done, in Terrano and geoplumb)

```
terrano-core/src/timeseries.rs
```

`RasterStack` holds the layers and their timestamps and computes composites
(mean, median, min, max, standard deviation), a per-pixel linear trend with its
coefficient of determination, change detection over a threshold, a z-score
anomaly against the stack mean, and phenology metrics. Seasonal decomposition is
the one listed capability that does not exist.

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

### Phase 4: EO Catalog Ingest Pipeline

**Data sources to support:**

| Source | Format | Coverage | Resolution | Cost |
|--------|--------|----------|------------|------|
| Sentinel-2 (Copernicus) | COG via STAC | Global | 10m | Free |
| Landsat 8/9 (USGS) | COG via STAC | Global | 30m | Free |
| NAIP (USDA) | COG | US | 0.6m | Free |
| Planet | COG | Global | 3-5m | Paid |
| Maxar/WorldView | GeoTIFF | Global | 0.3m | Paid |

**Pipeline:**
1. Search external STAC catalogs (e.g., `earth-search.aws.element84.com`)
2. Register items in Ptolemy's STAC catalog (metadata only)
3. Download COGs to S3 on demand (lazy fetch)
4. Serve tiles via Terrano COG tiler through Fenestra

Steps 1 and 4 are done by another route. geoplumb's STAC source searches the
api per pulled window, pages to the end of the results, and reads the assets it
finds over HTTP range requests, so `geoplumb-server` serves tiles from external
items with nothing copied and nothing registered first. The platform stack's
`containers/geoplumb/layers.toml` runs that against `cop-dem-glo-30` and
`sentinel-2-l2a` on `earth-search.aws.element84.com`.

Steps 2 and 3 are not built. Nothing writes items into Ptolemy's STAC catalog,
which is read only, and nothing copies an external asset into S3, so every pull
of a cold window costs the range requests again. geoplumb's own memory and disk
caches are what stands in for step 3.

### Phase 5: Cloud-Scale Processing

**For large-area analysis:**
- Dask-style chunked raster processing (process tiles in parallel)
- SQS job queue for tile-level processing tasks
- Output to COG in S3

**Integration with existing infrastructure:**
- Use existing SQS queues (tile-processing queue)
- Store results as COG in S3 tile bucket
- Register outputs in STAC catalog

None of this is built. geoplumb computes windows in parallel inside one process
and its `pyramid` example materializes a tile pyramid from the same graph, but
no job leaves the process. The SQS queues and the tiles S3 bucket the platform
profile creates have no consumer, as the README says.

## Roadmap

| Phase | State | Deliverable |
|-------|-------|-------------|
| 1 | Done | COG writer, read-only STAC API, COG tile serving from `geoplumb-server` |
| 2 | Done | Band math as one expression op, no per-index functions |
| 3 | Done | `RasterStack` in terrano, composites and zonal series in geoplumb |
| 4 | Partly done | External STAC search and serving in geoplumb, no Ptolemy registration and no S3 copy |
| 5 | Not started | Cloud-scale distributed processing |

## Dependencies

Phase 2 needed no new dependency: the expression parser is hand-written in
geoplumb.

Phase 3 needed no `chrono` either. `RasterStack` timestamps are `f64`, any
monotonic sequence, and geoplumb's own `parse_rfc3339` reads the interval on a
request into milliseconds.

Phase 4's HTTP client is `reqwest` in `geoplumb`, not a new ingest crate.

## Integration Points

- **GeoLang AI Agent**: "Show me NDVI change in this area over the last year" → queries STAC → fetches COGs → computes NDVI → renders in ViewTopia
- **ViewTopia**: geoplumb tiles reach the viewer through the platform proxy's `/plumb/*` route, and the timelapse panel drives the `?t=` interval
- **Geodukt ETL**: Spatial ETL pipelines can include EO processing steps
- **TileTopia**: 3D terrain from DEM COGs
