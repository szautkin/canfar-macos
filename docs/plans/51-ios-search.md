# Plan 51 — iPhone and iPad: Sky, a search for everyone (draft for thinking)

**Status: a draft for thinking (2026-10-24), nothing decided.** History:
- The person, first: "a search … I do not want to have a complex form … search collections like james
  web, hst telescope and some other latest and cool, we can use argus and prefil adql for high quality
  calibrated images".
- Then: "let's split plan for welcome pop up and the search fucntionality, I need to think more about the
  search on ios".
- Then: "let's think in details how it can be more frienlier for non astronomers? also, what if we add
  other sources not only cadc (ios version only); usually as non-astronomer I would like just to get some
  beatiful galaxy or say what major astronomical objects I can see from my location/town/place in the sky
  and give me some images?... what do you think, be critical and also, be proactively creative as well".

## The critical view first

1. **The first draft was for astronomers, not for everyone.**
   - "Webb's latest calibrated images" (level 3) are grayscale science frames, often of a few hundred
     MB.
   - Their names are like `jw02731-o001_t017_nircam_clear-f444w_i2d`.
   - Many of the latest are deep fields and calibration targets with nothing to "see".

   A non-astronomer opening one would find a dark grey square. Keep those shelves, but as the expert
   layer, not the front door.
2. **"Beautiful" pictures are not raw data.** The famous Webb and Hubble images are colour composites
   made by outreach teams from several filters. They come from ESA/Webb, ESA/Hubble, NASA, ESO and
   NOIRLab, under licences that differ: public domain, CC BY 4.0, or a photographer's copyright on APOD.
   Every image needs a credit, and a licence that allows showing it in an app.
3. **Do not build a planetarium.** SkySafari, Stellarium and Night Sky do the sky with AR, catalogues of
   millions and satellite passes, and do it well. Plan 47 already turned down a sky-finding feature. A
   full planetarium would make Verbinal a worse copy of them, and less of what it is.
4. **Seeing ≠ the picture.** M31 to the eye is a faint smudge; the picture is a telescope's. If the app
   says "you can see this tonight", it must say *how*: naked eye, binoculars or a telescope. It also
   depends on the Moon and the city's lights. Honest qualifiers, or it disappoints.
5. **Every outside source is a dependency.**
   - It can go down: Argus did on 2026-10-23.
   - It has fair-use rules.
   - Its licence must be checked before shipping, not after.
   - It costs testing.

   Few sources, chosen for clear terms and stable APIs, and a cache.
6. **Content is the hidden cost.** Friendly words for each object ("2.5 million light-years away: the
   light left it before there were humans"), in English and French, is writing, not code. Start small:
   about 40 objects.

## What only Verbinal can do: the bridge

From **a beautiful picture of something you can find in your sky**, to **the real data behind it**, in
the same app, in FITS and Cube viewers that read pixels, coordinates and checksums. Picture apps stop at
the picture, and archive tools start at the data; Verbinal can walk a curious person from one to the
other. That keeps it a science app with a friendly door, not a second planetarium.

```
  Tonight from Victoria      ->   Andromeda Galaxy (M31)     ->   The real data
  M31  high in the east,          [colour image, credited]        Survey FITS (2 MB) -> FITS viewer:
       binoculars                 "What is it" in plain words       zoom, sky coordinates, values
  Moon  bright, rises 21:14       Your eye · Binoculars ·         Hubble and Webb here (CADC)
  Jupiter  south-east, eye        Telescope · Hubble (FOV)          -> the archive's own files
  M42  rises 23:30                Visible / Infrared / Radio
                                  The full Moon to scale
```

## The design

### Sky: the place

The search-role tab (iOS 18, D7) is named **Sky**. Like the search tabs of Apple Music and TV, it has a
search field, and when nothing is typed it shows things to browse.

```
┌ Sky ──────────────────────────────── (SZ) ┐
│ 🔍 Search: Andromeda, Orion Nebula, M51    │
├ Tonight from Victoria · after 19:05 ───────┤
│ 🌕 Moon — bright, 92 %, rises 21:14         │
│ 🪐 Jupiter — south-east, naked eye          │
│ 🌌 Andromeda Galaxy — high east, binoculars │
│                                See all  ›  │
├ Galaxies ──────────────── Nebulae ─────────┤
│ [M31] [M51] [M81] …     [M42] [M16] …      │
├ Object of the day ─────────────────────────┤
│ [ wide colour image: the Pillars (M16) ]   │
├ For astronomers ───────────────────────────┤
│ Webb and Hubble in CADC's archive        › │
└────────────────────────────────────────────┘
```

- **Tonight** (D3, D4):
  - **Where:** the person's place, which they choose. It comes from the location, on tap, at reduced
    accuracy, or from a town they type (Apple's geocoder).
  - **What:** the catalogue's objects, plus the Moon and the planets.
  - **When:** sorted by how well placed they are tonight: above the horizon after dusk, high, and away
    from a bright Moon.
  - **Each row:** a direction in words ("high in the east"), when ("after 21:30"), and how ("naked eye ·
    binoculars · telescope", from magnitude and size).
  - **Honest notes:** "The Moon is bright tonight: faint galaxies are hard to see." "From a city, try
    binoculars."
  - **Nothing leaves the phone.** The sky is computed on the device. Requests to image services carry
    the object's position, never the person's.
- **Galaxies, Nebulae, Clusters, Planets:** shelves from the bundled catalogue.
- **Object of the day:** one object a day from the catalogue, preferring one that is visible from the
  person's place.
- **Search:**
  - a friendly name or a catalogue ID, matched against the catalogue first;
  - else CDS Sesame (SIMBAD) resolves it to a position and a type, and the object page is built from
    that (a generic page: picture, data, archive; no blurb).
- **For astronomers:** the first draft's CADC shelves, as they were (Webb, Hubble, cubes;
  calibration ≥ 3, public).

### An object's page

- **The picture:** a colour image at the object's size:
  - CDS **hips2fits** cuts any sky survey to any position and field (for example Pan-STARRS colour in the
    north, DSS2 colour elsewhere);
  - or a credited press image when the catalogue names one (D2).
- **The field of view, as a control**, the creative part: **Your eye · Binoculars · Telescope ·
  Hubble**. Each is a field (about 10°, 3°, 0.5°, 3′), cut again at the same place. M31 is a faint
  smudge at 10° and a spiral at 3°. The person learns why telescopes matter by sliding.
- **In different light:** Visible · Infrared · Radio, if surveys cover it (Pan-STARRS or DSS, 2MASS or
  WISE, NVSS or VLASS). The same patch of sky, different physics.
- **The full Moon to scale:** a faint circle of 0.5° over the picture. "M31 is six full Moons across."
- **What is it:** two or three plain sentences: type, distance in light-years, one wonder. Ours, written
  for the catalogue, in English and French.
- **When to see it from [town]:** rises, highest at, sets; how (eye, binoculars, telescope).
- **The real data (the bridge):**
  - **Survey image (FITS):** hips2fits again, as a small FITS (about 1–4 MB) with its WCS, into Downloads
    (plan 48). It opens in the **FITS viewer**: zoom, the compass, sky coordinates under the finger, the
    values.
  - **Hubble and Webb looked here:** CADC's archive around the position, with the first draft's rules
    (calibrated, public). It is the expert layer, one tap away.
- **Share:** a postcard, the picture with its name, place and credit.

### Sources (iOS only, D2)

| Source | For | Terms to check (spike) | Fallback |
|---|---|---|---|
| **CDS hips2fits** (Strasbourg) | the colour picture, the field slider, the wavelengths, the survey FITS | CDS fair use; each survey's credit and licence (DSS: STScI/AURA, and POSS plates; Pan-STARRS; 2MASS; WISE; NVSS/VLASS) | the last picture cached; another survey |
| **CDS Sesame / SIMBAD** | names to positions and types, outside the catalogue | CDS fair use, credit | the catalogue only |
| **CADC** (Argus, DataLink) | "Hubble and Webb looked here", the expert shelves | ours | cached last results |
| **NASA Image and Video Library** (later, D2) | press pictures | mostly public domain; each item's own credit | none needed |
| **ESA/Webb, ESA/Hubble, ESO, NOIRLab** (later, D2) | press pictures with AVM (sky position) | CC BY 4.0, credit | — |

**Not taken:** APOD. Many of its pictures are the photographers' copyright, case by case.

### The catalogue

A bundled `SkyCatalogue.json`, about 40 objects at first (D5):
- the Messier showpieces, famous NGC and IC objects, both hemispheres;
- the Moon and the planets.

Each entry has:
- id, names (English, French), type;
- RA and Dec (J2000);
- magnitude, size, distance;
- the best field;
- the preferred survey, north or south;
- "What is it" (English, French);
- how it is seen (eye, binoculars, telescope);
- an optional press-image reference.

Adding an object is one entry.

## How it is built (Pragmatic principles, applied)

| Principle | Here |
|---|---|
| **Orthogonality** | **SkyCore** is pure Swift with no UI and no network: sidereal time, altitude and azimuth, rise, transit, set, twilight, the Moon's position and phase, the planets (low precision, Meeus). **Sources** are adapters behind one protocol, **Catalogue** is data, and **Views** only show. The object page opens files through the shell (`iOSOpenFile`), as Compute does. |
| **DRY** | **One object page** whatever the way in (Tonight, a shelf, Search, Object of the day). **One `SkyImage`** (URL, credit, licence, kind: picture or FITS) for every source. **One archive client**, shared with the Mac (the first draft's S1). |
| **SOLID** | **O:** a new source is a new adapter; a new object, a new JSON entry. **I/D:** views depend on `ImageSource` and `PositionResolver` protocols, and tests use fakes. |
| **ETC** | The catalogue, the surveys per region, the fields (eye, binoculars, telescope, Hubble), the thresholds (twilight, a bright Moon, the cellular question) are data or constants in one place. |
| **Tracer bullet** | **One object, end to end:** M31 from the catalogue → its page → a hips2fits colour picture with its credit → Survey image (FITS) → the FITS viewer. Then Tonight, then the shelves, then the expert layer. |
| **Prototypes** | A throwaway spike before code: hips2fits speed and sizes per survey; each survey's licence for showing it in an app; Sesame's answers; the low-precision ephemerides against JPL Horizons for a few dates. |
| **Don't program by coincidence** | SkyCore is tested against published examples (Meeus) and Horizons, not against "looks right". |
| **Broken windows** | Credits on every picture from the first one; the outage words from the first; nothing about the person's place leaves the phone. |

## Steps

| # | Step | Size |
|---|---|---|
| **K0** | Spike (throwaway): hips2fits per survey (speed, size, look, north and south), the licences and the credit wording, Sesame, ephemerides vs Horizons. Decide the surveys. | S |
| **K1** | Tracer bullet: M31 in the catalogue; its page; the colour picture with its credit; Survey image (FITS) → FITS viewer. The Sky tab (search role) with that one object. | M |
| **K2** | SkyCore with its tests: sidereal time, altitude and azimuth, rise, transit, set, twilight, the Moon, the planets. | M |
| **K3** | Tonight: the place (location on tap, reduced accuracy, or a typed town), the list, the honest notes. | M |
| **K4** | The catalogue at about 40 objects (English and French words); the shelves; Object of the day; the field control; In different light; the Moon to scale. | L (mostly content) |
| **K5** | Search: the catalogue, then Sesame; the generic page. | S |
| **K6** | For astronomers: the CADC layer (the first draft's S1–S4: the shared archive client, the shelves, "Hubble and Webb looked here"). | M |
| **K7** | Share as a postcard; the outage cache; VoiceOver; French; iPad; the privacy wording (location: on-device, When In Use, reduced accuracy); App Review notes; a Sources and Credits page. | M |

Later, if the person wants them:
- the press pictures (NASA, ESA);
- a "point your phone" arrow (heading and altitude, not AR);
- Object of the day as a widget;
- a "clear skies?" note (WeatherKit: an entitlement and an attribution).

**Tests:**
- **SkyCore:** Meeus's worked examples; Horizons for the planets on several dates.
- **Visibility:** below the horizon, twilight, a bright Moon, the city note.
- **The catalogue's JSON:** each object has its position, field and survey, both languages, and a valid
  how-to-see.
- **The source adapters:** URLs built, answers parsed, failures said.
- **The object page's model:** its data.

## Decisions for the person (recommendation first)

| # | Decision | Recommended | Other |
|---|---|---|---|
| D1 | What Sky is | **a friendly door with a bridge to real data**: pictures and "tonight", then a survey FITS, then the archive | the first draft (CADC shelves only); a full stargazing app (no) |
| D2 | Sources in v1 | **CDS hips2fits and Sesame, plus CADC**; press pictures (NASA, ESA) later, once their licences are checked item by item | press pictures from the start |
| D3 | The person's place | **asked only on Tonight's first use: location (When In Use, reduced accuracy) or a typed town; computed on the device; never sent** | a typed town only, no location at all |
| D4 | The Moon and the planets in Tonight | **yes** (they are what people see), low-precision positions tested against Horizons | deep-sky objects only |
| D5 | The first catalogue | **about 40 showpieces from both hemispheres, our own words in English and French** | the 110 Messier objects at once |
| D6 | The tab | **Sky, the search-role tab: the search field and browse** | Sky as a plain fifth tab, with Search inside it |
| D7 | iOS minimum | **18** (the search role) | 17, with a plain tab |
| D8 | The field-of-view control and "In different light" | **in K4**: the most "Verbinal" parts, cheap with hips2fits | later |
