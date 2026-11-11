# Measured datasets

Raw data behind numbers quoted elsewhere in the docs. Committed because the
live sources expire.

## `noaa-section-availability-2026-08-22-to-2026-11-11.csv`

One row per hourly probe of NOAA's NWPS streamflow API, exported 2026-11-11
from the `publish_cadence_log` Firestore collection.

**Why it is committed: the live data is on a 90-day timer.**
`PROBE_RETENTION_MS` is 90 days and a Firestore TTL on `expiresAt` enforces
it, so the August samples are deleted on **2026-11-20**. This export is the
permanent copy. Without it the table in ADR 0018 would become unverifiable
nine days after it was written.

| Column | Meaning |
|---|---|
| `sampledAt` | when the probe ran, UTC |
| `<product>` | 1 if NOAA returned a run for that section, 0 if not, blank if the probe did not sample it |
| `<product>_referenceTime` | the model run returned, when there was one |
| `okCount` | how many of the probe's five endpoints answered |

**Rows:** 1,957. **Range:** 2026-08-22 09:07 to 2026-11-11 16:00 UTC.

**Recomputed from this file**, which is the point of having it:

| Product | Served | Share |
|---|---|---|
| `analysisAssimilation` | 1856 / 1957 | 94.8% |
| `shortRange` | 1637 / 1957 | 83.6% |
| `mediumRange` | 689 / 1957 | 35.2% |
| `longRange` | 694 / 1957 | 35.5% |

These are three rows larger than ADR 0018's figures (1,954) because the probe
kept running between the two exports. The percentages are unchanged to one
decimal place.

**To reproduce:** every row is a direct read of the collection, no filtering
or interpolation. A sample counts as served when that product's
`referenceTime` is non-null, which is the same test the store itself uses to
decide whether upstream published.

**The probe is still running**, hourly at `0 * * * *`
(`firebase-schedule-probePublishCadence-us-central1`, ENABLED, verified
2026-11-11), so the series continues. Re-export before 2026-11-20 if a
longer unbroken history matters.
