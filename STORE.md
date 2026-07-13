# HelioFITS — launch copy

Working name **HelioFITS** (also open: SunFITS). Both are clear on the Mac App Store
as of 2026‑07‑12 — only "QuickFits", CloudMakers' "FITS Preview", and the unrelated
"Helio Fit" fitness app exist. Do NOT ship as "FITS Quick Look" (confusable with
QuickFits; Apple may reject "Quick Look" in an app name).

## Tagline
> Quick Look previews for AIA, HMI, LASCO, PUNCH & more — in the right colors.

## App Store description

**HelioFITS** brings instant, science‑accurate previews of solar FITS files to Finder —
made for heliophysicists and solar astronomers.

Press Space on any `.fits` file and see it rendered with the **correct instrument
colormap** — SDO/AIA gold, HMI magnetograms, LASCO, SUVI, EIT, PUNCH, K‑Cor and more —
drawn straight from the sunpy standard.

**Features**
- Instrument‑ and wavelength‑aware color tables (73 sunpy LUTs)
- Finder Info panel shows Telescope, Instrument, Wavelength, Observation Date, Exposure
  and HDU count — and makes them Spotlight‑searchable
- Handles multi‑extension and Rice‑compressed archive files; pick or pin which HDU to
  show per folder (auto‑first, auto‑last, or a specific HDU)
- Blink between HDUs to compare processing levels or filters, pixel‑registered
- Native FITS header viewer with one‑click PNG export for slides and papers

Made by a solar physicist, for the archive on your disk.

## Positioning note (internal)
Position *for* solar/heliophysics science — do not position against astrophotographers.
QuickFits serves astrophotography (debayer camera frames, export TIFF for further
processing); HelioFITS serves calibrated solar science data, where the colormap and
header metadata carry physical meaning. Different jobs; both are good tools. We adopt the
canonical `gov.nasa.gsfc.fits` type so the two coexist cleanly on one Mac.

## Distribution (decision pending)
- Direct notarized download + open source (recommended for this GitHub‑native audience;
  community can PR new instruments/colormaps), optionally also Mac App Store for reach.
- Price: free or free‑plus‑donate maximizes adoption + reputation; a token price filters
  for serious users and covers the $99/yr dev account.
