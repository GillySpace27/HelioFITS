# Changelog

All notable changes to HelioFITS are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.1] - 2026-08-21

Two fixes, one of which meant a headline feature of 1.3.0 never actually ran.

### Fixed

- **"Open a Finder Window" always failed.** The button on the settings screen
  reported *"The application HelioFITS does not have permission to open
  gilly"* and opened nothing. It handed the home directory to the system open
  call, which the sandbox refuses: the app may only reach folders you choose
  yourself through a panel. It now asks which folder to open, starting in your
  home directory, and opens that. Broken since 1.2, on every click.
  ([#24](https://github.com/GillySpace27/HelioFITS/issues/24))
- **The Proba-3/ASPIICS colormaps added in 1.3.0 could never be selected.**
  The colour table is chosen from FITS header keywords, and the header reader
  that supplies them is compiled into a vendored library rather than built with
  the app. That library had not been rebuilt since 15 July, so the keywords the
  matcher needed were never present and every ASPIICS image fell back to the
  wide-band table. Rebuilt, and the matching is now verified against real files
  from the P3SC archive rather than against reported keyword values.
  ([#9](https://github.com/GillySpace27/HelioFITS/issues/9))
- **Level-3 ASPIICS products were matched on the wrong keyword.** Level-3
  processing removes `FILTER` and carries `PROD_ID` instead, which was not
  being read. Polarised brightness also needed both spellings: the archive
  writes `Polarizer` in level 1 and 2 and `Polarisation` in level 3. Green
  line, He I D3, polarised brightness and total brightness now each select
  their own table. Polarisation angle deliberately gets none: it is a cyclic
  quantity in degrees, and a brightness ramp would imply an ordering it does
  not have.

## [1.3.0] - 2026-08-19

First release driven entirely by reports from other people. Thanks to
[@DavidBerghmans](https://github.com/DavidBerghmans) (PI, Solar Orbiter/EUI),
[@nawinnova](https://github.com/nawinnova), and Chris Lowder (SwRI).

### Fixed

- **Images were displayed upside down.** Every image, on every instrument, since
  the first release. The renderer produced them correctly, which is why
  **Save PNG** always looked right, but the view drew them inverted. The pixel
  readout indexed the data in the renderer's orientation, so the values under
  the cursor disagreed with what was on screen. Reported by David Berghmans on
  an EUI/FSI frame with a polar coronal hole and a one-sided eruption, where the
  flip is finally visible; a full-disk AIA or PUNCH image is symmetric enough to
  hide it. ([#11](https://github.com/GillySpace27/HelioFITS/issues/11))
- **The pixel readout went stale after zooming** and reported values for a pixel
  the cursor was no longer over. It is now re-sampled whenever zoom or pan moves
  the image under a stationary pointer.
  ([#13](https://github.com/GillySpace27/HelioFITS/issues/13))
- **The stretch sliders silently did nothing while RHEF was active.** The filter
  and the stretch now compose: RHEF decides the ordering of the values and the
  stretch decides how that ordering maps onto the colour ramp, so the sliders
  work on a filtered image the way they do on an unfiltered one. Moving a slider
  no longer re-runs the filter either, only the per-pixel remap.
  ([#14](https://github.com/GillySpace27/HelioFITS/issues/14))

### Changed

- **The clip sliders are now logarithmic** in distance from their end of the
  distribution. A solar image has a heavy tail, so a linear percentile slider
  spent almost all of its travel doing nothing and the last fraction doing
  everything: on a typical AIA frame the final quarter of the High slider moved
  the white point by 13,925 counts while the first three quarters moved it by
  579 between them. Each quarter now moves it by a comparable amount.

- **The pixel readout is pinned to the top-left** instead of the bottom-left,
  where it grew into the filter menu and the Limb/Diff/Stretch buttons. Region
  statistics moved to the top-right to make room.

### Added

- **File ▸ Open… (⌘O).** The app could always open a FITS file, but only by
  double-clicking one in Finder. It replaces SwiftUI's "New Window" item, which
  did nothing useful: the only window the app owns is the settings panel, and
  that already has its own item at ⌘,.

- **Solar Orbiter/EUI colormaps.** FSI 174 and HRI_EUV use the AIA 171 table,
  FSI 304 uses AIA 304, and HRI_LYA has its own, from the table David Berghmans
  supplied. ([#10](https://github.com/GillySpace27/HelioFITS/issues/10))
- **Proba-3/ASPIICS colormaps** (wb, fe, he, p, ne), from the SIDC colour-table
  page, which sunpy does not yet carry. The header matching for these is
  **unverified** against real ASPIICS data; please report anything that renders
  in greyscale. ([#9](https://github.com/GillySpace27/HelioFITS/issues/9))
- **The stretch panel now shows the actual data limits** it is clipping to, with
  units, instead of only percentiles. Asked for by Chris Lowder, who wanted to
  know what vmin/vmax a PUNCH image was actually being scaled between.
  ([#12](https://github.com/GillySpace27/HelioFITS/issues/12))
- **The region-statistics histogram is now readable rather than decorative.**
  The distribution of the whole image is drawn behind the selected region's on a
  shared axis, so you can see whether a region is typical or unusual; the axis is
  labelled in data units; and the current display limits are drawn across it as
  markers, which shows how much of the data a stretch is clipping away in a way
  two numbers cannot. Binning runs over the image's 0.1–99.9 percentile range,
  because a min-to-max axis put a solar frame's entire distribution in the first
  two bins. Fixes the statistics text being cut off after the second line.

## [1.2] - 2026-07-28

First App Store release.

### Added

- **RHEF**, the Radial Histogram Equalizing Filter
  ([Gilly & Cranmer 2025](https://doi.org/10.1007/s11207-025-02578-x)), applied
  live in the preview and the viewer. Renders off the main thread.
- **PUNCH data cube support**: PAM/CAM polarization cubes render per plane, and
  the copied sunpy snippet slices the exact plane on screen.
- Keyboard control in the viewer: arrows blink layers, Command +/-/0 zoom,
  Command-C copies the readout. Toolbar toggles announce state to VoiceOver.

### Changed

- The main window was rebuilt around what the app does rather than its settings,
  after a usability review across a range of experience levels.
- Toolbar controls are labelled with words instead of symbols, since Quick Look
  never shows tooltips.

### Fixed

- Layer captions wrap instead of truncating in narrow Get Info previews.
- HMI magnetograms no longer render as a flat grey disk.
- A file that fails to render no longer claims to be a data table.

## [1.1.1] - 2026-07-15

### Added

- Universal binary: Intel Macs as well as Apple Silicon.

## [1.1] - 2026-07-15

### Fixed

- Table-only FITS files get a recognizable placeholder instead of a generic icon.

## [1.0] - 2026-07-14

Initial release: Quick Look previews, Finder thumbnails, Spotlight metadata and
a standalone viewer for solar FITS files.

[1.3.0]: https://github.com/GillySpace27/HelioFITS/releases/tag/v1.3.0
[1.2]: https://github.com/GillySpace27/HelioFITS/releases/tag/v1.2-build.6
[1.1.1]: https://github.com/GillySpace27/HelioFITS/releases/tag/v1.1.1-build.3
[1.1]: https://github.com/GillySpace27/HelioFITS/releases/tag/v1.1-build.2
[1.0]: https://github.com/GillySpace27/HelioFITS/releases/tag/v1.0-build.1
