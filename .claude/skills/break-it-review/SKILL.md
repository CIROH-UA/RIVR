# Break-It Review — RIVR

**Required before anything ships. Not a read-through. The reviewer's job is
to make the work fail.**

Run this when a change is finished and before it is merged to `development`,
and again before any build goes to a store.

---

## Why this exists, in one paragraph

Everything else was already in place and did not work. The guest-mode
disaster — which destroyed saved rivers, blocked every new user, and deleted
a real account of eight months — went through correctly named branches, a
`--no-ff` merge every time, and a green test suite, across five builds. An
audit on 2026-11-09 mutation-tested a sample of this suite and found **22%
of it vacuous**: 12 of 54 guards stayed green when the thing they claim to
protect was deleted. Two of those were written the week before by someone
who believed they were careful. Reading a diff has never caught any of it.
Trying to break it has caught all of it.

---

## Who reviews

**Someone, or some agent, that did not build it.** In practice: a fresh
agent given the diff and the claim, and NOT given the author's reasoning.

That matters more than it sounds. On 2026-11-03 two auditors were
deliberately kept from the prior conclusions; they found a stale cache that
had been broken for six weeks, a refresher checking for data twenty minutes
before fetching it, and four wrong claims in the prior work. An auditor shown
the conclusions first would have spent the day confirming them.

---

## The three questions

Every review answers all three, in writing, with evidence.

### 1. Can you make the test pass while the feature is broken?

Mutate the production code so the behaviour is gone, and run the test. **If
it stays green, the test is worthless and the change is not reviewed.**

Mutations that this repository has actually needed:

| Mutation | What it exposed |
|---|---|
| Delete the call the test greps for | the honest baseline |
| **Keep the call, make the body `if (false) return;`** | every grep-style guard in this repo. The test greps for a string; the string is still there |
| Replace a widget's effect but keep its layout size | a guard using `tester.getSize`, which is blind to transforms |
| Flip a threshold by one | a counter guard using two failures against a threshold of three |
| Swap the real implementation for the test's own fake | two guards found testing a reimplementation, not production |

**A mutation that does not compile proves nothing.** Make it compile, run it,
record what happened.

### 2. Can you reproduce the measurement that justified it?

Re-take it. Do not read it.

Every number in this repository that rested on **n ≤ 2** and could be checked
came back wrong or stale. Every number pinned by a test came back right, 21
for 21. The checklist before trusting any figure:

- **n, and min/median/max.** One sample is not a measurement.
- **Who generated the traffic?** A headline "p50 7.9 s" was 95% the
  investigator's own probing; the real user figure was 24.3 s, and the error
  inverted the recommended fix.
- **Which cache answered?** There are four: in-process in a Python function,
  the Firestore store, the Dart repository cache, and an unfiltered-response
  fallback. None announces itself.
- **Which of the two paths?** US rivers go through NOAA, global rivers
  through a separate proxy. A claim about "a river" is usually true of one
  and false of the other.
- **Same machine?** A Python import measured 1.6 s on the Mac and 6.6-7.8 s
  on the container.
- **Are the inputs real?** Three reach IDs invented for a fixture nearly
  became a reported NOAA outage.

### 3. What did the author claim without proving?

Go through the description and the comments. For each statement, mark it
**measured**, **inferred**, or **unsupported**. Say which.

Specific things to hunt, all of which have shipped here:

- a comment describing a mechanism the code does not have (a function whose
  comments promise an hourly retry; it runs once a day);
- "verified" or "tested" for a check nobody ran;
- a scope exclusion resting on a stale number (favourites were excluded from
  a performance investigation on a figure from two months earlier that
  measured a different screen);
- a fix credited with an improvement something else produced (a retry that
  has fired zero times in production, credited in the docs);
- a number with no date.

---

## What a passing review looks like

A short written answer to all three, attached to the change:

```
BREAK-IT REVIEW
1. Mutations tried:   <each one, and whether the test went red>
   Survivors:         <none, or: the guard is vacuous and here is why>
2. Measurement:       <re-taken, n=, min/median/max> or <none claimed>
3. Unproven claims:   <each, or: none found>
Verdict: ship / do not ship
```

**A survivor in question 1 blocks the change.** Not a note for later.

---

## Enforcement, honestly

This cannot be made a hard gate today. Branch protection needs repository
admin, which Jerson does not have on `CIROH-UA/RIVR`, and every release is
built locally so nothing between `main` and a store passes through GitHub
anyway.

So it is enforced by habit and by `git-guard`, which asks for it before a
push. That is weaker than a gate and the weakness is written down here on
purpose: twenty of the last hundred commits to `development` went in
directly, and `git-guard` caught none of them.

If repository admin is ever granted, the thing worth spending it on is
**required status checks**, not required pull requests. A branch name would
not have stopped any of the three worst failures in this project's history.
