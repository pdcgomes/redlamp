# Tethered capture baselines: Lightroom Classic and other tethering tools

Evidence for the [tethered capture findings](../tethering-findings.md): what Lightroom Classic and the other tethering tools offer, and whether sandboxed Mac App Store apps control USB cameras. Capture One is in its own [teardown](TC-capture-one-teardown.md).

All sources were checked on **2026-10-05** unless a note says otherwise; Apple's `com.apple.security.device.usb` sentence and Cascable Studio's App Store listing were checked again against their primary sources the same day. **Evidence** is what a primary source says (vendor page, help article, release notes, App Store listing). **Assessment** is our reading of it. Where a source could not be reached, the text says so.

**Access notes.** `helpx.adobe.com` returned HTTP 403 to curl, and headless Chrome did not return within 40 s on two attempts, so every Adobe help page below was read from an Internet Archive snapshot; the snapshot date and the page's own "Last updated" date are given in the sources list. `community.adobe.com`, `adobe.com` product pages and Canon's regional EOS Utility pages (`canon-europe.com`, `usa.canon.com`, `canon.com.au`) were blocked (403 or connection errors). The Lightroom Queen (lightroomqueen.com, Victoria Bampton's site) is a secondary source; it is used for release-by-release tethering history, which Adobe's own pages no longer list in full, and is labelled as such.

---

## Summary

- **Lightroom Classic tethers five makers.** Adobe's support list (last updated 28 Aug 2026) has 177 rows: Canon 78 (about 70 distinct models), Nikon 46 (45 distinct), Fujifilm 23, Leica 15 and Sony 15. Sony arrived in 13.3 (May 2024), Fujifilm in 14.4 (June 2025; before that only through Fujifilm's own plug-ins, paid for X-series and free for GFX), Leica in 15.0 (Oct 2025). In 15.4 (June 2026) Canon tethering moved from Canon's SDK to PTP, with a preference to switch back. Panasonic, OM System and Hasselblad are not on the list; for unlisted cameras Adobe suggests Auto Import, a watched folder filled by the maker's own software.
- **Lightroom Classic's feature set is modest.** It offers a floating tether bar with shutter speed, aperture, ISO and white balance, a Develop preset applied on import (including "Same as Previous"), session and shot subfolders, filename templates, metadata and keywords on import, and Live View with focus control and click-to-focus for Canon, Nikon and Sony. Fujifilm Live View is implied by Adobe's pages. Adobe documents no intervalometer, bracketing, focus stacking, multi-camera dashboard, barcode naming or scripting. Tethering ran under Rosetta on Apple Silicon until Canon (12.1, Dec 2022) and Nikon (14.0, Oct 2024) went native. Regressions recur in release notes; a 15.4 Canon break was fixed in 15.5. **Lightroom (desktop) and Lightroom mobile do not tether**, according to the Lightroom Queen's comparison table; no Adobe page or App Store listing claims they do.
- **Other tools add what Lightroom lacks:**
  - Smart Shooter has barcode and QR naming (from captures or live view), a ZeroMQ/JSON external API and multi-camera control. Version 6, which is still in testing, adds an in-app Python interpreter.
  - CaptureGRID has networked multi-camera rigs.
  - Cascable Studio controls more than 250 models from eight makers over Wi-Fi or Ethernet, and has "Storage Links" automation, AppleScript and Shortcuts.
  - Makers' own apps do host-driven focus bracketing (Canon EOS Utility, Hasselblad Phocus), pixel-shift capture (Sony), and Live Composite (OM Capture). LUMIX Tether connects up to 12 cameras, though not over USB on macOS 13–15.
- **Sandboxed Mac App Store apps do control USB cameras today:**
  - Cascable Studio is a Mac Catalyst app with full USB control of Canon EOS, Nikon, Sony and GoPro.
  - Kuuvik Capture 7 is a Canon EOS tethering app for Mac and iPad.
  - MacroDSLR drives Canon, Nikon and Sony over PTP over USB, with Live View on some cameras.
  - ShutterCount talks to Canon bodies over USB and Wi-Fi, to read shutter counts and set camera details.
  
  Apple documents the sandbox entitlement `com.apple.security.device.usb` for ImageCaptureCore on macOS 14 and later, and PTP pass-through (`requestSendPTPCommand`) on macOS 10.15+ and Mac Catalyst. Smart Shooter 6, distributed outside the store, now uses ImageCaptureCore as its default macOS camera transport.
- **darktable's manual** describes a tethering view built on gphoto2. It covers USB only (the manual describes no wireless option), Live View with focus control, guides and overlays, sequence, bracket and delayed (timelapse) capture, and per-session film rolls. libgphoto2's licence file is LGPL-2.1.

---

## 1. Lightroom Classic

### 1.1 Supported cameras

**Evidence.** Adobe's "Tethered camera support for Lightroom Classic" page ([A1], last updated 28 Aug 2026; snapshot of 30 Aug 2026) says Lightroom Classic "supports tethered capture for the cameras listed in this document on currently supported operating systems", and that for other models users should "contact the camera manufacturer". Counted from its tables:

| Maker | Rows on Adobe's list | Distinct models | Minimum Lightroom Classic version range |
|---|---|---|---|
| Canon | 78 | about 70 | 3.0 to 15.5 |
| Nikon | 46 | 45 | 3.0 to 15.1.1 |
| Fujifilm | 23 | 23 | 14.4 to 14.5 |
| Leica | 15 | 15 | 15.0 to 15.1.1 |
| Sony | 15 | 15 | 13.3 |
| **Total** | **177** | **about 168** | |

Notes on the counts:

- **Canon.** Eight rows repeat models listed earlier: EOS 5D, 20D, 30D, 350D, the Rebel XTi (400D), 1D Mark II and 5D Mark IV appear again with minimum version 15.5, and "EOS Kiss X 10i" is the Japanese name of the 850D. One 15.5 row, "Canon EOS 4D Digital", does not match a Canon model name we know. The 15.5 rows also add the EOS R5 C, R6 V and C50, the PowerShot V1, G1, G1 X Mark III and G7 X Mark II, and the IXUS 132. The Lightroom Queen's 15.5 post describes these rows as Canon cameras "updated to use PTP Support" with "no new cameras with tether support" [Q2].
- **Nikon.** The Z9 appears twice. One row reads "12.2 (macOS) / 12.4 (Windows) / 13.0 (Firmware 4.0)"; the other gives 14.0.
- **Sony.** Adobe's separate Sony page ([A4], last updated 13 Aug 2025; snapshot 16 May 2026) lists 21 models. Its list adds the α7 III, α7R III, α7R III A, α7 II, α7R II, α6300, α6400, α6500 and α6600 (all 14.5), but lacks the α7 V and α1 II, which the main page lists. The main page gives 13.3 as the α7 V's minimum version, while the Lightroom Queen lists α7 V raw support as new in 15.1 (Dec 2025) [Q5]. The 13.3 figure looks like an error on Adobe's page.
- **Canon caveats** [A1]: "For the 60D, 5D Mark III, and 1D X, a card must be in the camera". With the 50D on Windows, imports can fail if the card is inserted or removed mid-session.
- **Nikon caveats** [A1]:
  - Burst tethering "may be unreliable on macOS" for the D300, D300S, D700, D3, D3S, D3X, D90, D5000, D7000, D5100 and D7200.
  - A capture triggered from the tether bar must finish downloading before the next one.
  - Images "do not save to the compact flash card".
  - Multiple Nikon cameras can be tethered since 8.2 (February 2019).

**Assessment.** Native coverage is Canon, Nikon, Sony, Fujifilm and Leica. Panasonic, OM System, Hasselblad, Pentax/Ricoh and Phase One are not on Adobe's list. Adobe's tables carry visible errors (duplicate rows, a version number that predates the camera), so a model count should be quoted as approximate.

### 1.2 How support changed, by release

**Evidence** (Adobe release notes, What's new and fixed-issues pages [A8–A10]; Lightroom Queen release posts where Adobe no longer lists the item):

| Version (date) | Tethering change | Source |
|---|---|---|
| 8.0 (Oct 2018) | Canon tethering reworked: Disable Auto Advance and Save a Copy to Camera options; shutter speed, aperture, ISO and white balance settable from the tether window | [Q19] |
| 8.2 (Feb 2019) | Nikon brought to the same level; multiple Nikon cameras | [Q21], [A1] |
| 10.0 (Oct 2020) | Live View and manual focus adjustment for Canon | [Q15] |
| 10.2 (Mar 2021) | Nikon Live View as a beta, without Z-series | [Q16] |
| 10.3 (Jun 2021) | Native on Apple Silicon, but tethering needs a relaunch under Rosetta; Nikon Live View out of beta | [Q17], [A5] |
| 10.4 (Aug 2021) | Nikon Live View for D750 and D610 | [Q18] |
| 12.1 (Dec 2022) | Canon tethering native on Apple Silicon; Nikon still needs Rosetta | [Q14] |
| 12.2 (Feb 2023) | Tethering works on macOS Ventura; Nikon Z9 (macOS only) | [Q13] |
| 13.0 (Oct 2023) | Nikon Z8; fixes for Z9 firmware 4.0 and for a crash when tethering on Apple Silicon without Rosetta 2 | [Q12] |
| 13.3 (May 2024) | Sony tethering (camera in "PC remote" mode); Canon R6 II, R7, R8, R10, R50, R100, PowerShot V10 | [Q11], [A4] |
| 14.0 (Oct 2024) | Nikon tethering re-architected and native on Apple Silicon; Canon SDK updated for macOS Sequoia; Z8 firmware 2.0 fix | [Q10], [A10] |
| 14.2 (Feb 2025) | Click-to-select focus point and focus-mode menu in Live View for Sony, Canon and Nikon | [A8], [Q9] |
| 14.3 (Apr 2025) | Option to disable focus-point selection in Live View | [A9], [Q8] |
| 14.4 (Jun 2025) | Native Fujifilm tethering; Canon R1, R5 II, R50 V; fix for RAW+JPEG imported as two JPEGs | [A8], [Q7], [A10] |
| 14.5 (Aug 2025) | More Fujifilm and Sony models. "Treat JPEG files next to RAW files as separate photos" is not supported for the new Sony models | [A9], [Q6] |
| 14.5.1 (Aug 2025) | Fix: "Leica tether plugin causes Lr Classic to crash" | [A10] |
| 15.0 (Oct 2025) | Native Leica tethering; a choice between native capture and an installed Fujifilm or Leica plug-in when starting a session | [A9], [Q4] |
| 15.0.1 (Nov 2025) | Fix: Canon camera not detected after the tether bar launches (R5, R5 II and 5D III were reported) | [A10], [Q4] |
| 15.1 (Dec 2025) | More Leica models | [A9], [Q5] |
| 15.4 (Jun 2026) | "More reliable and faster tethering" for Canon; Canon rewritten on PTP, with a preference to revert to the Canon SDK | [A9], [A1], [Q1] |
| 15.5 (Aug 2026) | More Canon models on PTP; fix: "Canon tethering does not work after updating Lightroom Classic to version 15.4" | [A10], [Q2] |
| 15.6 (Sep 2026) | No tethering changes | [Q3] |

The Lightroom Queen's 15.4 post explains the PTP move: Canon tethering "has been rewritten to use the same PTP protocol used by Nikon and Sony. This means there shouldn't be such a lag in supporting new cameras" [Q1]. In 2018 the same site explained the lag: tethering "is usually added later than camera support", because Adobe waits for the maker to release its tethering SDK [Q20].

**Assessment.** Adobe has been moving from vendor SDKs to its own PTP code, one maker at a time.

- Nikon tethering still used Nikon's SDK in 9.0 [Q24]. By 15.4 the Lightroom Queen describes Nikon and Sony as already on PTP [Q1], so the 14.0 re-architecture [Q10] is the likely point of Nikon's switch. That is our inference.
- Canon followed in 15.4.
- Adobe's own release note claims only "more reliable and faster tethering" [A9]. Faster support for new bodies is the Lightroom Queen's explanation.

Lightroom Classic ran natively on Apple Silicon from 10.3 (June 2021). Native tethering followed about 18 months later for Canon (12.1) and about 40 months later for Nikon (14.0).

### 1.3 Features

**Evidence.** From Adobe's "Import photos from a tethered camera" ([A2], last updated 13 Aug 2025) unless noted.

- **Starting a session.** *File › Tethered Capture › Start Tethered Capture* opens Tethered Capture Settings, which has these options:
  - **Session**: the name of the session folder, with **Segment Photos By Shots** for subfolders. Cmd-Shift-T starts a new shot, or you can click the shot name.
  - **Destination**: where the session folder goes.
  - **Information**: metadata and keywords applied on import.
  - **Disable Auto Advance**: keeps the current photo on screen instead of jumping to the newest. The Lightroom Queen describes it as "useful if one person is working on the images while another person is shooting" [Q21].
  - **Disable Focus Selection**, for Live View.
- **Naming.** The 2019 version of the same page ([A2], snapshot 21 Jul 2019) documents a **Naming** option: "Session Name - Sequence" or any filename template, with a start number. The 2025 page no longer mentions it.
- **The tether bar** is a floating window (Cmd-T shows and hides it).
  - Captures come from its shutter button or from the camera's own release.
  - "You can control the Shutter Speed, Aperture, ISO, and White Balance of the tethered camera from the floating capture bar."
  - A **Develop Settings** pop-up applies a preset to each new capture. The Lightroom Queen's members-only tethering page, in its public search snippet, describes a **Same as Previous** option, which applies the previous photo's crop and Develop settings to each new capture [Q23].
- **Live View** opens in a separate window from the **Live** button on the tether bar.
  - Focus Control buttons drive focus. An **AF** button toggles autofocus, and manual focus steps are available when autofocus is off, but only when the lens is set to AF.
  - A focus-mode menu and click-to-focus anywhere in the frame were added in 14.2.
- **Live View by maker:**
  - Canon since 10.0 and Nikon since 10.2/10.3 [Q15–Q17].
  - Sony: Adobe's What's new says focus points and AF modes can be set "directly from the tethered live view window for Sony, Canon, and Nikon cameras" [A8].
  - Fujifilm: the Live View steps on [A2] say "Connect a supported Canon, Fujifilm, Nikon, and Sony camera", and the Fujifilm page lists a known issue, "The wide-tracking focus point isn't displaying correctly on GFX 100 II" [A3]. Both imply Live View for Fujifilm. The page's opening sentence still says Live View is "for Canon and Nikon cameras".
  - Leica: not documented in the pages checked.
- **Fujifilm specifics** [A3]:
  - Set the camera to USB tether shooting or "PC remote" mode, with "PC Save Image Size" at Original for RAW.
  - To change exposure from the bar, set the shutter dial to T, the lens to A and ISO to C.
  - Known issue: "Changing any camera setting prevents image capture via the tether bar"; the workaround is to restart the bar.
- **Auto Import** ([A7], last updated 27 Apr 2021). *File › Auto Import* watches one folder and moves new photos into a destination folder. It applies file naming, Develop settings, metadata and keywords, and can add the photos to a collection.
  - The watched folder "must be empty", and "Auto Import does not monitor subfolders".
  - Adobe presents Auto Import as the route for cameras that Lightroom Classic does not tether: "You can use your camera's software to download photos from your camera to a watched folder."

**Assessment.** Lightroom Classic covers the basic studio loop: shoot, auto-import into a named session with a preset, and review. It offers four exposure controls, and focus control in Live View. Adobe's pages describe no capture automation (interval, bracketing, focus stacking), multi-camera view, client view, barcode naming or scripting. The two-step "native list plus watched folder" model is the baseline that Redlamp must at least match.

### 1.4 Limitations and common complaints

**Evidence.**

- **OS updates break tethering.**
  - Adobe: "If you are on macOS Catalina, make sure that you update to macOS 10.15.3 or later. Tethering was broken in earlier versions of macOS Catalina" [A6].
  - Adobe's known-issues page (last updated 21 Apr 2026): macOS 14.2.0 "impacts device-related workflows … camera tethering"; the fix is macOS 14.2.1 [A11].
  - Tethering on macOS Ventura only worked from 12.2 [Q13].
- **Release-to-release regressions** named in Adobe's fixed-issues page [A10]:
  - Nikon Z8 with firmware 2.0 (fixed in 14.0).
  - RAW+JPEG imported as two JPEGs (14.4).
  - Leica plug-in crash (14.5.1).
  - Canon not detected after the tether bar launches (15.0.1).
  - Canon tethering broken by 15.4 (15.5).
  
  Earlier, the Lightroom Queen's bug lists include Nikon Z9 firmware 4.0 and a crash on Apple Silicon without Rosetta 2 (13.0) [Q12], Sony α7 IV firmware 3.01 not connecting in 13.3 [Q11], and Leica crashes with the plug-in (12.4, 12.5) [Q13].
- **Known issue**: a Nikon camera "fails to detect when the tether bar is open without connecting the camera"; connect first, then start tethering [A11].
- **Troubleshooting advice** [A6]:
  - Close the camera maker's software, which "could be trying to control your camera".
  - Put an empty card in, "especially if you're using a Nikon camera".
  - Use short cables.
  - On Windows, turn off AutoPlay.
- **Lag for new bodies.** The Lightroom Queen's comment threads record users waiting for tethering of newly released bodies, for example a Dec 2025 comment that the Canon R6 Mark III was not supported "especially as CaptureOne has it" [Q5]. The R6 Mark III arrived in 15.4 [A1].
- **Fujifilm** users previously needed Fujifilm's plug-ins (see §2.6). Since 14.4, Lightroom Classic tethers Fujifilm natively. Since 15.0 users choose between native capture and an installed plug-in instead of disabling the plug-in [A9], [Q4]. A 14.4 user with Fujifilm's "Tether Plugin Pro for GFX" installed reported broken tethering after the update [Q7].
- **Third-party plug-ins.** Smart Shooter 6 removed its Lightroom Classic plug-in because "Changes made by Adobe had already stopped it working with any camera that Lightroom Classic supports natively" ([K5], §2.1).
- **Stale documentation.** Adobe's "Tether support on Apple Silicon devices" page (last updated 24 May 2023, still published in 2026) says tethering runs "under the Rosetta emulation mode" [A5]. That was overtaken by 12.1 (Canon) and 14.0 (Nikon).

**Assessment.** The recurring complaints are breakage after OS or Lightroom updates, slow support for new bodies, and maker-specific quirks: card requirements, burst reliability, and settings changes stopping capture. Adobe's documentation is inconsistent across pages. A tethering feature in Redlamp will need per-OS-release regression testing with real bodies, and a clear message when another app holds the camera.

### 1.5 Lightroom (desktop) and Lightroom mobile

**Evidence.**

- The Lightroom Queen's feature table (updated 30 Jul 2025) lists "Tethered Shooting & Watched Folders" as **Yes** for Classic and **No** for "Desktop Cloud mode", "Desktop Local mode" and "Mobile" [Q22].
- The App Store descriptions of Lightroom mobile (version 11.6.1, 30 Sep 2026) and of Adobe Lightroom for Mac (version 9.6) do not mention tethering ([AS-LRm], [AS-LRd]; checked through the iTunes Lookup and Search APIs).
- Adobe's tethering pages refer only to Lightroom Classic [A1], [A2].
- We could not reach Adobe Community or adobe.com comparison pages (403 and connection errors).

**Assessment.** Of Adobe's Lightroom apps, only Lightroom Classic tethers. We found no Adobe statement either way for the other two apps; the absence is consistent across Adobe's help, the App Store listings and the Lightroom Queen's table.

---

## 2. Other tethering tools

### 2.1 Smart Shooter 5 and 6, and CaptureGRID 6 (Kuvacode)

**Evidence.**

- **Versions.** Smart Shooter 5.11 was released on 20 Sep 2026 for Windows and Mac and is sold through Tether Tools [K3]. Smart Shooter 6 "is still in testing", but version 6.5 (22 Sep 2026) is downloadable [K4]. Requirements are macOS 11+ for version 5 [K6] and macOS 13.5+ on "Intel or Apple Silicon" for version 6 [K5].
- **Cameras.** Smart Shooter 6's supported-camera page has 179 rows: Canon 67, Nikon 61, Sony 35, Fujifilm 15 and one Ricoh Theta S. Smart Shooter 5 has 134 rows: Canon 47, Nikon 48, Sony 26, Fujifilm 13 [K7]. No Panasonic, OM System or Leica bodies are listed.
- **Connection.** The docs describe wired USB only; we found no Wi-Fi feature in the v5 or v6 docs.
- **What's new in Smart Shooter 6** [K5], [K8]:
  - "Improved macOS camera support – New native camera backend using Apple's ImageCaptureCore API". The release notes add "Set default macOS camera transport mode to ImageCaptureCore".
  - A persistent database.
  - A multi-camera Dashboard.
  - Import from the camera's card.
  - Ratings, including reading ratings from EXIF.
  - 18 interface languages.
  - The Lightroom Classic plug-in was removed. Users are pointed to Lightroom's Auto Import on the download folder instead.
  - The External API became a paid add-on.
- **Features** [K5]–[K9]:
  - **Multi-camera**: Single, Multiple or group-limited control, cameras named by serial number, and a keyboard shortcut to fire all cameras.
  - **Live View**: up to four Live View windows, with focus control and zoom.
  - **Storage modes**: Disk, Card, Both, or "JPEG" (download only JPEGs).
  - **Filename expressions** use bracketed letters: session name and number, global sequence, per-camera batch number (shared by the RAW and JPEG of one exposure), camera name and serial, the camera's original name, barcode text, host name, date, time, milliseconds and camera group. Subfolders are supported.
  - **Barcode and QR scanning**: 15 symbologies using the open-source ZXing library. Scanning runs on captured photos and "also … for liveview images, so a barcode can be extracted directly from the liveview stream even before a photo is taken". The barcode text fills the `[Z]` filename token.
  - **Script Controls** (v6): "a built-in Python interpreter" for "time-lapse, focus stacking, bracketing, delayed trigger", with script-declared parameters shown as UI widgets [K9].
  - **External API**: a ZeroMQ publisher and request/reply server with JSON messages. Events cover new photos, photo state, camera detection and property changes, and requests control the app; sample code is at `github.com/kuvacode/smartshooter-api` [K10].
- **CaptureGRID 6** [K1], [K2]:
  - Multi-camera rigs across networked computers.
  - Windows, macOS and Linux, including Raspberry Pi.
  - Canon, Nikon, Sony and Fujifilm over "wired USB connection … using our custom built PTP engine".
  - Filename management per camera, and external trigger boxes.
  - €2,950 per rig (unlimited cameras and computers, one year of updates), or €950 for "CELL" (up to 8 cameras, one computer).

**Assessment.** Smart Shooter is the reference point for automation: barcode naming, scripting, an external API and multi-camera control. Its move to ImageCaptureCore on macOS suggests that Apple's API carries enough PTP control for four makers, though it does not prove that every vendor operation works through it. Adobe and Kuvacode describe the same hand-off to Lightroom: the capture app writes to a folder that Lightroom's Auto Import watches.

### 2.2 Cascable Studio, Cascable Pro Webcam and CascableCore (Cascable AB)

**Evidence.**

- **Distribution.**
  - Cascable Studio (previously "Cascable", with "Cascable Pro" features) is one App Store listing, "Cascable Studio: Camera Tether", version 7.4, 3 Oct 2026. It is free, with "Cascable Studio Pro" as a one-time purchase or subscription. The listing is available on Mac [AS-Cas].
  - The Mac version arrived in 7.0 (5 Dec 2024), built with "Apple's 'Catalyst' technology", and is included in the same purchase as iOS [C6], [C5]. Cascable's home page lists Studio "for iOS & Mac", Pro Webcam "for Mac" and CascableCore "for iOS, Mac & Vision Pro" [C1].
  - **Assessment:** being on the Mac App Store, it is sandboxed (App Review Guideline 2.4.5(i), [AP-G]).
- **USB.**
  - The listing says: "When using USB, Cascable can import images from any camera that supports the industry-standard PTP protocol, and can fully remote control and automate Canon EOS, GoPro, Nikon, and Sony cameras" [AS-Cas].
  - Cascable's wired-camera guide says Studio supports "full-featured remote control, tethering, and automation for wired Canon EOS, Nikon, and Sony Alpha cameras in 'PC Remote' mode … on iOS 15 and higher and macOS 14 and higher" [C4].
  - Canon USB on iOS needed iOS 14.2, and Nikon USB needed iOS/iPadOS 15.0 [C5].
- **Wi-Fi and Ethernet.** Wireless support covers "WiFi or Ethernet equipped" cameras from these ranges [AS-Cas]: Canon EOS, PowerShot and IXUS; Fujifilm X and FinePix; GoPro HERO 9 Black and newer; Nikon D; Olympus OM-D, PEN and SH; Panasonic LUMIX; Phase One IQ4; Sony Alpha, HX, RX and NEX. The Studio page counts "more than 250 models" [C2]. Fujifilm, GoPro, IXUS/ELPH and some older Panasonic and PowerShot models "don't support RAW image transfer" [AS-Cas].
- **How it connects (public notes)** [C4]:
  - On macOS 15 and later the app needs *Privacy & Security › Files & Folders › Removable Volumes*. On iOS it needs *Files and Folders* and *Camera* permissions.
  - "On the Mac only one app can connect to a USB camera at a time." The guide names Lightroom, EOS Utility (which "will, by default, run in the menu bar at all times and always connect"), Capture One, Image Capture and Photos as conflicts.
  - Newer Canons (from the R6 Mark II) need "Choose USB connection app" set to *Photo Import/Remote Control*.
  - Sony needs "PC Remote" mode. Other makers must be in PTP, MTP or Tethering mode.
- **Tethering behaviour** [C6]:
  - The default is "safe" tethering: the camera writes to its card, then the app copies the file.
  - "True" tethering for Canon, Nikon and Sony (7.0) uses the camera's Image Destination set to Host or Host + Camera.
  - **Storage Links** move images automatically to folders, external drives or Photos.
  - **App Connections** pass images to Capture One Pro (added to its catalog), Retrobatch workflows, or Photos.
- **Other features** [C5], [C6], [AS-Cas]:
  - Shutter Robot automation for bracketing and timelapses.
  - Live view rendered with Metal, with 3D LUTs, MetalFX upscaling, a negative (inverted) mode for scanning film, and onion skinning.
  - Video recording.
  - Elgato Stream Deck support, Shortcuts actions, and AppleScript on Mac (7.1).
  - TV output over AirPlay and HDMI.
  - Apple Watch shutter.
- **Cascable Pro Webcam** is a direct download (zip). It uses USB (Canon EOS, Nikon, Sony Alpha in PC Remote) or Wi-Fi (most Canon, Fujifilm, Nikon, Olympus, Panasonic and Sony), runs on macOS 10.15+, and is native on Apple Silicon [C3].
- **CascableCore SDK** [C7]–[C9]:
  - "for iOS, iPadOS, macOS, and visionOS". It covers over 250 cameras from Canon, Fujifilm, GoPro, Nikon, Olympus, OM System, Panasonic and Sony "via either WiFi or USB". USB is not available on visionOS.
  - APIs cover live view, settings, stills and video, and file transfer.
  - It is distributed through Swift Package Manager, with a 30-day evaluation licence after sign-up. **Pricing and licence terms are not public**; the developer site shows only sign-up and evaluation.
  - The README lists App Store and sandbox requirements:
    - `NSAllowsLocalNetworking`.
    - `NSLocalNetworkUsageDescription`.
    - `NSBonjourServices` with `_ptp._tcp`, for Canon in "EOS Utility" mode and some Nikons.
    - The `com.apple.developer.networking.multicast` entitlement, for SSDP discovery of Canon in "Smartphone" mode, some Sonys and most Panasonics.
  - The getting-started guide describes two camera "command categories", remote shooting and filesystem access. It also describes "camera-initiated transfers", which deliver "a preview (and sometimes the full image if the user is shooting tethered) of a photo shortly after it's taken" without leaving live view.

**Assessment.**

- Cascable Studio is direct evidence that a sandboxed, App Store-distributed Mac app can tether USB cameras.
- Being a Catalyst app, it cannot call the macOS-only ImageCaptureCore methods `requestEnableTethering()` and `requestTakePicture()` ([AP-3], [AP-4]). It most likely drives cameras through `requestSendPTPCommand` with vendor PTP operations. This is our inference, not a Cascable statement.
- Its Wi-Fi breadth (eight makers) and its automation hooks (Storage Links, AppleScript, Shortcuts, App Connections) are features to compare against Capture One.
- CascableCore is a commercial binary SDK with undisclosed terms. Using it in an MPL-2.0 project would need a licence negotiation.

### 2.3 Sony Imaging Edge Desktop (Remote)

**Evidence.**

- **Versions and platforms.** Imaging Edge Desktop has three parts: Remote, Viewer and Edit. Version 4.1.00 (14 May 2026) runs on macOS 14, 15 and 26 and on Windows 11 with Intel or AMD [S2], [S3]. 4.1.00 notes: "Data transfer speeds via USB during remote (tethered) shooting have been increased by approximately 10x (Mac)" [S2].
- **Connection.** "Remote (tether) shooting with Wi-Fi wireless connection is also supported" alongside USB [S1]. The help page says USB, Wi-Fi or LAN [S4].
- **Features** [S1], [S4]:
  - Live View (model-dependent), grids, guides and overlays.
  - Area-specified focus and magnified view.
  - Interval timer shooting. The destination folder must be empty, and the results can be turned into a time-lapse movie in Viewer.
  - Pixel Shift Multi Shooting: 4 or 16 frames, combined into ARQ on the computer, with motion correction.
  - Noise-reduction and HDR shooting.
  - A save destination, and "Display preview in Viewer" for immediate review.
  - XMP rating output, and registration of external programs.
  - A "Volume Photography Commands service" add-on is mentioned, for setting white balance in 10 K steps [S2].
- **Developer resources.**
  - The **Camera Remote SDK** (v2.02.00, 10 Jun 2026) supports USB, wired LAN and Wi-Fi on macOS 14.1+, Windows 11 and Linux (x86-64, ARMv7, ARMv8). It requires an application and a licence agreement [S5].
  - Sony also publishes **Camera Remote Command**, a PTP command reference with example code for "environment-independent camera control applications with PTP". It covers about 50 models (α, FX, ZV, RX), also requires an application and a licence, and notes that "Camera Control PTP 2 commands may become unusable on some models from 2027" [S6].

**Assessment.** Sony's own tool covers Wi-Fi and LAN as well as USB, and adds capture modes that need host-side compositing (pixel shift). Sony's published PTP reference gives a direct route to Sony control from vendor documentation, subject to its licence terms, which we have not read.

### 2.4 Canon EOS Utility

**Evidence.** From the EOS Utility 3.20 instruction manual (© 2026) [CA1]:

- **Cameras.** The compatible-camera page lists 48 entries: EOS R series (R1 to R100, RP), EOS M series, EOS DSLRs from the 1D X Mark III to the 1300D, and the R5 C and C50. Five M models do not support remote shooting [CA2].
- **Connection.** The camera connects "with an interface cable or over a LAN connection", including "Pairing over Wi-Fi/LAN" [CA3].
- **Features:**
  - Remote Live View shooting, an HDR mode, and **focus bracketing** for recent R bodies, the 90D, M6 II and C50 [CA4].
  - A timer, and **remote interval-timer** shooting: 5 s to 99:59 under computer control, or the camera's own interval timer on some bodies. Bulb, flash and movie recording are also supported [CA5].
  - Network and FTP settings for pro bodies [CA6].
  - Preferences for destination folder and subfolder rules, file naming rules (prefix, digits, start number, date formats), and **Linked Software**: "linked software … to start after images are transferred … To add third-party applications as linked software, click [Register]" [CA7].
- **Not verified.** The macOS versions and Apple Silicon support could not be checked, because the manual defers to "the Canon website" and Canon's regional download pages returned 403.
- **Developer resources** [CA8]:
  - **ED-SDK** v13.20.10: "The library modules work on Windows and macOS". An application is required.
  - **CCAPI** (Camera Control API) is "based on HTTP technology … via Wi-Fi". It can configure settings, get live view, trigger capture and retrieve images.

**Assessment.** EOS Utility's "Linked Software" hook is a ready integration point: a capture app hands each new file to a registered editor. Canon's own tool includes host-triggered focus bracketing and intervals. Adobe has moved off ED-SDK for Canon (§1.2).

### 2.5 Nikon NX Tether

**Evidence.**

- **Version and platforms.** NX Tether 2.5.0 (17 Mar 2026) supports macOS 26, 15 and 14 and Windows 11 64-bit [N2].
- **Cameras.** 17 models: Z9, Z8, Z6III, Z7II, Z6II, Z7, Z6, Z5II, Z5, Zf, Z50II, Z50, Z30, Zfc, ZR, D6 and D780 [N2].
- **Connection.**
  - "Built-in USB port required". Behaviour through a hub is not guaranteed.
  - "Users who wish to connect to the camera via built-in Wi-Fi will need the Wireless Transmitter Utility".
  - Signing in with a Nikon ID is required, and again after 30 days offline [N2].
- **Integration.** The product page says it "Works with both NX Studio and software such as Adobe Photoshop Lightroom and Capture One", with error notification by sound and on screen [N1].
- **Not verified.** Live View, interval and bracketing features: Nikon's online help returned 404, and the product and download pages do not list them.
- **Developer resources.** Nikon offers SDKs "free of charge … with completion of the required application process"; "Nikon does not provide technical support for SDKs" [N3].

**Assessment.** Nikon describes NX Tether as "a simple, stripped-down design" [N2], and it covers only recent Nikon bodies. Its value for Redlamp is as the folder-based companion that Nikon expects third-party editors to watch.

### 2.6 Fujifilm: FUJIFILM TETHER APP, X Acquire, Lightroom Classic plug-ins, Camera Control SDK

**Evidence.** Fujifilm's software page lists these alongside Capture One and other third-party tools [F1].

- **FUJIFILM TETHER APP** (macOS and Windows) [F2], [F3]:
  - It connects "via USB or network" and "provides automated image transfer", camera settings, and backup and restore of settings.
  - "Liveview on your Computer" is for GFX cameras only.
  - It "can be used as tether shooting plug-in for Adobe Photoshop Lightroom Classic".
  - The compatibility chart lists macOS 11 to 26 (not 10.15), and 31 cameras:
    - 8 GFX bodies, with full functions.
    - 12 X bodies with full functions only if "FUJIFILM Tether Shooting Plug-in PRO" is installed.
    - The X-T1, with everything except backup and restore.
    - 10 bodies limited to backup and restore.
  - The latest version noted is 1.34.0 (10 Jun 2025).
- **FUJIFILM X Acquire** (free) transfers images "to the Mac or PC and save[s] them in a specified folder", and backs up and restores settings over USB. Its chart lists macOS 10.12 to 14 and 26 cameras, and it works with the FT-XH file transmitter [F4], [F5].
- **Lightroom Classic plug-ins** [F6]:
  - The "Tether Shooting Plug-in" is paid. It works over USB, and "Wi-Fi connection is also supported for Wi-Fi connection capable models".
  - The "Plug-in PRO" is paid. It adds a control panel with Live View, shooting settings, "interval/bracketing shootings" and settings backup.
  - "Tether Shooting Plugin PRO for GFX" is free for GFX owners.
- **Camera Control SDK** [F7]:
  - It runs on Windows, macOS 10.12 to 26, Linux (Ubuntu, Raspberry Pi OS) and Android (USB only), over USB or TCP/IP via an access point.
  - Version 1.34 was released on 12 Nov 2025.
  - The page warns: "FOR INDIVIDUALS … USING THIS SDK TO CONNECT TO, OR CONTROL, ANY COMPATIBLE FUJIFILM CAMERA, WILL VOID THE CAMERA'S LIMITED PRODUCT WARRANTY". Download is subject to an EULA.

**Assessment.** Until Lightroom Classic 14.4, Fujifilm tethering into Lightroom meant a paid Fujifilm plug-in. Fujifilm's own app restricts Live View to GFX, and gates X-series features behind the PRO plug-in. The SDK's warranty warning makes it a poor dependency for an open-source app that users run on their own cameras.

### 2.7 Panasonic LUMIX Tether

**Evidence.** From [P1]:

- **Version and download.** LUMIX Tether 2.12 (26 Nov 2025) runs on Windows and Mac. Downloading requires the camera's serial number.
- **Cameras.** S series (S1, S1R, S1 II, S1R II, S1H, S5, S5 II, S5 IIX, S9, BS1H) and G/GH series (GH5, GH5S, GH5 II, G9, G9 II, GH6, GH7, BGH1).
- **Requirements.** macOS 12.0 to 15.6, on Intel or Apple Silicon, with USB 3.0/3.1.
- **Network connections.** Ethernet works for BGH1 and BS1H, and for the GH5 II, S5 IIX, GH7, S1R II and S1 II through a USB-LAN adapter. Wi-Fi works for BGH1 and BS1H only. Panasonic recommends USB or wired LAN, because Wi-Fi "connection may be interrupted".
- **Features.**
  - "Supports multiple connection. (Max.12 Units)" (Nov 2021), and a multi-view that displays up to 12 devices (Oct 2022).
  - Live view image quality settings (Nov 2019).
  - Settings save and load, menu operation, and firmware update on some models.
- **macOS limitation.** "Due to the specifications of macOS, the following functions do not work, if connecting the digital camera and PC with a USB cable. – Multiple connection" on macOS 13, 14 and 15.

**Assessment.** Panasonic's multi-camera mode does not work over USB on recent macOS, and Panasonic blames macOS. That is a warning for any Redlamp multi-camera plan on USB; the cause is not public. Lightroom Classic does not tether Panasonic natively, so a Panasonic user's path today is LUMIX Tether plus a watched folder.

### 2.8 OM System OM Capture

**Evidence.**

- **Cameras.** OM-1 Mark II, OM-1, E-M1X, E-M1 Mark III, E-M1 Mark II, E-M1 (firmware 2.0+) and E-M5 Mark II [O1]. The US software page lists a shorter set [O5].
- **Version and platforms.** Version 3.2 (27 Aug 2026) [O4]. It requires macOS 13 to 15 or 26, on "Intel Core i series or faster; Apple M1 chip or later", and a USB port. Downloading requires the camera's serial number [O3]. Version 2.2.1 (Feb 2021) added M1 compatibility [O6].
- **Features** [O2]:
  - Remote control from the computer. The OM-1 Mark II "is available with wireless camera control via Wi-Fi".
  - Image transfer through a wireless access point for the OM-1 II, OM-1, E-M1X and E-M1 III.
  - Live View with level gauge, AF frame, magnification, grid and "composite display for overlay images", which can be shown on multiple monitors.
  - Sequential, bulb, Live Composite, Live Bulb and Live Time with progress on the computer, interval shooting, all of the camera's bracketing modes, High Res Shot, keystone compensation and movie.
  - Saving to card, PC or both.
  - A link to OM Workspace for immediate viewing and editing, with downloads optionally shown on multiple monitors.

**Assessment.** OM Capture is OM System's own tethering path. Lightroom Classic does not list these bodies, and Cascable Studio controls Olympus OM-D bodies only over Wi-Fi [AS-Cas]. Its overlay composite display and Live Composite progress view have no counterpart in Lightroom Classic.

### 2.9 Hasselblad Phocus and Phocus Mobile 2

**Evidence.**

- **Phocus for Mac/PC** is free; version 4.2.2 for Mac is current. It supports "Tethered execution of Focus Bracketing sequences … via additional functionality in the Capture Sequencer tool. X, H and 907X cameras are supported" [H1].
- **Phocus Mobile 2** (iOS, iPadOS and Android) [H2]:
  - It controls aperture, shutter speed and ISO over Wi-Fi.
  - On the X2D II 100C it adds Live View, continuous, self-timer and interval modes, focus mode and area, and wake-from-off.
  - A USB-C cable to the phone or tablet gives "faster, more stable transmission" for import and editing (X2D II, X2D and CFV 100C on iOS).
  - The App Store listing ("Phocus Mobile", version 4.5.0, 17 Sep 2026) is not offered on Mac in the iTunes data [AS-Ph].
- **Not verified.** Phocus desktop's tethered connection types, Live Video, and Apple Silicon support: Hasselblad's download pages are rendered in JavaScript and did not expose them.

**Assessment.** Of the tools in this report, Phocus is the one that tethers Hasselblad X and H bodies (Capture One is out of scope here). Host-driven focus bracketing is the notable feature.

### 2.10 Leica

**Evidence.**

- **Leica FOTOS** is a mobile app. It sets "exposure time, aperture and ISO directly via the app, focus using your smartphone, and take[s] pictures and videos remotely", with live preview, for the M11, SL3 and Q3 families [L1]. Its App Store listing (version 6.2.0, 24 Sep 2026) is not offered on Mac [AS-L].
- **Desktop tethering:**
  - Lightroom Classic tethers Leica natively since 15.0 (15 models, §1.1).
  - Adobe refers to an installed "Leica plugin" that users can choose instead [A1], [A9]. It crashed Lightroom Classic in 14.5 (fixed in 14.5.1) [A10].
- **Not found.** We could not locate a Leica page for its Lightroom Classic tether plug-in or any Leica desktop tethering app; Leica's site returned 404 for the URLs tried.

**Assessment.** Leica relies on Adobe (and Capture One) for desktop tethering, and on FOTOS for phone and tablet remote control.

### 2.11 Comparison at a glance

Facts only, from the sections above; "—" means not stated in the sources checked.

| Tool | Mac requirement | Makers | Wired / wireless | Live View | Writes to a folder | Notable capture features |
|---|---|---|---|---|---|---|
| Lightroom Classic | current macOS | Canon, Nikon, Sony, Fujifilm, Leica | USB | Canon, Nikon, Sony (Fujifilm implied) | Session folder, Auto Import | Preset on import, shots |
| Smart Shooter 6 | macOS 13.5+, Intel/AS | Canon, Nikon, Sony, Fujifilm (+Theta S) | USB | Yes, 4 windows | Download folder | Barcode/QR naming, Python, ZeroMQ API, multi-camera |
| CaptureGRID 6 | macOS (version —) | Canon, Nikon, Sony, Fujifilm | USB, networked hosts | Yes | Per-camera naming | Large rigs, trigger boxes |
| Cascable Studio | macOS 14+ for USB | 8 makers (USB: Canon, Nikon, Sony, GoPro) | USB, Wi-Fi, Ethernet | Yes | Storage Links | Shutter Robot, AppleScript, Shortcuts, LUTs |
| Sony Imaging Edge Desktop | macOS 14–26 | Sony | USB, Wi-Fi, LAN | Yes | Save destination | Interval, pixel shift, HDR/NR |
| Canon EOS Utility | — | Canon | USB, Wi-Fi/LAN | Yes | Destination, Linked Software | Focus bracketing, interval, bulb |
| Nikon NX Tether | macOS 14–26 | Nikon (17 models) | USB; Wi-Fi via WT Utility | — | Yes (for LR/C1) | — |
| FUJIFILM TETHER APP | macOS 11–26 | Fujifilm | USB, network | GFX only | Automated transfer | Settings backup/restore |
| LUMIX Tether | macOS 12–15, Intel/AS | Panasonic | USB; Ethernet/Wi-Fi on some | Yes | — | Up to 12 cameras (not over USB on macOS 13–15) |
| OM Capture | macOS 13–26, Intel/M1+ | OM System/Olympus | USB; Wi-Fi on OM-1 II | Yes | Card, PC or both | Live Composite, bracketing, overlays |
| Hasselblad Phocus | — | Hasselblad | — | — | — | Tethered focus bracketing |
| darktable (§4) | — | gphoto2-supported | USB | Yes | Film roll per session | Sequence, bracket, timelapse |

### Assessment: features Capture One may lack, and implementation clues

These candidates need checking against the separate Capture One research:

- **Barcode and QR naming**, including from the live view stream (Smart Shooter).
- **Scripting and an external API**: in-app Python, and a ZeroMQ/JSON event and command bus (Smart Shooter); AppleScript, Shortcuts and Stream Deck (Cascable).
- **Multi-camera**:
  - dashboards and group control (Smart Shooter);
  - networked rigs (CaptureGRID);
  - 12-camera multi-view (LUMIX Tether).
- **Wireless tethering across makers** (Cascable: Canon, Fujifilm, GoPro, Nikon, Olympus, Panasonic, Phase One, Sony).
- **Automatic routing of captures** to folders, external drives or other apps (Cascable Storage Links and App Connections; EOS Utility Linked Software).
- **Live view aids**: 3D LUTs, onion skinning, a negative mode (Cascable); overlay composite (OM Capture); multi-point magnified live view (Kuuvik Capture, §3).
- **Host-driven capture sequences**: focus bracketing (EOS Utility, Phocus, Kuuvik up to 100 frames), intervals (EOS Utility, Sony, OM Capture, darktable), pixel-shift capture (Sony), Live Composite (OM Capture).

Implementation clues:

- **Adobe now tethers Canon, Nikon and Sony over PTP** (Canon last, in 15.4). The Lightroom Queen gives faster support for new bodies as the reason [Q1]. Adobe does not say whether its native Fujifilm and Leica support also uses PTP.
- **Kuvacode** wrote a custom PTP engine [K1], and Smart Shooter 6 now runs on ImageCaptureCore on macOS [K8].
- **Vendor references exist.** Sony publishes a PTP command reference [S6]. Canon (ED-SDK, CCAPI), Fujifilm and Nikon offer SDKs behind applications and EULAs [CA8], [F7], [N3].
- **Wi-Fi discovery** uses Bonjour `_ptp._tcp` for Canon "EOS Utility" mode and some Nikons, and SSDP for Canon "Smartphone" mode, some Sonys and most Panasonics [C8].
- **A PTP implementation written from the published PTP standard and vendor documents** fits Redlamp's rule to "implement from published specifications". Vendor SDK binaries would bring licence terms we have not reviewed.

---

## 3. Sandboxed Mac App Store apps that control USB cameras

**Evidence.**

- **Apple's rules and APIs:**
  - App Review Guideline 2.4.5(i): apps distributed through the Mac App Store "must be appropriately sandboxed" [AP-G].
  - Apple's ImageCaptureCore overview: "In macOS 14 and later, use the `com.apple.security.device.usb` entitlement key to allow your sandboxed app to interact with USB devices". It also says that to "import pictures and tether from a macOS app", the app enables the Hardened Runtime and adds the `com.apple.security.personal-information.photos-library` entitlement [AP-1].
  - The entitlement page says `com.apple.security.device.usb` lets "your sandboxed app … interact with USB devices" [AP-9].
- **ImageCaptureCore's capture API** [AP-2]–[AP-8]:
  - `ICCameraDevice` has a "Taking Pictures" group: `tetheredCaptureEnabled`, `ptpEventHandler`, `requestEnableTethering()`, `requestTakePicture()`, `requestSendPTPCommand(…)` and `requestDisableTethering()`.
  - `requestTakePicture()` and `requestEnableTethering()` are macOS-only.
  - `requestSendPTPCommand(_:outData:completion:)` is on macOS 10.15+, Mac Catalyst 13.1+ and iOS 13+.
  - `ptpEventHandler` is on macOS 12+ and on Catalyst and iOS.
  - The user-authorization calls `requestControlAuthorization` and `requestContentsAuthorization` are listed for iOS, iPadOS and Mac Catalyst 14+, not macOS.
- **App Store apps that control USB cameras on Mac** (iTunes Lookup and Search API, US store; descriptions quoted):

| App (developer) | Store data | USB camera control evidence |
|---|---|---|
| Cascable Studio: Camera Tether (Cascable AB) | Universal listing, offered on Mac; v7.4, 3 Oct 2026; Mac Catalyst [C6] | "can fully remote control and automate Canon EOS, GoPro, Nikon, and Sony cameras" over USB [AS-Cas] |
| Kuuvik Capture 7 (DIRE Studio) | Offered on Mac; v7.1, 1 Sep 2026; $149.99; "Includes both Mac and iPad versions" [D1] | Canon EOS tethering with "USB and Wi-Fi/Ethernet connections", live view, up to 15-shot exposure and 100-shot focus brackets, intervalometer [AS-Kuu] |
| MacroDSLR (CloudMakers) | Mac App Store (`mac-software`); v3.19, 7 Jan 2025 | "PTP-over-USB CCD driver for Canon, Nikon and Sony Alpha cameras"; driver "based on ImageCapture API"; Live View on some cameras; macro rail drivers [AS-Mac], [CM1] |
| AstroDSLR (CloudMakers) | Mac App Store; v4.17, 27 Nov 2024; **retired** by the developer in favour of INDIGO A1 [CM2] | Same INDIGO driver, Canon, Nikon, Sony and Fuji [AS-Ast] |
| ShutterCount / ShutterCount Pro (DIRE Studio) | Mac App Store; v7.1, 3 Sep 2026 | Reads Canon EOS bodies "directly from USB or Wi-Fi"; Canon camera management (date and time sync, owner, copyright) [AS-SC] |
| iRemoteCapture, Time Lapse Movie, PictureMe Pro 3, CameraTether (Boudewijn Krijger) | Mac App Store; last updated 2021–2023 | USB cameras "support taking a picture using the Take Picture button"; timelapse via a tethered camera [AS-BK] |
| Moments (David Wilson) | Mac App Store; v2.0.1, 12 Jan 2026 | Photo booth; "Canon EOS 650D (Rebel T4i) fully supported" [AS-Mom] |

- **Outside the store**, the following tools are direct downloads: Smart Shooter [K3], [K4], Cascable Pro Webcam [C3], and the maker apps in §2.
- **Platform constraints reported by developers:**
  - "On the Mac only one app can connect to a USB camera at a time" [C4].
  - On macOS 15+, Cascable needs *Files & Folders › Removable Volumes* [C4].
  - Panasonic says multi-camera over USB does not work on macOS 13–15 "due to the specifications of macOS" [P1].
  - macOS 10.15.2 and 14.2.0 each broke camera tethering until a point release [A6], [A11].

**Assessment.**

- **Yes: sandboxed USB camera control is in production on the Mac App Store** in 2026, from at least two actively maintained apps (Cascable Studio, Kuuvik Capture 7), plus MacroDSLR (updated Jan 2025) and ShutterCount (USB communication with Canon bodies).
- **The documented route is ImageCaptureCore with PTP pass-through**, together with the `com.apple.security.device.usb` entitlement on macOS 14+.
  - MacroDSLR's listing names the ImageCapture API, and its developer page says the driver "implements PTP-over-USB protocol".
  - For a Catalyst app such as Cascable, `requestSendPTPCommand` is the documented camera-control call, because the macOS-only capture calls are unavailable. We have not checked whether Catalyst apps can reach USB cameras through other frameworks.
  - Kuuvik Capture's route is not stated.
  - Smart Shooter 6 choosing ImageCaptureCore as its default macOS transport points the same way for a non-sandboxed app.
- **For Redlamp's future Mac App Store build**, a tethering stack built on ImageCaptureCore (`requestSendPTPCommand`, `ptpEventHandler`, `requestDownloadFile`), and not on libusb or vendor SDKs, keeps one code path for both builds.
- **Open questions** need a prototype:
  - whether every vendor operation that Redlamp wants (for example Sony's live view, or Canon's event polling) is reachable through pass-through;
  - how the "Removable Volumes" consent behaves;
  - whether a sandboxed app can drive several USB cameras at once, given Panasonic's note.

---

## 4. darktable tethering (user manual only)

**Evidence** (darktable 5.6 user manual [DT1]–[DT7]; source code not read):

- **Entering the view.**
  - Connect the camera by USB and do not let the OS mount or view it. If it is mounted, "unmount/eject" it, after which "darktable will then re-lock the camera so that it cannot be used by other applications".
  - In the lighttable's import module, *mount camera* reveals *copy & import from camera*, *tethered shoot* and *unmount camera* [DT1].
- **Backend.** "darktable uses gphoto2 to interface with your camera" [DT1].
  - The troubleshooting page uses the `gphoto2` command-line tool (`--auto-detect`, `--abilities`, `--capture-image-and-download`, `--capture-tethered`) to check support.
  - darktable shows *tethered shoot* only if the driver reports "capture choices: Image" and configuration support [DT4].
  - libgphoto2's repository licence file is LGPL-2.1 ([G1], GitHub licence API).
- **Capture.** Captures come from darktable's UI or from the camera's shutter. The newest capture is shown in the center view, and live view also displays there [DT1].
- **Sessions.**
  - Entering the view creates a film roll using the import session options, with job code "capture".
  - The **session** module sets a new job code, which creates a new film roll through the `$(JOBCODE)` variable [DT1], [DT7].
- **Right panel**: scopes, session, live view, camera settings, metadata editor and tagging. **Bottom panel**: star ratings and color labels [DT2].
- **Camera settings module**: "sequence, bracket and delayed captures", plus focus mode, aperture, shutter speed, ISO and white balance [DT5]. The overview mentions "timelapse captures, brackets for HDR and even sequential captures of bracketed images" [DT1].
- **Live view module**: "focus control, rotation, guides and overlays" [DT6].
- **Card storage.** By default gphoto2 "will only download images to your computer, and will not store them on the camera's memory card". The manual's workaround is `gphoto2 --set-config capturetarget=1` with darktable closed. The manual says this can fail, because darktable must read the same configuration file as the gphoto2 command-line tool, which a sandbox or container "that hides user account settings" (for example snap packages) prevents [DT3].
- **Examples**: a studio "screening" workflow, reviewing on the monitor with the client, and timelapse capture [DT3].

**Assessment.** darktable's feature set roughly matches Lightroom Classic's, and adds timelapse and bracketing, but no barcode naming, scripting or multi-camera. The manual shows gphoto2's model: a process that takes exclusive control of the device, with per-camera "abilities". It also shows a configuration weakness, card-versus-host storage held in gphoto2's own config. The manual does not say whether tethering works in darktable's macOS build. Using libgphoto2 in Redlamp would bring an LGPL-2.1 dependency. We have not checked how libgphoto2 reaches USB devices on macOS, or whether that works inside the App Sandbox; both need legal and technical review. Redlamp's rules point instead to a PTP implementation from published specifications, which this report does not evaluate.

---

## Sources

All checked 2026-10-05. Adobe help pages were read from Internet Archive snapshots; the snapshot date and the page's "Last updated" date are given.

**Adobe (via Internet Archive)**

- [A1] Tethered camera support for Lightroom Classic. Last updated 28 Aug 2026; snapshot 2026-08-30. https://helpx.adobe.com/lightroom-classic/desktop/kb/tethered-camera-support.html (snapshot: https://web.archive.org/web/20260830083930/https://helpx.adobe.com/lightroom-classic/desktop/kb/tethered-camera-support.html)
- [A2] Import photos from a tethered camera. Last updated 13 Aug 2025; snapshot 2025-12-20; 2019 version from snapshot 2019-07-21. https://helpx.adobe.com/lightroom-classic/help/import-photos-tethered-camera.html (snapshots: https://web.archive.org/web/20251220193513/… and https://web.archive.org/web/20190721231329/…)
- [A3] Set up tethered camera support for Fujifilm cameras. Last updated 13 Aug 2025; snapshot 2026-04-23. https://helpx.adobe.com/lightroom-classic/kb/fujifilm-tethered-support.html
- [A4] Sony Tethered Camera Support in Lightroom Classic. Last updated 13 Aug 2025; snapshot 2026-05-16. https://helpx.adobe.com/lightroom-classic/kb/sony-tethered-support.html
- [A5] Tether support on Apple Silicon devices. Last updated 24 May 2023; snapshot 2026-03-05. https://helpx.adobe.com/lightroom-classic/kb/tether-support-apple-silicon-devices.html
- [A6] Troubleshoot tethered capture. Last updated 24 May 2023; snapshot 2026-06-16. https://helpx.adobe.com/lightroom-classic/kb/troubleshoot-tethered-capture-lightroom.html
- [A7] Import photos automatically. Last updated 27 Apr 2021; snapshot 2026-09-03. https://helpx.adobe.com/lightroom-classic/desktop/import-photos/import-photos-automatically.html
- [A8] What's new in Lightroom Classic. Last updated 4 Aug 2026; snapshot 2026-09-24. https://helpx.adobe.com/lightroom-classic/desktop/introduction-to-lightroom-classic/whats-new.html
- [A9] Adobe Lightroom Classic release notes. Last updated 29 Sep 2026; snapshot 2026-10-02. https://helpx.adobe.com/lightroom-classic/desktop/introduction-to-lightroom-classic/release-notes.html
- [A10] Fixed issues in Lightroom Classic. Snapshot 2026-09-15. https://helpx.adobe.com/lightroom-classic/desktop/troubleshooting/fixed-issues.html
- [A11] Known issues in Lightroom Classic. Last updated 21 Apr 2026; snapshot 2026-05-18. https://helpx.adobe.com/lightroom-classic/kb/known-issues.html
- Not reachable: live helpx.adobe.com (HTTP 403 to curl; headless Chrome timed out at 40 s twice); community.adobe.com (403); adobe.com product pages (HTTP/2 stream error and timeout).

**The Lightroom Queen (secondary source)**

- [Q1] What's New in Lightroom Classic 15.4 (June 2026). https://www.lightroomqueen.com/whats-new-in-lightroom-2026-06/
- [Q2] … 15.5 (August 2026). https://www.lightroomqueen.com/whats-new-in-lightroom-2026-08/
- [Q3] … 15.6 (September 2026). https://www.lightroomqueen.com/whats-new-in-lightroom-2026-09/
- [Q4] … 15.0 (October 2025). https://www.lightroomqueen.com/whats-new-in-lightroom-2025-10/
- [Q5] … 15.1 (December 2025). https://www.lightroomqueen.com/whats-new-in-lightroom-2025-12/
- [Q6] … 14.5 (August 2025). https://www.lightroomqueen.com/whats-new-in-lightroom-2025-08/
- [Q7] … 14.4 (June 2025). https://www.lightroomqueen.com/whats-new-in-lightroom-2025-06/
- [Q8] … 14.3 (April 2025). https://www.lightroomqueen.com/whats-new-in-lightroom-2025-04/
- [Q9] … 14.2 (February 2025). https://www.lightroomqueen.com/whats-new-in-lightroom-2025-02/
- [Q10] … 14.0 (October 2024). https://www.lightroomqueen.com/whats-new-in-lightroom-2024-10/
- [Q11] … 13.3 (May 2024). https://www.lightroomqueen.com/whats-new-in-lightroom-2024-05/
- [Q12] … 13.0 (October 2023). https://www.lightroomqueen.com/whats-new-in-lightroom-2023-10/
- [Q13] … 12.2 (February 2023); also 12.4 and 12.5 for Leica crash reports. https://www.lightroomqueen.com/whats-new-in-lightroom-classic-12-2/ , https://www.lightroomqueen.com/whats-new-in-lightroom-classic-12-4/ , https://www.lightroomqueen.com/whats-new-in-lightroom-classic-12-5/
- [Q14] … 12.1 (December 2022). https://www.lightroomqueen.com/whats-new-in-lightroom-classic-12-1/
- [Q15] … 10.0. https://www.lightroomqueen.com/whats-new-in-lightroom-classic-10-0/
- [Q16] … 10.2. https://www.lightroomqueen.com/whats-new-in-lightroom-classic-10-2/
- [Q17] … 10.3. https://www.lightroomqueen.com/whats-new-in-lightroom-classic-10-3/
- [Q18] … 10.4. https://www.lightroomqueen.com/whats-new-in-lightroom-classic-10-4/
- [Q19] … 8.0. https://www.lightroomqueen.com/whats-new-in-lightroom-classic-80/
- [Q20] … 8.1 (comment thread on SDK lag). https://www.lightroomqueen.com/whats-new-in-lightroom-classic-81/
- [Q21] … 8.2. https://www.lightroomqueen.com/whats-new-in-lightroom-classic-8-2/
- [Q22] Lightroom cloud ecosystem vs. Lightroom Classic (updated 30 Jul 2025). https://www.lightroomqueen.com/lightroom-cc-vs-classic-features/
- [Q23] Site search snippet of the members-only "Tethered Shooting & Watched Folders" page. https://www.lightroomqueen.com/?s=%22same+as+previous%22 (page: https://www.lightroomqueen.com/premium-classic/import/tethered-shooting-watched-folders/, full text not accessible)
- [Q24] … 9.0 ("Nikon Tether SDK is updated to the latest version"). https://www.lightroomqueen.com/whats-new-in-lightroom-classic-9-0/

**App Store listings** (read through https://itunes.apple.com/lookup and /search, US store)

- [AS-LRm] Lightroom: AI Photo Editor. https://apps.apple.com/us/app/lightroom-ai-photo-editor/id878783582
- [AS-LRd] Adobe Lightroom: Photo Editor (Mac). https://apps.apple.com/us/app/adobe-lightroom-photo-editor/id1451544217
- [AS-Cas] Cascable Studio: Camera Tether. https://apps.apple.com/us/app/cascable-studio-camera-tether/id974193500
- [AS-Kuu] Kuuvik Capture 7. https://apps.apple.com/us/app/kuuvik-capture-7/id1495559464
- [AS-Mac] MacroDSLR. https://apps.apple.com/us/app/macrodslr/id1281646509
- [AS-Ast] AstroDSLR. https://apps.apple.com/us/app/astrodslr/id1111955128
- [AS-SC] ShutterCount. https://apps.apple.com/us/app/shuttercount/id720123827
- [AS-BK] iRemoteCapture https://apps.apple.com/us/app/iremotecapture/id1572978661 ; Time Lapse Movie https://apps.apple.com/us/app/time-lapse-movie/id1358333436 ; PictureMe Pro 3 https://apps.apple.com/us/app/pictureme-pro-3/id1481335480 ; CameraTether https://apps.apple.com/us/app/cameratether/id1469890158
- [AS-Mom] Moments. https://apps.apple.com/us/app/moments/id1194414752
- [AS-Ph] Phocus Mobile. https://apps.apple.com/us/app/phocus-mobile/id1452280435
- [AS-L] Leica FOTOS. https://apps.apple.com/us/app/leica-fotos/id1356061526

**Apple developer documentation** (read through the documentation JSON at developer.apple.com/tutorials/data/…)

- [AP-G] App Review Guidelines, 2.4.5. https://developer.apple.com/app-store/review/guidelines/
- [AP-1] ImageCaptureCore. https://developer.apple.com/documentation/imagecapturecore
- [AP-2] ICCameraDevice. https://developer.apple.com/documentation/imagecapturecore/iccameradevice
- [AP-3] requestEnableTethering(). https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestenabletethering()
- [AP-4] requestTakePicture(). https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requesttakepicture()
- [AP-5] requestSendPTPCommand(_:outData:completion:). https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand(_:outdata:completion:)
- [AP-6] ptpEventHandler. https://developer.apple.com/documentation/imagecapturecore/iccameradevice/ptpeventhandler
- [AP-7] ICDeviceBrowser. https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser
- [AP-8] requestControlAuthorization(completion:). https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser/requestcontrolauthorization(completion:)
- [AP-9] com.apple.security.device.usb. https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb

**Kuvacode (Smart Shooter, CaptureGRID)**

- [K1] CaptureGRID 6 home. https://kuvacode.com/
- [K2] Purchasing a licence. https://kuvacode.com/buy
- [K3] Smart Shooter 5. https://kuvacode.com/smartshooter5
- [K4] Smart Shooter 6. https://kuvacode.com/smartshooter6
- [K5] Smart Shooter 6 docs: Upgrading from Smart Shooter 5; macOS. https://smartshooter.com/v6/migration.html , https://smartshooter.com/v6/mac.html
- [K6] Smart Shooter 5 docs: macOS; Camera Control (keyboard shortcuts, including firing all cameras). https://smartshooter.com/v5/mac.html , https://smartshooter.com/v5/camera_control.html
- [K7] Supported Cameras (v6 and v5). https://smartshooter.com/v6/supported_cameras.html , https://smartshooter.com/v5/supported_cameras.html
- [K8] Release notes (v6). https://smartshooter.com/v6/release_notes.html
- [K9] Script Controls; Barcode Scanning; Viewing Cameras; Photo Download; Name Policy (v6). https://smartshooter.com/v6/script_controls.html , https://smartshooter.com/v6/barcode_scanning.html , https://smartshooter.com/v6/viewing_cameras.html , https://smartshooter.com/v6/photo_download.html , https://smartshooter.com/v6/name_policy.html
- [K10] External API (v6). https://smartshooter.com/v6/external_api.html

**Cascable**

- [C1] Home. https://cascable.se/
- [C2] Cascable Studio. https://cascable.se/studio/
- [C3] Cascable Pro Webcam. https://cascable.se/pro-webcam/
- [C4] Working with Wired Cameras. https://cascable.se/help/wired-cameras/
- [C5] Cascable Studio Version History. https://cascable.se/help/studio/version-history/
- [C6] Cascable Studio 7 is here (blog, Dec 2024). https://cascable.se/blog/cascable-7-released/
- [C7] CascableCore developer portal. https://developer.cascable.se/
- [C8] CascableCore Distribution README. https://github.com/Cascable/cascablecore-distribution
- [C9] Getting Started With CascableCore. https://github.com/Cascable/cascablecore-demo/blob/master/Getting%20Started%20With%20CascableCore.md

**Sony**

- [S1] Imaging Edge Desktop. https://imagingedge.sony.net/en-us/ie-desktop.html
- [S2] Imaging Edge Desktop support (news and versions). https://support.d-imaging.sony.co.jp/app/imagingedge/en/
- [S3] Recommended environment. https://www.sony.net/pcenv/ (redirects to https://support.d-imaging.sony.co.jp/www/disoft/int/pcenv/en/contents/index.html)
- [S4] How to use: Remote Shooting. https://support.d-imaging.sony.co.jp/app/imagingedge/en/instruction/4_5_remote.php
- [S5] Camera Remote SDK. https://support.d-imaging.sony.co.jp/app/sdk/en/index.html
- [S6] Camera Remote Command. https://support.d-imaging.sony.co.jp/app/cameraremotecommand/en/index.html

**Canon**

- [CA1] EOS Utility 3.20 Instruction Manual. https://cam.start.canon/en/S003/manual/html/
- [CA2] Compatible Cameras. https://cam.start.canon/en/S003/manual/html/UG-00_Before_0050.html
- [CA3] Connecting the Camera and Computer. https://cam.start.canon/en/S003/manual/html/UG-00_Before_0060.html
- [CA4] Focus Bracketing. https://cam.start.canon/en/S003/manual/html/UG-03_RemoteCamera_0040.html
- [CA5] Timer-Controlled Shooting. https://cam.start.canon/en/S003/manual/html/UG-03_RemoteCamera_0100.html
- [CA6] Network Settings. https://cam.start.canon/en/S003/manual/html/UG-04_Other_0060.html
- [CA7] Preferences. https://cam.start.canon/en/S003/manual/html/UG-05_Setting_0010.html
- [CA8] Canon South & Southeast Asia, List of Available SDKs. https://asia.canon/en/campaign/developerresources/sdk
- Not reachable: https://www.canon-europe.com/support/consumer/products/software/eos-utility/ (403), https://www.usa.canon.com/support/software/eos-utility (403), https://www.canon.com.au/support/software/eos-utility (403).

**Nikon**

- [N1] NX Tether product page. https://imaging.nikon.com/imaging/lineup/software/nx_tether/
- [N2] NX Tether 2.5.0 download page. https://downloadcenter.nikonimglib.com/en/download/sw/276.html
- [N3] Nikon SDK download. https://sdk.nikonimaging.com/apply/
- Not reachable: NX Tether online help (several URLs returned 404).

**Fujifilm**

- [F1] Software. https://www.fujifilm-x.com/global/products/software/
- [F2] FUJIFILM TETHER APP. https://www.fujifilm-x.com/global/products/software/tether-app/
- [F3] TETHER APP compatibility. https://www.fujifilm-x.com/global/support/compatibility/software/tether-app/
- [F4] FUJIFILM X Acquire. https://www.fujifilm-x.com/global/products/software/x-acquire/
- [F5] X Acquire compatibility. https://www.fujifilm-x.com/global/support/compatibility/software/x-acquire/
- [F6] Adobe Photoshop Lightroom Classic + Tether Plugin. https://www.fujifilm-x.com/global/products/software/adobe-photoshop-lightroom-tether-plugin/
- [F7] Camera Control SDK. https://www.fujifilm-x.com/global/camera-control-sdk/

**Panasonic**

- [P1] LUMIX Tether Download Program. https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html

**OM System**

- [O1] OM Capture overview. https://software.omsystem.com/omcapture/en/
- [O2] OM Capture features. https://software.omsystem.com/omcapture/en/features.html
- [O3] OM Capture download and system requirements. https://download.omsystem.com/pages/oc1download/en/
- [O4] OM Capture Update for macOS. https://support.jp.omsystem.com/en/support/imsg/digicamera/download/software/omc/omc_update_mac.html
- [O5] OM SYSTEM software (US). https://explore.omsystem.com/us/en/software
- [O6] OLYMPUS Capture Update for Mac. https://support.jp.omsystem.com/en/support/imsg/digicamera/download/software/oc/oc_update_mac.html

**Hasselblad**

- [H1] Phocus for PC/Mac. https://www.hasselblad.com/phocus/phocus-for-pc-mac/
- [H2] Phocus Mobile 2. https://www.hasselblad.com/phocus/phocus-mobile-2/

**Leica**

- [L1] Leica FOTOS. https://leica-camera.com/en-int/photography/leica-apps/leica-fotos
- Not found: a Leica page for its Lightroom Classic tether plug-in or a Leica desktop tethering app.

**Other developers**

- [D1] DIRE Studio, Kuuvik Capture. https://www.direstudio.com/kuuvik-capture/
- [CM1] CloudMakers, MacroDSLR. https://www.cloudmakers.eu/macrodslr/
- [CM2] CloudMakers home (INDIGO A1 "replaces retired … AstroDSLR"). https://www.cloudmakers.eu/

**darktable and gphoto2**

- [DT1] darktable 5.6 manual, tethering overview. https://docs.darktable.org/usermanual/5.6/en/tethering/overview/
- [DT2] Tethering view layout. https://docs.darktable.org/usermanual/5.6/en/tethering/tethering-view-layout/
- [DT3] Examples. https://docs.darktable.org/usermanual/5.6/en/tethering/examples/
- [DT4] Troubleshooting. https://docs.darktable.org/usermanual/5.6/en/tethering/troubleshooting/
- [DT5] Camera settings module. https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/tethering/camera-settings/
- [DT6] Live view module. https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/tethering/live-view/
- [DT7] Session module. https://docs.darktable.org/usermanual/5.6/en/module-reference/utility-modules/tethering/session/
- [G1] libgphoto2 licence file (LGPL-2.1, per GitHub's licence API). https://github.com/gphoto/libgphoto2/blob/master/COPYING (API: https://api.github.com/repos/gphoto/libgphoto2/license). gphoto.org itself was not reachable (connection refused on HTTP; certificate name mismatch on HTTPS).
