# Modal deployment verification — 2026-11-11

App: https://touseef12345bhatti--video-caption-app-web.us-east.modal.run/

Dashboard: https://modal.com/apps/touseef12345bhatti/main/deployed/video-caption-app

Modal hosts the frontend, API, processing jobs, export jobs, and scheduled
cleanup. The existing PostgreSQL database, private Cloudflare R2 storage,
and Gemini service remain in use.

## Verified live

| Check | Result |
|---|---|
| Database migrations | Completed successfully; schema was already current |
| Flutter web app and API health | Passed |
| Browser login screen and frontend assets | Loaded successfully |
| Registration and authenticated API access | Passed using a temporary test user |
| Database, Modal functions, private storage, FFmpeg, temporary disk | All dependency checks passed |
| Resumable upload and status | Chunk persisted and reported correctly |
| Gemini transcription | Completed on a synthetic spoken clip |
| Caption edit and saved render snapshot | Passed |
| Modal export worker | Completed |
| GPU | NVIDIA A10, driver 610.57.04 |
| NVIDIA encoding | Actual capability probe passed; export diagnostics report `h264_nvenc` |
| Signed export download | HTTP 200; 268,131 bytes |
| Downloaded media | H.264 video, AAC audio, 320 × 240, 30 fps, 3.000 seconds |
| Browser video decode | Loaded all required data; correct dimensions and duration |
| Temporary test data | Test users, projects, source files, exports, and playback objects removed |

The GPU configuration prefers L4 and permits A10/T4 fallbacks. Modal reported
insufficient L4 capacity during the initial check. Allowing alternative GPU
types enabled the export worker to run. A false negative in the original
NVENC check was corrected by using a 320 × 240 test frame; its earlier
64 × 64 frame was below the A10 encoder's supported minimum.

Browser playback was tested from the Modal origin using a private signed video
URL and an HTML video element. The current app opens signed download URLs via
browser navigation. The bucket does not currently permit cross-origin JavaScript
fetches from this origin; those are not used by the app's current download flow.
No bucket policy change was made.

## Timing limits

The final synthetic clip was three seconds long at 320 × 240. The caption job
took 83.234 seconds and the export job took 31.281 seconds as observed by API
polling. Those totals include scheduling, initialization, network/storage, and
database work. The renderer's internal elapsed time was 12.362 seconds, including
3.970 seconds starting Chromium, 3.544 seconds capturing frames, and 0.623 seconds
for full-resolution compositing and encoding.

These small deployment smoke tests establish correctness, not a speedup against
the previous host. Browser graphics and screenshot capture still use the existing
software path. Representative repeated exports are needed to compare latency,
quality, file size, and cost across CPU and GPU configurations.

## Local checks

- Complete backend suite with Modal dispatch selected: 84 passed, 1 skipped.
- Focused encoder tests after the probe correction: 4 passed.
- Flutter frontend and shared renderer release builds: passed locally and on Modal.
- Deployment definitions import and PowerShell deployment script parsing: passed.
