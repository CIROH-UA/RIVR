# RIVR remediation backlog

Built 2026-11-09 from five independent read-only audits: the test suite,
operational readiness, build and release, data correctness, documentation
accuracy. Full evidence in `/tmp/audit_*.md`, summarised per item below.

**Ranked by harm to a real user, not by how interesting the defect is.**

Every item says whether it is **PARALLEL-SAFE** (touches code nothing else
on this list touches) or **SERIAL** (shares code with another item, or
changes behaviour something else is being measured against).

---

## Tier 1 — a user is harmed now, or their data is at risk

### 1. Guest sign-in can destroy a returning user's saved rivers · SERIAL
One flaky read during the guest-to-account merge is indistinguishable from
"the account has no document". The merge then writes the guest's single
river as the whole list, and reports success, so no error ever surfaces.
Same harm as the 832 incident, which cost Jerson two rivers he could not
recover, reached by a different route.
*Fix shape:* the rule this repo already learned — nothing is written until
the operation has succeeded. *Guard:* failing test exists in the Phase 2
scratch directory.

### 2. A unit toggle can resurrect a dead push token and drop a river · SERIAL
The user document is overwritten whole from a cache that server writes never
invalidate. Tapping ft³/s ↔ m³/s can restore a dead FCM token (so flood
alerts keep silently failing), drop a river added on another device, and
undo flags the server set. Demonstrated against a fake Firestore.
*Shares the settings/auth path with item 1.*

### 3. The app can cache an EMPTY forecast over a full one · PARALLEL-SAFE
Two cache keys point at the same URL; last writer wins; the loser can be the
empty body. The user then sees a blank forecast held for six hours with no
indication anything is wrong. Found independently by two auditors. NOAA was
returning empty sections on 9 of 9 and 16 of 16 reaches on the day of audit,
so this path is being exercised now, not theoretically.

### 4. Metric users can see a flow 35.3x wrong, and the flood category inverts · PARALLEL-SAFE
Three separate routes, two of which flip the flood classification. Same
shape as the August card defect, this time from a race rather than a double
conversion. All three have runnable probes.
**Safety-relevant: this is a flood app.**

### 5. One failed request removes flood risk from a river for 30 days · PARALLEL-SAFE
A timeout and "this river genuinely has no thresholds" become the same
cached answer. Nothing retries, the freshness banner stays silent. Proven:
zero refetches across five reads after upstream recovered.
**Safety-relevant.**

### 6. Medium-range forecasts go stale every night · SERIAL
00:00–08:00 UTC daily, peaking at a run 32 hours old against a 24 hour cap.
The 2026-11-03 schedule fix cut this ~80%, not to zero. Before it, long
range served a run 196 hours old to live users.
*Shares the store refresh path with the alerting work in item 7.*

---

## Tier 2 — nothing would tell us if any of the above came back

### 7. Nothing watches production · PARALLEL-SAFE
Zero alert policies, zero notification channels, zero log-based metrics, no
log export. The six-week outage logged 611 errors while the function
reported 721 invocations and zero failures, because the failure is caught,
logged, and returns success. The built-in "function failed" alert could
never have fired. **Do not build on `storeHealth`:** it returned
`"healthy"` on a day the heartbeat logged degraded.
*Plan exists, costs $0, 12 policies and 2 email channels, all inside the
free tier.*

### 8. 22% of the test suite proves nothing · PARALLEL-SAFE
54 mutation experiments, 42 caught, **12 survived**. Three mechanisms:
- **grep-based wiring tests are defeated by `if (false)`** — the mutation
  keeps the string the test greps for and kills the behaviour. The entire
  ADR 0015 onboarding feature can be dead with 105 tests green. *These
  include tests written on 2026-11-02 by this session.*
- **two guards test a reimplementation**, not production. Deleting ADR 0014
  rule 2 (the refusal that stops `User.delete()` killing the wrong account)
  leaves 93 tests green.
- **no `FavoritesPage` or `FavoriteRiverCard` widget test exists at all**,
  which alone causes four of the findings.

### 9. A wall-clock assertion makes "one red line" normal · PARALLEL-SAFE
`river_data_repository_test.dart` asserts under 40 ms. Measured green
(1458/1458) on an idle machine and red (43 ms) under load. It is the fourth
version of a timing assertion the Phase 8 reviews caught three times. This
is exactly how the guest-mode regression's 27 new failures were read as
expected noise.

### 10. CI is a notification, not a gate · PARALLEL-SAFE
No branch protection; merges land a median of **2 seconds** after the branch
push while CI takes 3m20s. No CI job has ever built an artefact, and CI
compiles against a template whose token is the literal `INSERT-THE-KEY`, so
it is structurally incapable of catching the defect that shipped build 800.
All 10 integration test files are skipped on a premise CLAUDE.md has since
retracted.
**Jerson cannot fix the branch protection half: he has write, not admin, on
an org-owned repo.** It needs a CIROH-UA owner.

### 11. The release path has no guards where it has already failed · SERIAL
`make release-ios` and `make release-android` check nothing: not branch, not
cleanliness, not secrets, not the artefact. The iOS Release config still
carries `CODE_SIGN_IDENTITY = "iPhone Developer"`, the misconfiguration
behind the six-month push outage, worked around rather than fixed. The map
token reaches iOS through an optional include with no check.
**The reframe that matters:** every release is built locally, so nothing
between `main` and a store passes through GitHub. The Makefile checks are
the *primary* control and need nobody's permission. Do them first regardless
of the admin answer.
*Serial with item 10 — same release path.*

---

## Tier 3 — the record misleads the next reader

### 12. The banner at the top of CLAUDE.md points at a closed incident · PARALLEL-SAFE
Issue #38 closed 2026-11-09 03:23Z. SPF and DKIM both verified published.
The most-read paragraph in the repo sends every future session, and Dr.
Ames, chasing a solved problem.

### 13. 52 stale and 29 wrong claims across the docs · PARALLEL-SAFE
Of ~190 checked: 115 hold. **The pattern is clean: every claim resting on
n≤2 that could be checked came back wrong or stale; every claim pinned by a
test came back right, 21 for 21.** Documentation quality had nothing to do
with it; sample size did.
Includes: the GEOGLOWS publication window (wrong, spread to eight places,
sitting next to "do not re-derive it"), "83 errors, all benign" (94, 13 of
them store-down, over 25 days of being broken), and CLAUDE.md crediting a
retry that has never once fired.
*Proposal: a mandatory `⏱ MEASURED <date> · n=<count> · <method> ·
RE-MEASURE BY <date>` stamp, and a rule that an unstamped number may not
justify a decision or close a scope. CLAUDE.md goes 898 → ~380 lines.*

### 14. `storeHealth` reports a schedule that no longer exists · PARALLEL-SAFE
`functions/src/index.ts:207` serves ":20" when the cron is ":05", directly
below a comment warning against exactly this.

---

## Tier 4 — infrastructure exposure

### 15. Firestore has no backup, no PITR, no delete protection · PARALLEL-SAFE
Behind two guards that refuse a >50% delete, log ERROR, and return success.

### 16. The global forecast function still runs out of memory · SERIAL
Three kills on 2026-11-03 at ~2,060 MiB against a 2,048 limit. ~1.03 GB per
in-flight request and `containerConcurrency` is **80**, so two simultaneous
requests suffice. Documented as fixed in August; it was not.
*Serial with any other change to that function.*

### 17. The deployed flood-builder image lacks the guard that exists in source · PARALLEL-SAFE
The fix that stops a partial run republishing production (after a `--vpu`
test once replaced the live tileset with two reaches in Tanzania) is in
`daily/build_flooded.py` and not in the containerised copy. The scheduled
run passes no args, so the exposure is the manual command.

---

## Sequencing

**Do first, and alone:** item 7. Until something watches production we cannot
tell whether anything below regressed, which is the whole reason this
backlog exists.

**Then, parallel-safe in isolated worktrees:** 3, 4, 5, 8, 9, 12, 13, 14,
15, 17.

**Then serial, one at a time with a baseline:** 1 → 2 (shared auth path),
6 (store refresh), 10 → 11 (release path), 16.

**Required of every item, without exception:**
1. a test that is shown FAILING before the fix;
2. the mutation that proves the test is not vacuous — and for any
   grep-style guard, the mutation must be `if (false)`, not deletion;
3. a baseline captured before, and a stated condition for calling it fixed,
   written down before the work starts.
