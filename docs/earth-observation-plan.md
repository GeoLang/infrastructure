# Earth Observation (EO) Architecture Plan

## Vision

A cloud-native Earth Observation pipeline for the GeoLang suite, enabling satellite imagery cataloging, analysis, and time-series processing comparable to Google Earth Engine.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     GeoLang EO Stack                     │
├──────────┬──────────┬──────────┬──────────┬──────────────┤
│ STAC API │ COG Tiler│ Band Math│ Time     │ ML Feature   │
│(Ptolemy) │(Terrano) │(Terrano) │ Series   │  Extraction  │
│          │          │          │(new)     │ (Panoptes)   │
├──────────┴──────────┴──────────┴──────────┴──────────────┤
│                    EO Catalog Service                     │
│              (new crate or extend Ptolemy)                │
├──────────────────────────────────────────────────────────┤
│                    Object Storage (S3)                    │
│              Cloud Optimized GeoTIFFs (COG)               │
└──────────────────────────────────────────────────────────┘
```

## Components

### Phase 1: Foundation (existing + extensions)

| Component | Repo | Status | Work Needed |
|-----------|------|--------|-------------|
| **STAC Catalog API** | Ptolemy | ✅ Done | Add STAC Collection CRUD, item creation endpoints |
| **COG Writer** | Terrano | ✅ Done | Completed (tiled, overview pyramids) |
| **COG Tile Server** | Terrano | 🟡 Partial | Add HTTP range-request handler for serving individual tiles from COG files over HTTP; integrate with Fenestra's tile serving framework |
| **Raster Algebra** | Terrano | ✅ Done | Has unary/binary ops, hillshade, slope, aspect |
| **AI Feature Extraction** | Panoptes | ✅ Done | Segmentation, detection, change analysis |

### Phase 2: Spectral Analysis (new module in Terrano)

```
terrano-core/src/spectral.rs
```

**Band math and vegetation indices:**
- NDVI (Normalized Difference Vegetation Index)
- NDWI (Water Index)
- EVI (Enhanced Vegetation Index)
- NBR (Normalized Burn Ratio)
- SAVI (Soil-Adjusted Vegetation Index)
- Custom band math expressions (`(B4 - B3) / (B4 + B3)`)

**Implementation:**
```rust
pub fn ndvi(nir: &Raster, red: &Raster) -> Raster
pub fn ndwi(green: &Raster, nir: &Raster) -> Raster
pub fn evi(nir: &Raster, red: &Raster, blue: &Raster) -> Raster
pub fn band_math(bands: &[&Raster], expression: &str) -> Result<Raster, Error>
```

### Phase 3: Time Series Analysis (new module in Terrano)

```
terrano-core/src/timeseries.rs
```

**Capabilities:**
- Temporal composites (median, max NDVI, cloud-free mosaic)
- Change detection between two dates
- Trend analysis (linear regression per pixel over time)
- Seasonal decomposition
- Anomaly detection (deviation from multi-year mean)

**Implementation:**
```rust
pub struct RasterTimeSeries {
    pub rasters: Vec<(DateTime<Utc>, Raster)>,
}

impl RasterTimeSeries {
    pub fn composite_median(&self) -> Raster
    pub fn composite_max(&self) -> Raster
    pub fn trend(&self) -> (Raster, Raster)  // (slope, r²)
    pub fn change_detection(&self, t1: usize, t2: usize) -> Raster
    pub fn anomaly(&self, index: usize) -> Raster
}
```

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

### Phase 5: Cloud-Scale Processing

**For large-area analysis:**
- Dask-style chunked raster processing (process tiles in parallel)
- SQS job queue for tile-level processing tasks
- Output to COG in S3

**Integration with existing infrastructure:**
- Use existing SQS queues (tile-processing queue)
- Store results as COG in S3 tile bucket
- Register outputs in STAC catalog

## Roadmap

| Phase | Timeline | Deliverable |
|-------|----------|-------------|
| 1 | Now | COG writer ✅, STAC API ✅, COG tile serving endpoint |
| 2 | Short-term | Spectral indices module (NDVI, NDWI, EVI, band math) |
| 3 | Medium-term | Time series analysis, change detection |
| 4 | Medium-term | External STAC catalog ingest (Sentinel-2, Landsat) |
| 5 | Long-term | Cloud-scale distributed processing |

## Dependencies

Phase 2 requires only `terrano-core` (no new dependencies).

Phase 3 adds `chrono` to `terrano-core` for temporal indexing.

Phase 4 adds an HTTP client (`reqwest`) to `geokode-ingest` or a new `eo-ingest` crate for fetching external STAC catalogs.

## Integration Points

- **GeoLang AI Agent**: "Show me NDVI change in this area over the last year" → queries STAC → fetches COGs → computes NDVI → renders in ViewTopia
- **ViewTopia**: COG tiles served through existing tile infrastructure
- **Geodukt ETL**: Spatial ETL pipelines can include EO processing steps
- **TileTopia**: 3D terrain from DEM COGs
