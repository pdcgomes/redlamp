# Tethered capture: findings

What it would take for Redlamp to offer tethered capture that matches, then goes beyond, Capture One's: the camera controlled from the Mac by cable or wirelessly, each frame on screen and developed seconds after the shutter, and Capture One's range of cameras. Researched on 5 October 2026 at the owner's request; the source tag in the [research tracker](research-tracker.md) is **TC**.

The evidence is in four notes and a prototype:

- [Capture One teardown](notes/TC-capture-one-teardown.md): its features, release history and per-model camera list.
- [Lightroom Classic and other tools](notes/TC-lightroom-and-other-tools.md): Lightroom, Smart Shooter, Cascable, the makers' own apps, and Mac App Store apps that tether.
- [Routes and licences](notes/TC-routes-and-licences.md): Apple's ImageCaptureCore, the PTP standards, and each maker's SDK or protocol and its terms.
- [Architecture and workflow](notes/TC-architecture-and-workflow.md): how it fits Redlamp's code, tests and upkeep.
- [`research/prototypes/tethering`](../../research/prototypes/tethering/README.md): Capture One's camera list as JSON, and an ImageCaptureCore probe for the owner's Sony α7R V.

## 1. Summary

- **The gap is real but narrower than it looks.**
  - Capture One tethers 271 of the 768 models it lists: 210 with Live View, 57 wirelessly. It has done so for years, and tethering fixes appear in 88 of its 111 release notes.
  - Lightroom Classic tethers about 168 models from Canon, Nikon, Sony, Fujifilm and Leica, with a basic feature set (from Adobe's list of 28 August 2026; the list has duplicate and wrong rows). Lightroom's desktop and mobile apps don't tether at all.
  - Canon, Nikon, Sony and Fujifilm make up 188 of Capture One's 271. Phase One's own backs (53) are Capture One's sister company's and have no route on the Mac.
- **Redlamp's design already suits it.** Folders and sidecars work like Capture One's Sessions, which Capture One itself recommends for tethering. The decoder service takes bytes, Copy Settings already pastes onto photos that aren't open (Next Capture Adjustments), and focus-stack detection already finds brackets as they come in. No catalog is needed.
- **The technical route is clear, and it isn't the makers' SDKs.**
  - Apple's ImageCaptureCore finds USB cameras, takes pictures, downloads new frames and passes PTP commands and events through.
  - Sandboxed Mac App Store apps (Cascable Studio, Kuuvik Capture, MacroDSLR) already control Canon, Nikon and Sony cameras over USB this way, under the `com.apple.security.device.usb` entitlement.
  - Adobe moved Canon off Canon's SDK onto its own PTP code in Lightroom Classic 15.4, after Nikon and Sony according to The Lightroom Queen, and Smart Shooter 6 made ImageCaptureCore its default on macOS.
  - The makers' SDKs fit badly: they can't sit in an MPL-2.0 repository, and over USB they compete with macOS's `ptpcamerad`. Sony's and Fujifilm's also oblige the app to tell users their camera "will be out of … manufacturer-warranty".
- **The hard part is legal, not technical.** Standard PTP is published (in USB-IF's MTP 1.1 specification), but each maker's extensions, which carry exposure settings, autofocus and Live View, are documented only under licences. Those licences don't clearly allow publishing an open implementation. Sony's command reference is "only available for corporate customers"; Canon's and Nikon's licences are shown only after access is granted.
  - So the first decision is counsel's, and the owner's:
    - how Redlamp may learn each maker's extension;
    - whether to ask the makers directly, as Capture One has done with Canon and Panasonic, and Adobe with Leica;
    - whether the project needs a legal entity.
- **Size.** About 50 engineer-weeks (14, 22 and 14) reach Capture One's features for the four big makers, then wireless and the rest, in three stages (section 6). Hardware, counsel and a standing maintenance line come on top: each new body, firmware and macOS release needs checking.
- **Recommendation.**
  - Keep tethering after 1.0, but start the legal questions and maker conversations now, because they take months.
  - Stage 1 (capture sessions, a hot folder, standard ImageCaptureCore tethering, safe ingest, tether reports from the camera bench) is about 14 engineer-weeks, needs no maker licence, and already does more than Lightroom's Auto Import. It could be the first feature after 1.0.

## 2. Parity checklist

What photographers would compare, with Redlamp's plan and the tracker row that would deliver it.

| Feature | Capture One | Lightroom Classic | Redlamp | Row |
| --- | --- | --- | --- | --- |
| Captures into a plain folder, named by template and counter | Sessions, Next Capture Naming and Location | Session and shot folders, templates | Capture session on a Folders root | TET-01 |
| Settings for the next captures | Defaults, Copy from Last, Primary, Clipboard, a checklist; styles; Auto Alignment | A preset or Same as Previous | Default, previous, a recipe, or a Copy Settings checklist; AI masks recomputed after the frame is on screen | TET-01 |
| Second copy of each frame | Next Capture Backup (Studio), save to card and computer | Save a copy to the card (Canon) | Card copy by default where the camera allows, and a backup folder | TET-01, TET-12 |
| Cameras it doesn't support | Hot Folder | Auto Import (one watched, empty folder) | Hot folder that announces complete frames without waiting | TET-02 |
| Shutter, exposure, ISO, white balance, drive, format from the Mac | Camera and Camera Settings tools, every property the camera sends | Shutter, aperture, ISO, white balance | Camera bar, every property the camera reports | TET-04, TET-06 to TET-10 |
| Live View with focus and overlays | Zoom, focus, overlay image, Fujifilm click-to-focus | Focus control, click-to-focus | Zoom, focus, grid, overlay image, focus peaking, clipping, the recipe's look as a preview | TET-11 |
| Wireless | Canon, Sony, Nikon, Fujifilm, Panasonic; Canon's small raw first (patent pending) | No | PTP/IP for makers that allow it | TET-13 |
| Recovery when unplugged | ReTether (Canon, Nikon) | No | Frames shot while unplugged imported on reconnection | TET-12 |
| Client view | Client Viewers (Studio), Live for Studio on iPad (local network), Capture One Live (cloud, US$5 a month) | No | A second display following the latest capture; an iPad on the local network in Phase 5; no cloud | TET-16 |
| Focus brackets | Sent to Helicon Focus | No | Into the Stack workspace, found as they arrive | TET-14 |
| Supported cameras made public | A list per model | A list per model | Tiers from tests and photographers' reports on the cameras page | TET-15 |
| iPad and iPhone | Yes, wired and wireless | No | Phase 5, same package (no take-picture call on iPadOS: a PTP command instead) | TET-17 |
| AI culling while tethering | Assisted Review (16.8.6) | No | With OTH-02 | OTH-02 |
| Barcode naming, scripting, multi-camera | Barcode in Studio for Enterprise | No | Not proposed; Smart Shooter and Cascable do these | — |

## 3. Camera coverage

Measured from Capture One's list (5 October 2026) and each maker's published camera lists:

| Tier | What works | Makers and models |
| --- | --- | --- |
| 0. Any camera | The maker's own app writes into a folder Redlamp watches | Everything, including OM System (OM Capture), Panasonic (LUMIX Tether), Pentax and Ricoh (IMAGE Transmitter 2), Hasselblad (Phocus) and Phase One (Capture One) |
| 1. Any PTP camera on USB | Frames downloaded as they are shot; the Mac's shutter and standard properties where the camera accepts them (to be measured per body: TET-05) | Through ImageCaptureCore, no maker licence |
| 2. Full control | Exposure, autofocus, Live View, card copy, wireless | Canon (63 tethered in Capture One), Nikon (54), Sony (50), Fujifilm (21), then Leica (15) and Panasonic (3), each once DEC-29 settles how |
| Out of reach | | Phase One and Phase One Industrial (53): no macOS SDK, distribution needs Phase One's written consent. Older Mamiya and Leaf backs (7) |

- Tier 2 for the four big makers plus Leica and Panasonic covers 206 of Capture One's 271 tethered models (76%).
- Sony's own references don't reach every body Capture One does: its command reference covers 29 of Capture One's 50 tethered Sony bodies, by our mapping of Sony's model codes. The other 21 are older (α7, α7R II and III, α6000 to α6500, the A-mount bodies, older RX), and Capture One gives 18 of the 21 no Live View.
- Raw support gates all of it. Tethering a body is no use until LibRaw opens its files: the Sony α7 V doesn't today (CAM-13), and Capture One tethered it in 16.7.3.
- Capture One adds new bodies within weeks (the α7R VI in 16.8.1; "day-zero" Canon EOS R8 Mark II). Keeping pace needs a process: Capture One's list is re-read by [`capture_one_cameras.py`](../../research/prototypes/tethering/capture_one_cameras.py), and makers' SDK and protocol releases are tracked (TET-18).

## 4. The route

**Recommended:**

1. **One Swift PTP stack, written from published specifications,** in a platform-neutral `RedlampCapture` package, over two transports:
   - ImageCaptureCore for USB (`requestSendPTPCommand`, `ptpEventHandler`, downloads), which works with macOS's camera service instead of fighting it and is what sandboxed apps use today;
   - PTP/IP over Network.framework for Wi-Fi and Ethernet, which needs the Local Network permission and `NSLocalNetworkUsageDescription`.
2. **Each maker's extension implemented in that stack** only once DEC-29 says how Redlamp may learn and publish it: maker documentation under a licence that allows an open implementation, explicit permission from the maker, or another route counsel accepts.
3. **Makers' binary SDKs only as a fallback,** each in its own XPC helper outside the MPL-2.0 sources, built where the SDK is present. Fujifilm's public EULA is the clearest case. Sony's and Fujifilm's warranty-consent duties (DEC-31) and `ptpcamerad` on USB weigh against this route.
4. **The hot folder for everything else.**

**Excluded:**
- libgphoto2 (LGPL-2.1, and its maker tables are reverse-engineered data the clean-room policy excludes).
- CascableCore (a commercial SDK with unpublished terms).
- Panasonic's and Sigma's SDKs (Windows-only, or no right to redistribute).

**The probe** ([`tether-probe.swift`](../../research/prototypes/tethering/tether-probe.swift)) tests step 1 on the owner's α7R V with standard PTP only. Apple's SDK headers already settled two points:
- `requestEnableTethering` has been deprecated since macOS 14 ("cameras that support the standard take picture command will have the capability enabled by default").
- The authorisation prompts are iOS-only; on macOS 15 and later, cameras ask for Files & Folders › Removable Volumes instead (per Cascable).

Still to measure on the camera:
- what the α7R V offers in PC Remote and MTP modes;
- whether ImageCaptureCore delivers its frames without Sony's handshake;
- the time from shutter to file over USB.

## 5. Implications

- **Product.** Tethering turns Redlamp from an editor of finished shoots into a tool used during the shoot. That brings a new kind of user (studio, product, portrait), a second display and an iPad as clients, and a new promise: a frame is never lost.
  - Folders stop being strictly read-only. A capture session writes new files, and only those, into the folder the photographer chose (DEC-33).
- **Engineering.**
  - A new hardware-facing subsystem: PTP, two transports, a driver per maker, Live View, and an ingest path that writes to disk first and decodes from memory.
  - A PTP simulator and recorded sessions are needed, since CI has no camera.
  - Two code changes surface early. The folder watcher holds files under 2 s old as settling, so capture sessions must announce frames themselves. The decoder needs a bytes entry point on the app side; the service already takes bytes.
- **Legal.**
  - How to implement makers' extensions in open source (DEC-29, counsel).
  - Whether the project needs a legal entity for makers' programmes (DEC-30).
  - The warranty consent that Sony's and Fujifilm's SDKs require (DEC-31).
  - Capture One's patent-pending wireless design (DEC-34).
- **Distribution.** The recommended route works in the sandboxed Mac App Store build, with `com.apple.security.device.usb`, network client access and the Local Network prompt. Whether Apple's Photos Library entitlement is also needed is untested. Makers' SDKs over USB probably don't work in the sandbox (`ptpcamerad`; the developers' workarounds need what the sandbox forbids).
- **Support.**
  - Per-maker setup guides (Sony's PC Remote mode and Access Authentication, Canon's USB connection app, Nikon's transmitters) and a troubleshooting page.
  - A clear message when another app holds the camera: on the Mac only one app can.
  - Tethering will be a regular item in release notes, as it is for Capture One.
- **Hardware.** Every claim of support needs a body tested. The owner has an α7R V. Others need buying, borrowing, or photographers' reports through the camera bench (DEC-32).
- **Roadmap.** It competes with Phase 2 to 4 work for time. Stage 1 is small; Stages 2 and 3 are each about the size of focus stacking.

## 6. Plan and sizes

Sizes are this study's estimates (S ≤ 1 engineer-week, M 1 to 3, L 3 to 6), before the probe's results.

| Stage | Rows | What it delivers | Size |
| --- | --- | --- | --- |
| 1. Sessions and standard tethering | TET-01, TET-02, TET-03, TET-04, TET-05, TET-12, TET-15, TET-18 | Capture sessions with next-capture settings, a hot folder for any camera, frames downloaded from any PTP camera on USB, safe ingest and recovery, tether reports and support tiers, setup guides | about 14 ew |
| 2. Full control of the big four | TET-06 to TET-09, TET-11 | Settings, autofocus and Live View for Sony, Canon, Nikon and Fujifilm, wired | about 22 ew, after DEC-29 |
| 3. Wireless and beyond | TET-10, TET-13, TET-14, TET-16, TET-17 | Leica and Panasonic, Wi-Fi and Ethernet, focus brackets into stacks, client views, iPad | about 14 ew |

## 7. Risks

- **Licences block Stage 2.** If no maker lets Redlamp publish its extension, full control stays limited to makers that do, or moves into closed helpers. Mitigation: ask the makers early; Stage 1 doesn't depend on it.
- **ImageCaptureCore falls short for a maker.** Live View or the maker's handshake may not pass through cleanly. Cascable's App Store app suggests it does for Canon, Nikon and Sony over USB, but that is our inference, not Cascable's statement. The probe and Stage 1 find out before Stage 2 starts.
- **Upkeep.** Firmware and macOS updates have broken tethering for Lightroom (macOS 10.15.2, 14.2.0) and Capture One alike. Mitigation: recorded sessions in CI, a hardware check before releases, and reports from photographers.
- **Maker churn.** Sony warns that some commands "may become unusable on some models from 2027".
- **Patents.** Capture One calls its small-raw-first wireless design "pending patent" (DEC-34).
- **Scope.** Barcode naming, multi-camera and scripting are what studios ask of Smart Shooter and Capture One Studio; they are left out here, and should stay out until Stage 2 is done.

## 8. Decisions needed

All are tracker rows, Proposed until the owner decides:

- **DEC-29** *(counsel)*: how Redlamp may implement each maker's PTP extension in open source, and whether to approach the makers.
- **DEC-30**: a legal entity for makers' developer programmes.
- **DEC-31**: the warranty consent Sony's and Fujifilm's SDKs require.
- **DEC-32**: where tethering sits on the roadmap, and test cameras.
- **DEC-33**: capture sessions writing new files into the chosen folder.
- **DEC-34** *(counsel)*: Capture One's patent-pending wireless design.

Recorded skips: libgphoto2 (SKIP-14), and a cloud review service like Capture One Live (SKIP-15).

## 9. Still open

- The probe on the α7R V (TET-05): DeviceInfo, both USB modes, timings.
- Whether ImageCaptureCore connects to PTP/IP cameras over Bonjour, or a PTP/IP stack of Redlamp's own is needed for every wireless camera.
- Whether a sandboxed build needs the Photos Library entitlement, and which prompts appear.
- Native Apple Silicon builds of Nikon's and Fujifilm's macOS libraries, if the fallback route is ever used.
- Capture One's shutter-to-screen time on the same α7R V over USB: the benchmark to beat (the owner, with a trial).
