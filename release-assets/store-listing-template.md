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

## Full Description (B)

**Google Play: max 4,000 characters. Apple: no hard limit, ~4,000 recommended.**

```
RIVR puts the power of the NOAA National Water Model in your pocket. Monitor real-time river flow conditions, assess flood risk, and view short-, medium-, and long-range forecasts for rivers and streams across the United States.

REAL-TIME RIVER FLOW DATA
Track current flow conditions for over 2.7 million river reaches modeled by the National Water Model. See flow rates in cubic feet per second (cfs) or cubic meters per second (cms), with at-a-glance status indicators showing whether a river is flowing at normal, above-normal, or flood levels.

FLOOD RISK ASSESSMENT
Understand flood risk instantly with return period analysis. RIVR compares current and forecasted flows against established flood thresholds (2-year, 5-year, 10-year, 25-year, 50-year, and 100-year return periods) to show you whether a river is at normal flow or approaching action, moderate, major, or extreme flood risk.

MULTI-RANGE FORECASTS
View forecasts at three time horizons:
- Short range: Detailed hourly forecasts for the next 18 hours
- Medium range: Daily forecasts extending out 10 days
- Long range: Extended outlook up to 30 days

Interactive charts display forecasted flow alongside return period thresholds so you can see at a glance when and if flood levels may be reached.

INTERACTIVE MAP
Explore rivers across the US on a fully interactive map powered by Mapbox. Search for rivers by name or location, tap any river reach to view current conditions, and discover new waterways in your area.

SAVE YOUR FAVORITES
Build a personalized list of rivers you care about. Save your favorite fishing spots, kayaking runs, or rivers near your home and community. Your favorites dashboard shows current conditions for all saved rivers at a glance.

PUSH NOTIFICATIONS
Receive alerts when rivers on your favorites list reach elevated flood risk levels. Stay informed about changing conditions without having to check the app constantly.

POWERED BY NOAA
RIVR uses data from the NOAA National Water Prediction Service and the National Water Model, operated by NOAA's Office of Water Prediction. Return period thresholds are provided by the Cooperative Institute for Research to Operations in Hydrology (CIROH). This means you get the same authoritative data used by professional hydrologists and emergency managers, presented in an accessible mobile format.

FREE TO USE
RIVR is completely free with no in-app purchases, no ads, and no paywalls. Built as a public service tool to democratize access to critical water data.

Whether you are a kayaker checking river levels before a trip, a homeowner monitoring flood risk near your property, a farmer tracking irrigation water supply, or an emergency manager assessing conditions across a region, RIVR gives you the data you need in a clean, fast, mobile-first experience.
```

**Character count:** ~2,250 (well within both store limits)

---

## Keywords (A -- Apple Only)
**Max 100 characters, comma-separated, no spaces after commas**

```
river,flow,flood,forecast,NOAA,water,stream,hydrology,gauge,creek,weather,discharge,level,monitor
```

**Character count:** 95

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
https://hydromap.com/support
```

**Notes:** Both stores require a support URL. The page must exist and be live at submission time. Action item before submission: publish a support page at `hydromap.com/support` with at minimum a contact email (`admin@hydromap.com`) and a brief FAQ, or redirect this URL to a help-center page hosted elsewhere.

### Marketing URL (A -- Apple, Optional)
```
https://hydromap.com
```

### Privacy Policy URL (Required for both stores)
```
https://hydromap.com/privacy
```

**Notes:**
- **Required** for both Google Play and App Store.
- Must be publicly accessible (not behind a login).
- Must accurately describe what data the app collects (Firebase Auth account data, favorites stored in Firestore, FCM tokens for push notifications, analytics events).
- Google Play requires this before you can publish.
- Apple requires this for apps that use account-based features.
- Action item before submission: host the policy at `hydromap.com/privacy` (currently in draft at `docs/internal/privacy-policy-draft.md`, awaiting attorney review and hosting setup — see project schedule).

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

**Notes for the App Store review team (not shown to users):**

```
RIVR is a river flow monitoring app that displays real-time data from the NOAA National Water Model.

Demo instructions:
1. Launch the app and sign in (or create an account with any valid email).
2. The Favorites tab shows saved rivers. If empty, tap the "+" button or go to the Map tab.
3. On the Map tab, tap any blue river line to see current flow data.
4. Tap "View Details" to see full forecast charts and flood risk analysis.
5. Tap the star icon to save a river to favorites.

The app requires an internet connection to fetch real-time data from NOAA servers.

No demo account is needed -- the app uses Firebase Auth and any new account can access all features. There are no paid features, subscriptions, or in-app purchases.
```

---

## Additional Metadata

### Copyright (A)
```
2026 HydroMap
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
