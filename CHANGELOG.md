# Changelog

All notable changes to HelioFITS are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.5.0] - 2026-10-24

### Added

- **A header drawer in Quick Look.** A Header chip opens the current layer's header
  beside the preview and follows the layer as you scroll. One-click groups (All, Time,
  Instrument, WCS, Exposure) narrow it, and pinned keywords (pinned in the viewer or in
  Settings) come first and also show in the caption. iPhone and iPad get a Header sheet
  (#2, #66).
- **Filters: RHEF, MGN and WOW.** The viewer and Quick Look offer None, RHEF, MGN and
  WOW, with an optional swipe that shows the unfiltered image beside the filtered one.
  The readout keeps reporting the raw data (#4, #69).
- **RHEF controls.** Shadows and Highlights sliders reshape the RHEF image live, a
  Reveal control wipes back to the plain image, and the readout gives each pixel's rank
  in its ring (#71). Save RHEF PNG writes a RHEF image without changing the view (#73).
  An opt-in setting runs RHEF at full resolution in the viewer (#76).
- **A colorbar** beside the image that follows the live stretch, with typed vmin and
  vmax and draggable histogram handles. It hides in the narrow Finder column pane (#15).
- **Solar-coordinate tools.** Plane-of-sky rings and position-angle spokes (viewer,
  Quick Look, iPhone and iPad), and Compare for two files linked by helioprojective
  coordinates: swipe, blink or side by side in the viewer, a swipe on iPhone and iPad
  (#63).
- **Movie mode.** Open a folder to play its FITS files in DATE-OBS order, with a frame
  rate menu, a scrubber and an optional running difference. Play also loops a file's
  layers. Nothing starts playing by itself (#70).
- **Provenance in saved images.** Save PNG, the batch exporter and iOS Share write the
  display recipe (layer, colormap, limits, stretch, filter, app version) into the PNG's
  text chunks, with a RHEF stamp when RHEF is on. An Info popover shows the same
  recipe, and Copy Python now reproduces what is on screen (#64, #65).
- **Finder thumbnail labels.** Thumbnails of 128 px and up carry the file's instrument
  and wavelength from its header, files with several layers show a stack edge, and an
  opt-in setting draws an RHEF cover for files with a solar limb (#67).
- **Keyboard readout cursor.** Option-arrow moves a readout crosshair, Option-Shift-arrow
  draws a box and reports its statistics (#72).
- **A `heliofits` command-line tool** (build from source) with `--header`, `--info` and
  `--export` (#52).

### Security

- **The Finder Quick Look and Thumbnail extensions refuse oversized and compressed
  input.** A 5 KB header could ask the CFITSIO shim for gigabytes, and a gzip or PKZIP
  file made CFITSIO allocate up to 4 GiB. The extensions (macOS and iOS) now set a
  2^28 pixel limit (16384 x 16384) and show their usual "cannot preview" result for
  anything over it and for gzip, PKZIP, bzip2, compress, pack or LZH files. The main app
  is unchanged (no limit). Takes effect after `build-universal.sh` rebuilds the xcframework.
  See SECURITY.md.

### Changed

- **The app icon is the AIA 171 Sun inside a white file outline,** matching Heliad,
  HelioFITS Studio and Heliogram. The outline, screen and violet-black ground follow
  Heliogram's icon. The Sun is now the real AIA 171 frame of 2024-05-14 16:51:09 UT at
  full resolution, tone-matched to the old icon's disc, instead of the 512 px art.
  `scripts/make_app_icon.py` draws the macOS and iOS icon sets from
  `scripts/icon_sources/`.

- **RHEF follows RHEF 2.0's Upsilon split at 0.5.** The filter split its
  double-sided gamma at each annulus's mean rank; it now splits at 0.5, as the
  oRHEF-2.0 convention does, and accepts a (low, high) Upsilon pair. No image
  changes: ranks here are multiples of 1/(2m), so the only rank between 0.5 and the
  mean is 0.5 itself, where both halves meet (checked bit for bit on the RHEF golden
  bundle and on random tie-heavy data). Copy Python now names the deviations
  HelioFITS still declares (TIES-TOL, KEY-QUANT, GEOM-GRID, DTYPE-IN).

### Fixed

- **RHEF drew horizontal stripes over flat regions.** PUNCH L3 fills its
  out-of-field corners and occulter with exact zeros, a fifth of the frame. The
  filter ranked tied values one by one in scan order, so a constant region came
  out as row-by-row bands, and CFITSIO decodes that Rice-compressed zero fill to
  a tiny offset that differs per row (about 1e-29, where astropy reads exact 0).
  It now ranks ties the way sunkit-image's `rhef` does by default (average rank,
  `method="scipy"`), counting values within a billionth of the frame's peak as
  tied, so the fill stays flat. On data without ties or such noise the output is
  unchanged. Copy Python now calls `rhef` with
  that default rather than `method="numpy"`.

### Changed

- **iPhone and iPad read only the pixels they draw.** Rendering on iOS now reads a
  strided subset of a large image through a new `fitsshim_read_image_max` in the
  CFITSIO shim (a compressed image is decoded one tile at a time), so a 4096x4096
  PUNCH PAM plane never sits in memory whole. The Mac keeps the full read, so its
  clip levels are unchanged. The iOS preview also drops a PNG decode it did not
  need. The author measured, in the Simulator on a PUNCH PAM cube, a preview peak
  of 73 MB and a thumbnail peak of 8.5 MB (#35).

## [1.4.0] - 2026-09-27

Opening the app now opens the viewer, the viewer knows where its file lives, and Copy Python
hands you the array.

### Added

- **Show in Finder and Copy Path in the viewer.** Two buttons beside Copy Python,
  also in the File menu as Show in Finder (⇧⌘R) and Copy Path (⌥⌘C, the same
  shortcut Finder uses for Copy as Pathname).
- **The viewer's title bar carries the file's icon.** Drag it into Terminal, Mail
  or a save panel to hand over the file, or ⌘-click the title to see the folders
  above it.

### Changed

- **Opening the app now opens the viewer, not the settings.** With no file, the
  window is a drop zone: drop a FITS file on it or click Open… (⌘O). Opening a
  file still shows only that file's viewer.
- **The landing page is now a Welcome window** beside the viewer on launch, with
  a "Don't show this again" checkbox. Help ▸ Welcome to HelioFITS brings it back.
- **The default-layer and folder-rule controls moved to Settings (⌘,),** the
  standard macOS Settings window.
- **"Sync FITS previews to HDU…" is now its own dialog.** It used to be a sheet on
  the settings window, so it could arrive attached to a window that was hidden.
- **Copy Python now hands you the array by name.** The snippet includes
  `data = m.data`, the displayed HDU as stored in the file (a numpy array, with
  the header and WCS still on `m`). A separate numpy export would have been the
  same numbers without the metadata.
- **With RHEF on, Copy Python reproduces it.** The snippet adds sunkit-image's
  `radial.rhef` with the viewer's settings (`upsilon=0.35`, ordinal ranking) and
  names the result `rhef_data`. HelioFITS runs the filter on a display-sized grid;
  the snippet runs it at full resolution. Checked with sunkit-image 0.7.0 on an
  AIA 1700 frame and a PUNCH PAM cube plane.

## [1.3.2] - 2026-09-23

Multi-extension files are no longer cut off at eight, and the icon no longer sits on a grey
plate at small sizes.

### Fixed

- **Files with more than 8 image extensions showed only the first 8.** A UCoMP
  level 2 file carries 12. The viewer now pages through up to 128.
  ([#25](https://github.com/GillySpace27/HelioFITS/issues/25))
- **The app icon sat on a grey plate at 16 pixels on macOS 26.** The icon art
  arrived with its corners already rounded, and macOS 26, which applies its own
  shape, insets such art on a plate. The same AIA 171 icon is now supplied as
  full squares and macOS does the rounding.

### Changed

- **The About panel says what HelioFITS is and links to HelioFITS Studio,** the separate
  desktop application for coronagraph and wide-field imagery, so the two are not
  confused.

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
