# Video caption project performance audit

Date: 2026-11-06

## Summary

The main render-time cost is the current export architecture. It renders a transparent caption overlay in Chromium once per output frame, exports each frame as a PNG screenshot, then streams those PNGs to FFmpeg for compositing and H.264 encoding. At 30 fps this means 1,800 browser screenshots per minute of source video, with a browser-to-Python-to-FFmpeg handoff for every frame.

The two recorded end-to-end runs (both 15.723 seconds, 360x640) show edited re-render jobs taking 23.927 and 24.491 seconds. The observed rendering/encoding windows were 19.214 and 18.322 seconds, or 80.3% and 74.8% of each edited job. These are useful directional results, but are old, short-clip samples measured through one-second job polling. They do not establish current performance across device sizes or longer videos.

**Recommended direction:** keep the current Flutter renderer as the visual reference, but prototype a direct FFmpeg/libass path for final exports. The project already has ASS generation and an FFmpeg ASS render path. If that can be brought to visual parity for supported caption styles, it removes per-frame browser screenshots from export. If parity is not acceptable, optimize and benchmark the existing frame pipeline before changing encoders or adding hardware requirements.

## Current pipeline

1. The worker downloads and probes the source video, extracts 16 kHz mono FLAC, and sends audio to Gemini.
2. A shared Flutter scene is built into the worker image and opened in headless Chromium.
3. For each of `ceil(duration * 30)` frames, Python updates the scene time and asks Chromium for a transparent PNG screenshot.
4. Python writes the PNG bytes to FFmpeg's `image2pipe`; FFmpeg scales/pads the source, composites the overlay, converts to yuv420p, encodes H.264, and muxes AAC audio.
5. The worker probes and uploads the output.

The corresponding implementation is in [flutter_render_service.py](backend/services/flutter_render_service.py), [render_scene.py](backend/services/render_scene.py), [ffmpeg_service.py](backend/services/ffmpeg_service.py), and [tasks.py](backend/workers/tasks.py).

## Findings by impact

### 1. Per-frame Chromium screenshot pipeline dominates export time — high confidence

`FPS` is fixed at 30. `render_scene()` loops over all frames; `capture_frames()` performs a Playwright `page.evaluate()` and a PNG `page.screenshot()` for each frame. The PNG is then written to a pipe and decoded again by FFmpeg. This imposes per-frame browser protocol and PNG encode/decode costs in addition to video work. At the configured maximum duration of one hour, this is up to 108,000 screenshots per export.

The logs already capture frame count, screenshot time, PNG byte count, FFmpeg progress, and total render duration. However, the stored benchmark reports currently available in the repository are from October and do not include those finer measurements.

**Best long-term solution:** use the existing `build_ass_subtitle()` / `render_captions()` path as the export fast path, then close the visual gap between the ASS templates and the Flutter scene. This asks FFmpeg to render text and effects during the video pass instead of transferring a full transparent image for every frame. Keep Flutter rendering for editor preview and use image-diff/representative clips to define acceptable export parity. The project README currently says export and preview use the same Flutter scene, so this is a deliberate product tradeoff that needs visual acceptance criteria.

**Fallback if parity must stay pixel-identical:** retain Flutter export and profile the current frame path on representative 720p, 1080p, and 4K inputs. Measure wall time and CPU per frame. Test lower-resolution render surfaces only if text quality remains acceptable at final output size. PNG is lossless and supports transparency, so replacing it with JPEG would break overlay quality/transparency.

### 2. Renderer is serialized within each Celery worker process — high confidence

`_scene_runtime` is one process-wide `_SceneRuntime`, and `use()` holds a single lock over the entire render. Docker starts each worker with Celery concurrency 2, but two render jobs in the same worker process cannot use Chromium concurrently. One job can wait for the lock while occupying a Celery slot. Increasing Celery concurrency alone will not increase render throughput and may increase memory and queueing.

**Recommendation:** make renderer concurrency explicit. First measure whether jobs wait on the renderer lock. Then choose either one render at a time per worker (predictable CPU/memory) or a small bounded renderer pool sized to the host. Add separate render-worker capacity rather than increasing general task concurrency blindly.

### 3. Chromium is forced onto SwiftShader software graphics — likely cost, needs measurement

Chromium launches with `--use-angle=swiftshader`, which selects software WebGL. This makes rendering portable in a container without a GPU, but Flutter's browser renderer and screenshot path can then consume substantial CPU. Do not simply remove it: many deployments have no usable GPU, and an unsupported hardware path can fail or vary across hosts.

**Recommendation:** benchmark the current software path against an optional GPU-enabled worker image on actual deployment hardware. Treat GPU rendering and hardware H.264 encoding as separate experiments: GPU encoding only speeds FFmpeg's encoder and will not eliminate per-frame Flutter rendering or PNG transfer.

### 4. “Encoder drain” metric does not represent total FFmpeg work — measurement gap

Frame capture and pipe writes happen while FFmpeg is already decoding, compositing, and encoding. The `encoder_drain` timer starts only after all screenshots are written and stdin is closed. FFmpeg backpressure can also make screenshot or pipe-write calls wait for downstream processing. Therefore `frame_capture`, `pipe_write`, and `encoder_drain` are useful phase observations but are not independent additive costs and must not be interpreted as a clean encoder-versus-renderer split.

**Recommendation:** record total render wall time and FFmpeg progress/CPU samples, and add a controlled capture-only run and encode-only run for diagnostic benchmarks. Keep concurrent pipeline timing as the production metric. Record lock wait separately from browser startup. Compare medians across repeated runs.

### 5. H.264 quality preset has a large speed/size tradeoff — known configuration

Standard uses `libx264 -preset veryfast -crf 18`; high uses `-preset slow -crf 16`. The “high” option will encode more slowly by design. Standard is already configured for speed, so changing CRF/preset alone is unlikely to approach the gains of removing the per-frame browser transport. FFmpeg documents that filter graph threading and codec threading are separate controls; this pipeline fixes complex-filter threads at 2 and leaves x264 threads on auto. Under CPU limits or multiple workers, measure CPU saturation rather than assuming more threads help.

**Recommendation:** preserve `veryfast` as the default. Make the slower high-quality behavior clear in settings. Benchmark `faster`/`ultrafast` only against file size and visual quality on hard cases (fine text, gradients, motion). Try optional `h264_nvenc` only where supported, with a software fallback and separate quality validation.

### 6. Progress reporting adds database work during rendering — low-to-medium impact

The worker calls the progress callback about once per second. Each update checks cancellation by refreshing/querying the job, then commits progress. This provides useful UX and cancellation responsiveness, but a one-hour job can trigger thousands of database round trips. It is unlikely to explain the measured 18-second render on a short clip, but it adds load at scale.

**Recommendation:** keep cancellation responsive while rate-limiting persisted progress updates (for example every 2–5 seconds or a meaningful percentage change), and always persist stage boundaries and completion. Measure before changing the interval.

### 7. Initial transcription latency remains a large non-render stage

The historical reports show Gemini speech analysis at 23.719–33.990 seconds, around half of initial-processing time. Edited re-renders skip this stage. This is a separate optimization track from export speed; switching providers or changing chunk/concurrency strategy should be based on the current Gemini diagnostics and accuracy/cost requirements.

### 8. Some async upload finalization performs synchronous object-storage I/O

`finalize_upload()` is async but calls synchronous `storage_service.upload_file()` before returning. This can block the FastAPI event loop while a source upload is copied to object storage. Historical upload completion was about two seconds, so this is a responsiveness issue rather than the main export bottleneck. Use a threadpool or async S3 client if upload concurrency becomes a problem.

## Optimization plan

1. **Read current render diagnostics first.** In development, the authenticated `GET /api/diagnostics/jobs/{job_id}/render` endpoint returns the recorded metrics. Compare `derived.capture_percent`, `encoder_drain_percent`, PNG MB/s, `video_seconds_per_render_second`, output resolution, quality preset, and render total. Treat capture and drain as overlapping pipeline observations.
2. **Add lock-wait measurement and a representative baseline.** Run repeated standard-quality exports at 15 seconds, 1 minute, and 5 minutes at 720p/1080p (and 4K only if supported). Capture CPU, memory, and output bytes. Report median and p95.
3. **Prototype an ASS export path.** Compare visual outputs against the Flutter renderer for every preset family, RTL text, word highlighting, motion, aspect ratio, and user style overrides. Adopt only after agreeing on acceptable differences.
4. **If ASS parity is insufficient, profile the browser pipeline.** Test bounded renderer pools, a lower resolution overlay raster surface, and optional GPU workers independently. Measure output quality and resource use along with time.
5. **Tune encoder presets last.** Compare standard `veryfast` with faster presets and supported hardware encoders on the same corpus. Expose only options whose size/quality tradeoff is acceptable.
6. **Tune worker scheduling.** Size render concurrency from measured per-job CPU/RAM and prevent long render jobs from blocking transcription tasks in the same pool.

## What the current evidence cannot establish

- The two recorded benchmarks are short and from October 2026; they are not a current multi-resolution performance baseline.
- No current worker CPU, memory, disk, or GPU samples are stored in the markdown reports.
- No numeric result can be promised for the proposed optimizations before benchmarking on the deployment host.
- The fastest architecture depends on whether exact Flutter preview/export parity is a hard requirement.

## Web references

- [Flutter web rendering architecture](https://docs.flutter.dev/platform-integration/web): Flutter web uses browser graphics APIs through CanvasKit and Skwasm; the choice of renderer and browser environment matters.
- [Flutter rendering performance](https://docs.flutter.dev/perf/rendering-performance): Flutter recommends profiling release/profile behavior and measuring rendering work rather than assuming widget-level optimizations apply.
- [Playwright screenshot API](https://playwright.dev/python/docs/screenshots): screenshots return image bytes and support transparent backgrounds; screenshot capture is still an image serialization step.
- [FFmpeg documentation](https://ffmpeg.org/ffmpeg.html): filter-complex thread count is distinct from codec thread settings; FFmpeg provides separate controls for graph execution and encoding.
- [FFmpeg codec documentation](https://www.ffmpeg.org/ffmpeg-all.html): encoder presets and CRF are quality/performance tradeoffs, and available encoder options depend on the codec/build.
