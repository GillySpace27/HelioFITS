# icon_sources

Inputs of `scripts/make_app_icon.py`.

| File | What it is |
|---|---|
| `aia_171.png` | SDO/AIA 171 full disc, image time 2024-05-14 16:51:09 UT (Helioviewer sourceId 10), the X8.7 flare day that HelioFITS Studio's iris is cut from. A Helioviewer render with its standard AIA 171 colour table: 1200 x 1200 px, 1.9 arcsec/px, centred on the Sun, no watermark, scale bar or events. Fetched 2026-10-23 for a requested time of 2024-05-14T16:51:00Z; the image time is from `getClosestImage`. A byte-scaled render for the icon, not calibrated data. |
| `shipped_icon_512.png` | The 512 px icon HelioFITS shipped before 2026-10-23 (`icon_512x512@1x.png` at 7f7c58d). Only its disc's brightness distribution is used, as the tone target. |

Request for `aia_171.png`:

```
https://api.helioviewer.org/v2/takeScreenshot/?date=2024-05-14T16:51:00Z&imageScale=1.9&layers=[SDO,AIA,AIA,171,1,100]&events=&eventLabels=false&scale=false&watermark=false&x0=0&y0=0&width=1200&height=1200&display=true
```

Credit: SDO/AIA data courtesy of NASA/SDO and the AIA science team; rendered by Helioviewer
(helioviewer.org).
