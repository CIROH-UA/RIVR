# RIVR backend / data-path latency audit
Scope: everything from the app's HTTP call outward. Read-only.
All timestamps UTC. Every finding labelled MEASURED or INFERRED.
Vantage point unless stated: Jerson's MacBook Pro, home network, Vancouver WA.
(Vantage point is itself a confound for absolute numbers — see F0.)

## Inputs (so nothing here is invented)
MEASURED 2026-11-03: real reach ids pulled from the production Firestore
`river_data` collection (205 docs, 8-page paginated, mask=product):
- 35 distinct NWM reach ids, 4 distinct GEOGLOWS river ids.
- NWM: 10092062 10349218 10375648 10375832 10376596 10390560 10391170 1260371
  13608610 17865930 18228725 18229897 18229909 18477067 19785459 21797179
  22050573 22515036 23099678 23735707 23736377 23815040 23856587 23997208
  23997282 23997364 23997390 24279026 24415128 2806543 3529025 4604796 4605750
  943020265 946020369
- GEOGLOWS: 430500180 610419514 670056845 670068119
These are reaches real users have favourited, not invented ids.

## The call set for one river (read off the code, not assumed)
MEASURED (code read 2026-11-03), `lib/services/4_infrastructure/river_data/nwm_data_source.dart`
+ `api/noaa_api_service.dart`. One NWM product == one upstream call:
| product | upstream call |
|---|---|
| reachMetadata | GET api.water.noaa.gov/nwps/v1/reaches/{id} |
| currentFlow | GET .../reaches/{id}/streamflow?series=short_range |
| shortRange | GET .../reaches/{id}/streamflow?series=short_range (same URL again) |
| mediumRange | GET .../streamflow?series=medium_range |
| longRange | GET .../streamflow?series=long_range |
| returnPeriods | GET nwm-api.ciroh.org/return-period?comids={id}&key=... |
INFERRED: `currentFlow` and `shortRange` are the *identical* URL, so any surface
asking for both pays it twice unless the repository's cache collapses them.
Cheapest test: client-side, count sockets — that is the other analyst's half.

## F1 — NOAA's filtered streamflow endpoint returns HTTP 200 with an EMPTY
## series about half the time, and the app answers that with a second, heavier
## request. (MEASURED)

Source: production Firestore `publish_cadence_log`, pulled 2026-11-03 ~14:30 UTC.
n = 1751 hourly rounds, 2026-08-22T09:07Z .. 2026-11-03T14:01Z (73 days).
Each round fires all five endpoints at once against reach 9962444 ("Dead River").

| endpoint | n | ok | 200-but-series-empty | HTTP error |
|---|---|---|---|---|
| analysis_assimilation | 1751 | 94.6% | 0.1% | 5.3% |
| short_range | 1751 | 84.3% | 10.7% | 5.0% |
| medium_range | 1751 | 38.0% | **50.0%** | 12.1% |
| long_range | 1751 | 37.9% | **53.0%** | 9.1% |
| unfiltered | 1751 | 81.8% | 0% | 18.2% |

HTTP failure codes (MEASURED): 504 gateway timeouts dominate
(unfiltered 254, medium 147, long 95, aa 29, short 24) plus exactly 63 403s on
every endpoint in the same rounds (one blocking episode, not endpoint-specific).

Why it matters: `NoaaApiService.fetchForecast` treats "200 with an empty
section" as a miss and calls `_fetchWithUnfilteredFallback`, i.e. a SECOND
request to the unfiltered `/streamflow` endpoint. So for ~half of all
mediumRange and longRange fetches the app pays two round trips, not one.

### Latency of each endpoint, measured FROM INSIDE GCP (ms)
| endpoint | n(ok) | min | p50 | p90 | p99 | max | median body |
|---|---|---|---|---|---|---|---|
| medium_range | 665 | 1073 | **11588** | 44876 | 59272 | 60292 | 156.3 KB |
| long_range | 664 | 295 | **6294** | 22147 | 55773 | 59520 | 63.4 KB |
| unfiltered | 1433 | 190 | 4377 | 33420 | 57211 | 59874 | 7.6 KB |
| short_range | 1476 | 170 | 1396 | 12761 | 40368 | 58220 | 2.6 KB |
| analysis_assimilation | 1657 | 195 | 1328 | 11959 | 27511 | 53000 | 5.6 KB |

### CONFOUNDS I am controlling for, named
1. **n=1 REACH.** All 1751 samples are reach 9962444. The 50% empty rate could
   be a property of that reach rather than of the API. Independent test now
   running over 10 real favourited reaches (see F2) — treat F1's empty rates as
   provisional until F2 lands.
2. **The probe fires all five endpoints SIMULTANEOUSLY** (its own source says so,
   deliberately, to separate weight from load). Five concurrent requests from
   one client inflate every latency relative to the app, which issues these
   serially. So F1's latency column is an UPPER bound on per-call server time
   and must not be quoted as the app's experience.
3. **Vantage point is GCP, not a phone.** These numbers contain no mobile
   network. They are a LOWER bound on what a device waits.
4. The probe takes no retries (by design) while the app retries up to 2x on
   timeout/5xx — so the app's wall clock on a failing call is worse, not better.

### Counter-intuitive and important (MEASURED, same dataset)
When the filtered call comes back EMPTY, the whole two-call sequence is FASTER
than when the filtered call succeeds:
| product | filtered succeeded (p50 / p90) | filtered empty + fallback (p50 / p90 / max) |
|---|---|---|
| medium_range | 11588 / 44876 ms (n=665) | 2652 / 9919 / 46654 ms (n=875) |
| long_range | 6294 / 22147 ms (n=664) | 2377 / 8933 / 110988 ms (n=833) |
| short_range | 1396 / 12761 ms (n=1476) | 2043 / 5288 / 46680 ms (n=187) |
INFERRED from this: NOAA is slow exactly when it HAS data to serialise, and the
"empty" responses are mostly genuine no-data for this reach at that hour (the
unfiltered body median is only 7.6 KB, i.e. also empty). So the fallback is NOT
the main cost driver on this reach — payload serialisation is. The cheapest test
that would settle it: F2, below, repeats the empty check across many reaches and
records whether the unfiltered response then CONTAINS the missing section.
## F2 — The cloud store (ADR 0011) has STOPPED serving mediumRange and
## longRange. 100% of them are past their own window. (MEASURED)

Measured 2026-11-03 ~14:40 UTC by reading every `river_data` document for all
35 real NWM reaches + 4 GEOGLOWS rivers (214 documents, Firestore REST, mask on
`runId` + `window`). "Expired" = `window.validUntil` < now.

| product | docs | missing | present | EXPIRED | age of newest write (h): min / med / max |
|---|---|---|---|---|---|
| currentFlow | 35 | 0 | 35 | **0** | 0.9 / 0.9 / 0.9 |
| shortRange | 35 | 0 | 35 | **0** | 0.9 / 0.9 / 0.9 |
| reachMetadata | 35 | 0 | 35 | 0 | 11.6 / 11.7 / 488.9 |
| returnPeriods | 35 | 0 | 35 | 0 | 11.6 / 539.8 / 539.8 |
| geoglowsForecast | 4 | 0 | 4 | 0 | 2.8 / 2.8 / 2.8 |
| **mediumRange** | 35 | 1 | 34 | **34 (100%)** | 125.9 / 144.9 / 144.9 |
| **longRange** | 35 | 8 | 27 | **27 (100%)** | 183.9 / **1029.9** / 1029.9 |

Worked example, reach 10092062 (Weber River), MEASURED:
- shortRange   runId 2026-11-03T11:00:00Z  (3 h old)
- mediumRange  runId 2026-10-28T06:00:00Z  (6 days old)
- longRange    runId 2026-09-21T06:00:00Z, fetchedAt 2026-09-21T16:21Z,
  validUntil 2026-09-23T04:21Z, Firestore updateTime 2026-09-23T00:20Z
  → the store has not written this document in **41 days**.

Independent corroboration, MEASURED the same hour: the project's own
`storeHealth` endpoint returns **HTTP 503 `"status":"down"`**:
`longRange has not advanced for 184h (cap 36h)`,
`mediumRange has not advanced for 126h (cap 18h)`,
`longRange is serving a run 194h old (cap 36h)`,
`mediumRange is serving a run 134h old (cap 24h)`.
(That call itself took 4.96 s TTFB, n=1.)

### Why this is a LOADING-SPEED finding, not just a data-freshness one
MEASURED, for comparison, same session: a single store document read over
Firestore REST from this machine, n=8:
TTFB min 174 ms / median 222 ms / max 567 ms; total 302 / 353 / 700 ms.
Against NOAA live medium_range at a p50 of 11.6 s (F1), the store is the
difference between a third of a second and ten-plus seconds.

INFERRED (not yet proven): because every mediumRange and longRange entry is
past `validUntil`, the client cannot serve them from the store and must go live
to NOAA for both products on every favourite — paying exactly the two slowest
calls in F1. Cheapest test that would settle it: read
`store_backed_data_source.dart` + `river_data_repository.dart` for what happens
to an expired store entry, and confirm against the device's own log that a
favourite's medium/long range produces an upstream call. Doing that next.

### Confound I controlled for
The 687,900-byte figure for a mediumRange document is **Firestore REST
JSON**, which wraps every number as `{"doubleValue": …}`. The Dart SDK reads
protobuf over gRPC, so that is NOT the bytes a phone transfers and must not be
quoted as such. Same document's `payload` field alone is 77,949 REST bytes for
longRange. I have not measured the on-wire SDK size and am not claiming it.
## F3 — ROOT CAUSE, PROVEN: NOAA only answers medium/long range for a window
## narrower than 20 minutes, and the store's probe and its fetch are 20 minutes
## apart. So the store can never capture those two products. (MEASURED)

Timestamps UTC, 2026-11-03.

### Step 1 — NOAA's behaviour CHANGED on 2026-09-17 (MEASURED, n=1751 hourly samples)
Hour-by-hour availability of `?series=…` from `publish_cadence_log`, reach 9962444:
- **Up to 2026-09-16**: medium_range and long_range answered with data in
  **18-24 of 24 hours every day** (e.g. 2026-08-24 24/24, 2026-09-14 24/24).
- **From 2026-09-17 onward**: long_range answers in exactly **3 hours a day —
  UTC 10, 16 and 22** — every single day from 2026-09-19 to 2026-11-02 without
  exception. medium_range answers in **1-5 hours a day**, clustered at UTC
  02 / 08 / 13-14 / 19-20.
- short_range and analysis_assimilation were **unaffected** (19-24 of 24 hours
  throughout, 24/24 on 2026-11-02). So this is not a general API degradation.
INFERRED: NOAA now exposes a 6-hourly product only briefly around its run
rather than retaining it. Cheapest test: F4 below is measuring the window width
live, right now.

### Step 2 — The store's two clocks are 20 minutes apart (MEASURED)
- `probePublishCadence` samples at **:00-:01** past the hour (1304 of 1763
  samples at minute 00, 454 at minute 01).
- `storeRefreshHourly` runs at **:20** past the hour (observed starts 10:20:04,
  11:20:12, 12:20:12, 13:20:04).
- `runStoreRefresh` decides what to refresh from `readLatestProbe()` — i.e. from
  the :00 sample — then fetches at :20.

### Step 3 — the consequence, caught in the act twice in one morning (MEASURED,
### production logs)
| time | probe at :00 | trigger decision at :20 | outcome at :20 |
|---|---|---|---|
| 09:00:50 | medium_range **OK**, ref 2026-11-03T00:00:00Z | triggered `mediumRange` | **25 of 25 fetches failed**, every one `"200 with no mediumRange section"` |
| 10:00:50 | long_range **OK**, ref 2026-11-03T00:00:00Z | triggered `longRange` | **35 of 35 fetches failed**, every one `"200 with no longRange section"`; report `planned 35, written 0, failed 35, reachesToRetry 35` |
| 11:00 / 12:00 / 13:00 | both empty | `"probe reported no run this hour"` ×2 | not even attempted |

So the store is in a permanent double bind: in the 20-21 hours a day when the
probe sees nothing it never tries, and in the 3-4 hours when it does see
something the data is already gone by the time it fetches. That is why
`longRange` last landed **2026-09-21** and `mediumRange` **2026-10-28** (F2) —
the 2026-09-21 date is four days after the NOAA behaviour change, which is the
corroboration I wanted.

### Step 4 — every hour the store logs the damage and nobody is reading it
MEASURED, every hourly run: `extendWindowCoverage` logs at **ERROR**
`"store windows past their hold cap; letting them expire"` with
**`count: 61`** and a `sample` list of `nwm__*__mediumRange` ids.
61 = the 34 expired mediumRange + 27 expired longRange documents I counted
independently in F2. Two independent routes to the same number.

### Step 5 — the client then goes live, by design (MEASURED by reading the code)
`store_backed_data_source.dart`, `_readStoreFrom`:
```
if (!entry.window.validUntil.isAfter(DateTime.now().toUtc())) {
  AppLogger.info(_tag, 'store document ${snap.id} expired; using the live path');
  return null;          //  -> _inner.fetch(key)  -> NwmDataSource -> NOAA
}
```
So for mediumRange and longRange the store is currently contributing **nothing**
on **every** favourite, and the device pays the live NOAA call instead of the
~0.3 s Firestore read. This is the single largest backend contribution to
"how long it takes a river to load" that I have found.
MEASURED store read for comparison, n=8: 302 / 353 / 700 ms total.

## F4 — What the live path actually costs, measured serially from a phone-like
## single client over 10 real reaches. (MEASURED)

My own harness, 2026-11-03 14:00-14:20 UTC: 10 reaches × 4 interleaved rounds,
one request at a time, fresh TCP per request, randomised order within a round.
Vantage: home broadband, Vancouver WA.

| call | n | min | p50 | p90 | max | median body |
|---|---|---|---|---|---|---|
| GET /reaches/{id} | 40 | 0.26 | **0.28** | 0.31 | 0.75 | 0.5 KB |
| ?series=short_range | 40 | 0.26 | **0.45** | 0.76 | 1.37 | 2.6 KB |
| CIROH return-period | 40 | 0.60 | **0.89** | 1.08 | 1.36 | 0.2 KB |
| ?series=long_range | 40 | 0.26 | 0.30 | 1.26 | 4.07 | 0.7 KB (all empty) |
| ?series=medium_range | 40 | 0.26 | 0.32 | 4.98 | **13.47** | 0.7 KB (mostly empty) |
| unfiltered fallback | 69 | 0.25 | 0.56 | 4.54 | **24.41** | 7.7 KB |

Fixed per-call overhead on a FRESH connection (median, n=40 each):
DNS 4 ms + TCP connect 88 ms + TLS 176 ms cumulative → **~176 ms before the
server does anything**, then server time: reach 103 ms, short_range 280 ms,
return-period **805 ms**, unfiltered 381 ms. Transfer time was ≤2 ms on all of
them. So on this link every NOAA call is dominated by handshake + server
think-time, not by bytes. INFERRED (not measured): on cellular that 176 ms
handshake is several times larger and is paid per call unless the client reuses
one connection — that is the client analyst's half, and the cheapest test is to
count distinct TLS handshakes during one river open.

### The empty-section rate is a property of the MOMENT, not the reach (MEASURED)
This kills F1's biggest confound (n=1 reach).
- long_range: **40/40 empty** (100%), 4/4 rounds, all 10 reaches.
- medium_range: 29/40 empty (72.5%) — **round 0: 0/10 empty, rounds 1,2,3:
  10/10, 10/10, 9/10.** It flipped from "has data" to "no data" for all ten
  reaches at the same time, mid-run.
- short_range: 0/40 empty.
Per-reach counts are flat (3/4 or 4/4 for every reach); per-round counts are
all-or-nothing. The empty response is time-correlated across reaches, exactly
as the production logs show (all 35 reaches failing in the same second).

### The unfiltered fallback is almost pure waste (MEASURED)
Of 69 fallbacks triggered, the unfiltered response **also** lacked the section
in **66** (long_range 40/40, medium_range 26/29). It supplied the missing data
in **3 of 69 = 4.3%**. So 95.7% of the time the app pays a second round trip
(p50 0.56 s, p90 4.54 s, max 24.41 s here) to learn the same nothing.

### Direct snapshot, independently confirming the state (MEASURED, n=3 reaches,
### 2026-11-03T14:20:38Z)
Reaches 10092062, 9962444 and 10375648, unfiltered endpoint, 0.47 s each:
`analysisAssimilation` 49 points ref 2026-11-03T10:00Z, `shortRange` 18 points
ref 2026-11-03T12:00Z, and `mediumRange`, `longRange` **and**
`mediumRangeBlend` all **EMPTY** — on all three reaches, while all three
advertise those series in their own `reach.streamflow` list.
## CORRECTION to F4, logged against myself — 2026-11-03T14:25:00Z (MEASURED)
F4 said the empty-section behaviour is "a property of the MOMENT, not the
reach". A single interleaved sample taken at 14:25:00Z, two reaches, same
endpoint, same second, refutes the strong form of that:
- reach 10092062: `mediumRange` EMPTY, `mediumRangeBlend` EMPTY
- reach 23099678: `mediumRange` **1500 data points**, `mediumRangeBlend` 240

So availability is **both** time-varying and reach-varying. What F4's data
genuinely supports is the weaker, still-important claim: emptiness moves in
lockstep across reaches *within* a round (0/10 → 10/10 between consecutive
rounds minutes apart), which is why the store loses all 35 reaches at once —
but "every reach is empty whenever any reach is empty" is NOT established and
the 14:25 sample contradicts it. F1's n=1-reach confound is therefore reduced,
not eliminated. A dedicated 3.5-hour poller (2 reaches × every 60 s) is running
to separate the two dimensions properly; see F6.

## F5 — Negative result, checked rather than assumed (MEASURED)
Two reaches in the production work list have 9-digit ids (943020265,
946020369) which sit ABOVE the documented island COMID band
(`islandComidMin` 800000000 … `islandComidMax` 921999999 in `nwm_domain.dart`),
so `nwmDomainOf` classifies them CONUS. I checked whether that was a
misclassification inflating their refresh rate. It is not: `GET
/reaches/943020265` returns **"Rio Grande", 34.6362 / -106.742** — New Mexico,
genuinely CONUS. No finding here.

Incidental (MEASURED): `GET /reaches/{id}` returns the reach object at the top
level, whereas `/streamflow` nests it under `reach`. Not a latency issue.
## F6 — GEOGLOWS: what a global river tap actually costs, end to end (MEASURED)

### 6a. What a real user waited (MEASURED — the only non-synthetic number in
### this whole audit)
Cloud Run request logs for `geoglows-forecast`, 180 days, filtered to
`httpRequest.userAgent="RIVR/1.0"` — i.e. the app itself, not the store's node
client and not anyone's curl. **That filter is the whole point: of 249 logged
requests only 10 came from the app; the other 239 are node (the store) and
curl (prior probing), and the curl ones are mostly 0.00 s cache hits that would
have dragged the median to nothing.**
n=10, every app-origin request in the window, all HTTP 200, revision 00006:
12.01, 14.27, 20.84, 20.97, 23.67, 24.34, 28.01, 29.17, 30.52, 34.04 s
→ **min 12.0 / median 24.0 / max 34.0 s.**

### 6b. My own probe, revision 00008 (MEASURED)
2026-11-03 14:23-14:26 UTC, 10 distinct real river ids, serial, then the same
10 repeated immediately. Client-side totals:
- **first time a river is asked of an instance: n=9, min 8.29 / median 8.47 /
  max 17.11 s** (payload 22-25 KB)
- **repeat on the SAME instance (`lru_cache` hit): n=5, 0.10 / 0.12 / 0.17 /
  0.19 / 0.39 s** — about 80x faster
- **repeat that landed on a DIFFERENT instance: n=3, 8.34 / 8.82 / 9.49 s**
- a river GEOGLOWS does not have (130264877): **HTTP 502 after 14.14 and
  14.20 s**, reproducible 4/4 — two full attempts, one per candidate date

CONFOUND, found and controlled: Cloud Run spread my serial requests over **two
instances** (`…bde6`, `…bdaa`, visible in `labels.instanceId`). That is the
entire explanation of the three "slow repeats" — the cache is per-instance
and in-process. Had I not segregated by instanceId I would have reported the
cache as unreliable rather than as per-instance.
Client vs server latency agreed closely (my median 8.47 s against Cloud Run's
own 8.22 s for the same requests), so **none of this is my network.**

### 6c. Where the seconds go, from the function's own timing lines (MEASURED)
The deployed function prints a per-phase line. n=31 lines in the last 24 h.
| phase | observed |
|---|---|
| `import geoglows` on an instance's FIRST request | 6.59, 6.60, 7.22, 7.48, 7.77 s (n=5) |
| `import geoglows` on every later request | 0.00 s |
| `forecast` (S3) | 6.62 … 10.40 s |
| `forecast_stats` (S3) | 6.58 … 10.38 s |
| `return_periods` (S3) | 4.99 … 7.69 s |
| `in_build_payload` (the three run in parallel, so ≈ slowest + import) | 7.41-10.06 s warm; **14.84, 16.35, 16.53, 16.99, 17.59 s** on an instance's first request |

CONTAMINATION FLAG, restated: `geoglows_forecast` was **redeployed today at
04:33 UTC** (revision 00008-jof) and the timing lines in `main.py` are dated
2026-11-02 and reference ADR 0017 — i.e. the prior investigation. So 6b/6c
measure DIFFERENT CODE from 6a. The 24 s median is what users got on revision
00006; the 8.5 s is revision 00008 under my own back-to-back traffic, which
also keeps instances warm in a way a real tap does not. I am not claiming the
redeploy caused the improvement. I have NOT read ADR 0017.

## F7 — ROOT CAUSE of the GEOGLOWS cost: 86 MB and 117 S3 GETs are fetched to
## return 23 KB, and 62% of it is the same static index downloaded three times.
## (MEASURED)

Instrumented `s3fs.S3FileSystem._cat_file` in the project's own venv
(Python 3.13, `geoglows` 2.2.0) and counted every byte of one river's resolve
(river 230179215, date 20261103):
| geoglows call | wall | S3 GETs | bytes | breakdown |
|---|---|---|---|---|
| `data.forecast` | 3.20 s | 40 | **33.33 MB** | `rivid` index 17.65 MB in 32 GETs + one `Qout` chunk 15.67 MB |
| `data.forecast_stats` | 1.94 s | 40 | **33.33 MB** | **the same `rivid` index again** + **the same `Qout` chunk again** |
| `data.return_periods` | 1.52 s | 37 | **19.34 MB** | `river_id` index 17.65 MB in 32 GETs + one `gumbel` chunk 1.69 MB |
| **total per river tap** | | **117** | **86.0 MB** | to produce a **23 KB** JSON answer — a ratio of ~3,700 : 1 |

**52.95 MB of the 86.0 MB (62%) is the river-id index, pulled three separate
times in one request** because each `geoglows.data.*` call builds its own.

### Why the chunk read is unavoidable but cheap, and the index is avoidable and
### expensive (MEASURED)
Zarr layout, read off the live store:
`Qout` shape (52, 280, 6838900), chunks **(52, 280, 686)** — one chunk carries
686 rivers, 39.95 MB uncompressed, median **15.46 MB compressed** across its
9972 chunk objects (152.28 GB total). So one river costs a whole 686-river chunk.
Splitting that cost, n=4 chunks from this machine:
- downloading a 16 MB chunk: **0.27 / 0.28 / 0.29 / 0.32 s**
- Blosc/zstd decompressing it to 40 MB: **0.00-0.02 s — negligible**
- reading the 17.65 MB `rivid` index as 32 sequential GETs: **2.19 s**
So locally the index is ~85% of a `forecast` call and the data chunk is ~12%.
INFERRED (not measured): the same structure holds on Cloud Run, where every
phase is uniformly ~3-4x slower than here (forecast 6.6-10.4 s vs my 2.4-3.4 s;
return_periods 5.0-7.7 s vs my 1.4-1.7 s). The flat ratio argues for per-GET
latency/bandwidth rather than CPU — and the decompression measurement above
independently rules CPU out. Cheapest test that would settle it: time a single
16 MB `cat_file` from inside the function and compare to 0.3 s. That needs a
deploy, which this audit is not allowed to do.

### The parallelism in `_build_payload` IS earning its keep (MEASURED)
Interleaved, fresh process per trial, 4 distinct rivers, local vantage:
- parallel (as deployed): n=6, 3.17 / **3.36** / 5.31 s
- serial (the three reads one after another): n=6, 5.50 / **6.14** / 6.76 s
So the ThreadPoolExecutor saves ~2.8 s, ~45%. The problem is not the
concurrency, it is the 86 MB.

## F8 — the coords proxy adds another ~14 s when it is needed (MEASURED)
`geoglows-reach-coords` Cloud Run request logs, 180 days, app-origin only
(`userAgent="RIVR/1.0"`): **n=3 — 0.68, 13.71, 14.29 s**; 2 of 6 total logged
requests returned 404. n=3 is small and I am not dressing it up, but the
mechanism is in the code: `_load_coords_index` downloads a ~138 MB parquet of
all 6.8M reaches per instance before it can answer. INFERRED: a GEOGLOWS
favourite whose coordinates need healing pays this on top of the forecast call.
Cheapest test: 5 serial calls for distinct rivers and read the instanceIds.
## F9 — THE UPSTREAM FAULT, CHARACTERISED: NOAA's NWPS streamflow API answers
## the SAME request with and without the data, a few times a minute. It is not
## a publication window — it is backend inconsistency. (MEASURED)

This supersedes my own earlier framing in F3 step 1 ("NOAA now exposes a
6-hourly product only briefly"). That was wrong, or at best half the story.

### The experiment
Identical URL, one reach (23099678), `?series=medium_range`, requests 5 s apart,
2026-11-03 14:31-14:33 UTC, **n=24**:
- **22 of 24** → HTTP 200, **718 bytes**, `mediumRange: {}`, 0.26-0.60 s
- **2 of 24** → HTTP 200, **156,968 bytes**, 1500 data points,
  `referenceTime 2026-11-03T06:00:00Z`, 0.54 s and 0.59 s

Tighter repeat, same URL, **14 requests inside 5 seconds** (14:35:30-14:35:35):
**3 of 14 full (156,968 B), 11 of 14 empty (718 B).** Response `date` headers
one second apart; two of the full ones landed in the same second as empties.

So **the data exists** — stamped 06:00Z, about 8.5 h old at the time — and NOAA
serves it on roughly **8-21% of identical requests**. Nothing about the request
changes. Combined observed rate so far: **5 of 38 ≈ 13%** (n=38, two runs).
A larger run (2 reaches × 3 endpoints × n=40) is in flight to firm this up.

### It is a fleet-level inconsistency (MEASURED)
`api.water.noaa.gov` resolves to exactly two A records and carries **no CDN
headers at all** (no `via`, no `age`, no `cache-*`, no `server` — only `date`),
so this is not edge caching. Pinning each IP with `curl --resolve`, n=20 each:
- **137.75.89.53 → 0 of 20 full**
- **137.75.89.46 → 4 of 20 full (20%)**
Not a clean two-way split, so there are more backends behind at least one
address. Under 50/50 DNS that predicts ~10% overall, which matches.

### Why this is THE root cause of everything in F2 and F3
- The store's hourly probe gets the run id on ~13% of attempts →
  `"probe reported no run this hour"` on the other ~87%.
- When the probe does win, the per-reach fetch 20 minutes later rolls the dice
  again, 35 times, and loses essentially every time — observed exactly:
  **35 of 35 longRange fetches failed at 10:20, 25 of 25 mediumRange at 09:20**,
  each `"200 with no <section> section"`.
- Joint probability of a product actually landing in the store in a given hour
  is therefore small, which is precisely why `longRange` last advanced
  **2026-09-21** and `mediumRange` **2026-10-28**.
- The hour-of-day pattern in F3 (long_range "only at UTC 10/16/22") is an
  ARTEFACT of one sample per hour against a ~13% success rate — not a window.
  I am correcting my own F3 step 1 on that point. What F3 steps 2-5 establish
  (the two clocks, the 61 abandoned documents, the client fall-through) all
  still stand; only the mechanism's name changes, and the new name makes the
  store's failure WORSE, not better, because no amount of rescheduling fixes a
  13% coin flip — only retrying does.

### And the app's own answer to an empty section is almost useless (MEASURED)
`NoaaApiService` responds to an empty section with ONE unfiltered call, and the
unfiltered endpoint is on the same flaky fleet: in my 6-request serial/concurrent
comparison, 2 of 6 unfiltered calls returned the full 189,054-byte payload and 4
returned 7,923 bytes. And over the 69 fallbacks in F4 it supplied the missing
section **3 times in 69 (4.3%)**. One retry against a 13% success rate is close
to worthless; the fix shape is "retry the same filtered URL a handful of times",
which the repo has explicitly forbidden itself from doing in the store
("never add retries to the store's fetchers").

## F10 — MAJOR CORRECTION to F1: the probe's latency column is not credible,
## and the slowness is in the path from GCP, not in the endpoint. (MEASURED)

From **this machine**, 2026-11-03 14:20-14:36 UTC, across roughly 330 requests:
**every** NWPS response came back in **0.25-0.62 s** — the 718-byte empties, the
156,968-byte medium range, and the 189,054-byte unfiltered payload alike — with
**zero** 504s and zero errors.
From **GCP us-central1** over 73 days (n=1751) the same endpoints record p50
0.8-32 s with 5-18% HTTP errors, almost all 504.

I tested the obvious explanation and it failed: the probe fires its five
endpoints simultaneously, so I replicated that exactly — 5 concurrent vs 5
serial, 3 rounds each, same reach. **Concurrent: 0.264-0.306 s TTFB. Serial:
0.257-0.581 s.** No meaningful difference. The probe's concurrency is NOT the
cause.
Also checked and ruled out: gzip (`--compressed` changed nothing, NWPS does not
appear to compress) and CDN edge caching (no cache headers at all).

Splitting the probe's own OK latencies at the 2026-09-17 behaviour change:
| endpoint | era | n | p50 | median KB |
|---|---|---|---|---|
| medium_range | pre | 514 | 10452 ms | 156.6 |
| medium_range | post | 151 | **32210 ms** | 153.2 |
| long_range | post | 135 | 4288 ms | 62.2 |
| short_range | post | 898 | 917 ms | 2.6 |
| unfiltered | post | 967 | 1854 ms | 7.5 |

INFERRED, and the most important open question I am leaving: **NOAA appears to
serve Google Cloud egress far worse than a residential client** — 32 s and 12%
504s there against 0.5 s and 0% here, for byte-identical responses. I cannot
settle it read-only: the decisive test is to run the same five-endpoint probe
simultaneously from a GCP VM and from a residential IP, n≥30 each, and compare.
If it is confirmed, it reverses a design assumption: the store exists partly to
move slow NOAA calls off the device, and the device may in fact be the faster
place to make them.
## F11 — CORRECTION, and it refutes my own F10 inference. NOAA is globally
## ~14x slower in exactly the moments it HAS the 6-hourly data. (MEASURED)

I inferred in F10 that NOAA serves GCP egress far worse than a residential
client. I tested it with data I already had and it is **wrong**. Within each
probe round all five endpoints are fired together, so I compared the companion
endpoints in the same round. Post-2026-09-17 rounds where `short_range`
succeeded, n=898:

| rounds where… | n | short_range p50 **in the same round** | unfiltered p50 same round | medium_range p50 |
|---|---|---|---|---|
| medium_range **succeeded** | 151 | **8926 ms** | **48539 ms** | 32210 ms |
| medium_range empty/errored | 747 | **651 ms** | — | 673 ms |

Pearson r(medium_range elapsed, short_range elapsed) across the 151
medium-OK rounds = **0.743**.

So it is not the vantage point and not the endpoint weight: **the entire NWPS
API is roughly 14x slower in the rounds when it has medium-range data to
serve** — short_range goes from 0.65 s to 8.9 s, the unfiltered call to 48.5 s.
My residential measurements today were all taken in the fast, data-absent
regime, which is why they looked uniformly sub-second. F10's "NOAA hates GCP"
inference is withdrawn.

### Synthesis: there are two regimes, and the user meets both
INFERRED from the combination of F9 and F11, and consistent with every
measurement above:
- **Regime A — the 6-hourly products are not being served** (the great majority
  of hours). Everything answers in 0.26-0.65 s. The app makes its calls, gets
  empty medium/long sections, pays one extra unfiltered round trip that is
  useless 95.7% of the time, and **renders a river with no medium or long range
  forecast at all.** Fast, and wrong.
- **Regime B — the 6-hourly products ARE being served** (a minority of hours,
  and only ~5-21% of requests even then). The whole API is ~14x slower:
  short_range 8.9 s, medium_range 32.2 s, unfiltered 48.5 s at the median from
  GCP. **This is the slow river load the owner is complaining about**, and it
  is the regime in which the app actually has something to show.

That is the uncomfortable shape of it: the app is slow precisely when it is
working. Cheapest test to confirm the regimes from the device's own vantage:
sample one reach every 60 s for 24 h from a residential link, recording both
presence and latency; I have a 3.5-hour version of that running now (F12).

### What a river load costs, totalled from the measurements above
Serial, per NWM river, in regime A (MEASURED from this machine today):
reachMetadata 0.28 s + currentFlow/shortRange 0.45 s + returnPeriods 0.89 s
+ mediumRange 0.32 s + its useless fallback 0.56 s + longRange 0.30 s + its
useless fallback 0.56 s ≈ **3.4 s of serial network for a river with no
medium/long forecast in it**, of which **1.1 s (33%) is two fallback calls that
returned nothing.**
In regime B, INFERRED by substituting the GCP regime-B medians for the same
call set: ≈ 8.9 + 32.2 + 48.5 s on the three heavy calls alone, i.e. well over
a minute if issued serially — and the app's `_httpGetWithRetry` allows 3
attempts at a 20 s timeout (`_normalTimeout`), so a single stuck medium-range
call can burn **60 s** before failing. That is MEASURED from code, not observed.
## F12 — CAPSTONE: the data is published and complete. NOAA's NWPS REST API
## just will not hand it over. (MEASURED)

Checked NOAA's own open-data bucket `noaa-nwm-pds` for today, 2026-11-03,
read at 14:38 UTC (first attempt mislabelled these as "absent" because the
directories are `medium_range_mem1..mem6` and `long_range_mem1..mem4`, not
`medium_range` / `long_range` — my error, caught by listing the day directory):

| product | cycles present today | files | size | newest object written |
|---|---|---|---|---|
| `medium_range_mem1` | **t00z and t06z, both complete** | 640 each | 25.9 + 26.0 GB | 12:38:46 UTC |
| `long_range_mem1` | **t00z, complete** | 270 | 3.0 GB | 09:10:28 UTC |
| `medium_range_blend` | t00z, t06z | 640 each | 25.9 + 26.0 GB | 12:39:06 UTC |
| `short_range` | t00z … t12z (13 cycles) | 72 each | 1.6 GB each | 13:52:51 UTC |

And the `referenceTime` on the rare full medium-range response from the API is
**2026-11-03T06:00:00Z** — exactly the t06z run sitting complete in that bucket.

So, stated plainly and measured three independent ways (the API's own rare
successes, the model output on S3, and the API's section lists advertising the
series): **the forecast exists, it is complete, it is hours old, and NOAA's
REST API serves it on a small minority of identical requests.** There is no
publication window. My F3 step 1 is withdrawn; F9 is the correct account.

### Hit rate, firmed up (MEASURED)
Serial, 0.4 s apart, n=40 per cell, 2026-11-03 14:36-14:39 UTC:
| reach | medium_range | long_range | unfiltered |
|---|---|---|---|
| 23099678 | **2/40 (5%)** | **0/40 (0%)** | **6/40 (15%)** |
| 10092062 | **8/40 (20%)** | **0/40 (0%)** | (pending) |
Plus the earlier bursts on 23099678: 2/24 and 3/14.
Pooled across everything I ran today: medium_range **17 of 158 ≈ 11%**;
long_range **0 of 120**, despite t00z being complete on S3 since 09:10 UTC.
The unfiltered endpoint has a **higher** hit rate than the filtered one
(6/40 vs 2/40 on the same reach in the same window), which is the one point in
favour of the app's fallback — small, but real, and it returns every section at
once.

### What this means for where the work belongs (INFERRED from the above)
Retries needed for a 90% chance of getting the section, at the observed rates:
p=0.20 → 11 attempts; p=0.11 → 20; p=0.05 → 45.
**A phone cannot win that race and should not try.** A background job can: the
store could spend 45 attempts an hour on one probe reach at negligible cost,
and it currently makes **one, with retries explicitly forbidden** ("never add
retries to the store's fetchers" — a rule written for a *rate-limiting* reason
that does not apply to a 5% availability lottery). Alternatively the bucket
holds the authoritative answer with 100% availability.
This is the one place where a backend change would most directly fix the
owner's complaint, and it is also why the complaint got worse around
mid-September rather than being present all along.
## F13 — the CIROH return-period API is NOT a problem (MEASURED)
n=35, one request per distinct real comid, serial, 2026-11-03 14:39 UTC:
**35/35 HTTP 200**, total min 0.57 / p50 0.78 / p90 0.95 / max 1.72 s,
bodies ~180 bytes. It is the slowest of the small calls (median server think
time 805 ms in F4, against 103 ms for `/reaches/{id}`), but it is reliable and
it is a 30-day-window product the store holds fresh (F2).
This also retires the n=1 scare I logged against myself at the start: my very
first sample read **8.53 s**. Across 36+ samples it has never come near that
again. One sample would have had me reporting a non-problem.

## F14 — the four stream-conditions Cloud Functions contribute ZERO (MEASURED)
`geoglows_stream_conditions`, `nwm_stream_conditions`,
`geoglows_conditions_latest`, `nwm_conditions_latest`:
**0 GET requests each in the last 90 days**, and each one's most recent log
entry of any kind is its own deploy timestamp (2026-08-10 / 2026-08-16).
They are off the river-load path entirely and cannot be contributing latency.
## F15 — Total backend cost of loading one NWM river, in the FAST regime
## (MEASURED, n=40 reach-rounds)

Computed from the F4 harness by reconstructing the exact call set
`NwmDataSource` issues per product, plus the fallbacks each empty section
actually triggered. 10 real reaches × 4 interleaved rounds, 2026-11-03
14:00-14:20 UTC, home link, regime A (no medium/long data being served):

| | min | p50 | p90 | max |
|---|---|---|---|---|
| **issued SERIALLY** (sum of all calls) | 2.91 s | **4.12 s** | **21.09 s** | 35.36 s |
| **issued in PARALLEL** (slowest single call) | 0.61 s | **1.07 s** | 11.77 s | 24.41 s |

Breakdown of that serial p50 of 4.12 s:
- **1.29 s (31%) is the two unfiltered fallback calls, which returned nothing**
  (F4: useful in 3 of 69).
- **0.45 s is a duplicate** — `currentFlow` and `shortRange` are the *same URL*
  (`?series=short_range`), fetched as two separate products.
- So **~42% of the serial wall clock in the fast regime is pure waste**, before
  anything about NOAA's reliability is addressed.

In the slow regime (F11) the same call set's three heavy calls alone median
8.9 + 32.2 + 48.5 s from GCP. I have not yet caught that regime from a
residential vantage; the F16 poller is running to try.

Whether the app issues these serially or in parallel is the client analyst's
measurement, not mine. What I can say is that the gap between the two columns
(4.12 s vs 1.07 s at the median, 21.1 s vs 11.8 s at p90) is the prize for
getting that right, and it is smaller than the prize for fixing F12.
## F16 — What the store WOULD save, if it were working (MEASURED)
Store document sizes for reach 10092062, read 2026-11-03 14:42 UTC. The
Firestore REST figure is an artefact of REST's `{"doubleValue": …}` wrapping and
must not be quoted as transfer cost; the logical JSON is what
`RiverDataEntry.toJson()` holds and the gzip column shows how little of it
survives compression on the wire:

| product | Firestore REST | logical JSON | gzipped | NOAA live equivalent |
|---|---|---|---|---|
| mediumRange | 671.8 KB | **79.4 KB** | **1.9 KB** | 153-157 KB per fetch |
| longRange | 314.5 KB | 37.8 KB | 1.9 KB | 62-63 KB per fetch |
| shortRange | 13.9 KB | 1.7 KB | 0.6 KB | 2.6 KB |
| currentFlow | 13.9 KB | 1.7 KB | 0.6 KB | 2.6 KB |
| returnPeriods | 1.9 KB | 0.4 KB | 0.2 KB | 0.2 KB |
| reachMetadata | 1.1 KB | 0.3 KB | 0.2 KB | 0.5 KB |

So a working store turns a 153 KB, 11-32 s, 5-20%-reliable NOAA call into a
~2 KB compressed, **0.30 s (n=8: 0.302 / 0.353 / 0.700 s)**, 100%-reliable
Firestore read. The design is right. It is simply not running for the two
products that matter most to the complaint (F2), for the reason in F12.
## F17 — The client CACHES NOAA's empty answer for up to 6 hours. The server
## refuses to. (MEASURED by reading both, 2026-11-03)

Server, `functions/src/store-upstream.ts`:
```
if (sectionIsEmpty) {
  throw new Error(`${reachId}/${product}: 200 with no ${section} section — ` +
    "treating as a failed fetch rather than storing an empty forecast");
}
```
Client, `NwmDataSource.fetch` for `mediumRange` / `longRange`: returns
`SourceFetchResult(payload: mediumPayload, …, runId: _runIdOf(payload,'mediumRange'))`
with **no emptiness check at all** — `_runIdOf` just yields null.
Then `RiverDataRepository._doFetch` caches it unconditionally:
```
final entry = RiverDataEntry(… validUntil: result.validUntil ??
    source.validUntil(key.product, now, reachId: key.reachId) …);
await _cache.put(entry);
```
and `NwmDataSource.validUntil` for mediumRange/longRange is
`PublishSchedule.nextCycle(now, everyHours: 6)`.

So the two halves of the same system disagree about what an empty section
means, and the client takes the harmful side: **a user who opens a river during
one of the ~80-95% of requests that miss gets an empty medium/long range cached
for up to six hours**, and will not retry inside that window — even though, per
F12, a retry a few seconds later has an 11-20% chance of succeeding and the
forecast is sitting complete in NOAA's bucket the whole time.

Verified prerequisite (MEASURED): Remote Config `store_read_enabled` is
**`true`** (template version 86, updated 2026-11-03T12:43Z), so favourites
really are on the store path and F2's expiry really does push medium and long
range onto the live path.
## F18 — The GEOGLOWS 24-second median, fully decomposed. Two independent
## routes to the same number. (MEASURED)

30 days of `geoglows-forecast` Cloud Run request logs, HTTP 200 only,
segmented by `labels.instanceId` — i.e. by whether a request was the FIRST one
its container ever served:

| condition | n | min | p50 | p90 | max |
|---|---|---|---|---|---|
| **A — cold container** (first request on that instance) | 45 | 16.95 | **22.47 s** | 25.66 | 34.04 |
| **B — warm container, river not in its cache** | 86 | 1.78 | **7.99 s** | 11.13 | 25.95 |
| **C — warm container, `lru_cache` hit** | 108 | 0.00 | **0.00 s** | 0.00 | 0.02 |

Implied container cold-start cost = p50(A) − p50(B) = **14.48 s**.

Now line that up against F6a — the ten real app-origin requests: 12.01, 14.27,
20.84, 20.97, 23.67, 24.34, 28.01, 29.17, 30.52, 34.04 s, median **24.0 s**.
**Every single one falls in band A.** A real user tap is essentially always a
cold container, because `min_instances=0` and the traffic is sparse: 15% of
consecutive-request gaps in 30 days exceed Cloud Run's ~15-minute idle window,
and 19% of all successful requests were the first on their instance.

So the 24 s a person waits for a global river is:
| component | cost | evidence |
|---|---|---|
| container cold start (module-scope numpy/pandas/xarray/zarr/s3fs import) | **~14.5 s** | A−B split above, n=45 / n=86 |
| …of which the deferred `import geoglows` inside the handler | **6.6-7.8 s** | the function's own timing lines, n=5 |
| three parallel S3 reads (forecast + stats + return periods) | **~8.0 s** | B band p50, n=86; function lines 6.6-10.4 s each |
| …of which re-downloading the 17.65 MB river index three times | ~85% of each read | F7: 2.19 s of a 2.4-3.4 s local read; 53 of 86 MB |
| JSON payload the user actually receives | 22-25 KB | F6b |
| a repeat tap of the same river on the same instance | **0.1-0.4 s** | F6b n=5, and band C n=108 |

Three measured levers, in order of size: **`min_instances=0`** (~14.5 s),
**the thrice-downloaded river index** (most of the remaining 8 s), and the
`lru_cache` being per-instance and in-process so it almost never hits for a
real user (band C is 108 of 239 requests but **0 of the 10 app requests**).
## F19 — Negative result: Mapbox tiles are not a contributor (MEASURED)
n=3 per cell, three tilesets × four zooms, 2026-11-03 14:43 UTC, home link:
| tileset | z0 | z6 | z9 | z12 |
|---|---|---|---|---|
| `nwm-channels-v3` | 27.5 KB | 51.6 KB | 6.0 KB | 1.1 KB |
| `geoglows-world-v3` | 215.1 KB | 22.9 KB | 5.8 KB | 0.7 KB |
| `rivr-flooded-20261103` | 74.4 KB | 15.6 KB | 404 | 404 |
Latency: **first (uncached) fetch 0.17-0.51 s; repeats 0.056-0.157 s** — every
cell, every tileset. The flood tileset's z0 tile is 74.4 KB, i.e. **14.5% of
Mapbox's 500 KB ceiling**, so the headroom CLAUDE.md claims is real and today's
build (published 12:43 UTC per Remote Config version 86) is healthy. The z9/z12
404s over Provo are simply "no flooded reaches in this tile", and z0/z6 carry
real content, so this is not the empty-tileset failure mode the repo documents.
Nothing here is on the critical path for a slow river.
## F20 — NOAA's own documentation says this should not be happening, and the
## API offers no way to work around it. (MEASURED, from the live spec)

Fetched `https://api.water.noaa.gov/nwps/v1/docs/swagger.json` (HTTP 200,
44,091 bytes, 2026-11-03 14:45 UTC). The streamflow endpoint takes **exactly
two parameters**:
- `reachId` (path)
- `series` (query), enum `analysis_assimilation | short_range | medium_range |
  long_range | medium_range_blend`

**There is no `reference_time`, no run selector, no archive parameter.** So an
app cannot ask for "the t06z run I know exists"; it can only ask and hope.

And NOAA's API info page states the service "provides access to the most recent
streamflow model run as well as a three-day rolling archive of past model runs"
for short_range, medium_range, medium_range_blend, analysis_assim and
analysis_assim_extend, and "one day for the long_range configuration".
Against that documented behaviour, today's measurements —
**medium_range 17/158 ≈ 11%, long_range 0/120, with the t06z medium-range and
t00z long-range runs both complete on `noaa-nwm-pds`** — are a malfunction, not
a design. I found no NOAA announcement of a change around 2026-09-17 (web
search, nothing relevant).

Consequences for what can be done about it, INFERRED but tightly:
1. No client-side parameter fixes this. Only repetition or a different source.
2. Repetition is viable on a server (45 attempts an hour costs nothing) and not
   on a phone (11 attempts for a 90% chance at p=0.20, 45 at p=0.05).
3. `noaa-nwm-pds` has the authoritative answer with 100% availability, but at
   26 GB per medium-range cycle it is a batch job, not a per-tap read — the
   same shape as the flood-tileset pipeline this project already runs.
4. It is worth telling NOAA (`nwps.webmaster@noaa.gov`): this is a reproducible
   defect with a clean reproduction — 40 identical requests, count the
   non-empty responses.

Sources consulted: water.noaa.gov/about/api and the live swagger.json above.

# =====================  CONCLUSIONS  =====================
Written 2026-11-03 ~14:50 UTC. Every number below is cross-referenced to the
finding that produced it. "MEASURED" means I ran the check in this session or
read it out of production logs/data; "INFERRED" means I did not.

## There are two different slow rivers, and they have nothing in common
### 1. A GLOBAL (GEOGLOWS) river — median 24.0 s, and that is the real figure
MEASURED (F6a): the ten app-origin requests ever logged, 180 days —
12.0 / 14.3 / 20.8 / 21.0 / 23.7 / 24.3 / 28.0 / 29.2 / 30.5 / 34.0 s.
MEASURED decomposition (F18, n=45/86/108 by container):
- **~14.5 s** container cold start — `min_instances=0`, and 19% of all
  requests are the first on their instance while a real user tap is
  essentially always one (all 10 app requests sit in the cold band)
- **~8.0 s** three parallel S3 reads
- **0.1-0.4 s** if the same instance already answered that river
MEASURED cause of the 8 s (F7): **86.0 MB and 117 S3 GETs to return 23 KB**,
of which **52.95 MB (62%) is the same 17.65 MB river-index array downloaded
three times** — once per `geoglows.data.*` call. The data chunk itself
downloads in 0.27-0.32 s and decompresses in 0.00-0.02 s.
This river is slow **every single time it is not already in the store**, and
only 4 GEOGLOWS rivers are in the store (F2), so in practice: always.

### 2. A US (NWM) river — fast but WRONG most of the time, slow when it is right
MEASURED (F12, F9): NOAA's NWPS API returns the medium-range section on
**17 of 158 identical requests (11%)** and the long-range section on
**0 of 120**, while the t06z medium-range and t00z long-range runs sit
**complete** on NOAA's own `noaa-nwm-pds` bucket (25.9 GB + 3.0 GB, newest
objects written 12:38 and 09:10 UTC). 14 requests inside 5 seconds returned
3 full and 11 empty. This is an upstream malfunction against NOAA's own
documented 3-day archive (F20), with no API parameter that can work around it.
MEASURED (F11): and in the rounds when it DOES serve that data, the whole API
is **~14x slower** — short_range p50 goes 0.65 s → 8.9 s, medium_range
→ 32.2 s, unfiltered → 48.5 s; r = 0.743 between medium and short elapsed.
So the app is slow precisely when it has something to show.

## The single biggest systemic finding: the cloud store has silently stopped
MEASURED (F2, F3): **mediumRange 34/34 expired (median write age 144.9 h),
longRange 27/27 expired (median 1029.9 h) and 8 of 35 missing entirely.**
`storeHealth` returns HTTP 503 `"down"` naming exactly those two products.
Every hour `storeRefreshHourly` logs at ERROR `"store windows past their hold
cap; letting them expire"` with `count: 61` — the same 61 documents I counted
independently. Caught in the act: at 09:20 UTC **25 of 25** mediumRange
fetches failed and at 10:20 **35 of 35** longRange fetches failed, every one
`"200 with no <section> section"`. The client then falls through to live by
design (`'store document … expired; using the live path'`), so the store is
contributing **nothing** for the two products that cost the most.
A working store read is **0.30 s** and ~1.9 KB gzipped (F16) against NOAA's
11-32 s and 153 KB. The design is right; it is simply not running.
MEASURED prerequisite (F17): `store_read_enabled` is `true`, so this is live
behaviour, not a disabled feature.

## Two self-inflicted wastes, measurable today
MEASURED (F15), regime A, n=40 reach-rounds, serial p50 **4.12 s**:
- **1.29 s (31%)** is the unfiltered fallback, which supplied the missing
  section in **3 of 69 attempts (4.3%)** (F4)
- **0.45 s** is a duplicate: `currentFlow` and `shortRange` are the SAME URL
So ~42% of the fast-regime serial wall clock is waste before anything upstream
is addressed. Parallelising the same set would give p50 1.07 s.
MEASURED (F17): the client **caches NOAA's empty answer for up to 6 hours**,
while the server explicitly refuses to store it. A user who opens a river
during a miss sees no medium/long forecast for the rest of the cycle.

## Things I checked and found innocent (so nobody re-litigates them)
- CIROH return-period API: 35/35 HTTP 200, p50 0.78 s (F13). My own opening
  n=1 read 8.53 s and was an outlier.
- The four stream-conditions Cloud Functions: **0 requests in 90 days** (F14).
- Mapbox tiles: 0.056-0.51 s, flood z0 at 14.5% of the size ceiling (F19).
- Reaches 943020265 / 946020369 are genuinely CONUS ("Rio Grande"), not
  misclassified island reaches (F5).
- Blosc/zstd decompression of a 40 MB chunk: 0.00-0.02 s. Not a CPU problem (F7).
- The probe's 5-way concurrency: replicated it, 0.264-0.306 s concurrent vs
  0.257-0.581 s serial. Not the cause of its inflated latencies (F10/F11).

## Mistakes I made and corrected, in order
1. Reported CIROH at 8.53 s from **n=1**; 36 samples put it at 0.78 s (F13).
2. Claimed emptiness was "a property of the moment, not the reach"; a 14:25
   sample showed one reach full and another empty in the same second (F4 CORRECTION).
3. Called the hour-of-day pattern a NOAA **publication window**; it is a
   ~11% per-request lottery sampled once an hour (F3 step 1 withdrawn, F9/F12).
4. Inferred NOAA **serves GCP worse than residential**; testing the companion
   endpoints in the same probe round refuted it — NOAA is slow for everyone in
   those moments (F10 withdrawn, F11).
5. Reported medium/long range **"absent"** from `noaa-nwm-pds`; they are there
   as `medium_range_mem1..6` and `long_range_mem1..4` (F12).

## Biggest open questions I could NOT settle read-only
1. Whether the GEOGLOWS improvement I measured (8.5 s warm vs the historic
   24 s) is the 2026-11-03 04:33 redeploy or just my own warm-instance traffic.
   Settles with: `min_instances=1` for an hour and re-measure band A, or a
   single cold request on each revision. **The cold-start probe armed in this
   session is the cheap half of that and its result is pending.**
2. Whether NOAA's 11% hit rate varies by region/reach systematically (I saw
   5% and 20% on two reaches). Settles with: n=40 on 20 reaches spread across
   CONUS in one hour.
3. Whether the app issues its six product calls serially or in parallel — the
   4.12 s vs 1.07 s question (F15). That is the client analyst's measurement.
4. Whether a residential client sees the 14x slow regime too (F11). A 24-hour
   1-per-minute poller from this machine would settle it; a 3.5-hour version is
   running now.

## F21 — `geoglows_forecast` still OOMs, at 2 GiB, and two concurrent requests
## are enough to do it. (MEASURED)

Deployed config, read 2026-11-03 14:46 UTC (`gcloud run services describe`):
revision `geoglows-forecast-00008-jof`, **cpu 1, memory 2 Gi,
containerConcurrency 80**, `startup-cpu-boost: true`, and **no `minScale`
annotation** — confirming the `min_instances=0` premise of F18.

Production errors today (MEASURED, Cloud Logging, 90-day window):
```
2026-11-03T03:23:43Z  Memory limit of 2048 MiB exceeded with 2071 MiB used
2026-11-03T03:24:56Z  Memory limit of 2048 MiB exceeded with 2056 MiB used
2026-11-03T05:57:26Z  Memory limit of 2048 MiB exceeded with 2075 MiB used
                      ...the container instance was found to be using too much
                      memory and was terminated
```
One of those surfaced to the caller as **HTTP 503 after 26.1 s**.

The code comment at the function says GB_2 was the fix for an earlier GB_1 OOM
(1065 MiB used against 1024). It is not sufficient. The overshoot is tiny —
8 to 27 MiB over — and `geoglows_reach_coords` documents a "~1.1 GB transient
parse peak" for the same xarray/zarr machinery. **1.03 GB × 2 = 2.06 GB >
2.048 GB**, so *two* concurrent requests are enough, and
`containerConcurrency` is **80**.

CONFOUND, named: all three OOMs today fell inside a window of back-to-back curl
probing (03:22-05:57 UTC) from a prior session, not organic app traffic. So I
am NOT claiming users are hitting this routinely — app traffic is sparse enough
(F18: 15% of gaps exceed 15 minutes) that single requests dominate. What I am
claiming, measured: the instance dies on the second simultaneous request, and
the things that generate simultaneous requests are (a) the ADR 0011 store's
GEOGLOWS fan-out, (b) any burst of real users, and (c) the client retrying.
The cheapest fix is `containerConcurrency: 1`, which costs nothing at this
traffic level and makes the failure impossible; raising memory treats a symptom.

Also MEASURED: river_id **130264877** returns HTTP 502 after **14.14, 14.20,
14.30, 14.93, 14.98 s** (n=5, every attempt) — `_resolve` tries two candidate
dates and each costs a full ~7 s of S3 reads before the `KeyError` surfaces.
A river GEOGLOWS does not have costs the user 14 seconds to be told nothing.

## F22 — Provenance check on my most-quoted number, plus a live cross-
## contamination warning. (MEASURED)

I verified that `User-Agent: RIVR/1.0` identifies the app and nothing else:
`grep -rn "RIVR/1.0"` across `lib/`, `functions/src/` and
`functions_geoglows/` hits **only** `lib/.../api/geoglows_api_service.dart:34`
and `lib/.../api/noaa_api_service.dart:44`. No TypeScript or Python function
sets it (the store's calls log as `node`). So F6a's ten requests are genuinely
the Flutter app.
Their remote IPs confirm real, varied clients: 79.117.187.76 (Spain),
170.82.209.168 (Brazil), 24.21.116.231 (Pacific NW), 146.70.175.6 ×3 and
146.70.86.220 (VPN egress), 24.22.95.76. Mobile/residential, several abroad —
which fits, GEOGLOWS being the non-US source.

### ⚠️ CONTAMINATION, happening right now, in both directions
Between **14:33 and 14:45 UTC today** five NEW `RIVR/1.0` requests appeared on
`geoglows-forecast` from 24.22.95.76 and 2601:1c2:4000:290:… with latencies
**0.0035, 0.0048, 0.0057, 0.0099 and 8.744 s**. Those are not mine (I used
curl). Something is running the real app against this endpoint during my
measurement window — plausibly the client-side analyst's device or simulator.

Two consequences I must state rather than discover later:
1. **My probing warmed the instance that is now answering their device.** Four
   of those five requests are 3-10 **millisecond** `lru_cache` hits, which no
   real user would ever see (F18 band C: 108 of 239 logged requests, but **0 of
   the 10 historic app requests**). Any client-side figure for GEOGLOWS taken
   in this window is optimistic by roughly 8-24 seconds and should be discarded.
2. Conversely, their traffic keeps instances warm, which biases **my** band-A
   cold-start probe toward being too fast. The probe I armed waits 25 minutes
   of silence first; if their device keeps hitting the endpoint, that silence
   never happens and the sample is invalid. I will check the instanceId of my
   cold sample before believing it.

I have not read `/tmp/audit_client.md` or coordinated with them; this is
inferred purely from the server-side log, which is my own scope.

## F23 — CORRECTION OF A CORRECTION: it is BOTH a window AND a lottery.
## (MEASURED) — and this is where my conclusion moved twice.

Trail, so a reader can see the conclusions move:
1. **First position (F3 step 1).** The hour-by-hour pattern in 73 days of
   probe data — long_range answering at UTC 10, 16, 22 every day from
   2026-09-19 to 2026-11-02 without exception — looked like a **publication
   window**. I wrote that NOAA had started exposing the 6-hourly products only
   briefly around each run.
2. **I withdrew that (F9/F12)** after measuring 14 identical requests inside
   5 seconds returning 3 full and 11 empty, and after finding the complete
   t00z/t06z runs on `noaa-nwm-pds`. I concluded the hour pattern was an
   **artefact of one sample per hour against a ~11% per-request lottery**.
3. **That over-corrected, and the data caught it.** MEASURED, same endpoint,
   same reaches, 10 minutes apart on 2026-11-03:
   - 14:36-14:39 UTC: medium_range **2/40** on reach 23099678, **8/40** on
     10092062
   - 14:45-14:47 UTC: medium_range **0/175** across **all 35 reaches × 5
     rounds** — and long_range **0/175** in the same sweep
   A ~11% lottery does not produce 0 of 175. The hit rate went to **exactly
   zero** for every reach within minutes.

**Final position, which both halves of the evidence support:** availability is
gated by a **coarse time window** (roughly an hour around each 6-hourly run —
and today's medium-range window had closed by 14:45), and **inside that window
only ~5-20% of identical requests return the section**. Neither mechanism alone
fits the data; both together fit all of it, including:
- the store's probe at :00 winning and its fetch at :20 losing (F3) — the
  window was still open at :00 and the lottery was lost at :20, or the window
  closed in between; and
- long_range at 0/120 all afternoon while its t00z run sat complete on S3 since
  09:10 UTC — the long-range window at UTC 10/16/22 simply was not open.

## F24 — the other mistake, preserved in full
I reported that `medium_range` and `long_range` were **"absent"** from NOAA's
`noaa-nwm-pds` bucket for today. That is the **opposite of the truth**, and had
I stopped there I would have published "NOAA has stopped producing the medium
and long range forecast" — a claim that would have sent anyone reading it in
entirely the wrong direction, and that the owner might have relayed upstream.
What actually happened: I listed `noaa-nwm-pds/nwm.20261103/medium_range` and
`/long_range`, both of which 404, and took the absence at face value from a
single check. The products are published as **`medium_range_mem1..mem6`** and
**`long_range_mem1..mem4`** (one directory per ensemble member). Listing the
parent day directory instead of guessing the child name found them immediately,
complete, 25.9 + 26.0 + 3.0 GB, newest objects written 12:38 and 09:10 UTC.
The lesson is the same one that caught me on the CIROH 8.53 s: a single
negative check is not a measurement.

## F25 — The 35-reach survey, complete. ZERO of 700. (MEASURED)
2026-11-03 14:45:46 → 14:49:32 UTC. All **35 real favourited reaches** from the
production work list, 10 interleaved rounds (reach order reshuffled each
round), `?series=medium_range` and `?series=long_range`, one request at a time:

| series | full responses | n | HTTP | latency min / p50 / p90 / max | body |
|---|---|---|---|---|---|
| medium_range | **0** | 350 | 350× 200 | 0.25 / 0.31 / 0.35 / 1.04 s | 718 B |
| long_range | **0** | 350 | 350× 200 | 0.25 / 0.31 / 0.35 / 0.46 s | 718 B |

**0 of 700**, every one a clean HTTP 200 with an empty section, in under half a
second. Nine minutes earlier the same endpoint gave 2/40 and 8/40 on two of
these same reaches. This is the firmest evidence for F23's "window AND lottery"
reading, and it is also the plainest statement of the user impact:

**At 14:45-14:49 UTC today, every RIVR user opening any of their 35 favourited
rivers would have received no medium-range and no long-range forecast at all —
after the app made four round trips per river to discover it (two filtered
calls, two unfiltered fallbacks) — and the client would then have cached that
emptiness for up to six hours (F17).** Fast, and empty.

This also disposes of the n=1-reach confound completely. It is not reach
9962444, and it is not the ten reaches of F4. It is all 35, simultaneously.

## F26 — The window closing, watched minute by minute (MEASURED)
Dedicated poller, 2 reaches (10092062, 23099678), the unfiltered endpoint every
60 s, 2026-11-03 14:22 → 14:50 UTC, 28 consecutive minutes. Counting minutes in
which EITHER reach returned a non-empty mediumRange or longRange:
| 5-minute bucket | minutes with any medium/long data |
|---|---|
| 14:2x | 3 |
| 14:3x | 3 |
| 14:4x | **1** (last hit 14:41) |
| 14:45-14:49 (the 700-request sweep, F25) | **0 of 700** |
| 14:4x after 14:41, and 14:50 | 0 |

`shortRange` returned 18 points in **every one of the 28 minutes**, on both
reaches — so this is not a connectivity or throttling artefact on my side; the
same request to the same host at the same moment kept working for short range
while medium range faded out.
Never once did both reaches have medium range in the same minute, which is the
lottery; and the hits decayed to zero and stayed there, which is the window.

## F27 — My cold-start probe is INVALID, and I am reporting that rather than
## the number it produced. (MEASURED)

The probe was designed to wait 25 minutes of total silence so Cloud Run would
scale `geoglows_forecast` to zero, then take one genuinely cold sample. I
checked the precondition before trusting the result. **The silence never
happened.** Request log for `geoglows-forecast` from 14:26:00 UTC onward:

```
14:33:00  RIVR/1.0   8.744 s  200
14:34:41  RIVR/1.0   0.0035 s 200
14:36:22  RIVR/1.0   0.0057 s 200
14:38:02  RIVR/1.0   0.0099 s 200
14:38:40  curl/8.7.1 8.485 s  200      <- not mine; my own curl work on this
14:38:49  curl/8.7.1 0.0034 s 200         endpoint ended at 14:26
14:38:49  curl/8.7.1 9.565 s  200
14:45:15  RIVR/1.0   0.0048 s 200
14:46:56  RIVR/1.0   0.0108 s 200
14:48:37  RIVR/1.0   0.0049 s 200
14:50:18  RIVR/1.0   0.0044 s 200
```
So the instance was kept warm continuously through the entire 25-minute window
by another party's traffic, and whatever my 14:51 sample reports is **band B
(warm instance), not band A (cold container)**. I will check its `instanceId`
and will not quote it as a cold start.

**This costs nothing**, because the question it was going to answer is already
answered better: F18 measures the cold-start band from **45 real cold-container
requests over 30 days** (p50 22.47 s) against **86 warm-instance ones**
(p50 7.99 s). An n=1 probe was only ever going to corroborate an n=45 result.
The open question it could NOT have settled either way — whether today's 8.5 s
is the 04:33 redeploy or just warm instances — remains open, and the only clean
test is a single cold request on each revision, which needs a deploy.

### An incidental observation I can measure but cannot attribute
The `RIVR/1.0` requests above are spaced **101, 101, 100, …, 101, 101, 101
seconds** apart — a timer, not a person — and almost all return in 3-11 ms,
i.e. `lru_cache` hits for the **same river** repeatedly. Something is polling
one GEOGLOWS river roughly every 100 seconds. I cannot attribute it: it is
most likely the client-side analyst's harness, it could be a real device, and
`AppConfig.defaultRefreshInterval` is 300 s, not 100. **Flagging it, not
concluding it.** If it turns out to be app behaviour rather than a test
harness, it is a separate finding: a per-river poll of a function that costs
8-22 s on a miss and exists to be read once.

# ============  ADDENDUM TO THE CONCLUSIONS (written after F23-F27)  ============

Three things changed or firmed up after the Conclusions section above was
written. The Conclusions stand except where noted here.

**1. The NWM availability question is settled, and the answer is "both".**
Not a publication window (my first reading), not purely a per-request lottery
(my over-correction), but a **coarse window with a lottery inside it** — F23.
The decisive numbers:
- 14:36-14:39 UTC: medium_range **2/40** and **8/40** on two reaches (lottery)
- 14:45-14:49 UTC: medium_range **0/350** and long_range **0/350** across
  **all 35 production reaches**, 10 rounds, every one a clean HTTP 200 in
  0.25-1.04 s (window closed) — F25
- the minute-by-minute decay in between: 3 hits, 3 hits, 1 hit, then zero,
  while `shortRange` kept returning 18 points in all 28 minutes — F26

**2. The plainest statement of user impact I can make, and it is measured.**
At 14:45-14:49 UTC today, **every** RIVR user opening **any** of their 35
favourited rivers received **no medium-range and no long-range forecast**,
after the app made four round trips per river to find out (two filtered calls
plus two unfiltered fallbacks), and the client then cached that emptiness for
up to six hours (F17). The forecast was sitting complete on NOAA's own bucket
the entire time (F12).

**3. My cold-start probe failed its own precondition and I am not using it.**
Another party's traffic kept the instance warm for the whole 25-minute window
(F27), so the sample is band B, not band A. No loss: the cold-start figure
rests on **45 real cold-container requests over 30 days**, not on one probe.

## What I did NOT get to, stated plainly rather than padded
- A single cold request per revision, to separate the 2026-11-03 04:33 redeploy
  from warm-instance luck on GEOGLOWS. Needs a deploy or a quiet endpoint.
- Whether the 11% lottery rate varies systematically by region. F25 answers the
  within-one-window version (0/700 everywhere at once), but I never caught an
  open window with 20 reaches in it.
- Whether a residential client also sees F11's 14x slow regime. The poller was
  running toward the 16:00 UTC long-range window to try; whatever it shows is
  appended below this line.

### F27, concluded with the actual result (MEASURED)
The probe fired at 14:52:09 UTC and returned:
```
COLD 760021642 code=200 total=0.160709
```
**0.161 s.** That is band C — an `lru_cache` hit — not a cold container. The
invalidity is self-evident in the number, and it is visible in the mechanism
too: river 760021642 was last fetched at **14:19:52** on instance `…bde6`, and
that instance was still alive **32 minutes later** because another party's
traffic hit the endpoint every ~101 s throughout. I predicted this result from
the precondition check before seeing it, which is the only satisfying part.

The probe's remaining two samples (15:12 and 15:32 UTC, rivers 210230337 and
620569308) are compromised the same way and worse: **both of those rivers were
also already fetched on instance `…bde6` at 14:20:00 and 14:20:40**, so even a
genuinely cold container would have been contaminated by my own choice of
river ids. That is a design error in my probe, not just bad luck — a cold-start
probe must use river ids that have never been requested, and I reused three
from my own earlier sweep. Noting it so nobody repeats it.

**Net: the cold-start question is answered only by F18's n=45 historical
split (p50 22.47 s cold vs 7.99 s warm), and that is the number to use.**

## F28 — PRE-REGISTRATION of probe 2's interpretation, written 14:54 UTC,
## BEFORE reading ADR 0017 and BEFORE the 16:06 result exists.

Why this exists: I was asked to write up probe 2 and then read the prior
investigation. Probe 2's result does not arrive until 16:06 UTC. Rather than
sit idle, I am fixing my interpretation of both possible outcomes NOW, so that
having read the ADR cannot colour how I read my own poller. The result gets
appended below this block, unedited, whatever it says.

Probe 2 = the minute-by-minute poller (2 reaches, unfiltered endpoint, every
60 s, running 14:22 → ~17:52 UTC). The 73 days of probe data say the
**long_range** section is answerable at UTC hours **10, 16 and 22**, every day
from 2026-09-19 to 2026-11-02 without exception. It is 0/120 and then 0/350 all
afternoon (F25). So:

**Outcome A — long_range appears at or near 16:00 UTC on either reach.**
Then the window component of F23 is confirmed prospectively, not just
retrospectively: I will have predicted an availability window from historical
data and then watched it open. That upgrades F23 from "both mechanisms fit the
data" to "the window is real and its phase is known (6-hourly, long range at
10/16/22Z, medium range at 02/08/14/20Z)". It also means the store's :20
schedule is fixable in principle — move the fetch to :01 and it is inside the
window — though the lottery still caps the success rate at whatever the
in-window hit rate is, which I measured at 5-20% for medium range.

**Outcome B — long_range does NOT appear at 16:00 UTC.**
Then I must NOT quietly keep the window story. Two readings would remain open
and I commit to saying so rather than picking the convenient one:
 (i) the window exists but is narrower than my 60 s sampling or lower-hit-rate
     than 1-in-60 at this moment, or
 (ii) long_range availability has degraded further since 2026-11-02 and is now
     simply gone, in which case the "10/16/22Z" pattern is history and the
     current state is worse than F23 describes.
Distinguishing them needs a day of 10-second sampling, which I will not have.
Either way, Outcome B does NOT rescue the pure-lottery reading I already
withdrew, because F25's 0/700 is incompatible with an 11% lottery.

**Either outcome leaves these untouched**, and I note it so nothing downstream
hangs on probe 2: the store's 20-minute gap and its 25/25 and 35/35 failures
(F3), the 61 abandoned documents (F2/F3), the 0/700 sweep (F25), the complete
t00z/t06z runs on `noaa-nwm-pds` (F12), the absent `reference_time` parameter
(F20), and the entire GEOGLOWS decomposition (F7/F18). Probe 2 refines the
*phase* of one mechanism. It cannot overturn any of those.


# ╔══════════════════════════════════════════════════════════════════════════╗
# ║  GRADING OF ADR 0017 (read for the first time at 14:55 UTC, after all    ║
# ║  measurements above were taken and recorded)                             ║
# ╚══════════════════════════════════════════════════════════════════════════╝

Documents graded: `docs/adr/0017-global-river-load-latency.md` (387 lines) and
`docs/adr/0017-appendix-overnight-log.md` (257 lines).

Overall: **the GEOGLOWS half is largely right and in one place better than
mine. The US half is wrong, and wrong in the way that matters. And its
headline distribution is computed on a contaminated sample that understates
the user-facing problem by about 3x, which then inverts its own
recommendations.**

---
## A. WHERE WE AGREE (independently, different instruments)

**A1. The root cause of the GEOGLOWS cost. Strong convergence.**
ADR exp 6b/7: one river = **80 S3 round trips** (40 head + 40 get), 38 distinct
keys, **37 of 38 identical between two different rivers** — only the data chunk
differs; three such reads per tap ≈ 240 trips.
Me (F7): one river = **117 S3 GETs and 86.0 MB** to return 23 KB, of which
**52.95 MB (62%) is the river-id index, downloaded three times**.
These are the same finding measured two ways — they counted trips, I counted
bytes — and the counts reconcile: their 40 GETs × 3 reads = 120, against my
measured **117**. I did not instrument `head_object`, so their head half is
theirs alone and I cannot contradict it. **Credit: this is their best work and
it is correct.**

**A2. A warm instance is still slow for a river it has not seen.**
ADR finding 3: 17.1 / 8.7 / 8.9 s new-to-instance, 1.9 s repeat (n=3 + 2).
Me (F18): band B **p50 7.99 s, n=86**; band C **p50 0.00 s, n=108**.
Same conclusion, my n is ~20x larger. Their 1.9 s repeat is now 0.11-0.4 s
after their own fix, which my F6b independently measured at 0.10-0.39 s (n=5).

**A3. It is not CPU.** ADR 6b: CPU 27-32% of wall time, threading 1.46-1.73x.
Me (F7): Blosc/zstd decompressing a 40 MB chunk takes **0.00-0.02 s** (n=4),
against 0.27-0.32 s to download it. Agreed, and my number is sharper.

**A4. An unknown river id is slower than a successful one, and returns 502.**
ADR exp 9: 14.39 / 15.12 / 15.16 s, HTTP 502 (n=3).
Me (F21): 14.14 / 14.20 / 14.30 / 14.93 / 14.98 s, HTTP 502 (n=5). Agreed.

**A5. The OOM at 2 GiB is real and unfixed.** ADR exp 2 logged
`2075 MiB used` against the 2048 limit. I found three OOM events in today's
log at **2056 / 2071 / 2075 MiB** — and **the 2075 one is literally their
experiment 2**. I had attributed those OOMs to "a prior session's back-to-back
probing" and declined to blame users; that call was right, and the prior
session is now identified. Their line *"It was not fixed; it was postponed"*
is correct.

**A6. Service configuration**: 2 GiB, 1 vCPU, minInstances 0, concurrency 80,
timeout 120 s. I read the same values off the live service. Agreed.

**A7. The deferred import costs 6.6-7.8 s on the container.** ADR finding 10.
My F18/F6c: **6.59 / 6.60 / 7.22 / 7.48 / 7.77 s (n=5)**. Agreed exactly.

**A8. The GEOGLOWS REST return-period endpoint is broken** (28/28 HTTP 500).
Not something I tested; consistent with what `config.dart` already records.
No dispute.

---
## B. WHERE WE DISAGREE — bluntly

### B1. "US rivers are not the problem" is WRONG, and it is the central error.
ADR finding 1 rests on **three requests to one reach on one day** —
`reaches/{id}` 0.28 s, `short_range` 0.30 s, `analysis_assimilation` 0.29 s —
later supported by the overnight sampler at n=28 (metadata) and n=9-28
(short_range). My numbers for those same endpoints agree to two decimal places
(F4: `/reaches/{id}` p50 **0.28 s**, `short_range` p50 **0.45 s**, n=40 each).

**The problem is what was never requested. Neither document ever issues a
single `?series=medium_range` or `?series=long_range` call.** Not once, in 644
lines. Those two are:
- empty on **50.0%** and **53.0%** of 1751 hourly samples over 73 days (F1)
- **0 of 350 and 0 of 350** across all 35 production reaches this afternoon (F25)
- the two products that have broken the ADR 0011 store for six weeks (F2)
- **p50 32.2 s** from GCP when they do answer, with the whole NWPS API ~14x
  slower in those moments, r = 0.743 (F11)
- each costing the app a second, 95.7%-useless round trip (F4, F15)

A conclusion that "US rivers are not the problem" drawn from the two series
NOAA serves reliably, while the two broken ones are never touched, is not a
small gap. It is the finding the investigation was for, and it was missed by
choosing the wrong three endpoints and never widening.

### B2. "The servers we do not control were the steadiest part of the system."
Presented as *the honest answer to the question Jerson actually asked*. It is
wrong, and the ADR's own appendix contradicts it:
- its own GEOGLOWS upstream forecast: **4 failures in 28** (14%)
- its own GEOGLOWS return-periods: **28 of 28 HTTP 500**
- and from the project's own `publish_cadence_log`, which neither document
  consults: NOAA medium_range **38.0% ok**, long_range **37.9% ok**, 504s on
  every endpoint, and **4.9% of 1751 hours in which NOTHING succeeded at all**,
  in 56 episodes up to 4 consecutive hours (F1).
The servers we do not control are the **least** reliable part of this system.
The ADR reached the opposite conclusion by sampling only the dependencies that
behave. There is a real irony here worth naming: the author correctly catalogues
four of their own over-claims under *"The uncertainty was mine, not the
servers'"* — and then makes a fifth, larger one as the summary of that very
exercise.

### B3. "Cold start adds about six seconds on top" — the ADR has the right
### number elsewhere in the same finding and leads with the wrong one.
Finding 4 headlines **6.2 s**, from **one** Cloud Run log excerpt (n=1), while
the appendix had already measured container readiness at n=15 (median 6.7 s)
and the same finding's own table shows **22.8 s vs 7.3 s** — a 15.5 s gap.
Me (F18), by `instanceId` over 30 days: cold **p50 22.47 s (n=45)** vs
warm-new-river **p50 7.99 s (n=86)** → cold start costs **14.48 s**, not 6.2 s.
The 6.2 s is TCP-probe readiness; the user-visible penalty is readiness **plus**
the 6.6-7.8 s deferred import the ADR itself measured in finding 10. The ADR
holds all three numbers and never adds them up.
Also wrong in the same finding: *"a third of calls land on a brand-new
instance"* (38 starts / 126 invocations). Measured over the same 30 days:
**45 cold of 249, = 18%** (F18).

### B4. "Concurrency 80 means burst fan-out across instances is NOT a
### contributor" (finding 5) is contradicted by the ADR's own experiment 2,
where three concurrent requests **queued on one instance** (26 s each instead
of 8-11 s) and OOM-killed it. Concurrency 80 is precisely *why* they landed on
one instance rather than fanning out. My F21 makes the arithmetic explicit:
~1.03 GB peak × 2 = 2.06 GB > the 2.048 GB limit, so **two** concurrent
requests suffice. The correct conclusion is the opposite of the one written:
concurrency 80 is a defect, and `containerConcurrency: 1` is the cheap fix.

### B5. An internal contradiction never reconciled: finding 6 says an unknown
river costs **8.0 s**; exp 9 says **14.39-15.16 s**. My n=5 says 14.1-15.0 s.
The appendix is right and finding 6 was left standing. Same pattern with
finding 7 (*"Module imports are not the cost"*, 1.60 s locally), which finding
10 explicitly refutes while finding 7 keeps its heading.

---
## C. CLAIMED WITHOUT HAVING PROVEN — the one most wanted

### C1. ★ THE BIG ONE: the headline distribution is computed on a pool that is
### 95% not-the-app, and it understates the user-facing median by ~3x.
ADR finding 2: *"126 real invocations of `geoglows_forecast` over 30 days"* →
p50 **7.9 s**, p75 20.6, p90 24.1, p95 24.8, max 34.0, over 8 s **48%**,
over 15 s **33%**. The word "real" is doing unearned work and no user-agent
segregation is mentioned anywhere in either document.

I pulled the same 30 days and segregated by `httpRequest.userAgent`:
| caller | n | p50 | share over 8 s |
|---|---|---|---|
| `curl/8.7.1` (**the author's own probing**) | 123 | 0.00 s | 24% |
| `node` (**the ADR 0011 store**, not a user) | 116 | 7.69 s | 42% |
| **`RIVR/1.0` (the actual app)** | **10** | **24.34 s** | **100%** |

And the ADR's table reproduces from the pooled set: excluding sub-1 s cache
hits from all 249 gives n=141, p50 **8.5 s**, p75 **21.1**, p90 **24.3**,
p95 **25.6**, max **34.0** — against their n=126 / 7.9 / 20.6 / 24.1 / 24.8 /
34.0. Same pool, same shape, one day of window offset.

So **the distribution the ADR leads with is mostly its own curl traffic and the
store's cron traffic.** The user-facing figure is **median 24.3 s with 100% of
requests over 8 s**, not 7.9 s with 48% over 8 s. I verified `RIVR/1.0` is set
only in `lib/.../geoglows_api_service.dart` and `lib/.../noaa_api_service.dart`
and in no function (F22), so the segregation is sound.

### C2. ★ That contamination then INVERTS the recommendations.
The overnight *"Recommended order of work"* puts **"hold the dataset handle per
container"** first, calls it *"the whole root cause"*, and the main ADR tells
the reader to *"treat the cold-start levers as the small remainder they are"*.

A per-container handle only pays off on the **second and later** request to a
given container. Measured band assignment of all ten real app requests (F22 +
this grading): **6 cold, 4 warm-new-river, ZERO cache hits** — while the pooled
set has **119 cache hits of 249**. So:
- a per-container cache has **never once helped a real user** in 30 days of logs;
- the handle fix addresses the ~8 s term, which is 4 of 10 app requests;
- **cold start, at 14.48 s, is the larger term for 6 of 10** and the ADR tells
  the reader to deprioritise it.

A curl loop hitting the same rivers repeatedly on one instance is *exactly* the
traffic pattern a per-container cache optimises — and it is 123 of the 249
requests in the pool the priority was derived from. Real users generate the
opposite pattern: sparse, bursty, worldwide, always a new container.

Worse, the main ADR's own options table rates **"cache per river per day,
shared (Firestore)"** at *High* confidence — the one option that works
regardless of container state — and the overnight *"Recommended order of
work"* **silently drops it entirely**. The two recommendation lists in the same
document disagree, and the later one is the weaker.

**Correct priority, from the numbers: (1) shared per-river-per-day cache, which
is the only lever that helps a cold tap by a user nobody has warmed;
(2) `minInstances 1` or a pre-warm ping, worth ~14.5 s of a 24.3 s median —
and the ADR is right that it must be priced first; (3) the held handle, worth
most of the remaining 8 s but only from the second river on an instance;
(4) `containerConcurrency: 1`; (5) 404 instead of 502.**

### C3. Favourites declared out of scope on a claim that is FALSE.
Scope: *"Out: favourited rivers. ADR 0011's store already serves those, and the
measurement that matters there was taken on a device (969 ms cold on iPhone).
Nothing here contradicts it."*
The store does **not** serve those. Measured today (F2): **mediumRange 34/34
expired, longRange 27/27 expired with a median write age of 1029.9 hours
(43 days), 8 of 35 missing entirely**, and the project's own `storeHealth`
endpoint returning **HTTP 503 `"status":"down"`** naming exactly those two
products. The 969 ms figure is from ADR 0011 Phase 8 on **2026-08-30** — three
weeks before the 2026-09-17 upstream regime change and six weeks before the
store's long-range documents stopped advancing. **It is a two-month-old
measurement being used to exclude from scope the largest live defect in the
system.**

### C4. "one in-flight request costs roughly 690 MB of RAM (2075/3)".
Arithmetic presented as measurement: it assumes all three requests peaked
simultaneously and that baseline is zero. The observed overshoots are only
**8-27 MiB over 2048** (F21), which is the signature of ~2 requests at ~1.03 GB,
not 3 at 690 MB — and the repo elsewhere documents a "~1.1 GB transient parse
peak" for the same machinery. The number is then used to reason about capacity.

### C5. "The fix works, proven, not estimated" — proven LOCALLY, for ONE leg.
To its credit the ADR says both things plainly (*"0.37s… locally"*, *"the
ensemble-stats and return-period legs are NOT yet proven and must not be
claimed"*). But by the time it reaches the recommendation list it has become
*"the whole root cause, prototyped"*. The ADR's own exp 6 measured the Mac at
~6x faster than the container on identical code, so 2 trips on the container is
not 0.37 s and no projection is offered. My F7 supports the direction — the
chunk itself downloads in 0.27-0.32 s and decompresses in 0.02 s, so a held
handle should approach ~0.3-0.5 s per river — but that is my inference, not a
container measurement either.

### C6. "126 real invocations… traffic is only 4.2 calls/day arriving in short
### bursts (median gap between calls 0.3 min)". A **0.3-minute median gap** is
the fingerprint of the author's own curl loops, not of users. My measurement of
the same 30 days: gaps p50 **9 s**, p75 **638 s**, p90 **63,520 s**, with
**15% of gaps exceeding Cloud Run's ~15-minute idle window**. The bimodality is
the tell, and quoting a median over a bimodal mixture of "my own loop" and
"a user, last week" describes neither.

---
## D. MISSED ENTIRELY (nothing in either document)

1. **The ADR 0011 store has stopped serving mediumRange and longRange** —
   34/34 and 27/27 expired, 8 missing, longRange median write age **43 days**,
   `storeHealth` returning **503 "down"** (F2). The single largest live bug.
2. **The store's 20-minute blind spot**: probe at **:00**, fetch at **:20**;
   caught in the act at 09:20 (**25/25** reaches failed) and 10:20 (**35/35**),
   every one `"200 with no <section> section"` (F3).
3. **`count: 61` logged at ERROR every single hour** — `"store windows past
   their hold cap; letting them expire"` — matching the 61 expired documents I
   counted independently from Firestore by a different route. Two routes, one
   number, nobody reading either (F3).
4. **NOAA's medium/long range is a window AND a lottery**: 0/700 across 35
   reaches at 14:45-14:49; 2/40 and 8/40 nine minutes earlier; **3 full of 14
   inside 5 seconds**; per-IP **0/20 vs 4/20** (F9, F23, F25).
5. **The forecast is complete on `noaa-nwm-pds` the whole time** — t00z and
   t06z medium-range (25.9 + 26.0 GB) and t00z long-range (3.0 GB), newest
   objects 12:38 and 09:10 UTC — so this is an API-layer defect, not missing
   data (F12).
6. **There is no `reference_time` parameter** on the NWPS endpoint (live
   swagger), so no client-side workaround exists (F20). This closes off the
   obvious fix before anyone proposes it.
7. **NOAA is ~14x slower in the moments it HAS the data** (short_range 0.65 s →
   8.9 s in the same probe round, r = 0.743) — the app is slow exactly when it
   is working (F11).
8. **The unfiltered fallback is 4.3% effective** (3 of 69) and is **31% of the
   serial wall clock** (F4, F15).
9. **`currentFlow` and `shortRange` are the same URL**, fetched as two products
   (F15) — 0.45 s of pure duplication.
10. **The client caches NOAA's empty answer for up to 6 hours while the server
    explicitly refuses to store it** — the two halves disagree and the client
    takes the harmful side (F17).
11. **The 2026-09-17 regime change** — the date the complaint got worse, visible
    in 73 days of the project's own probe data (F3, F23).
12. **`publish_cadence_log` exists and has 1751 samples.** The project built a
    probe precisely to answer "how reliable is upstream", and neither document
    reads it. Every number in B2 came out of it in one query.
13. **`geoglows_reach_coords` adds ~14 s** when a GEOGLOWS favourite needs its
    coordinates healed (app-origin: 0.68 / 13.71 / 14.29 s, n=3) (F8).
14. **The three-way instance split** (cold / warm-new / cache hit) at
    n=45 / 86 / 108, which is what makes every GEOGLOWS number interpretable.

---
## E. A MISTAKE OF MINE THIS GRADING EXPOSED
In my 14:52 report I wrote that **"all ten historic app requests sit in the
cold band"**. Checking it properly by `instanceId` for this grading:
**6 cold, 4 warm-new-river, 0 cache hits.** I had inferred the band from the
latency range (12-34 s against band A's min of 16.95 s), and 12.01 s and
14.27 s are below that floor — they were warm-instance requests seconds after a
cold one on the same instance. The claim that survives, and the one that
matters for C2, is the stronger half: **zero of ten were cache hits**, against
119 of 249 in the pooled set.

---
## F. GRADE

| Area | Grade | One line |
|---|---|---|
| GEOGLOWS root cause (the 80-trip / shared-index finding) | **A** | Correct, well-instrumented, and in the head-request detail better than mine |
| Self-correction discipline | **A−** | Four over-claims catalogued honestly; then a fifth made in the summary of that exercise |
| GEOGLOWS cost decomposition | **C** | Right components, wrong weights: 6.2 s for a cold start that is 14.48 s, on n=1, with the right number in its own table |
| Sampling hygiene | **D** | The headline distribution is 95% its own curl and the store's cron; "real invocations" is not real |
| US / NOAA half | **F** | Three requests, one reach, one day, and the two broken series never requested once |
| Scope decision on favourites | **F** | Excluded on a two-month-old 969 ms figure while the store is returning 503 "down" on those exact products |
| Prioritisation | **D** | Inverted by the contaminated pool; the one option that helps real users was rated High and then silently dropped |
| Honesty about what is unproven | **B+** | Labels local-vs-container and unproven legs properly; then lets "prototyped" harden into "the whole root cause" |

**The sentence I would put at the top of a revision:** *the proxy findings are
sound and the fix list is roughly inverted; and the thing the trigger actually
asked about — "how long it takes for some river to load" — has a second,
larger cause in the US path that this investigation measured three times, on
one reach, on one day, using the only two endpoints that work.*
