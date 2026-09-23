# Changelog

- 2026-09-23: the preview pins geolang v0.1.7, which carries the chat spend caps, the `/upload` caps and the viewer eval fixes, and `geolang_upload_limits` passes the `GEOLANG_UPLOAD_*` caps to geolang-api.
- 2026-09-23: the platform profile gives the GeoLang executor 8192 MiB, enough for its two concurrent 3072 MiB tool runs.
- 2026-09-23: every service gets a morning scale-up schedule at `morning_scale_up_hour`, 08:00 by default in the `nightly_scale_down` timezone.
- 2026-09-23: `enable_demo_landing_page` serves a static page at `/try/` from S3 through CloudFront. Its start button calls a wake Lambda behind a public function URL, and an idle Lambda stops every service after thirty minutes with no `/chat/agui` call outside the demo hours. The preview turns it on.
