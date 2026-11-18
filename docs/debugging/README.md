# How the GF-1261 protocol was worked out

The Liyu GF-1261 ships with Windows-only software (SignMaster) and no protocol
documentation. Everything Recorte knows about talking to the cutter — and in particular
**Print & Cut** with registration marks — was recovered by watching what SignMaster sends
over USB. This folder keeps the raw evidence and the tooling, so anyone can check the
findings or repeat the process for a similar cutter.

![Captured cut path drawn over the print sheet](print-and-cut-overlay.png)

*The cut path decoded from the USB capture (magenta), drawn on top of the sheet SignMaster
printed. Green circles: the four registration marks. The two line up exactly, which is what
confirmed the coordinate system and units.*

## Setup

| | |
|---|---|
| Host | macOS, with Windows running in a [UTM](https://mac.getutm.app) VM |
| Vendor software | SignMaster (inside the VM), USB device passed through to Windows |
| Sniffer | [Device Monitoring Studio](https://www.hhdsoftware.com/device-monitoring-studio) (HHD Software), *Packet View* on the cutter's USB device |
| Job | A sheet of four contour-cut stickers, sent as a Print & Cut job |

## Step 1 — What is this device?

On Windows the cutter doesn't appear as a COM port but under *Universal Serial Bus*
devices. The capture session records its device path:

```
usb#vid_0483&pid_5750#stm3210#{…}
```

- **VID `0483`** is STMicroelectronics: the controller is an STM32.
- **PID `5750`** is ST's generic example product ID, reused by many STM32 gadgets — which is
  why Device Monitoring Studio's database labelled the port *"LED badge — mini LED display —
  11x44"* (still visible in the original capture filename). It isn't one; it's the cutter.
- On the Mac the same device enumerates as a USB **printer-class** device named
  "LIYU CUTTING PLOTTER" (vendor string "AHLY CUTTINGPLOTER", serial "STM3210"). No kernel
  driver claims the interface, so Recorte opens it with IOUSBHost and writes the job to the
  bulk OUT endpoint — no driver, no print queue. (Recorte first used a raw CUPS queue; macOS
  refuses those now: `lpadmin: Raw queues are no longer supported on macOS.`)

## Step 2 — Capture a job

With Packet View attached to the device, a Print & Cut job was sent from SignMaster.
Files in [`captures/signmaster/`](captures/signmaster):

| File | What it is |
|---|---|
| `capture-a.dmslog8`, `capture-b.dmslog8` | Device Monitoring Studio logs of the session (two saves of the same capture) |
| `packet-view.dmswks9` | The Device Monitoring Studio workspace used (JSON) |
| `print-sheet.pdf` | The sheet SignMaster printed: artwork, four registration marks, job number and QR code |
| `print-and-cut-job.plt` | The exact bytes sent to the cutter, extracted from the capture (step 3) |

## Step 3 — Pull the payload out of the log

`.dmslog8` is a binary format, but each USB transfer is stored as a fixed binary record
header followed by the payload. The header ends with `02 00 00 00 <u32 length>`, and a kind
byte separates *submitted* OUT transfers (`0x06`, carrying the data) from their
*completions* (`0x17`, which echo the length but have no data).
[`tools/extract_dmslog.py`](tools/extract_dmslog.py) walks those records, keeps only the
submitted transfers, joins them and validates every command:

```sh
python3 tools/extract_dmslog.py captures/signmaster/capture-b.dmslog8 job.plt
# job 0: 20126 bytes, 1638 commands, invalid=[]
# job 1: 20126 bytes, 1638 commands, invalid=[]
# record kinds {'06', '17'}
# 22 transfers, 40252 payload bytes; all jobs identical: True
```

What that tells us:

- Traffic is **one-way**: 22 host→device bulk transfers of ~2 KB, and no replies from the
  cutter. No handshake or status polling is needed to cut.
- The job was sent twice during the session and both copies are byte-identical, so
  SignMaster's output is deterministic: no timestamps or counters in the stream.
- Both log files give the same payload.

## Step 4 — Read the protocol

The payload is plain HPGL, with a small vendor preamble for the camera:

```
TB25,10012,6966;CT1;<1024 spaces>\r\n
IN;SP1;
PU0,12;PD0,92;                       ← short tick at the first mark
PU1,3551;PD1,3564;PD4,3590;…         ← sticker contours (absolute PD moves)
PU6966,0;PG!;\r\n                    ← park past the sheet, page out
```

| Command | Meaning (as inferred) |
|---|---|
| `TB25,10012,6966` | Start a registration-mark job. `25` = mark size setting (Ø5 mm, i.e. ×0.2 mm); `10012` = distance between marks *across* the media; `6966` = distance between marks *along the feed*, both in steps |
| `CT1` | Turn on contour cutting from the marks |
| 1024 spaces + CRLF | Padding; reproduced as-is |
| `IN;SP1;PU…;PD…` | Standard HPGL: initialise, select tool 1, pen up/down to absolute coordinates |
| `PG!` | End of page / feed out |

The numbers were checked against the printed PDF (255.4 mm wide):

- **Units:** 40 steps/mm. `10012 / 40 = 250.3 mm` = page width minus the two 2.5 mm
  side insets of the marks. `6966 / 40 = 174.15 mm` = the measured vertical distance
  between the mark centres on the sheet.
- **Axes:** plotter **X runs along the feed** and **Y across the media**, origin on the
  top-left mark. Drawing the decoded path with that mapping lands it exactly on the printed
  outlines (image above).

## Step 5 — Turn it into code

- [`CutterCore/Sources/CutterCore/Output/PrintAndCut.swift`](../../CutterCore/Sources/CutterCore/Output/PrintAndCut.swift)
  generates the same preamble, mark layout and trailer.
- [`CutterCore/Sources/CutterCore/Output/HPGL.swift`](../../CutterCore/Sources/CutterCore/Output/HPGL.swift)
  writes the cut paths using the axis convention above.
- [`CutterCore/Sources/CutterCore/Machine/MachineProfile.swift`](../../CutterCore/Sources/CutterCore/Machine/MachineProfile.swift)
  holds the 40 steps/mm resolution.

## Still unknown

- Whether the cutter ever answers (status, errors, "mark not found"). Nothing came back in
  this capture.
- The meaning of `CT` values other than `1`, and whether `TB` accepts other mark shapes.
- Speed and force commands: this job used the values set on the cutter's panel.

Captures from other jobs (plain cuts, different mark sizes, speed/force changes) would fill
these gaps. Contributions are welcome.

## The Mac connection (2026-11-18)

Interface 0, class 07/01/02 (printer, bidirectional), 39-byte configuration descriptor:

| Endpoint | Type | Max packet |
|---|---|---|
| `0x03` OUT | bulk | 64 |
| `0x81` IN | bulk | 64 |
| `0x82` IN | interrupt | 8 |

- Jobs go to `0x03`. A 20 KB Print & Cut job was accepted in 10 × 2 KB transfers in 0.09 s:
  the cutter buffers the whole job.
- It stalls the printer-class requests GET_DEVICE_ID and GET_PORT_STATUS (`0xE0005000`), and
  nothing ever comes back on `0x81` — same as the Windows capture: one-way.
- Tested on the machine: knife-up moves and SignMaster's plain rectangle cut correctly.
  A Print & Cut job sent without the printed sheet makes the head hunt for marks past its end
  stop (loud grinding); only send those with the sheet loaded and the origin on the first mark.

## Cutter Troubleshooting window

Always in Debug builds (**Help ▸ Cutter Troubleshooting…**, ⌥⇧⌘D). In release builds it
appears after **Settings ▸ Cutter ▸ Troubleshooting** is switched on. Everything is logged to the
window, to the unified log (subsystem `pt.cookiebytes.recorte`, category `CutterDebug`) and to a
file: `debug-logs/cutter-<date>.log` in the repo when run from Xcode (git-ignored), otherwise
`~/Library/Logs/Recorte/`.

| Button | What it does |
|---|---|
| Full check (safe) | USB devices and interfaces from the IOKit registry (and who owns each one), serial ports, third-party drivers, then Probe USB. Sends nothing. |
| Probe USB | Opens the cutter's interface: endpoints, configuration descriptor, printer-class status requests, reads bulk IN |
| Soft reset | Printer-class SOFT_RESET |
| Send | Sends a payload over USB |

Payloads: *Move head* (knife up, nothing cut — use this first), Recorte's test square,
SignMaster's 104×86 mm rectangle byte-for-byte, or any PLT file (asks first if it's a Print &
Cut job). USB options: chunk size per bulk transfer, *Seize* (take the interface from another
app), soft reset first, read-back time.
