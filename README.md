# Recorte

**A native macOS app for vinyl cutters, made for designers. For now it supports the Liyu GF-1261.**

Recorte opens on an empty canvas where you draw shapes, write text (outlined automatically)
and import Illustrator / SVG / PDF / DXF artwork. Pick a material, press **Cut…**, done. It
also does **Print & Cut** with the cutter's registration-mark camera, without SignMaster or a
Windows VM.

Built by [CookieBytes](https://cookiebytes.pt) — software development & home automations.

- Swift 6, SwiftUI, macOS 14+
- English and Portuguese (follows the system language)
- No drivers: the cutter is a USB printer-class device, so Recorte sends HPGL through a raw
  CUPS queue (a serial-port transport is also included for other HPGL cutters)
- Projects are saved as `.recorte` files (older `.cookiecut` projects still open)

> **Status:** early development, built and tested against a GF-1261. Other Liyu GF-series
> models may work but haven't been tried.

## How the protocol was worked out

Liyu publishes no protocol documentation, and its software is Windows-only. The USB traffic
from SignMaster was captured and decoded to learn the device identity, the coordinate system
and the Print & Cut preamble. The raw captures, the extraction script and a step-by-step
write-up are in **[docs/debugging](docs/debugging/README.md)**.

![Cut path decoded from the USB capture, drawn over the printed sheet](docs/debugging/print-and-cut-overlay.png)

## Build

Requirements: Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`build.command`
installs it with Homebrew if missing).

```sh
./build.command        # xcodegen + core tests + swift build + xcodebuild → Recorte.app (log in build.log)
open Recorte.xcodeproj
```

Core tests (no Xcode project needed): `cd CutterCore && swift test`.
`swift build` at the root type-checks the whole app without Xcode.

## First run with the machine

The GF-1261 enumerates as a **USB printer-class device** (STM32, VID `0483` / PID `5750`,
"LIYU CUTTING PLOTTER"), not as a serial port. No driver is needed:

1. Plug the cutter in and open **Settings ▸ Cutter**. With *Printer queue* selected the
   app lists the cutter under "Found on USB"; press **Set up the cutter** to create a raw
   CUPS queue (`Recorte_Liyu`). The app never auto-selects a queue it cannot identify
   as the cutter.
2. Press **Test cut**: a 20 mm square with a circle inside. Adjust blade depth and
   pressure until the square weeds cleanly.
3. Axis convention (verified from the [SignMaster capture](docs/debugging/README.md#step-4--read-the-protocol)):
   plotter X runs along the feed, plotter Y across the media. If a plain cut still comes out
   mirrored, toggle the `HPGLOptions.mirrorX`/`flipY` defaults in `JobPlanner`.

## Editor

| Tool | Key | |
|---|---|---|
| Select / move / resize (⇧ keeps proportions) | V | Delete, ⌘D duplicate, arrows nudge 1 mm, ⌘] / ⌘[ reorder |
| Pan | H | pinch to zoom, or the zoom buttons |
| Rectangle, Ellipse, Line, Polygon, Star | R E L G S | drag to draw, click for a 40 mm default, ⇧ for square |
| Freehand | P | ends closed when you finish near the start |
| Text | T | click to place; edit text, font and size in the sidebar |
| Import… | ⌘⇧I | adds an SVG/PDF/AI/DXF as one object |
| Cut… | ⌘P | material, size, position, test cut, send or save HPGL |

## Print & Cut

1. Enable **Print & Cut** in the canvas sidebar. The canvas becomes the sheet, with the
   registration marks drawn in.
2. **Place artwork…** (PDF/AI/PNG/JPEG). Placed artwork is printed, never cut.
3. Draw or import the cut lines on top.
4. **Cut… ▸ Save print sheet…**, print it, load the printed sheet in the cutter and press **Cut**.

The cutter reads the marks with its camera. The job format, reverse-engineered from a
SignMaster job (see [docs/debugging](docs/debugging/README.md) and
`CutterCore/Output/PrintAndCut.swift`):

```
TB<mark size>,<across steps>,<feed steps>;CT1;<1024 spaces>\r\n
IN;SP1;PU…;PD…;…
PU<feed steps>,0;PG!;\r\n
```

Coordinates are relative to the top-left mark (plotter X = feed, Y = across, 40 steps/mm).
The default layout prints Ø5 mm circles 2.5 mm from the sheet's left/right edges
(mark size setting 25 = Ø5 mm).

## Opening files

| Format | Notes |
|---|---|
| `.ai` | Must be saved with *Create PDF Compatible File* (Illustrator's default). First artboard only. |
| `.pdf` | First page. |
| `.svg` | Unitless sizes default to 72/inch (Illustrator); switchable in Settings ▸ Files. |
| `.dxf` | LINE, (LW)POLYLINE with bulges, CIRCLE, ARC, ELLIPSE, SPLINE. |

Text must be converted to outlines before saving (the app warns when it finds text).
Clipping paths and images are ignored.

## Project layout

```
project.yml              XcodeGen spec for the app (generates Recorte.xcodeproj)
App/Recorte/             SwiftUI app (document-based: File ▸ Open, recents, drag to Dock)
CutterCore/              Swift package with all the logic, testable without the app
  Design/                Project model: canvas, shapes, text (CoreText outlines), imported artwork
  Geometry/              Point/Rect/AffineTransform, Polyline, curve flattening
  Import/                SVG, PDF/AI (CoreGraphics), DXF importers
  Processing/            Cut ordering (inner shapes first), blade-offset compensation, job planner
  Output/                HPGL and Print & Cut generators
  Transport/             CUPS raw-queue and serial port (termios) transports
  Machine/               Machine profile (GF-1261) and material presets
docs/debugging/          USB captures, extraction script and protocol write-up
```

## Roadmap

- Direct IOUSBHost bulk transport (skip CUPS) and reading the cutter's status replies.
- Multiple artboards / pages picker.
- Weeding lines and tiling for jobs longer than the media.
- Notarised Developer ID build for distribution.

## Contributing

Issues and pull requests are welcome. USB captures from other Liyu models, or from jobs that
use different settings, help most: the [debugging write-up](docs/debugging/README.md) shows
how to make one and what is still unknown.

---

Made by [CookieBytes](https://cookiebytes.pt) · [Instagram](https://www.instagram.com/cookiebytes.pt)
