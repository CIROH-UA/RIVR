# ADR 0018: NOAA serves medium and long range about a third of the time

**Status:** Proposed
**Date:** 2026-11-11

## Context

RIVR's forecast panels depend on NOAA's NWPS streamflow API returning the
section that was asked for. This project has treated gaps in that service as
incidents: a six-week outage, a nightly stale window, an alert firing at
05:09 on 2026-11-11. Each was investigated on its own, with small samples,
and each produced a different theory.

Jerson asked the right question: since we consume their data, what is NOAA's
actual pattern?

The answer was already on disk. `publish_cadence_log` has sampled the API
hourly since August and holds 90 days under a TTL. Nobody had read it as a
dataset.

## Measured

⏱ MEASURED 2026-11-11 · **n = 1,954 hourly samples** · 2026-08-22 09:07 to
2026-11-11 13:00 UTC · read from `publish_cadence_log` via the Firestore REST
API, counting a sample as "served" when that product's `referenceTime` is
non-null.

| Product | Served | Share |
|---|---|---|
| `analysisAssimilation` | 1853 / 1954 | **94.8%** |
| `shortRange` | 1634 / 1954 | **83.6%** |
| `mediumRange` | 688 / 1954 | **35.2%** |
| `longRange` | 693 / 1954 | **35.5%** |

**Medium and long range are available roughly one request in three.** That is
the single most important fact about this app's data supply, and until now it
was neither written down nor measured at this scale.

### It is NOT a time of day effect

`mediumRange` availability by UTC hour, same dataset, 81 to 83 samples per
hour:

| Hour | Share | | Hour | Share |
|---|---|---|---|---|
| 00 | 30.9% | | 12 | 29.3% |
| 01 | 35.8% | | 13 | 42.2% |
| 02 | 55.6% | | 14 | 58.0% |
| 03 | 29.6% | | 15 | 30.9% |
| 04 | 30.1% | | 16 | 27.2% |
| 05 | 30.9% | | 17 | 29.6% |
| 06 | 29.6% | | 18 | 30.9% |
| 07 | 30.9% | | 19 | 36.6% |
| 08 | 54.3% | | 20 | 46.9% |
| 09 | 41.0% | | 21 | 32.1% |
| 10 | 25.6% | | 22 | 28.4% |
| 11 | 30.5% | | 23 | 28.4% |

Flat near 30% at almost every hour, with mild peaks at 02, 08 and 14 that are
consistent with the 6-hourly publish cycle landing rather than with a daily
outage window.

## Disproven

**"Medium range goes stale in a nightly 00:00-08:00 UTC window."** That is
backlog item 6's framing and it does not survive this dataset. Those hours
run 29.6% to 35.8%, which is indistinguishable from the rest of the day. The
nightly pattern was an artefact of small samples taken at night.

**"The 2026-11-11 05:09 alert was an outage."** Six consecutive failed hours
is unremarkable at a 30% success rate. It is what the base rate produces
regularly, not an event.

**"Six attempts at ~35% leaves about a 7% chance of coming away empty."**
That was my arithmetic on 2026-11-11 and it is wrong, because it assumed the
attempts are independent. Measured, they are not: see the retry section
below. The real figure is close to the opposite.

**"It is a per-request lottery."** Asserted in the 2026-11-03 work from 3 full
responses of 14 on one reach. The retry data below contradicts it at much
larger n: within a single burst the section is almost always either there on
the first ask or absent for all six. Not fully settled, so the Unverified
entry remains, but the lottery framing should not be repeated as fact.

## Unverified

**Whether the ~35% is per-request or per-publication-window.** The probe takes
ONE sample per hour, so it cannot by itself distinguish "NOAA serves this
section 35% of the time to everyone" from "NOAA serves it reliably inside
short windows that our hourly sample usually misses".

The retry evidence added below points at a WINDOW, not a lottery, and is
recorded there. This entry stays Unverified rather than moving, because the
retry data is indirect: it shows bursts behaving all-or-nothing, which is
consistent with a window but does not measure the window's edges.

Cheapest test that would settle it properly: ten requests in quick succession
at a fixed minute, repeated across several hours, comparing the within-burst
hit rate to 35%.

## Measured: the retry budget almost never helps

⏱ MEASURED 2026-11-11 · 7 days of production logs · every query
positive-controlled against a known event before any zero was trusted.

`EMPTY_SECTION_ATTEMPTS = 6` retries a 200-with-empty-section, 400 ms apart.
Its two outcomes are both logged, so both can be counted.

| Outcome | Count over 7 days |
|---|---|
| section arrived on a retry (attempt 2) | 1 |
| section arrived on a retry (attempt 3) | 1 |
| **budget exhausted, all 6 attempts empty** | **59** |

Broken down by product, the exhaustions were `mediumRange` 39, `longRange`
12, `shortRange` 4, `currentFlow` 4.

**So the retry rescues roughly 3% of the fetches that use it**, and costs six
requests each time it does not. Set against the 35% hourly availability, the
two numbers only reconcile if attempts inside one burst are strongly
correlated: when NOAA has the section it gives it on the first ask, and when
it does not, asking six times across 2.5 seconds does not change the answer.

### What this does and does not license

It does NOT license shrinking the budget yet. One week, 61 uses, and the two
successes are real: a rescued fetch is a forecast panel that renders. The
honest position is that the budget is far less effective than the comment at
its definition claims, and that more retrying is not the lever.

It does mean **further retry work is not justified**, which closes the
question the 2026-11-10 deploy left open.

## Consequences, proposed not decided

1. **The "wrote nothing" alert will fire often**, because a run that happens
   to hit a bad patch is normal at this base rate. Retuning it to catch
   sustained failure rather than a bad patch is worth doing, so it does not
   train the reader to ignore it. **Not changed without Jerson's word: it is
   his inbox.**
2. **Backlog item 6's fix addresses a different shape** than what is actually
   common. It helps when the probe reports nothing; the common case is the
   probe seeing a run and the fetches failing anyway. The fix is sound and
   remains unexercised.
3. **Holding stale data is the right behaviour**, and it already happens. At
   35% availability the alternative is blank panels most of the time.
4. **The retry budget is a candidate for shrinking, not growing.** Six
   attempts buy a 3% rescue rate and spend six requests per failure against
   an endpoint that is already struggling. Not proposed as a change on one
   week of data; recorded so nobody increases it on the assumption that more
   attempts help.

## Out of scope

Anything involving the upstream provider. This ADR is about understanding
their pattern so our own retry, caching and alerting decisions rest on a
measured number instead of on the last bad night.
