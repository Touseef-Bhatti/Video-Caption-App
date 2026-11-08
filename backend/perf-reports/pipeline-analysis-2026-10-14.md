# Video caption pipeline analysis

## Run outcome

Run `2026-10-14T15-36-03-989Z` completed the full workflow: upload, default caption processing, one caption edit, save, edited re-render, and export creation.

| Item | Result |
|---|---:|
| Input | `videoplayback.mp4` |
| File size | 864,445 bytes (844.18 KiB) |
| Resolution | 360 x 640 |
| Video duration | 15.723 s |
| Caption language | Urdu (auto-detected) |
| Caption segments | 3 |
| Total workflow time | 94.446 s |
| Initial processing | 67.149 s |
| Edited re-render | 23.927 s |
| Exports created | 2 |

The initial pipeline ran at 4.27 wall-clock seconds per second of source video. The edited re-render ran at 1.52 wall-clock seconds per second of source video. The full workflow, including upload and editor API operations, ran at 6.01 wall-clock seconds per second of source video.

## Corrected initial processing stages

These durations were reconstructed from the recorded stage transition timestamps. Each boundary has up to about one polling interval of uncertainty.

| Stage | Observed time | Share of initial processing |
|---|---:|---:|
| Queue wait | 1.020 s | 1.5% |
| Preparing video | 1.021 s | 1.5% |
| Gemini speech analysis | 33.990 s | 50.6% |
| Create and save captions | 1.119 s | 1.7% |
| Render frames, encode, and mux | 27.988 s | 41.7% |
| Finalize and store export | 1.996 s | 3.0% |

Speech analysis was the largest stage. Rendering and encoding was the second largest. Together they accounted for about 92.3% of initial processing time.

Audio extraction completed between polls and was not observed as a separate state, so this run cannot assign it a trustworthy standalone duration.

## Corrected edited re-render stages

| Stage | Observed time | Share of edited re-render |
|---|---:|---:|
| Queue wait | 1.670 s | 7.0% |
| Prepare source | 1.997 s | 8.3% |
| Render frames, encode, and mux | 19.214 s | 80.3% |
| Finalize and store export | 1.036 s | 4.3% |

The one caption change was saved in 0.085 seconds. Requesting the re-render took 0.104 seconds. Most of the edited workflow time was inside rendering and encoding.

## Upload and API activity

| Operation | Time |
|---|---:|
| Create upload session | 0.115 s |
| Upload one 864,445-byte chunk | 0.051 s |
| Observed chunk throughput | 135.866 Mbps |
| Assemble, validate, store, and enqueue | 2.048 s |
| Load captions | 0.018 s |
| Load preview URL | 0.123 s |
| Save caption change | 0.085 s |
| Request edited render | 0.104 s |
| List exports | 0.018 s |
| Get export download URL | 0.021 s |

The report recorded 76 HTTP requests. Sixty-seven were job-status polls. Their aggregate request time was 5.926 seconds, including one 4.891-second outlier; this is request latency observed by the page and does not add linearly to the asynchronous worker duration.

## Resource observations

The browser collected 95 JavaScript heap samples. Used heap ranged from approximately 3.22 MiB to 7.90 MiB and ended near 3.55 MiB. The fall during the run is consistent with browser garbage collection, so this single run does not indicate a browser memory leak.

The browser report did not measure backend or worker CPU, RAM, disk I/O, GPU use, cumulative CPU time, or peak process count. Browser security prevents the page from reading those host and container metrics. The Python performance harness can collect Docker CPU and memory snapshots when it runs from the host.

## Measurement gaps found

1. The original stage table displayed only the final progress interval for stages that emitted multiple progress updates. It reported initial rendering as 1.986 seconds and edited rendering as 1.037 seconds. The correct observed windows are 27.988 and 19.214 seconds. The web page and Python harness have been corrected.
2. Flutter frame generation and FFmpeg video encoding run concurrently through a frame pipe. The current worker exposes them as one `Rendering video` stage, so this run cannot provide trustworthy separate frame-render and encode durations.
3. Final export download timing was requested but was not recorded. The browser returned `Failed to fetch`, consistent with object-storage CORS blocking the cross-origin read. Export creation still completed.
4. Stage boundaries are estimates from one-second polling. An individual boundary can be early or late by roughly one polling interval.
5. This is one run on a short video. It is useful for locating large costs, but averages and percentiles require repeated runs across several video lengths and resolutions.

## Priorities

1. Improve Gemini latency and resilience because transcription consumed half of initial processing and recent runs also encountered upstream 503 responses.
2. Optimize the shared renderer because rendering and encoding consumed 41.7% of initial processing and 80.3% of edited re-render time.
3. Add worker-side sub-timers around scene startup, frame capture, FFmpeg drain/encode, output validation, and storage upload if separate render and encode measurements are required.
4. Enable storage CORS for the frontend origin or proxy the export through the backend to measure final download time in the browser.
5. Run the host-side performance harness for Docker CPU and memory measurements, then repeat enough runs to calculate median and tail latency.
