# River load performance — where this stands

Last updated 2026-11-03 23:30Z.

One page for the whole workstream, because the detail is spread across
ADR 0016, ADR 0017, `docs/adr/0017-audit/` and `notifications_history.md`
and none of them says what is actually done.

Jerson's original complaint: *"how long it takes for some river to load…
at this point it looks like it's just the way the source data is."*

**It is not the source data.** Three independent investigations agree.

---

## The one-paragraph version

A river is slow for three unrelated reasons. For **US rivers**, NOAA's API
answers "success" with the medium and long range forecasts simply missing,
most of the time — so the app waits, falls back, and often gets nothing,
while the cache meant to protect it had been empty for six weeks. For
**global rivers**, our own proxy makes ~80 network round trips per river to
return 22 KB, and the app shows a **blank screen** for the whole 8-10
seconds rather than filling in as it goes. None of it is the data being
large: parsing takes 3 milliseconds and the payloads are tiny.

---

## Fixed and verified

| What | Evidence |
|---|---|
| **`longRange` store recovered** | 1 fresh of 27 → 35 of 35, held over two hourly checks. Had been pinned to a run from 21 September. Hourly expired-window ERROR fell 60 → 34 |
| **Refresh decides on fresh evidence** | Schedule :20 → :05. Deployed 20:56Z, scheduler verified reading `5 * * * *` |
| **GEOGLOWS: no doomed date attempt** | Was asking for a run that cannot exist for 11 hours a day; measured 2.7-11.6 s of waste per request, now one attempt |
| **GEOGLOWS: return periods cached per river** | Repeat of a river 2.3 s → **0.11 s** |
| **Favourites list interaction** (ADR 0016) | Swipe tracks the finger 1:1 (was 91% with a 40 pt dead zone), 22 mutations caught, 1,458 tests |

## Deployed but NOT proven in production

| What | Why it is not proven |
|---|---|
| Empty-section retry, 6 attempts | Succeeded **0 times** in three runs — every fetch landed first attempt. Unit-tested and mutation-checked only |
| Circuit breaker, 3 reaches | Tripped **0 times** in three runs |

## Known broken, not fixed

Ordered by how much a user would notice.

1. **A global river shows a blank screen for 8-10 seconds.** The GEOGLOWS
   branch awaits everything before clearing `_loading`; the NWM branch
   paints progressively. Measured 9,147 ms cold, 222-420 ms warm (n=8).
   **Entirely ours, entirely in the client.** Even a perfect server leaves
   this.
2. **`mediumRange` store is dead** — 0 fresh of 34. Every run skips it with
   *"probe reported no run this hour"*. The probe takes one sample per
   endpoint by design and loses the same lottery the fetcher does. The fix
   is to separate the instrument from the trigger, not to add retries.
3. **Two concurrent requests kill the GEOGLOWS function.** ~1.03 GB each
   against a 2 GiB limit, and `containerConcurrency` is **80**. One line of
   config (`concurrency: 1`) makes it impossible; more memory only moves
   the cliff.
4. **80 S3 round trips per river, 97% of them identical between rivers.**
   Holding the dataset open per container takes it to 2. Prototyped, 2
   round trips measured. **But** of the ten real app requests in 30 days,
   **zero** were cache hits, so this buys little at today's traffic and
   grows in value with use.
5. **An unknown river costs 15 s and reports a server error** (n=5). With
   the index held in memory this is a dictionary lookup.
6. **The app fetches `long_range` on every forecast open and it is empty
   6/6**, dragging a ~190 KB unfiltered fallback behind it.
7. **Duplicate requests**: `currentFlow` and `shortRange` are the same URL
   under two cache keys. Costs ~5 ms, so it is a correctness and
   upstream-load issue, not a speed one — and when the two copies differ it
   is a real bug.

## Not a code problem

**NOAA's API does not serve data it holds.** Medium range answered 17 of
158 pooled requests and **0 of 700** across all 35 production reaches;
long range 0 of 120. Meanwhile `noaa-nwm-pds` held the complete t00z and
t06z runs — 640 files, 26 GB — the whole time, and the API offers no
`reference_time` parameter to ask for them. This is worth raising with
NOAA. No amount of retrying on our side is the right long-term answer.

## Dead ends, measured — do not revisit

| Theory | Why it is dead |
|---|---|
| The data is too large | Parsing is ~3 ms (n=40); payloads are 22 KB |
| Switch GEOGLOWS to the REST API | Measured **slower**: zarr 1.32-2.50 s vs REST 2.43-4.39 s |
| It is CPU | CPU is 27-32% of a read; threading gives 1.46-1.73x, not 3x |
| A shared per-river forecast cache | Jerson's reasoning was right and the audit confirmed it: zero cache hits among real users |
| More memory on the GEOGLOWS function | Treats the symptom; two concurrent requests still exceed any limit we set |
| The servers we do not control are unreliable | NOAA metadata 0.27 s median (n=30), GEOGLOWS upstream 2.65 s (n=21), both steady |

## Method notes, because they cost a day

Three investigations produced **nine** wrong conclusions between them. Every
one failed the same way — a conclusion drawn from too few samples under
conditions nobody had controlled. The worst: a headline latency
distribution computed over 249 requests of which only **10 were the app**,
the rest being the investigator's own probing. Segregate by caller before
quoting a user-facing number.
