## Item 4 — a metric user could see a flow 35x wrong, with the flood category inverted

**Broken.** One invariant, three ways: the stored entry's unit tag did not
describe the payload it was attached to.

* The tag was read from the live preference BEFORE the await, while the
  conversion read it again AFTER. The favourites page flips that preference
  without cancelling in-flight reads, so a toggle landing in that window
  tagged CMS data as CFS. The decoder trusts the tag alone, re-converted, and
  produced a number 35.3x too low — then classified against correct
  thresholds, so every river read Normal. In a flood app.
* One point with a null flow, which NOAA does send, threw a cast error that
  discarded the ENTIRE series around it. A 120-point forecast with one bad
  reading rendered as "No data", and the empty result was cached as a
  confirmed success.
* The 30-second unfiltered-fallback cache was keyed by reach alone and stored
  already-converted bytes with no record of the unit.

**Changed.** The converter now stamps the payload with the unit it actually
produced, and the data source reads that stamp instead of the preference, so
tag and payload cannot disagree by construction. Unreadable points are
dropped individually, with the count logged. A payload with no readable
points anywhere is refused at the source rather than stored as a success.

**Break-it review.** Five mutations, all caught: removing the stamp;
`if (false)` around the stamp; `_unitOf` ignoring the stamp; bad points
discarding the series again; `if (false)` around the usable-series guard.

Two things worth recording. The usable-series check first named a section
per product, which duplicated a mapping that belongs to `ForecastValues` —
replaced with "is there anything readable anywhere", using the real parser
rather than counting raw entries, because a section can be structurally
present and decode to nothing. And four existing tests broke: their fixtures
carried a referenceTime with zero points, which is not a response NOAA sends
successfully. Fixtures made realistic; the assertions they make about call
mapping and run identity are untouched.

1,480 tests, analyze clean.

