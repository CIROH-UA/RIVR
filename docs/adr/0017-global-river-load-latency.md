# ADR 0017 — Why a global river takes so long to open

**Status:** Accepted — instrumented, two causes removed, a third measured and still open
**Date:** 2026-11-02
**Trigger:** Jerson: *"one of the things that bothered me the most about this
app is how long it takes for some river to load… at this point it looks like
it's just the way the source data is."*

## Scope

In: the latency of opening a river that is **not** already a favourite —
the tap-from-the-map path.

Out: favourited rivers. ADR 0011's store already serves those, and the
measurement that matters there was taken on a device (969 ms cold on
iPhone). Nothing here contradicts it.

---

## Measured

### 1. US rivers are not the problem

NOAA NWPS, 2026-11-02, reach 23997208 (Elwha River), three endpoints:

| Endpoint | Time |
|---|---|
| `reaches/{id}` | 0.28 s |
| `streamflow?series=short_range` | 0.30 s |
| `streamflow?series=analysis_assimilation` | 0.29 s |

**Caveat on an easy false alarm:** several reach ids return HTTP 503 with
`{"code": 14, "message": "Data unavailable"}`. Three of the ids I tried were
ones I had invented for test fixtures, so this is most likely NOAA's answer
for "no such reach" rather than an outage. Not investigated further, and
**not** reported as a problem.

### 2. Global rivers are the problem, and here is the shape of it

126 real invocations of `geoglows_forecast` over 30 days, from Cloud
Logging:

| | |
|---|---|
| p50 | **7.9 s** |
| p75 | **20.6 s** |
| p90 | 24.1 s |
| p95 | 24.8 s |
| max | 34.0 s |
| over 8 s | 60 of 126 — **48%** |
| over 15 s | 42 of 126 — **33%** |

### 3. It is NOT mainly cold start — I got this wrong first

My first reading was that the warm path is 1.9 s and therefore almost all of
the delay is cold start. **That was an artefact of my own test**: I requested
the *same* river three times, and the function caches per river in-process.

Re-measured against a **warm** instance, asking for rivers it had not seen:

| Request | Time |
|---|---|
| river 220458875 (new to the instance) | **17.1 s** |
| river 220458880 (new to the instance) | **8.7 s** |
| river 220458900 (new to the instance) | **8.9 s** |
| river 220458874 repeated, same instance | 1.9 s, 1.9 s |

So a river the instance has never fetched costs **9-17 s even when
everything is warm**. Only a repeat of the very same river is fast.

This matches what this repository already recorded and I had half-forgotten:
*"a cold proxy call costs 10-14 s against a zarr on S3 (2.5 s only when an
instance still has that river cached)."*

### 4. Cold start adds about six seconds on top

Instance startup, from the Cloud Run log of a real start:

```
03:18:01.055  Starting new instance. Reason: AUTOSCALING
03:18:07.237  Default STARTUP TCP probe succeeded
```

**6.2 s** to container readiness. 38 instance starts against 126
invocations in 30 days, and traffic is only 4.2 calls/day arriving in short
bursts (median gap between calls 0.3 min), so a third of calls land on a
brand-new instance.

Split by whether a call followed a recent one:

| | n | median |
|---|---|---|
| first call after a quiet spell (≥15 min) | 35 | **22.8 s** |
| call within 15 min of the previous | 90 | **7.3 s** |

The 7.3 s figure is finding 3, not warmth — those calls are mostly for
rivers the instance had not fetched before.

### 5. Service configuration

`geoglows_forecast`: 2 GiB, 1 vCPU, **minInstances 0**, maxInstances 100,
container concurrency 80, timeout 120 s, python313. Concurrency 80 means
burst fan-out across instances is **not** a contributor.

### 6. An unknown river costs 8 seconds and answers 502

`river_id=130264877` (not a real GEOGLOWS id) returns, after 8.0 s:

```
HTTP 502
{"error": "RuntimeError: no forecast for river_id 130264877
           (20261103: GroupNotFoundError; 20261102: KeyError)"}
```

Two small things wrong: a client error is reported with a server-error
status, which invites the client to retry something that will never succeed;
and discovering it costs 8 s because the function probes today's run and
then yesterday's.

### 7. Module imports are not the cost

Timed locally with `python -X importtime`, cold interpreter per module:

| Module | Cumulative |
|---|---|
| `geoglows` | 1.60 s |
| `pandas` | 1.00 s |
| `s3fs` | 0.24 s |
| `xarray` | 0.20 s |
| `zarr` | 0.19 s |
| `numpy` | 0.09 s |

The in-repo note that `geoglows` costs *"~12 s to import"* does not
reproduce here. It may still cost more on a cold container with no page
cache and 1 vCPU, but it cannot be the bulk of a 9-17 s steady-state fetch,
because a warm instance pays no import at all and is still slow.

---

## Measured, after instrumenting (2026-11-02)

Four timing lines were added to `_build_payload` and the function deployed.
One cold request answered the question.

### 8. Two of the three costs were waste, and both are now gone

A 20.5 s cold request, from the log:

| Attempt | What happened |
|---|---|
| `date=20261103` (today) | `import=7.78s`, forecast `1.94s/GroupNotFoundError`, stats `1.90s/GroupNotFoundError`, **`return_periods=3.81s`**, total **11.59 s** |
| `date=20261102` (yesterday) | forecast `8.74s`, stats `8.71s`, **`return_periods=6.32s`**, total **8.74 s** |

Two things fall straight out of that:

* **Today's run did not exist, and could not have.** `_candidate_dates()`
  always offered today first, on a comment that said forecasts "publish
  daily at 00Z". They are *stamped* 00Z but do not land until **10:15-10:30
  UTC** — a number this repository had already measured and acts on
  elsewhere (the flood builder runs at 11:00 because of it). So for the
  first eleven hours of every UTC day, every request spent a whole attempt
  on a group that cannot exist: **2.7-11.6 s of pure waste**.
* **Return periods were fetched on BOTH attempts.** They are a long-term
  statistic of the river and do not vary by date, yet they sat inside the
  per-date loop and cost 2.2-6.3 s each time.

**Fixes applied:** `_candidate_dates()` does not offer a run before it can
plausibly have published; `_return_periods()` is its own `lru_cache` keyed
on the river alone, still submitted to the thread pool so a genuine miss
still overlaps the other two reads.

### 9. Before and after, same four requests

| | Before | After |
|---|---|---|
| cold container, river never fetched | 20.5 s | **18.2 s** |
| warm, a river never fetched | 11.2 s | **10.6 s** |
| warm, another river never fetched | — | **8.2 s** |
| repeat of the same river | 2.3 s | **0.11 s** |

The logs confirm the doomed attempt is gone: every request since the deploy
shows a single `date=20261102` line where there used to be two.

**Be honest about the size of this.** The win on a repeat is enormous and
the waste removed was real, but *the number that matters — the first tap of
a river nobody has opened — moved from about 11 s to about 8-10 s.* It did
not transform.

### 10. What is actually left, and it is the whole remainder

| Read | Time |
|---|---|
| `geoglows.data.forecast` | 8.0 s, 9.1 s, 11.4 s |
| `geoglows.data.forecast_stats` | 7.4 s, 10.4 s, 9.1 s |
| deferred `geoglows` import, cold container only | 6.6-7.8 s |

They run in parallel, so the floor for a new river is the slower of the two:
**8-10.5 s**. That is now the entire problem.

Note also that the import really does cost 6.6-7.8 s on the container, where
it measured 1.6 s locally — finding 7 was measured on the wrong machine and
the in-repo "~12 s" note was closer to right than I was.

---

## Unverified

**Why one river's forecast takes 8-11 s to read.** Both reads go through
`geoglows.data.*`, which may re-open the zarr store on each call rather than
holding it; if so, a module-level handle opened once per instance would make
every river after the first on that instance much cheaper. The variance
across three similar rivers (8.0 / 9.1 / 11.4 s) has the shape of repeated
object-store round trips rather than data volume — the payload is 22 KB.

*Cheapest test:* time `geoglows.data.forecast` twice for two different
rivers in one process against a hand-rolled `xarray.open_zarr` with a cached
handle, locally, against the same bucket. No deploy needed.

**Where the 9-17 s actually goes inside a warm request.** The shape points
at reading the river's slice out of the GEOGLOWS zarr on S3 — opening a
zarr group over object storage is many small HTTP round trips, and the
function reads across two daily groups when the first is missing. But
nothing in the function logs timings, so this is inference, not measurement.

**ANSWERED — see findings 8-10 above.** The timing lines are deployed and
stay deployed: the next person to ask this question should not have to
deploy again.

**Whether the zarr carries consolidated metadata.** If it does not, opening
the group costs one request per array. This is the single most common cause
of exactly this symptom and is cheap to check from the same log.

---

## Disproven

**"It is just the way the source data is, and nothing can be done."**
Jerson's working assumption, and the reason this had been left alone. The
same function answers the *same* river in 1.9 s once it has it in memory, so
the data is not inherently slow to serve — the 9-17 s is the cost of
*reaching* it, which is a property of how it is fetched and cached, not of
the data.

**"Almost all of the delay is cold start."** Mine, earlier the same day,
from testing one river three times. Corrected in finding 3 above: a warm
instance is still 9-17 s for a river it has not seen.

---

## Options, with what each would actually buy

None of these is chosen yet.

| | Buys | Costs | Confidence |
|---|---|---|---|
| **Cache per river per day, shared** (Firestore, same shape as ADR 0011's store) | Every tap after the first, by anyone, anywhere, becomes fast for the rest of the day | Moderate work; one more collection to sweep | High — the 1.9 s repeat measurement is exactly this effect, just per-instance instead of shared |
| **Instrument, then fix what it shows** | The real answer to finding 3 | One deploy | This is the prerequisite for everything below |
| **Consolidated zarr metadata / fewer round trips** | Possibly most of the 9-17 s | Unknown until instrumented; may not be ours to change | Unverified |
| **minInstances 1** | Removes the 6.2 s container start, ~a third of calls | Real monthly money for a 2 GiB instance held 24/7 — must be priced before proposing | Low value alone: it does not touch the 9-17 s |
| **Pre-warm ping from the app** | The same 6.2 s | Nearly free | Same limit: it does not touch the 9-17 s |
| **404 instead of 502 for an unknown river** | Stops the client retrying a dead request | Trivial | High |

**The order that follows from the measurements** is: instrument first, then
the shared per-river cache, and treat the cold-start levers as the small
remainder they are — not the other way round.
