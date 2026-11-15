# SignMaster CUT+ARMS 5.0 reference screenshots

Captured 2026-11-15 in the Windows VM, job `ARMS-Sample-01` (4 stickers, artwork 209.291 × 174.150 mm), cutter "Cutting Plotter CCD ARMS Cutter" = Liyu GF-1261.

| File | How to get there | What it shows |
|---|---|---|
| 01-studio.png | Open ARMS-Sample-01.vDoc | Design on a Letter page. |
| 02-create-cut-contour-menu.png | Toolbar contour button ▾ | Menu: Create Cut Contour… / Contour Cut Wizard… |
| 03-create-cut-contour.png | Create Cut Contour… | Builds the cut line around images: Build Contours / Boxes / Grid Table / Cutting Grid, contour type, corner style, outline offset (% or mm), keep holes, include images (vectorize). |
| 04-contour-cut-wizard-menu.png | Contour button ▾ | Contour Cut Wizard… |
| 05-wizard-output-options.png | Contour Cut Wizard ▸ Output Options | Cutting device + Spooler…; Manual / QR Code / Automatic ARMS (CCD); printing device: Print Direct / Print as PDF / Save as Image / Save PDF; selected objects, clip to page, tiled copies; mark position 20.5 mm; job name; full width; cut insides first; practice sheets (Calibrate, ARMS Practice). Buttons: Skip / Print (PDF) / Cancel. |
| 06-wizard-print-options.png | Print Options tab (after printing) | Use design size and position; auto center small jobs (A4); page marks; left/top position with arrows, Reset, Center; cutting tool presets. Buttons change to Re-print / Cut / Done. |
| 07-wizard-pdf-options.png | PDF Options tab | Margin around PDF. |
| 08-wizard-mark-options.png | Mark Options tab | Extra marks by target spacing (1000 × 300 mm) or number of marks; yellow mark background. Preview: "Marks: 250.291 mm x 174.150 mm" on a 255 × 255 mm sheet; View both / Print only / Cut only; Save as PLT. |
| 09-spooler-connection.png | Spooler… ▸ Connection | Direct USB Port, `vid_0483&pid_5750`, Detect. |
| 10-spooler-preview.png | Spooler ▸ Preview | Machine drawing, 1800 mm media width; the job sits at the **right** of the media (origin side). |
| 11-spooler-cut-options.png | Spooler ▸ Cut Options | Media width 1800 mm; blade offset 0.25; overcut 2.00; cutting force 70 g and speed 200 mm/s both **off**; advance after plot on; Area Tests. Spooler buttons: Nest, Area Test, Cut Now, Done; Copies. |
| 12-send-to-be-cut-general.png | Normal Cut (not the contour wizard) ▸ General | Model, media width 1800 mm, job name, quantity; Rotate, Mirror, Advance After Plot (on), Absolute (position); Registration Marks, Assign Tools by Color; Auto Speed-Weed, Auto Weed-Box; Weld Text, Speed-Weed Text Only. Buttons: Area Test / Cut Now / Spool All / Cancel. Preview puts the job at the right of the media. |
| 13-send-to-be-cut-cutter-control.png | Send to be Cut ▸ Cutter Control | Blade offset 0.31, Passes, Cut holes first; preset condition; Force 70 g and Speed 120 mm/s ticked (see `docs/debugging/captures/signmaster/plt/`). |
| 14-send-to-be-cut-settings.png | Send to be Cut ▸ Settings | Position x / y, weed box offset 5 mm. |
| 15-send-to-be-cut-tiling.png | Send to be Cut ▸ Tiling/Panels | Automatic tiling, vinyl width / length, tile overlap 10 mm. |
| 16-send-to-be-cut-black-general.png | Normal Cut, rectangle 104 × 86 mm in black | Same General tab; preview shows "Black Color (1/1)". Saved as `plain-black-passes1.plt`. |
| 17-send-to-be-cut-passes-2.png | Send to be Cut ▸ Cutter Control, Passes 2 | Saved as `plain-black-passes2.plt`: path repeated without lifting the knife. |

Not captured yet: the window after pressing Cut (loading instructions / marks detected), and cutting progress.
