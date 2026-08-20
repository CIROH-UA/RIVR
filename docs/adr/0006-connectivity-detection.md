# 0006 — Detecting connectivity, not interfaces

**Status:** Accepted, shipped 2026-08-20
**Supersedes:** the original `ConnectivityService` / `OfflineBanner` pair

## Context

The offline banner had been in the app since early on and had never been
revisited. An audit of the whole path — 37 lines of widget over 31 of provider
over 17 of service — found eight defects, most of them below the widget.

## The decision that matters: an interface is not the internet

`connectivity_plus` reports which **network interface** is up. Its own
documentation states this is not a guarantee of internet access. Airport wi-fi,
a captive portal, a hotel splash page and a dead router all present a live
interface, so the banner stayed hidden in exactly the situations a user needs
telling.

An interface is now treated as **necessary but not sufficient**:

- No interface at all → conclusively offline, no probe.
- An interface present → confirm with a request to a 204 endpoint
  (`clients3.google.com/generate_204`) before declaring the app online.

The 204 is the point. A captive portal cannot fake it — it intercepts the
request and answers `200` with its own login page, which fails the check and
correctly reads as offline.

**Costs accepted:** one small request per state change, a dependency on a
third-party endpoint, and a 3-second timeout on the offline path. Mitigated by
caching the probe result for 10 seconds so rebuilds do not each hit the network,
and by only probing when an interface exists.

## Three bugs found in the same path

| Bug | Why it mattered |
|---|---|
| `results.every((r) => r == none)` | `Iterable.every` is vacuously **true** for an empty list, so a platform returning `[]` showed a false offline banner over a working app. |
| Unguarded `.then()` in the provider constructor | `notifyListeners()` after dispose throws. No `catchError` either, so a platform throw was an unhandled rejection. |
| No debounce | Interface events arrive in bursts; a wi-fi → cellular handover could flash the banner. Now debounced 900 ms and de-duplicated. |

## Accessibility

White on iOS `systemOrange` measures **2.2:1**. WCAG AA needs 4.5:1 at 13 px.
The colour was never the problem — the foreground was: the same orange with
near-black text measures **9.55:1**. Also added a wifi-slash icon so the state
is not carried by colour alone, and a `liveRegion` label, since the change was
previously invisible to VoiceOver.

## Placement

It was a `Positioned(top: 0)` inside a Stack, which **overlaid the first
favourite** rather than pushing the list down — despite a code comment claiming
it was "pinned below nav bar". It now sits in a column and takes real height.

**One `SafeArea` wraps that column, not one per child.** The scaffold's
navigation bar is translucent, so the child starts at y=0 behind it and
something must clear it; but as *siblings*, the banner's `SafeArea` and the
list's own each applied the full inset and opened a gap. Nested, the outer one
consumes the padding and hands descendants a zeroed `MediaQuery`, making the
inner one a no-op.

This was found on device, not by reasoning: the first attempt removed the
banner's `SafeArea` entirely and the banner vanished behind the nav bar.

## Rejected

- **A recovery toast.** Jerson: *"There is no need to have a recovery toast, you
  simply don't display the orange banner anymore. The simple the better."*
- **Reusing this banner on the map.** See `MapOfflineNotice`: orange is the
  Moderate rung of the flood ladder, and a connectivity message in a flood
  colour reads as a flood. The map keeps its own neutral pill and different
  wording, because there the risk is tiles rather than stale numbers.

## Still open

`error_service.dart` produces its own "No internet connection…" strings in two
places. Different surface, different wording, not unified.


## Correction — what the CI failure actually was (2026-08-20)

CI went red on this work: `flutter analyze` flagged
`unawaited_return_in_try_block` on `isCurrentlyOffline`, where
`return offlineFor(results)` handed the future back before the try block
closed.

**The first explanation given for it was wrong.** The commit message claimed a
probe timeout would escape the catch. It would not: `_canReachInternet` wraps
the entire probe in its own `catch (_)`, and Dart's bare catch takes `Error` as
well as `Exception`, so timeouts, DNS and TLS failures are absorbed one level
down. `_hasNoInterface` is pure list work.

**Measured:** `offlineFor` is total on every current path. Three tests now pin
it — a throwing client, a thrown `Error`, and a 30-second timeout all resolve
to `true` rather than propagating.

The `await` stays, but as defence rather than a fix: that totality is an
internal detail one refactor away from changing, and the design promise is that
a hiccup must never be reported as offline.

## Local and CI run different Flutter versions

The lint was invisible locally because this machine is on **3.41.7** while CI
resolves `channel: stable` to **3.47.1** — four months apart. Local `flutter
analyze` being clean is not evidence that CI will be.

Two consequences worth acting on before a release:

- CI re-resolves `stable` on every run, so it can turn red on untouched code.
- `SizeTransition.alignment` does not exist in 3.41.7, so the two
  `axisAlignment` deprecation infos introduced here cannot be cleared without
  upgrading. They are infos, and CI runs `--no-fatal-infos`, so they do not
  block today.
