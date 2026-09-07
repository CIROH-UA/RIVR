# RIVR Store Listing Template

Fill in each section below before submitting to the Google Play Store and Apple App Store. Fields marked with (G) are Google-specific, (A) are Apple-specific, and (B) apply to both.

---

## App Identity

### App Name (B)
**Max 30 characters (both stores)**

```
RIVR - River Flow & Forecasts
```

Alternative options:
- `RIVR - River Flow Tracker` (25 chars)
- `RIVR - River Flow Monitor` (26 chars)
- `RIVR` (4 chars -- simple, but less discoverable)

### Subtitle (A -- Apple Only)
**Max 30 characters, appears below the app name on the App Store**

```
Real-Time River Flow & Floods
```

Alternative options:
- `NOAA River Flow & Flood Risk` (29 chars)
- `River Monitoring & Forecasts` (29 chars)
- `Stream Flow & Flood Forecasts` (30 chars)

### Short Description (G -- Google Play Only)
**Max 80 characters, appears in search results and the top of the listing**

```
Monitor river flows, check flood risk, and view NOAA forecasts for any US river.
```

Alternative options:
- `Real-time river flow data, flood risk alerts, and NOAA forecasts for the US.` (77 chars)
- `Track river conditions with NOAA data: flow rates, flood risk, and forecasts.` (78 chars)

---

## Promotional Text (A -- Apple Only)
**Max 170 characters, editable without a new build**

```
Live river flow and flood forecasts for millions of rivers worldwide, straight from NOAA's National Water Model and GEOGLOWS. Free, no ads, no paywall.
```

---

## Full Description (B)

**Google Play: max 4,000 characters. Apple: no hard limit, ~4,000 recommended.**

```
RIVR puts the NOAA National Water Model in your pocket. Check current river flow, see how close a river is to flooding, and read forecasts hours to weeks ahead — for rivers and streams across the United States and around the world.

LIVE RIVER FLOW
Current flow for 2.7 million US river reaches, updated hourly, in cubic feet or cubic meters per second. Every river carries a status badge — Normal, Action, Moderate, Major or Extreme — so you know at a glance whether it is running high.

FLOOD RISK, EXPLAINED
RIVR compares each river's flow against its own return-period thresholds (2-year through 100-year floods), the same benchmarks hydrologists and emergency managers use. You see not just the number, but what it means.

FORECASTS AT THREE RANGES
• Short range: hourly, next 18 hours
• Medium range: daily, next 10 days
• Long range: outlook to 30 days
Charts plot the forecast against flood thresholds, so a coming peak is obvious before it arrives.

RIVERS WORLDWIDE
Outside the US, RIVR draws on the GEOGLOWS global streamflow model for 15-day forecasts on rivers across every continent.

A MAP OF EVERY STREAM
Explore rivers on an interactive map, in 2D or 3D. Rivers at flood stage are coloured by severity, updated daily. Tap any stream for its conditions and forecast.

FAVOURITES AND ALERTS
Save the rivers you care about — near home, a fishing spot, a paddling run — and see them all on one screen. Turn on flood alerts and RIVR notifies you the moment a favourite river crosses a flood threshold, and as it gets worse.

BUILT ON PUBLIC SCIENCE
Data comes from NOAA's Office of Water Prediction, the CIROH return-period service, and the GEOGLOWS initiative. RIVR is built by HydroMap LLC with the Brigham Young University hydroinformatics group.

FREE, NO ADS
No subscriptions, no in-app purchases, no ads. Built as a public service.
```

**Character count:** ~1,900. Submitted to App Store Connect 2026-09-07. The
earlier draft said US-only; the screenshots show Peru, China and Congo, so the
copy now says what the reviewer will see.

---

## Keywords (A -- Apple Only)
**Max 100 characters, comma-separated, no spaces after commas**

```
river,NOAA,water,stream,hydrology,gauge,creek,discharge,level,monitor,kayak,fishing,rain,cfs,alert
```

**Character count:** 98. `flow`, `flood` and `forecast` were dropped on
purpose — they are in the app name, and Apple does not index a keyword twice.

**Notes:**
- Do not repeat words from the app name or subtitle (Apple indexes those separately).
- Apple treats these as individual search tokens; order does not matter.
- Avoid trademarked terms unless you have rights (NOAA is a government agency, so using it is fine).
- Single words perform better than phrases.

---

## Category

### Google Play (G)
**Primary category:** Weather
**Secondary category (if available):** Maps & Navigation

**Notes:** Google Play allows one primary category. "Weather" is the best fit because the app provides environmental/hydrological data and forecasts. "Maps & Navigation" would be an alternative if Weather feels off.

### Apple App Store (A)
**Primary category:** Weather
**Secondary category:** Navigation

**Notes:** App Store Connect allows a primary and secondary category. Weather fits best for discoverability among users looking for environmental monitoring. Navigation is suitable as a secondary given the map-based exploration feature.

---

## What's New (B)
**Used for each version release. Template below -- customize per release.**

```
What's New in RIVR [VERSION]:

- [Primary feature or improvement]
- [Secondary feature or improvement]
- [Bug fix or performance improvement]
- [Any other notable changes]

Thank you for using RIVR! Your feedback helps us improve.
```

**Example for a first release:**

```
Welcome to RIVR! This is our initial public release.

- Real-time river flow monitoring for 2.7M+ US river reaches
- Flood risk assessment with return period analysis
- Short, medium, and long range flow forecasts
- Interactive map with river search and exploration
- Save and track your favorite rivers
- Push notifications for flood risk alerts
- Support for both cubic feet/second and cubic meters/second

We would love to hear your feedback -- contact us at the support link below.
```

---

## URLs (B)

### Support URL (Required for both stores)
```
https://hydromap.com/contact/
```

**Notes:** Verified live 2026-09-07. `hydromap.com/support` is NOT a page — the
site serves its homepage for unknown paths, so that URL "works" (HTTP 200) while
showing a reviewer nothing about support. Use the contact page.

### Marketing URL (A -- Apple, Optional)
```
https://hydromap.com
```

### Privacy Policy URL (Required for both stores)
```
https://hydromap.com/privacy-policy/?product=rivr
```

### Terms of Service URL (A -- Apple, optional; also linked from the app)
```
https://hydromap.com/terms-of-service/?product=rivr
```

**Notes:**
- **Required** for both Google Play and App Store.
- Must be publicly accessible (not behind a login).
- Must accurately describe what data the app collects (Firebase Auth account data, favorites stored in Firestore, FCM tokens for push notifications, analytics events).
- Google Play requires this before you can publish.
- Apple requires this for apps that use account-based features.
- Hosted and verified live 2026-09-07 (mentions RIVR and Firebase). The
  `?product=rivr` query selects the RIVR section of HydroMap's policy. As with
  support, `hydromap.com/privacy` is a homepage catch-all, not the policy.

---

## Content Rating Guidance

### Google Play Content Rating Questionnaire

RIVR should receive an **"Everyone" (E)** rating. Key answers for the questionnaire:

| Question                                    | Answer |
|---------------------------------------------|--------|
| Violence                                    | No     |
| Sexual content                              | No     |
| Language                                    | No     |
| Controlled substances                       | No     |
| User-generated content                      | No     |
| Users can share info with others            | No     |
| Shares user location with others            | No     |
| Users can purchase digital goods            | No     |
| Contains ads                                | No     |
| Government-required content ratings         | N/A    |

**Note:** The app accesses device location for the map feature, but it does not share location data with other users. It stores favorites in Firestore (tied to the user's account), but this is not user-generated content visible to others.

### Apple App Store Age Rating

RIVR should receive a **4+** rating. Key answers:

| Content descriptor                          | Frequency   |
|---------------------------------------------|-------------|
| Cartoon or Fantasy Violence                 | None        |
| Realistic Violence                          | None        |
| Sexual Content or Nudity                    | None        |
| Profanity or Crude Humor                    | None        |
| Alcohol, Tobacco, or Drug Use              | None        |
| Simulated Gambling                          | None        |
| Horror/Fear Themes                          | None        |
| Medical/Treatment Information               | None        |
| Mature/Suggestive Themes                    | None        |
| Unrestricted Web Access                     | No          |
| Gambling and Contests                       | No          |

---

## App Review Notes (A -- Apple)

**Reviewer sign-in:** `appreview@hydromap.com` — a real Firebase Auth user,
created 2026-09-07. The password is NOT in this repo; it lives in App Store
Connect's Sign-In Information field and with Jerson. The app has no email
verification gate, so the account works as soon as it exists.

**Version field:** must equal the build's short version (`2026.2.x`, from
`make version`) or App Store Connect will not attach the build. It defaults to
`1.0.0` on a new app record.

**Notes for the App Store review team (not shown to users):**

```
RIVR is a river flow monitoring app that displays real-time data from the NOAA National Water Model.

Sign in with the reviewer account provided. Any new account created with an email address also has full access — there are no paid tiers.

To see the app working:
1. Favorites (home) lists saved rivers with their current flow and flood status.
2. Tap a river card for its forecast page: flow gauge, trend and forecast chart.
3. Tap the map icon (top left) to open the map. Tap any river line for its detail sheet, then "View Forecast".
4. Settings > Notifications shows the flood alert controls.

Location permission is optional; it only centres the map. Notifications are optional. The app needs an internet connection for live data.
```

---

## Additional Metadata

### Copyright (A)
```
2026 HydroMap LLC
```

### Developer Name (B)
```
HydroMap
```

### Developer Email (B)
```
admin@hydromap.com
```

### Developer Website (B)
```
https://hydromap.com
```

### Default Language (B)
```
English (United States) -- en-US
```

### Target Audience (G -- Google Play)
- Not directed at children under 13 (avoid COPPA requirements for the "Designed for Families" program)
- Target age: 13+

### App Access (G -- Google Play)
- The app requires account sign-in (Firebase Auth) to save favorites and receive notifications.
- All features are free; there is no restricted access for reviewers.

---

## Localization Notes

RIVR is currently English-only. If localizing in the future:
- Store listing text (name, description, keywords, what's new) should be translated per locale.
- Screenshots should be re-captured in each language, or use language-neutral screenshots.
- Both stores allow separate metadata per locale.
- Google Play supports 70+ languages; App Store supports 40+ languages.
