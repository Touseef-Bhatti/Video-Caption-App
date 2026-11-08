# Video caption pipeline analysis: run 2

## Result

Run `2026-10-14T15-52-57-125Z` completed the complete browser workflow successfully: upload, default processing, automatic Urdu detection, caption creation, one text edit, save, edited re-render, and creation of two exports.

| Item | Result |
|---|---:|
| Input | `videoplayback.mp4` |
| File size | 864,445 bytes |
| Resolution | 360 x 640 |
| Video duration | 15.723 s |
| Caption segments | 3 |
| Total workflow | 76.007 s |
| Initial processing | 48.167 s |
| Edited render job | 24.491 s |
| Initial processing real-time factor | 3.064x |
| Edited render real-time factor | 1.558x |

## Initial processing

| Observed stage | Time | Share |
|---|---:|---:|
| Queue wait | 1.041 s | 2.2% |
| Preparing video | 2.026 s | 4.2% |
| Analyzing speech | 23.719 s | 49.2% |
| Rendering and encoding | 18.288 s | 38.0% |
| Finalizing and storing | 3.080 s | 6.4% |

`Extracting audio` and `Creating captions` transitioned between browser polls and were not observed as separate stages. Their time is included inside adjacent observed windows. Exact separation requires worker-side timestamps rather than one-second job polling.

## Edited re-render

| Observed stage | Time | Share |
|---|---:|---:|
| Queue wait | 1.019 s | 4.2% |
| Preparing source | 2.034 s | 8.3% |
| Rendering and encoding | 18.322 s | 74.8% |
| Finalizing and storing | 3.103 s | 12.7% |

The caption edit API call took 0.069 seconds and the render request took 0.022 seconds. The actual render and encode stage remained the dominant cost.

## Comparison with run 1

| Measurement | Run 1 | Run 2 | Change |
|---|---:|---:|---:|
| Total workflow | 94.446 s | 76.007 s | -19.5% |
| Initial processing | 67.149 s | 48.167 s | -28.3% |
| Speech-analysis window | 33.990 s | 23.719 s | -30.2% |
| Initial render and encode | 27.988 s | 18.288 s | -34.7% |
| Edited render job | 23.927 s | 24.491 s | +2.4% |
| Edited render and encode | 19.214 s | 18.322 s | -4.6% |
| Upload init and chunk | 0.167 s | 0.093 s | -44.3% |

Run 2 saved 18.439 seconds overall. Most of the improvement came from faster speech analysis and the initial render. The edited re-render was effectively stable; its render stage improved slightly, while queue, preparation, and finalization took longer.

## Browser resources

The report collected 75 browser heap samples. Used JavaScript heap ranged from 3.22 MiB to 6.81 MiB and ended below its starting value after garbage collection. This run shows no browser-memory growth signal.

Backend and worker CPU, memory, disk I/O, GPU use, and cumulative CPU time were not measured by the browser. Those require the host-side performance harness or server-side instrumentation.

## Remaining issue

The final export was rendered and its signed URL was returned, but browser download measurement failed with `Failed to fetch`. Storage CORS is still preventing the test page from reading and counting the downloaded bytes.

## Conclusion

The corrected stage-duration calculation is working. Run 2 shows that speech analysis and rendering/encoding remain the two main costs, accounting for approximately 87% of initial processing. More runs are needed before treating the improvement as a stable benchmark because Gemini latency and local render contention vary between runs.
