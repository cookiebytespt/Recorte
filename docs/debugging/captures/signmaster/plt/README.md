# SignMaster "Save as PLT" files (2026-11-15)

Saved from SignMaster CUT+ARMS 5.0 with Cutting Force / Cutting Speed ticked, to see how it sends them.

| File | Job | Speed field (mm/s) | Force field (g) | Settings sent |
|---|---|---|---|---|
| contour-speed451-force70.plt | ARMS-Sample-01 (Print & Cut) | 451 | 70 | `TB25,10012,6966;CT1;SP1;VS451;HS70;` + 1024 spaces, CRLF |
| contour-speed451-force120.plt | same | 451 | 120 | `…;SP1;VS451;HS120;` |
| contour-speed100-force120.plt | same | 100 | 120 | `…;SP1;VS100;HS120;` |
| contour-speed120-force120.plt | same | 120 | 120 | `…;SP1;VS120;HS120;` |
| plain-rectangle-speed120-force70.plt | 127 × 111 mm rectangle, normal Cut (no marks) | 120 | 70 | `IN;SP1;SP1;VS120;HS70;` at the start |

Findings:
- Force is `HS<grams>`, not `FS`. Speed is `VS<value>` with the mm/s number typed in SignMaster (not cm/s).
- Print & Cut: settings go on the TB line after `CT1;`, before the 1024 spaces and before `IN;`. The cut body is byte-identical to `print-and-cut-job.plt` from the USB capture.
- Plain cut: one line, no line breaks between commands; `IN;SP1;SP1;VS…;HS…;` then the path; ends `PU<job length>,0;PG;` (contour jobs end `PG!;`).
- Both start with a 2 mm stroke before the real path (`PU81,93;PD81,173;` plain, `PU0,12;PD0,92;` contour), probably to line the drag knife up.
- The plain job cuts the rectangle path 4 times (four identical `PU81,113;…` blocks) with Passes = 1. To check: were there 4 overlapping rectangles in the design?

## Follow-up: why the first plain file cut 4 times (2026-11-15)

Rectangle 104 × 86 mm, black (not Contour Cut Color), Force 70 g, Speed 120 mm/s.

| File | Change | Result |
|---|---|---|
| plain-black-passes1.plt | black colour, Passes 1 | path cut **once** |
| plain-black-passes2.plt | Passes 2 | path drawn twice **without lifting the knife**; overcut only after the last pass |
| plain-black-spooler-cleared.plt | Spooler job list cleared first | byte-identical to passes1 |

- The 4× cut in `plain-rectangle-speed120-force70.plt` is not Passes: there the knife lifted and overcut after every copy. It came from the rectangle being in **Contour Cut Color** (or the Spooler state at the time); a normal colour cuts once.
- Passes = repeat the closed path continuously, overcut once at the end.
- Overcut: after closing, the knife carries on 1 mm past the start point (`PD81,113;PD81,153`).
- Trailer `PU<job length along feed>,0;PG;` = Advance After Plot.
