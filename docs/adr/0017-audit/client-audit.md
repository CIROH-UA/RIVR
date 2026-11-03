# RIVR client-side load-latency audit (analyst: client scope)

Repo: /Users/jerson/developer/ciroh-rivr-app/RIVR @ `321a688` (branch `development`)
Flutter 3.47.1 / Dart 3.13.1. Host: darwin 25.6.0.

## Standing confounds I am tracking
- **C1 Pre-existing instrumentation.** HEAD already contains `1bfddbb Find the root
  cause of slow global river loads` and `9930b43 Merge chore/instrument-geoglows-latency`.
  So the code I measure is NOT the code the owner complained about; some of it
  may already be partly fixed/instrumented. I have deliberately not read
  docs/adr/0017-*. Every finding below is from the code as it stands at 321a688.
- **C2 Debug vs release.** Everything I run in a simulator/test is a DEBUG JIT
  build. Dart CPU work (jsonDecode, unit conversion, widget build) is multiples
  slower in debug. Any app-side CPU number must be labelled debug and, where it
  matters, re-measured in profile/release.
- **C3 Network from this Mac != network from a phone.** curl timings below are
  wired/wifi from the dev machine, no cellular, no TLS cold start, no iOS
  URLSession. They bound the *server* contribution only.
- **C4 Warm caches.** NOAA/CDN caches, the app's own disk cache, and the
  `_unfilteredCache` in NoaaApiService all make a second measurement cheaper.
  Cold vs warm is called out per measurement.
- **C5 Mock vs real services.** `test_app.dart` wires mocks; a mock answers in
  microseconds and hides every network finding. Call-count work done under mocks
  is labelled as such.

---

## F1 — MEASURED: `?series=long_range` is empty for every reach tested, and the
## app answers that by fetching the biggest payload the API serves.

2026-11-03T14:12Z. n=6 reach ids, 1 sample each (counts as a *presence* test, not
a latency test).

`GET /nwps/v1/reaches/<id>/streamflow?series=long_range` returned HTTP 200 with
`"longRange": {}` for all 6 of 6 ids tried (18471070, 10376596, 23021904,
10092062 — which all DO have medium-range data — plus 10376293 and 19020084,
which return 66-byte bodies for every series).

`NoaaApiService.fetchForecast` treats an empty target section as a failure of the
filtered endpoint and calls `_fetchWithUnfilteredFallback`, i.e.
`GET /reaches/<id>/streamflow` with NO series filter and `_longTimeout`.

MEASURED, n=1, cold: that unfiltered call for 18471070 was **16.1 s / 188,739 B**,
and its `longRange` section was **still `{}` (2 bytes of JSON)**. So the fallback
cost the largest request in the app and returned nothing usable.

Implication (INFERRED from the code path, not yet observed in a running app):
every NWM forecast-page open pays one extra ~190 KB request that cannot succeed,
and the resulting entry is cached under the `longRange` key carrying the whole
unfiltered body (incl. the ~99 KB mediumRange section), because
`NwmDataSource.fetch` stores `longPayload` verbatim.
Cheapest settling test: run the app against a real network and count
`Fetching unfiltered forecast:` lines in AppLogger per forecast-page open. Queued.

Section sizes of the unfiltered body (18471070, pretty-printed JSON bytes):
reach 374 · analysisAssimilation 3,209 · shortRange 1,233 · **mediumRange 98,789**
· longRange 2 · mediumRangeBlend 15,835.

## F2 — MEASURED (code reading, not yet runtime): `currentFlow` and `shortRange`
## are the same HTTP request under two different cache keys.

`NwmDataSource.fetch`:
- `ForecastProduct.currentFlow` -> `_api.fetchCurrentFlowOnly(id)` which is
  literally `fetchForecast(id, 'short_range', isOverview: true)`.
- `ForecastProduct.shortRange` -> `_api.fetchForecast(id, 'short_range')`.

Same URL (`AppConfig.getForecastUrl(id,'short_range')`); the only differences are
timeout (15 s vs 20 s) and an `X-Request-Priority: high` header.
`RiverDataRepository._inFlight` dedupes by `key.storageKey`, and the two products
have different storage keys, so **no dedupe happens**.
`ReachForecastPage._load()` reads `currentFlow`; `ReachDataProvider.loadAllData`
reads `shortRange`. Both run on one forecast-page open.
Status: INFERRED that this produces 2 live requests per open — needs the runtime
request count to be MEASURED. Queued with F1.

## F3 — MEASURED (code reading): retry/timeout budget per request
`_httpGetWithRetry(maxRetries: 2)` = up to 3 attempts, retrying on 5xx and on
TimeoutException, with a 1 s then 2 s sleep. Timeouts: `_quickTimeout` 15 s
(overview), `_normalTimeout` 20 s, `_longTimeout` (unfiltered fallback) — value
still to be read.
Worst-case single-product wall time: 15+1+15+2+15 = **48 s** for an overview
product, 20+1+20+2+20 = **63 s** for a normal one, before the caller sees an error.
INFERRED: this is the tail the owner feels as "never loads". Not yet observed.

---

## F4 — MEASURED: one NWM river opened from the map and then viewed as a
## forecast costs **8 HTTP requests**, two of which are byte-identical.

Harness: `test/_audit_scratch/` (throwaway). Real `NoaaApiService` (real network,
counting `http.Client`), real `ForecastService`, real `NwmDataSource`, real
`RiverDataRepository`; in-memory `IRiverDataCache` and `IReachCacheService` so
every iteration is a genuinely COLD open. `HttpOverrides.global = null` so
flutter_test does not stub the socket.
Confounds controlled: fresh Harness per reach per iteration (no app cache carry-
over); 4 different reach ids so one bad reach cannot carry the result; URLs
recorded verbatim so a "duplicate" claim is a string comparison, not a guess.
Confound NOT controlled and acknowledged: this is the Mac's network, Dart VM,
debug mode (C2/C3). Request COUNTS are build-independent; the ms are not.

2026-11-03T14:14Z, n=4 reaches x 1 iteration (counts stable across all 4; the
timings are n=4 and quoted as a range).

**S1 — map tap, detail sheet only.** 3 requests, 3,389-3,398 B total.
  `GET /reaches/<id>` · `GET /reaches/<id>/streamflow?series=short_range`
  · `GET nwm-api.ciroh.org/return-period?comids=<id>`
  All three issued concurrently (start offsets 0-6 ms).
  first-product-landed 283 / ~300 / 331 ms (min/median/max, n=4)
  all-three-settled 822 / 882 / 929 ms (n=4)
  The **return-period call is consistently the slowest of the three** despite
  being the smallest response (175-185 B): 721-928 ms vs 272-316 ms for
  `/reaches/<id>`.

**S2 — the same river, then "View Forecast".** 8 requests, in this order:
  1 `/reaches/<id>`                      526 B   (sheet, reachMetadata)
  2 `...streamflow?series=short_range`  2,687 B  (sheet, currentFlow)
  3 `return-period?comids=<id>`           185 B  (sheet, returnPeriods)
  4 `...streamflow?series=short_range`  2,687 B  **(provider, shortRange — byte-identical to #2)**
  5 `...streamflow?series=long_range`     717 B  (empty section)
  6 `...streamflow?series=medium_range`   717 B  (empty section)
  7 `...streamflow` (unfiltered)        7,859 B  **(fallback for #5)**
  8 `...streamflow` (unfiltered)        7,859 B  **(fallback for #6 — byte-identical to #7)**
  Totals: 23,193-23,343 B, allMs 1,278 / 1,761+2,197 / 2,650 (min/median-ish/max, n=4).
  The forecast page's own `_load()` re-read of the three sheet keys cost **0
  requests** (pageLoadReqs == sheetReqs in all 4) — the shared cache works there.

**F4a MEASURED: #2 and #4 are the same URL under two cache keys.** Confirms F2.
`RiverDataRepository._inFlight` dedupes on `key.storageKey`, and
`nwm__<id>__currentFlow` != `nwm__<id>__shortRange`, so the dedupe cannot see it.
The two cached payloads are the same size to the byte
(`currentFlow=1624`, `shortRange=1624` chars for 18471070), i.e. the app stores
the same series twice and downloads it twice.

**F4b MEASURED: `_fetchUnfilteredForecast` has no in-flight dedupe, so the
fallback stampedes.** #7 and #8 are the same URL, issued 322 ms and 47 ms apart
in different iterations, both 7,859 B. `NoaaApiService._unfilteredCache` is only
written *after* the response lands (30 s TTL), so two fallbacks that overlap —
which is the normal case, because `_loadSectionParallel` fires medium and long
together — both miss and both fetch. Nothing in the repository can catch this:
the stampede is one layer below it, inside the API service.

## F5 — MEASURED: NOAA's medium-range section vanished mid-audit, and that
## doubles the app's request count.

Same reach 18471070, `?series=medium_range`:
  14:12:15Z -> 156,732 B, mediumRange section 98,789 B of JSON (data present)
  14:16:31Z -> 717 B, mediumRange section `{}` (data absent)
  14:16:53Z -> 717 B (sampler), and the unfiltered body had dropped from
               188,739 B to 7,859 B with mediumRange, longRange AND
               mediumRangeBlend all empty.
So upstream drops whole sections for minutes at a time. Client consequence,
MEASURED in F4: when medium-range is absent the app pays requests #6 AND #8; when
it is present it pays #6 (157 KB) and still pays #5+#7 for long range.
This was the confound that was biting me: my first size table (F1) was taken in
a window where medium range existed, and 4 minutes later it did not. **Any
byte/latency number here is only valid with its timestamp.** A 240-minute
sampler (3 reaches x 3 endpoints, 55 s period) is now running to get the
distribution — /tmp/rivr_audit/noaa_sections.tsv.

## F6 — MEASURED: `?series=long_range` was empty on every single observation so
## far (n=6 reaches at 14:12Z, plus the sampler), so the long-range fallback
## fires on every forecast-page open and has never yet returned data.
The unfiltered body's `longRange` was `{}` in all observations too. So requests
#5 and #7 are, so far, pure waste on every open.

---

## F7 — MEASURED: tap-to-rendered-pixel, split into app-side and network.
Method: `flutter drive` on a real booted simulator (iPhone 17 Pro Max,
7770B002-…), DEBUG build, `IntegrationTestWidgetsFlutterBinding`. The measured
action is exactly what the sheet's "View Forecast" button does —
`Navigator.pushNamed(AppRoutes.forecast, ReachArgs(...))` — and the clock starts
on that call. Detector: `_ForecastSkeleton` disappearing from the tree (that is
the frame on which real content first replaces the placeholder), plus
`ReachDataProvider.hasHourly/Daily/ExtendedForecast` for the series.
Fresh GetIt + fresh in-memory caches every iteration, so every iteration is a
cold open. ONE repository registered in GetIt, as production does — note the
repo's own `test_app.dart` builds TWO repositories with TWO caches, which would
have doubled every count; I did not use it.

**MODE=mock (zero-latency fakes replayed from real captured payloads,
including a 157 KB medium-range body) — this is the pure APP-SIDE cost.**
n=5, same reach 18471070, debug build:
  route push -> first frame:        33 / 36 / 101 ms
  route push -> skeleton gone:      212 / 219 / 384 ms
  everything (name, flow, daily):   179 / 184 / 355 ms
Confound: iteration 0 is the outlier in every column (101 / 384 / 355) — JIT
warm-up. Iterations 1-4 are 212-231 ms for skeleton-gone, i.e. the app-side
cost is **~0.21-0.23 s steady-state, in DEBUG**. A release build will be lower,
so treat 0.23 s as an upper bound.

**MODE=real (real NoaaApiService, real network) — the total.** n=5:
  route push -> first frame:    31 / 35 / 70 ms
  route push -> skeleton gone:  393 / 421 / 493 ms
  HTTP requests:                8 in 4 of 5 runs, 7 in the fifth
  HTTP bytes:                   23,237 B x4, and 203,913 B once (see F8)
  Idle frame cadence during the wait: 4,193 pumped frames in 70,009 ms
  = 16.7 ms/frame, i.e. **~60 fps with no jank while loading**.

**So: of the ~420 ms to first real content, ~220 ms is the app and ~200 ms is
the network.** The app is NOT the bottleneck for first paint on a US river.
MEASURED. The thing that is slow is what happens *after* first paint — the
series the user scrolls to (F8) — and the GEOGLOWS path (F10).

## F8 — MEASURED: the medium-range section flaps between full and empty within
## seconds, and the app can throw away the good copy.
From the 4-hour sampler (/tmp/rivr_audit/noaa_sections.tsv) and the drive runs:
- 14:21:48Z reach 23021904 `?series=medium_range` -> 157,194 B, **1,500 data
  points**. At the SAME second its unfiltered `/streamflow` -> 7,849 B,
  mediumRange **0 points**.
- 14:22:47Z the same reach, filtered -> 716 B, 0 points.
So the two endpoints disagree with each other, and each one flaps, inside one
minute.
**The consequence, MEASURED in drive iteration 4:** the two concurrent
unfiltered fallbacks (F4b) hit the same URL 6 ms apart and got **different
bodies** — 7,859 B (mediumRange empty) and 188,739 B (mediumRange full). They
race to write `NoaaApiService._unfilteredCache`, and whichever lands last wins.
So the app can download a full medium-range forecast and then cache the empty
one over it, under both the `mediumRange` and `longRange` keys, with a 6-hour
freshness window. The user sees "no forecast" on a river that has one, and the
app will not look again for up to 6 hours.
That is INFERRED as the user-visible outcome; MEASURED is the two different
bodies from the same URL 6 ms apart, and the absence of any dedupe or
ordering between them.

## F9 — MEASURED, n=48 per endpoint: these calls are priced by ROUND TRIP, not
## by payload. The coordinator's observation holds.
Sequential curl, one reach (18471070), 25 s apart, 2026-11-03T14:2x-15:0xZ:
| endpoint | bytes | total min/median/max (s) | median TTFB |
|---|---|---|---|
| `/reaches/<id>` | 526 | 0.259 / **0.310** / 0.599 | 0.310 |
| `?series=short_range` | 2,668 | 0.259 / **0.274** / 0.668 | 0.274 |
| `return-period?comids=` | 185 | 0.642 / **0.869** / 1.263 | 0.869 |
TTFB == total to three decimals on every row, so **none of this is transfer
time** — it is all server think time. The 185-byte return-period call is
**2.8x the median latency of the 2,668-byte NOAA call** and 14x smaller.
Client consequence: shaving bytes buys nothing; removing a round trip buys
~0.3 s on NOAA and ~0.9 s on the CIROH return-period host. The app currently
makes 8 round trips for one river (F4), 2 of which are exact duplicates.

## F10 — MEASURED: a GLOBAL (GEOGLOWS) river is a completely different shape of
## wait — ONE blocking request, nothing on screen until it lands.
Code: `ReachForecastPage._loadGeoglows()` is a single `await repo.read(
geoglowsForecast)`; `_loading` is cleared only at the end, so there is no
progressive render on this branch at all (contrast the NWM branch's three
independent products). `GeoglowsApiService` uses a **90 s timeout and NO
retry**; one request, one URL, the `geoglows_forecast` Cloud Function proxy.

Drive run, real network, river 760021642, n=4 consecutive:
  route push -> skeleton gone: **9,147 ms**, then 319, 222, 233 ms
  HTTP: exactly 1 request, 21,762 B, every time
  the single request itself: 8,927 ms, then 211, 124, 148 ms
So the same page, same river, same build, is **9.1 s on the first open and
0.22 s on the next three**. A 40x spread, and n=1 would have told either story.

**MEASURED cause: the proxy caches per RIVER, and the cache is what you are
measuring.** Sampler (/tmp/rivr_audit/geoglows.tsv, n=6 so far, 18-minute
cycles so the gen2 function can scale to zero):
  same river re-requested immediately: 0.105 s, 0.113 s (n=2)
  a river the proxy has NOT just served: 8.65 s, 8.26 s, 9.67 s (n=3)
  (the 4th "coldish" sample, 0.128 s, was a river I had probed manually 3
  minutes earlier — a cache hit, and exactly the confound this sampler exists
  to expose)
So for a user tapping a global river nobody has looked at recently, the
measured cost is **~8-10 s with a blank page**. Sampling continues; I will
quote the final n.

## F11 — MEASURED (code + DI reading, not yet runtime): the favourite path and
## the map-tap path are NOT the same, and the difference is structural.
`StoreBackedDataSource` wraps both sources in `forecast_dependencies.dart`, and
its server read is gated: `if (backed != null && !backed.contains(key.storageKey))
return null;` where `backed` is `StoreSubscriptionService.watchedIds`.
- MEASURED by reading `watchedIds` and `documentIdsFor`: those ARE
  `nwm__<id>__<product>` storage keys, so the gate is comparing like with like.
  (I expected a reachId-vs-storageKey mismatch here and there is none.)
- `kStoredProducts` covers currentFlow, shortRange, mediumRange, longRange,
  reachMetadata, returnPeriods for NWM and geoglowsForecast for GEOGLOWS —
  i.e. **every product either page reads**. So a favourite CAN be fully
  store-served.
- A reach tapped on the map is not in `watchedIds`, so it gets a local
  Firestore cache probe (free, local) and then falls through to the live path.
  **Every map tap is a live upstream load, by design.**
INFERRED, not yet measured: that the store is actually populated and the
`store_read_enabled` switch is on, so favourites really are fast in production.
Cheapest settling test: read `storeHealth` (HTTPS, returns
`{status, products[], runs[]}`) and read a few `river_data` documents. Queued.

---

## F12 — MEASURED, n=205 documents: for a FAVOURITED river, medium range and
## long range are NOT served by the store. They go live, exactly like a map tap.
Read-only survey of the production `river_data` collection
(Firestore REST, `mask.fieldPaths` so only metadata came back, gcloud access
token for jersondevs@gmail.com, no writes), 2026-11-03T14:41Z. 205 documents
covering 35 NWM reaches and 4 GEOGLOWS reaches:

| product | fresh | EXPIRED |
|---|---|---|
| currentFlow | 35 | 0 |
| shortRange | 35 | 0 |
| reachMetadata | 35 | 0 |
| returnPeriods | 35 | 0 |
| geoglowsForecast | 4 | 0 |
| **mediumRange** | **0** | **34** |
| **longRange** | **0** | **27** |

Worked example, reach 10092062:
  currentFlow  run 2026-11-03T11:00Z  fetched 1.3 h ago   expires in 0.8 h
  shortRange   run 2026-11-03T11:00Z  fetched 1.3 h ago   expires in 0.8 h
  mediumRange  run 2026-10-28T06:00Z  fetched **145.3 h** ago  **expired 127.3 h ago**
  longRange    run 2026-09-21T06:00Z  fetched **1030.3 h** ago **expired 994.3 h ago**

`StoreBackedDataSource._readStoreFrom` explicitly refuses an expired document
("An expired document is not served") and returns null, so `fetch` falls
through to `_inner.fetch` — the live NOAA path.

**Client consequence, MEASURED from the code path plus this document state:**
opening the forecast page for a FAVOURITE costs the same live NOAA work as a
map tap for the two heavy products — the empty-section flap (F8), the
unfiltered fallback (F1) and its stampede (F4b) all apply. The favourites
*list* is genuinely store-served and fast, because it only needs currentFlow +
reachMetadata + returnPeriods, which are all fresh. So ADR 0011's "969 ms cold
favourites paint" and the owner's "some river takes forever to load" are not in
conflict — they are different surfaces.
This corrects the inference I left open in F11. The store IS populated and the
switch question is moot for these two products: even a resolved, enabled switch
cannot serve an expired document.

**Also MEASURED here: the currentFlow/shortRange duplication (F2/F4a) is
replicated into the store.** `nwm__10092062__currentFlow` and
`nwm__10092062__shortRange` both carry a 3,349-byte payload — the same series,
stored twice, so a favourite pays two Firestore document reads for one series,
and the server pays two writes an hour for it.

Why the two products' documents are stale is a SERVER question and out of my
scope; that it leaves the client on the live path is the client finding.

---

## F13 — MEASURED: GEOGLOWS proxy, final sampler numbers.
/tmp/rivr_audit/geoglows.tsv, 18-minute cycles so the gen2 function can scale
to zero, rotating river ids, 14:20Z-14:57Z.
  river the proxy had NOT just served: 8.26 / 9.01 / 9.67 s (min/median/max, n=4)
  same river re-requested seconds later: 0.105 / 0.113 / 0.118 s (n=3)
  (Two samples labelled "coldish"/"newwarm" came back in 0.113-0.128 s because
  I had probed those rivers minutes earlier — a cache hit, and exactly the
  confound the rotation exists to expose. Excluded from the n=4.)
TTFB == total on every row, so it is all server think time.
Payload 21,596-24,438 B in every case, so payload is not the variable.

## F14 — MEASURED, and a CORRECTION TO MY OWN EARLIER CLAIM: the duplicate
## `short_range` request costs almost no wall time. It costs bytes and load.
I said earlier (from the S2 harness) that the duplicate added 86-609 ms to the
critical path. That was an ARTEFACT OF MY HARNESS, which ran the sheet phase
and the provider phase sequentially. In the real app they overlap: the page's
`_load()` (currentFlow) and the post-frame `provider.loadReach()` (shortRange)
start inside the same frame, and the drive logs show the two identical
`?series=short_range` requests issued 0-6 ms apart.
Extra wall time = the gap between the two identical requests' completion (the
slower gates the provider's fan-out), n=5 drive iterations:
  218 / 5 / 5 / 3 / 3 ms -> median 5 ms, max 218 ms.
Same for the two duplicate unfiltered requests: concurrent, so the wall cost is
the completion gap (iter 0: 103 vs 623 ms -> 520 ms; iter 4: 122 vs 371 ms ->
249 ms), n=2 usable.
So the duplicates are a BANDWIDTH AND UPSTREAM-LOAD defect, not a latency
defect — except when the two copies of the same URL come back DIFFERENT (F8),
which is a correctness defect. Fixing them is cheap and right; it will not make
the page feel faster.

## F15 — NEGATIVE RESULT, MEASURED (n=40 per case, debug): parsing is not a
## factor. ~3 ms against a two-second load.
| what | min | median | max |
|---|---|---|---|
| `jsonDecode`, 157 KB medium-range body | 0.26 ms | 0.29 ms | 4.56 ms |
| `jsonDecode`, 2.7 KB short-range body | 0.01 ms | 0.01 ms | 0.01 ms |
| full `fetchForecast` hop minus the socket (decode + unit conversion), 157 KB | 1.96 ms | 2.19 ms | 14.20 ms |
| same, 2.7 KB | 0.15 ms | 0.17 ms | 0.22 ms |
| `NwmForecastPayload.decode`, 157 KB | 0.93 ms | 0.98 ms | 2.82 ms |
| same, 2.7 KB | 0.02 ms | 0.02 ms | 0.03 ms |
Recorded as a negative result on purpose: "the app is slow because it parses big
JSON on the main isolate" is a plausible theory and it is DEAD. Nothing should be
spent on isolates, streaming parsers or payload trimming for CPU reasons.
Caveat: debug JIT on the host Dart VM. A real iPhone is slower per core, but the
margin here is three orders of magnitude; this does not need re-measuring.

## F16 — METHOD WARNING: `flutter drive` will silently run the PREVIOUSLY
## INSTALLED binary with the PREVIOUS run's dart-defines, exit 0, and report
## "All tests passed".
Observed 2026-11-03. I asked for `--profile`; the build failed with
`Target aot_assembly_profile failed: release/profile builds are only supported
for physical devices`, and `flutter drive` then launched the already-installed
DEBUG app. The test ran, passed, and printed `mode=real geoglows=true` when I
had passed `--dart-define=MODE=mock` and no GEOGLOWS flag at all.
Print the configuration from inside the test on every result line and check it,
or a day's numbers can belong to a different experiment than you think.
Consequence for this audit: I COULD NOT CLEAR THE DEBUG-BUILD CONFOUND AT ALL.
Profile and release builds do not run on the simulator and no physical iPhone
was available. Every app-side timing here is a DEBUG UPPER BOUND.

## F17 — NOT COMPLETED: touch -> sheet content.
A drive test (`drive_tap_sheet_test.dart`) that starts the clock on a real
`tester.tapAt` gesture and presents the production `ReachDetailsBottomSheet`
exactly as `MapPage._onReachSelected` does was written and passed `flutter
analyze`. Its run was **KILLED by the host for low memory** before it emitted a
single line — the captured output is 2 lines, zero `RESULT` records. So it is
not "ran and was inconclusive": it never produced an observation at all.
NO NUMBERS, THEREFORE NO CLAIM.
The file was deleted in the cleanup pass (scratch tests were removed to leave
the repo as found), so reproducing this means rewriting it. The recipe: mount a
`CupertinoApp` whose home has one tap target; in `onTap` start a Stopwatch and
call `showCupertinoModalPopup` with `ReachDetailsBottomSheet(selectedReach:
SelectedReach(...))`; register `IFlowUnitPreferenceService`,
`IGeocodingService`, `IRiverDataRepository`, `IForecastService` and
`INoaaApiService` in GetIt (the page resolves them in `initState`); drive with
`tester.tapAt`, then `tester.pump()` in a loop — NOT `pumpAndSettle` — checking
`find.byType(ReachDetailsBottomSheet)` and the value/category text each frame.
Run it alone, with nothing else competing for memory, which is what killed it.
Specifically still unmeasured: the two `queryRenderedFeatures` platform-channel
calls in `MapReachSelectionService._queryReachAtPoint` (one over the stream
layers, one over the flood layer, sequential), and the sheet's own first-frame
cost. Both are local — no network — so they are INFERRED to be tens of
milliseconds, and that inference is not evidence.
From the code, not measured: `_focusCameraOnReach` runs a 700 ms Mapbox `flyTo`
but is NOT awaited before `showCupertinoModalPopup`, so it does not gate the
sheet.

---

# Grading ADR 0017 — "Why a global river takes so long to open"

Read 2026-11-03 ~15:50Z, after everything above was measured and written.

## Where we AGREE

1. GEOGLOWS is the slow path and the per-river cost dominates. Theirs: p50 7.9 s,
   48% over 8 s (n=126 invocations), "9-17 s even when everything is warm".
   Mine, independent: a river the proxy had not just served 8.26 / 9.01 / 9.67 s
   (n=4); the same river again 0.105 / 0.113 / 0.118 s (n=3).
2. "It is NOT mainly cold start — I got this wrong first." Correct, and correctly
   diagnosed: the function caches per river in-process, so sampling one river
   repeatedly measures the cache. I rotated river ids with 18-minute gaps BECAUSE
   that is the obvious trap, and I still hit it twice. Their self-correction is
   the most valuable paragraph in the document.
3. Their cache-hit figure: 0.12 / 0.15 / 0.26 s (n=24) vs mine 0.105 / 0.113 /
   0.118 s (n=3). Agree.
4. The two NOAA endpoints they timed: theirs 0.28 s and 0.30 s (n=1 each); my
   medians 0.310 s and 0.274 s (n=48 each). Their numbers happened to be right.
5. Payload is not the variable. Agree, and F9 generalises it at n=48.
6. The 80-round-trips-per-river / 97%-identical-keys finding is the strongest
   thing in the document and I have nothing that contradicts it. The held-handle
   fix follows from it and is the right first move.
7. "It is just the way the source data is" is disproven. Agree.

## Where we DISAGREE — bluntly

**D1. "Out: favourited rivers. ADR 0011's store already serves those… Nothing
here contradicts it." This is wrong, and it is the most consequential error in
the document.**
Read-only survey of the production `river_data` collection, n=205 documents / 35
NWM reaches: `mediumRange` 0 fresh, 34 EXPIRED; `longRange` 0 fresh, 27 EXPIRED.
Reach 10092062's longRange document was fetched 1,030 h ago and expired 994 h
ago. `StoreBackedDataSource` explicitly refuses an expired document and falls
through to `_inner.fetch` — live NOAA. So a FAVOURITE'S FORECAST PAGE IS ON THE
LIVE PATH for exactly the two heaviest products, with the empty-section flap,
the unfiltered fallback and the stampede all in play.
The ADR's justification for excluding favourites is ADR 0011's "969 ms cold on
iPhone". That number is the favourites LIST, which reads only currentFlow +
reachMetadata + returnPeriods — and all three of those ARE fresh (35/35 each).
The ADR used a measurement of one screen to declare a different screen out of
scope. The distinction that reconciles them: THE FAVOURITES LIST IS STORE-SERVED
AND FAST; THE FORECAST PAGE FOR A FAVOURITE FALLS THROUGH TO LIVE NOAA. Both are
true at once.

**D2. "US rivers are not the problem" is asserted from n=1 per endpoint on one
reach, and it is wrong about the app even though it is right about those two
URLs.**
Three single pings cannot support that heading, and the ADR's own self-criticism
section condemns exactly this pattern. What the pings missed:
- it never timed the `return-period` call on nwm-api.ciroh.org, the SLOWEST call
  the detail sheet makes: 0.642 / 0.869 / 1.263 s (n=48), 2.8x the median of the
  2,668-byte NOAA call, on a 185-byte body;
- it never COUNTED REQUESTS. One US river, map tap then View Forecast, costs 8
  HTTP requests (n=4 reaches, identical count in all), 23 KB-204 KB, of which TWO
  PAIRS are byte-identical duplicates;
- it never saw that `?series=long_range` was empty on 6/6 reaches, which makes
  `NoaaApiService` fall back to the unfiltered `/streamflow` endpoint on EVERY
  forecast-page open — a request measured once at 188,739 B / 16.1 s whose
  `longRange` section was still `{}`.
"US rivers are not the problem" is defensible as "NOAA's two main endpoints are
fast". As written it will stop anyone looking at the US client path, which has
four distinct defects in it.

**D3. "404 instead of 502 for an unknown river — Buys: stops the client retrying
a dead request. Confidence: High."**
THE CLIENT DOES NOT RETRY. `GeoglowsApiService._getJson` is a single
`_client.get(...).timeout(90s)` with no retry logic anywhere on the GEOGLOWS
path, and it treats every non-200 identically. This change buys nothing on this
client. Returning 404 is still correct hygiene; the stated benefit is false, and
the "High" confidence is confidence in an assumption about code the author did
not read.

**D4. "Cache per river per day, shared (Firestore, same shape as ADR 0011's
store) — Confidence: High."**
The proposal is sound; the confidence is not. The counter-evidence is sitting in
the very store held up as the model: it currently has 100% of its mediumRange and
longRange documents expired and therefore inert (D1). An existing instance of the
proposed pattern has silently stopped serving two of its seven products and
nobody noticed. Find out why before building a second one — otherwise this
recommendation builds a cache that quietly does nothing in six weeks, which is
precisely what this repo's own standing rule warns about.

## Claimed without having PROVEN

1. "p50 7.9 s, p75 20.6 s" over 126 invocations is presented as user-facing
   latency, but it is invocation duration MIXING CACHE HITS WITH REAL FETCHES —
   the ADR's own later table separates them (4 real fetches vs 24 cache hits). A
   distribution over a bimodal mixture is not a user latency. The honest
   user-facing figure is the new-river one, and in their own night table that is
   n=4 (8.69 / 17.93 / 22.21 s) — a 2.5x spread on four samples, quoted to two
   decimals.
2. "about 240 round trips per river tapped" — arithmetic (80 x 3), not measured.
3. "three concurrent taps killed the container — 720 round trips and 2,075 MiB
   against a 2,048 MiB limit" — the 720 is the same arithmetic. The OOM may be
   real; the mechanism is inferred.
4. The held-handle fix table quotes "0.37 s, 0.38 s, 0.49 s, 2.45 s LOCALLY"
   against "8.1-8.6 s ON THE CONTAINER" — a local-vs-container comparison
   presented in one table as before/after. The ADR caught this exact confound one
   finding earlier (import 1.6 s locally vs 6.6-7.8 s on the container, a 4-5x
   gap) and then repeats it for the fix with no caveat. The fix is probably right;
   the 20x improvement is not measured where it matters. The n=4 also contains a
   2.45 s outlier — 6.6x the median — which the summary line ("2 round trips /
   0.37 s") does not carry.
5. "38 instance starts against 126 invocations … so a third of calls land on a
   brand-new instance" — the ratio is asserted from two aggregates; one start can
   serve many calls.
6. Scope: "Nothing here contradicts [ADR 0011]." It does. See D1.

## What it MISSED — the client, which is most of what a user waits on

The ADR has no client-side content at all beyond an assumption about retries.

1. THE GEOGLOWS BRANCH RENDERS NOTHING UNTIL THE SINGLE PROXY READ RETURNS.
   `ReachForecastPage._loadGeoglows()` is one awaited `repo.read` and `_loading`
   clears only at the end, whereas the NWM branch fires three independent
   products and paints each as it lands. Drive, real network, n=8: skeleton
   visible 9,147 ms on a cold river, 222-420 ms warm. That asymmetry is a CLIENT
   decision and it is why a global river feels catastrophic rather than merely
   slow. Even with the held-handle fix at ~8 s, the page is blank for 8 s.
   A progressive render here is a client fix the ADR does not consider.
2. `GeoglowsApiService` has a 90-SECOND timeout and no retry. The ADR's 15 s
   bad-id failure is a 15 s blank screen, and a genuinely slow call can hold the
   page for a minute and a half.
3. One US river costs 8 HTTP requests, not the 3 the architecture implies.
4. `currentFlow` and `shortRange` are THE SAME URL under two different cache
   keys, so `RiverDataRepository._inFlight` cannot dedupe them. The duplication is
   replicated into the cloud store: `nwm__<id>__currentFlow` and
   `nwm__<id>__shortRange` both hold the same 3,349-byte payload.
5. The unfiltered fallback STAMPEDES: `_unfilteredCache` is written only after the
   response lands and `_loadSectionParallel` fires medium and long together, so
   both fall back and both fetch the same URL.
6. `?series=long_range` was empty on 6/6 reaches, and the unfiltered fallback it
   triggers had an empty `longRange` in every observation. Two of the eight
   requests have never once returned usable data.
7. NOAA's sections FLAP between full and empty inside one minute, and the two
   endpoints disagree at the same second: reach 23021904 `?series=medium_range`
   157,194 B / 1,500 points at 14:21:48Z, 716 B / 0 points at 14:22:47Z; the
   unfiltered endpoint showed 0 points at the same second the filtered one showed
   1,500. Worse: THE TWO CONCURRENT UNFILTERED FETCHES RETURNED DIFFERENT BODIES
   6 ms APART — 7,859 B and 188,739 B — racing to write a last-writer-wins cache.
   The app can download a full medium-range forecast and cache the empty one over
   it with a 6-hour window. A correctness bug with a latency-shaped symptom
   ("this river has no forecast"), unreachable by any server tuning.
8. PARSING IS ~3 ms (n=40). A whole class of theory is dead; record it as dead.
9. LATENCY TRACKS ROUND TRIPS, NOT PAYLOAD (n=48 per endpoint, TTFB == total on
   every row; 185 B at 0.869 s vs 2,668 B at 0.274 s). Practical rule: removing a
   round trip is worth ~0.3 s on NOAA and ~0.9 s on the CIROH return-period host;
   removing bytes is worth nothing in time.
10. App-side cost is small but not zero: route push to real content 212 / 219 /
    384 ms with zero-latency fakes vs 393 / 421 / 493 ms over the real network
    (n=5 each). THIS IS A DEBUG UPPER BOUND AND I COULD NOT CLEAR THAT CONFOUND
    WITHOUT A PHYSICAL IPHONE. The app rendered at 16.7 ms/frame (4,193 frames in
    70,009 ms) while waiting: no jank, no main-thread blocking.
11. The `flutter drive` silent-fallback trap (F16).

## Would this ADR send someone to fix the wrong thing?

On GEOGLOWS, no — the held-handle fix is the right first move and well evidenced.
But as a guide to "why does a river take so long to load" it would:
- skip the favourites forecast page entirely, which is on the live path (D1);
- spend effort on 502->404 for a client retry that does not exist (D3);
- leave the US client path untouched behind an n=1 heading (D2) — 8 requests, two
  duplicate pairs, a guaranteed-useless ~190 KB fallback on every open, and a
  last-writer-wins cache race that can store an empty forecast over a full one;
- build a second shared cache without noticing the first one has two dead
  products (D4).

THE RIGHT ORDER, COMBINING BOTH HALVES:
1. Hold the zarr handle (theirs) — the biggest single win.
2. Make the GEOGLOWS branch render progressively. An 8 s wait with something on
   screen is a different product from an 8 s blank page.
3. Fix `_fetchUnfilteredForecast` to dedupe in flight and stop caching an empty
   section over a full one.
4. Stop asking for `long_range` until NOAA serves it, and stop fetching
   `short_range` twice.
5. Find out why the store's mediumRange and longRange documents all expired,
   before building anything new that depends on that pattern.
