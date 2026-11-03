# ADR 0017 — overnight findings log

## 05:26Z — experiment 1, cold start sized
Container readiness measured 15 times over 7 days: min 3.2s, median 6.7s,
max 9.0s. Cold start is real but bounded at ~7s median. It cannot explain a
20s load on its own.

## 05:22Z — before the queue started, worth recording
Upstream GEOGLOWS REST, from this Mac:
  forecast          2.7-3.3s   5 KB
  forecaststats     2.8-2.9s  15 KB
  forecastensemble  2.9s      59 KB
  returnperiods     9.9-10.5s HTTP 500 — BROKEN, every time
Our own proxy fetches the same forecast+stats via zarr on S3 in 8-11s each.
So the public API we do not control is roughly 3x FASTER than our proxy for
the two things that matter. Return periods are the one thing the REST API
genuinely cannot serve.

## 05:57Z — experiment 2. The shape of the problem changed.
Five concurrent requests for five different rivers. Two were cache hits
(0.18s, no log line), so n=3 did real work.

  river 220458890   25.6s   200
  river 220458910   25.9s   200
  river 220458874   26.3s   503  <- container killed
  wall clock        26.4s

They did not overlap. Alone these take 8-11s; together they took ~26s each,
which is three of them queueing. Per-leg timings inflated about 3x
(forecast 24-25.6s against 8-11s alone).

The 503 was an OUT OF MEMORY kill:
  "Memory limit of 2048 MiB exceeded with 2075 MiB used"
  "the container instance was found to be using too much memory and was
   terminated"

So one in-flight request costs roughly 690 MB of RAM (2075/3) to produce a
22 KB answer. The service has 1 vCPU and 2 GiB. Three people tapping global
rivers at the same moment take the service down and one of them gets an
error.

This is the same OOM this repo already hit once, at 1 GiB, and "fixed" by
doubling the memory to 2 GiB. It was not fixed; it was postponed.

INFERENCE, not yet measured: 690 MB and 8-11s for a 22 KB result is the
signature of pulling whole compressed chunks across the network and
decompressing them locally to slice one river out — which is exactly the
work the upstream REST API does server-side in 3s. Experiment 6 tests this.

## 06:28Z — experiment 3. The cost is flat, and it is ours.
Five rivers, one at a time, no overlap (contention controlled after exp 2).

  river       upstream forecast     our proxy
  220458874   2.55s   5127 B        8.63s   22515 B
  220458880   3.08s   5127 B        8.50s   22362 B
  220458900   2.84s   5127 B        8.10s   22584 B
  220458901   3.02s   5127 B        0.11s   (cache hit, excluded)
  220458905   3.62s   5127 B        8.43s   22608 B

Upstream 2.55-3.62s, n=5. Ours 8.10-8.63s, n=4 — a spread of half a second
on eight and a half. That tightness matters as much as the number: the work
is deterministic and identical for every river, not network weather.

Payload is constant (upstream returns exactly 5127 bytes for every river;
ours 22.4-22.6 KB). So time does not track the amount of data wanted.

NEW CONFOUND FOUND, in my own sampler: it picks its river from
(epoch/1800) % N, so it reuses the SAME river for a whole 30-minute window.
Its "ours_new" column is therefore only genuinely new on the first round of
each window; the 0.15s rows are cache hits, not fast cold fetches. Do not
read that column as cold-start data.

## 06:58Z — experiment 4. The server we do not control is the reliable one.
15 sequential calls rotating across 9 rivers:
  n=15  min 2.39s  median 2.65s  max 3.75s  spread 1.36s  failures 0

Then 6 repeats of a single river, to check the upstream is not just serving
me its own cache and flattering itself: 2.39, 2.41, 2.51, 2.62, 2.65, 2.74s
— indistinguishable from fresh rivers. The stability is genuine.

21 calls, 21 successes, everything between 2.4 and 3.8 seconds.

This answers Jerson's actual question. The external dependency is not the
source of the uncertainty and not the source of the slowness. Measured from
this Mac on home broadband; experiment 7 checks whether us-west1 sees the
same thing.

## 07:28Z — experiment 5. The US source is not involved in this problem.
Metadata, 21 sequential calls across three VERIFIED-real reaches (Elwha,
Mississippi, Onion Creek):
  n=21  min 0.26s  median 0.27s  max 0.41s  failures 0
Streamflow series, the heavier endpoint the app actually draws from:
  n=9   min 0.27s  median 0.28s  max 0.31s  failures 0

And the loose end from earlier is closed. The 503s that nearly became an
"outage" report are a PERMANENT answer: the same id returned 503 six times
out of six, each in 0.27s. That is NOAA saying "no such reach" with the
wrong status code, not NOAA being down. My original three ids were ones I
had invented for test fixtures.

Running tally of who is slow:
  NOAA (not ours)              0.3s   rock steady, n=30
  GEOGLOWS upstream (not ours) 2.6s   steady, n=21
  our proxy (ours)             8.4s   steady, n=4
Every external dependency measured tonight is both fast and dependable.

## 07:58Z — experiment 6. I was wrong again, and this one matters.
Both code paths timed in ONE process, alternating, same rivers, n=4 each:

  AWS/zarr (what our function uses)  min 1.32s  median 1.44s  max 2.50s
  REST     (the "fast" API)          min 2.43s  median 3.40s  max 4.39s

The zarr route is FASTER than the REST API, not slower. Swapping to REST —
which is what finding 3 pointed at — would have made the app worse.

It also warms up inside a process: the same river went 2.50 -> 1.64 -> 1.31s
on repeated calls, so the library holds something open after the first read.

The library does in 1.4 seconds what our container takes 8.4 seconds to do,
using the same code against the same bucket. So the route is not the
variable. The ENVIRONMENT is.

LEADING HYPOTHESIS, not yet tested: the service has 1 vCPU, and the function
fires its three reads into a 3-thread pool. Decompressing zarr chunks is
CPU-bound; three of them on one core cannot overlap, they queue. 3 x 1.4s of
CPU plus overhead lands near the 8.4s observed, and it explains experiment
2 as well — three concurrent requests means nine of these on one core, which
both serialised AND hit 2 GB of memory.

Caveat I must keep attached to these numbers: this is a Mac with many cores
and a different network. The local absolute times do NOT transfer to the
container. What transfers is the RELATIVE result — aws beats rest — because
both were measured the same way in the same process.

## 08:28Z — experiment 6b. CPU was wrong too. Here is the bottom of it.
First, killing my own hypothesis: CPU is 27-32% of a read's wall time
(0.39-0.45s of ~1.44s, n=3) and threading gives 1.46-1.73x, not 3x. One
core costs us about 1.3s. It is not the 7-second gap.

So I counted what the read actually DOES, by wrapping the S3 client:

  ONE river, steady state, 1.33s wall
    S3 round trips    80     (40 head_object + 40 get_object)
    per round trip    min 24ms   median 43ms   max 86ms
    time inside S3    3.33s, overlapped down to 1.33s wall

Eighty network round trips to produce a 22 KB answer. And our function makes
three of these reads per tap, so a single river costs about 240 round trips.

That is the bottom of it, and it explains everything above it:
 - why time is flat per river (exp 3): the trip count is fixed, not the data
 - why the Mac is 6x faster than the container (exp 6): same 80 trips, but
   from GCP us-west1 to AWS us-west-2 each trip costs more
 - why three at once died (exp 2): 240 trips become 720, and each read holds
   decompressed buffers while it waits
 - why repeats are instant: the lru_cache skips all 80

Half the trips are head_object — existence checks before each read, the
classic signature of a zarr opened without consolidated metadata.

## 08:58Z — experiment 7. The 80 trips are almost all the same 80 trips.
Two different rivers, same process, after a warm-up call:

  river 220458874   80 S3 calls, 38 distinct keys
  river 220458880   80 S3 calls, 38 distinct keys
  identical keys    37 of 38  (97%)
  different         exactly ONE: Qout/0.0.2494, the data chunk

Shared every time: .zmetadata, .zattrs, .zgroup, rivid/0, rivid/1,
ensemble/0 and friends — the dataset's metadata and its river-id index.
Only the single chunk holding the requested river is specific to the
request.

So the function re-downloads the same index for every river, every time,
and has been doing it three times per tap (forecast, stats, return
periods).

THE FIX FOLLOWS DIRECTLY, and it is small: open the dataset once per
container, hold the handle at module level, reuse it. First river on an
instance pays the 80 trips; every river after pays about two. It also fixes
the out-of-memory kill from experiment 2, because the shared index stops
being allocated once per in-flight request.

ESTIMATED, not yet measured: this should take a warm-instance river from
~8.4s to roughly the decompression cost alone, which measured 0.39-0.45s of
CPU locally. The honest test is to implement it and re-run experiment 3.

## 09:30Z — experiment 7b. The fix works, proven, not estimated.
Opened the dataset once with consolidated metadata, loaded the river index
once, then read four rivers off that held handle:

  river 220458880   0.38s    2 S3 calls
  river 220458900   2.45s    2 S3 calls
  river 220458905   0.49s    2 S3 calls
  river 220458910   0.37s    2 S3 calls

Eighty round trips per river becomes TWO. n=4, median ~0.44s, one outlier
at 2.45s which is a chunk not yet in any cache.

Proven for the forecast read. The ensemble-stats and return-period legs are
NOT yet proven and must not be claimed — they are separate datasets and
need the same handle treatment.

Note experiment 8 is time-gated: the publication window is 10:15-10:30Z and
it is 09:30Z. The 12-minute sampler is recording straight through it, so the
data will exist for the final report whether or not a tick lands on it.

## 09:58Z — experiment 8. My own fix is built on a number that is slightly wrong.
When each day's run actually finished publishing (.zmetadata LastModified):

  20261102  11:59Z   <- outlier
  20261101  09:51Z
  20261031  09:51Z
  20261030  09:45Z
  20261029  10:08Z
  20261028  09:41Z
  20261027  09:51Z
  20261026  09:42Z
  n=8  earliest 09:41  median 09:51  latest 11:59

The repo's recorded "10:15-10:30 UTC" is close but late; the median is
09:51. More importantly my own fix earlier tonight hard-codes 11:00 as the
hour before which we do not ask for today's run. That is wrong twice over:

 - between ~09:51 and 11:00 today's forecast exists and we deliberately
   serve yesterday's instead, so the data is up to an hour staler than it
   needs to be; and
 - on a day like yesterday, when publication finished at 11:59, requests
   between 11:00 and 11:59 pay the doomed 8-second attempt all over again.

The right design does not guess an hour at all: ask S3 whether today's key
exists. That is one head request, about 40ms, against an attempt that costs
2.7-11.6 seconds when it fails. Caveat on the method: LastModified on
.zmetadata is a proxy for "the run is readable" — it is written late in the
upload, which is why it is a good proxy, but it is still a proxy.

## 10:28Z — experiment 9. The failure path is slower than the success path.
A river id that does not exist:

  our function   14.39s  15.12s  15.16s   HTTP 502   (n=3)
  upstream api    0.68s   0.74s   1.03s   HTTP 400   (n=3)

Fifteen seconds to say "no". That is worse than succeeding, because the
function runs the whole 80-round-trip metadata load for each of two
candidate dates before giving up.

Two things wrong, both cheap to fix:
 - it is a 502, a SERVER error, for what is a client mistake. 400 or 404 is
   the honest answer and the one upstream gives.
 - it does not need to touch S3 at all. The river index is already loaded;
   once the handle is held per container (finding 7b) checking whether an
   id exists is a dictionary lookup.

Checked the app side: geoglows_api_service does not retry on a non-200, so
a user does not get a retry storm — they just wait fifteen seconds for a
failure. Small mercy, and it means fixing the status code is about honesty
and speed rather than preventing a loop.
