# Tethered capture for Redlamp: technical routes and licences, maker by maker

Evidence for the [tethered capture findings](../tethering-findings.md): how Redlamp could control cameras on the Mac, and what each route's licence allows. Every source below was checked on 2026-10-05; source IDs in square brackets point to the list at the end. Sony's "only available for corporate customers" and the SDK's warranty-consent clause were checked again against Sony's pages the same day.

Claims are labelled **Evidence** (what a source says, quoted or closely paraphrased) or **Assessment** (our reading, which counsel or a hardware test should confirm). Where something could not be verified, the text says so.

What we did not do: we registered for nothing, submitted no application, and accepted no licence or disclaimer. Where a document sits behind an "accept" step (CIPA DC-005, the Nikon SDK licence, the Canon licences), only what is visible before that step is reported. No GPL or LGPL source code was read; one libgphoto2 issue thread is cited only for its description of macOS behaviour.

## Summary

- **ImageCaptureCore gives Redlamp a licence-free base on macOS.** It finds USB PTP cameras, takes a picture (`requestTakePicture()`, macOS only), passes raw PTP commands through (`requestSendPTPCommand`, macOS 10.15+, iPadOS 13+), delivers PTP events (`ptpEventHandler`, macOS 12+) and downloads new files [A1–A9]. It has no API for exposure settings, autofocus or Live View; those need PTP commands sent through the passthrough. `requestEnableTethering()` has been deprecated since macOS 14, with Apple saying that capable cameras now have tethering on by default [A3]. Apple's documentation asks sandboxed macOS 14+ apps for `com.apple.security.device.usb`, and tethering macOS apps for the Photos Library entitlement [A1].
- **`ptpcamerad` stands between vendor SDKs and USB cameras.** macOS starts it on demand and it opens a PTP session before a vendor SDK can claim the camera. Developers outside the sandbox work around it with kill loops and USB re-enumeration [X1–X3]. Capture One documents a related problem: card scanning on recent macOS "steals the camera connectivity" [X4]. Assessment: ImageCaptureCore goes through the system's own camera service, so it should not meet this conflict, and a sandboxed app cannot rely on the kill-and-re-enumerate workarounds.
- **The core PTP operation and property codes are freely downloadable** in USB-IF's MTP 1.1 specification [P1, P2], and the USB transport in the Still Image class definition [P4]. Both grant reproduction "for internal use only" and disclaim IP warranties. ISO 15740:2013 costs CHF 227 [P7]. CIPA's PTP/IP standard (DC-005) is free but sits behind a disclaimer page we did not accept. Its public white paper says discovery, pairing and authentication are out of scope [P5, P6]. Assessment: an own Swift implementation of standard PTP and PTP/IP appears unencumbered by these documents, but vendor extensions (settings, Live View) need vendor documentation.
- **Vendor routes for Apple Silicon Macs:**
  - **Sony:** the Camera Remote SDK (version 2.02.00, macOS 14.1+, USB, wired LAN and Wi-Fi, 32 listed bodies) may ship "in an inseparable way" inside an app [S1, S2]. The Camera Remote Command PTP reference (50 bodies) is "only available for corporate customers" [S3].
  - **Canon:** EDSDK is USB-only on macOS (60+ bodies; macOS 26 added in v13.20.11) [C1, C8]. CCAPI runs over Wi-Fi and needs per-camera activation [C6, C10]. The licences are visible only after access is granted [C4]. Canon Singapore's public terms include confidentiality and a territorial limit [C2].
  - **Nikon:** free SDKs; a unified Z-series module 2.0.0 covers 15 Z bodies. Older D-series modules ran under Rosetta 2, and the licence is shown only inside the download flow [N1–N3].
  - **Fujifilm:** its SDK supports macOS 10.12–26 over USB and Wi-Fi for 18 bodies, and has a public EULA [F1, F2].
  - **Sigma:** a Mac SDK exists, but its licence allows "personal or internal business purposes" only [SG2, SG3].
  - **Not available on macOS:** Panasonic's SDK (Windows only) [PA1], Phase One's (Windows and Linux) [PO2] and Ricoh's (Windows/Linux USB, iOS/Android wireless) [R1–R3].
  - **No public SDK found:** Leica, OM System and Hasselblad X. Each has its own Mac tether app.
- **Open-source fit:** MPL-2.0 allows a "Larger Work" that combines MPL files with separately licensed files [P9]. No maker's SDK can sit in the public repository, though. Fujifilm and Sony also require end users to be told that a camera controlled through the app falls "out of such manufacturer-warranty" [S2, F2]. Panasonic and Ricoh restrict combination with licences that require source disclosure [PA2, R3]. Every vendor-SDK route therefore needs counsel before work starts (matrix in section 4).

## 1. Apple: ImageCaptureCore on macOS and iPadOS

### 1.1 What it does natively

Evidence (Apple documentation JSON, availability as listed by Apple):

| Capability | API | macOS | iPadOS / iOS | Mac Catalyst | Source |
|---|---|---|---|---|---|
| Find cameras (USB; location masks also include Bonjour, shared, Bluetooth) | `ICDeviceBrowser`, `browsedDeviceTypeMask`, `ICDeviceLocationTypeMask.bonjour` | 10.4 | 13.0 (mask 15.2) | 13.1 (mask 15.2) | [A10, A11] |
| Enable or disable tethering | `requestEnableTethering()`, `requestDisableTethering()` | 10.4, **deprecated 14.0** | not available | not available | [A3, A4] |
| Read tethering state | `tetheredCaptureEnabled` | 10.4 | 13.0 | 13.1 | [A5] |
| Take a picture | `requestTakePicture()` | 10.4 | **not available** | not available | [A6] |
| Send a raw PTP command | `requestSendPTPCommand(_:outData:completion:)` (also async) | 10.15 | 13.0 | 13.1 | [A7] |
| Receive PTP events | `ptpEventHandler`; delegate `cameraDevice(_:didReceivePTPEvent:)` | 12.0; delegate 10.4 | 13.0 | 13.1 | [A8, A9] |
| New captures appear as items, then download | `cameraDevice(_:didAdd:)`; `requestDownloadFile(...)`; `requestReadData(from:atOffset:length:...)` | class 10.4 (per-method availability not checked) | class 13.0 | class 13.1 | [A2, A9] |
| Battery level, clock sync, delete, upload | `batteryLevel`, `requestSyncClock()`, `requestDeleteFiles`, `requestUploadFile` | class 10.4 (per-method availability not checked) | class 13.0 | class 13.1 | [A2] |
| User authorisation | `requestControlAuthorization(completion:)`, `requestContentsAuthorization(completion:)` | **not listed** | 14.0 | 14.0 | [A10] |

- Evidence: the deprecation note on `requestEnableTethering()` reads: "Third party cameras that support the standard take picture command will have the capability enabled by default. This call will have no effect" [A3]. The `requestTakePicture()` page still says "Before taking a picture, you must first enable tethering by calling requestEnableTethering()" [A6].
- Evidence: Apple's retired PTPPassThrough sample (2009, Mac OS X 10.6) is "a sample camera client application that uses PTP pass-through APIs in ImageCaptureCore framework to communicate with a PTP camera" [A22]. The current reference does not document the byte layout that `requestSendPTPCommand` expects [A7]. Assessment: the retired sample is the public example of that layout; we did not review its code.
- Evidence: `ICReturnPTPDeviceError.Code.notAuthorizedToSendCommand` exists, with no description [A12]. A user on the Apple Developer Forums reported that error from `requestSendPTPCommand` on iOS 13.6, with the same command working on macOS [A23] (user report, before the iOS 14 authorisation API).
- Evidence: the constants include `transportTypeTCPIP`, and `ICDeviceLocationTypeMask.bonjour` is "A mask for detecting a network device that publishes a Bonjour service" [A11]. A 2019 forum post reports `_ptp._tcp` Bonjour cameras appearing in Image Capture on macOS 10.14 [A24] (user report). Assessment: We could not verify whether current macOS ImageCaptureCore connects to PTP/IP cameras; this needs a hardware test.
- Assessment: there is no ImageCaptureCore API for exposure settings, focus or Live View. All three need PTP passthrough, using either the standard device properties (MTP 1.1 Appendix C, such as F-Number, Exposure Time and Exposure Index) or vendor operations. Whether a body accepts the standard properties varies by maker and must be tested.

### 1.2 Sandbox entitlements, Info.plist keys and prompts (Mac App Store)

- Evidence: "To import pictures and tether from a macOS app, you first need to enable the Hardened Runtime capability in Xcode, and then add the Photos Library Entitlement." [A1]. The key is `com.apple.security.personal-information.photos-library`; Apple says to add it "under Resource Access, select Photos Library" with the Hardened Runtime [A15]. Apple's App Sandbox page lists only address book, location and calendars under App Data [A19]. Assessment: whether a sandboxed App Store build also needs this key for tethering is not stated; test before release.
- Evidence: "In macOS 14 and later, use the com.apple.security.device.usb entitlement key to allow your sandboxed app to interact with USB devices." [A1]. The key's own page says: "Use this key to allow your sandboxed app to interact with USB devices through USB device access APIs." [A13].
- Evidence (network cameras): `com.apple.security.network.client` permits outgoing connections; "For UDP sockets, the network entitlements restrict both initiation and data flow ... Apps using UDP usually require both entitlements." [A14]. Local network privacy applies on macOS 15 and later. Apple: "All Bonjour operations require local network access", and the system shows an alert the first time a program accesses the local network [A18]. Apps should carry `NSLocalNetworkUsageDescription` and list browsed Bonjour types in `NSBonjourServices` [A17]. Helper tools are attributed to the app that launched them [A18]. Assessment: a PTP/IP implementation needs `network.client`, possibly `network.server` (some cameras open a connection back to the host), `NSLocalNetworkUsageDescription`, and `_ptp._tcp` in `NSBonjourServices` if it browses.
- Evidence (iPadOS): "Before you can tether from an iOS app ... Add the NSCameraUsageDescription key" [A1, A16]; the control and contents authorisation requests exist on iOS/iPadOS 14+ and Mac Catalyst 14+ [A10].
- Evidence: the Camera entitlement (`com.apple.security.device.camera`) covers "built-in and external cameras, and capture movies and still images", with per-app consent since macOS 10.14 [A26]. Assessment: Apple does not tie it to ImageCaptureCore; it governs capture devices such as webcams.
- Evidence (helpers): an embedded helper tool in a sandboxed app gets App Sandbox and `com.apple.security.inherit` [A20]. App Review Guideline 2.4.5 requires Mac App Store apps to be "appropriately sandboxed", and says they "may not present a license screen at launch" [A21]. Assessment: a vendor SDK moved into a helper runs under the same sandbox, so the helper does not add privileges. Consent screens that Sony or Fujifilm require must appear at first camera connection, not at launch.

### 1.3 `ptpcamerad` and conflicts with vendor SDKs or libusb

- Evidence (this Mac, macOS 26.6.2 build 25G83): `ptpcamerad(8)` reads "ptpcamerad is a system daemon responsible for communicating with PTP cameras ... users should not run ptpcamerad manually." [A25]. It is a per-user LaunchAgent (`/System/Library/LaunchAgents/com.apple.ptpcamerad.plist`) with `RunAtLoad` false and Mach service `com.apple.ptpcamerad`, so launchd starts it on demand. `com.apple.icdd` is `KeepAlive` and `RunAtLoad` true [A25].
- Evidence (third party, libgphoto2 issue #971, March 2024): "It used to (macOS 12 and older) auto start when the camera gets plugged in but you could just `pkill` it ... In macOS 13 they changed the launch configuration so it gets started once an application (like Preview.app or Dropbox, or even a printer driver) wants to talk to the/a camera. Annoyingly it also gets restarted every time you kill it" [X1].
- Evidence (third-party developer of a Sony SDK bridge, April 2026): "`launchctl bootout gui/<uid>/com.apple.ptpcamerad` fails under SIP"; "CMIO does a Mach service lookup on com.apple.ptpcamerad when it sees a USB camera, and launchd respawns the daemon"; the stale session is cleared with an IOKit USB re-enumerate [X2]. Another Sony SDK wrapper: "macOS launches `ptpcamerad` for any imaging USB device and it grabs the PTP session before the SDK can" [X3].
- Evidence (vendor, Capture One support): "Due to recent macOS updates, Mac scans the card when it is detected, which steals the camera connectivity with Capture One while that scanning process is ongoing." It also asks users to remove "EOS Utility or Sony Imaging Edge", which "can interfere" [X4]. Canon's FAQ: "EDSDK 64bit library may cause crashes when EOS Utility is running on the same computer." [C6].
- We found no Apple engineer statement on this in the Developer Forums; the threads we could read were user posts [A23, A24].
- Assessment: going through ImageCaptureCore avoids the race, because ImageCaptureCore talks to the camera through the system service. A vendor SDK, or a libusb or IOKit stack, competes with `ptpcamerad` for the USB interface. Inside the App Sandbox, killing a system daemon is not available as documented API; we did not test whether the sandbox would even allow it. USB re-enumeration would need `com.apple.security.device.usb`, and its behaviour in a sandbox is untested. Network transports (LAN, Wi-Fi) do not involve `ptpcamerad`.

## 2. Public standards

| Document | Where | Cost and access | Licence or notice (key sentence) | Source |
|---|---|---|---|---|
| ISO 15740:2013, PTP (edition 3) | iso.org | CHF 227; 115 pages; "last reviewed and confirmed in 2023" | Sold by ISO; "A VendorExtensionID can be registered through IS&T." | [P7] |
| MTP 1.1 (USB-IF, 6 April 2011) | usb.org document library, `MTPv1_1.zip` | Free, no login | "A LICENSE IS HEREBY GRANTED TO REPRODUCE THIS SPECIFICATION FOR INTERNAL USE ONLY. NO OTHER LICENSE ... IS GRANTED" | [P1, P2] |
| MTP 1.1 Adopters Agreement | in the same zip | Optional; "not effective until a fully executed original has been received by the Secretary at USB Implementers Forum" | Adopters grant each other patent licences under "Necessary Claims" on "reasonable and non-discriminatory terms, and with a zero royalty or zero fee ("RAND-Z")" | [P3] |
| USB Still Image Capture Device Definition 1.0 (2000, errata 2007) | usb.org, `usb_still_img10.zip` | Free, no login | "A LICENSE IS HEREBY GRANTED TO REPRODUCE AND DISTRIBUTE THIS SPECIFICATION FOR INTERNAL USE ONLY." | [P4] |
| CIPA DC-005-2005, PTP over TCP/IP ("PTP-IP") | cipa.jp | Free download behind a disclaimer ("Please read and accept the disclaimer"); **not accepted** | Disclaimer: "Neither CIPA nor any of its members shall in any way warrant or take any responsibility for no-infringement of Intellectual Property Rights" | [P5] |
| CIPA DC-005 white paper | cipa.jp, direct PDF | Free | "portions of this document are Copyright © 2004-2005 FotoNation Inc." | [P6] |
| PTP Vendor Extension ID registry | imaging.org (IS&T) | Public page | "Since 2011, IS&T has been responsible for assigning VEID codes." | [P8] |

Evidence on content:

- MTP 1.1 §1.5: "This protocol is implemented as an extension of the existing Picture Transfer Protocol, as defined by the ISO 15740 specification" [P2]. Appendix D lists the PTP operations with codes and parameters (from D.2.1 GetDeviceInfo through D.2.14 InitiateCapture, `0x100E`, and D.2.28 InitiateOpenCapture). Appendix C lists device properties (F-Number, Exposure Time, Exposure Index, Focus Mode, White Balance, Exposure Program Mode and others) [P2].
- The Still Image class definition specifies the USB class requests (Cancel, Get Extended Event Data, Device Reset, Get Device Status), the bulk-pipe containers, and "ANNEX A. STRUCTURE OF THE PIMA 15740 DATASETS [NORMATIVE]". It notes that such devices "are PIMA 15740 single session devices" [P4].
- DC-005 was "published 2005-11, confirmed 2019-06" and "proposed to be a CIPA standard on 2005-04-06 by ... FotoNation Inc." [P5]. The white paper says: "The scope of PTP-IP does not specify such aspects of networking applications as network configuration, device discovery, device bonding, user authentication etc." It also notes that PTP-IP "can support multiple concurrent sessions" [P6].

Assessment (counsel should confirm):

- The usb.org notices restrict copying the documents, not implementing them. Operation codes and data layouts are interoperability facts. Writing Swift code from MTP 1.1 Appendices C and D and the Still Image class definition, without copying text, appears unencumbered by these notices.
- The RAND-Z pledge binds only parties that sign the Adopters Agreement. Its scope excludes "the implementation of other published specifications developed elsewhere but referred to in the body" [P3], which arguably includes the core PTP from ISO 15740. We found no patent declaration for ISO 15740 or DC-005, and did not search the ISO patent database.
- PTP/IP is unencumbered at the level of the transport. Each maker adds its own discovery and pairing, which the standard leaves out [P6] and which are not public.

## 3. Maker by maker

### 3.1 Sony

**Route A: Camera Remote SDK (a library)**

- Evidence: version 2.02.00 (10 June 2026; "Added support for ILCE-7RM6"). The SDK covers "changing the camera settings, shutter release and live view monitoring" [S1].
- Evidence (platforms and transports): "macOS® 14.1 - / macOS® 15.1 - / macOS® 26.0 -", Windows 11 ("Computers with Intel or AMD processors (does not work on ARM-processor-based computers)", a note for Windows), and Linux (ARMv8, ARMv7, x86). Interfaces are "USB, Wired LAN, Wireless LAN (Wi-Fi)", varying by device [S1].
- Evidence (cameras): 32 entries, among them ILCE-1M2, ILCE-1, ILCE-9M3, ILCE-7RM6, ILCE-7RM5, ILCE-7M5, ILCE-7M4, ILCE-7CR, ILCE-7CM2, ILCE-6700, ZV-E1, DSC-RX1RM3, ILX-LR1, cinema bodies (BURANO, FX3, FX6, FX30) and PTZ heads (BRC-AM7, ILME-FR7). "It is necessary to update each camera to the latest System Software" [S1].
- Evidence (how to get it): regional "APPLY" links. The UK form asks for name, surname, company, industry and company type before a free download [S1, S6].
- Evidence (licence, public, accepted by clicking "I AGREE" before download) [S2]:
  - Grant (ii): "incorporate a binary form of the library file in the SOFTWARE into the APPLICATION SOFTWARE in an inseparable way and distribute the APPLICATION SOFTWARE to any third parties".
  - Grant (iii): the end-user licence is "solely for the purposes to remotely control or use the DEVICE in a normal usage".
  - Restrictions: "You may not share, distribute, rent, lease, sublicense, assign, transfer or sell the SOFTWARE unless expressly authorized"; "You may not separate any individual component of the SOFTWARE unless expressly authorized".
  - Warranty consent: "explain to and obtain a consent from the END-USERS ... that once a DEVICE is used or controlled through the APPLICATION SOFTWARE, the DEVICE will be out of such manufacturer-warranty as separately specified by SONY". A similar consent is required for the arms-use prohibitions.
  - Updates: "If and when such updated SOFTWARE is released, you shall use such updated SOFTWARE to modify the APPLICATION SOFTWARE".
  - Termination is possible if Sony "reasonably determines the APPLICATION SOFTWARE otherwise creates a negative user experience".
  - Open-source components: these "may be covered by open source software licenses", with a list at oss.sony.net. Governing law is Japan's (Tokyo District Court).
  - There is no confidentiality clause as such.
- Evidence (open-source components): Sony's source-distribution site has no Camera Remote SDK entry in the category pages we checked (`DI`, `B2B` and `Others`) [S5]. Two third-party developers report that the macOS SDK ships "native arm64 + x86_64 dylibs", "uses a bundled libusb for USB transport", is "only ad-hoc signed", and looks up its plugins at `Contents/Frameworks/CrAdapter` [X2, X3]. **Not verified from a Sony source.** libusb is LGPL-2.1, which Redlamp's clean-room policy excludes if it applies to bundled binaries.
- Assessment:
  - The licence permits shipping the library inside the app. "Inseparable" probably means bundled inside the app, not a separate download; whether an XPC helper inside the bundle qualifies needs counsel.
  - The MPL-2.0 source tree cannot contain the SDK headers or binaries (restriction above). The Sony module would need to be an optional build component.
  - The warranty-consent and arms-consent duties fall on Redlamp as distributor.
  - USB use on macOS conflicts with `ptpcamerad` (section 1.3); LAN and Wi-Fi avoid it.

**Route B: Camera Remote Command (a PTP command reference)**

- Evidence: version 2.02.00 (10 June 2026) [S3].
  - Cameras: 50 bodies, adding older ones to the SDK list (ILCE-7M3, ILCE-7M2, ILCE-7RM3A, ILCE-6600, ILCE-6400, ILCE-6100, ZV-1, ZV-E10, RX100M7, RX10M4, HX99 and others). "Only supports the latest firmware version."
  - Interfaces: USB, wired LAN and Wi-Fi. PTP-IP was added in 2024.1.0 (16 October 2024).
  - It is described as "a communication protocol that is Sony's proprietary extension of the ISO standard PTP".
  - "Camera Control PTP 2 commands may become unusable on some models from 2027, so their use is not recommended."
  - FAQ: "It is free of charge."; developers "can sell their apps for legitimate purposes"; "No. Camera Remote Command is only available for corporate customers."
- Evidence (licence, public) [S4]:
  - The "LICENSED MATERIALS" are "any protocol and example programs ... and any printed, on-line or other electronic documentation for such protocol".
  - The grant covers developing application software for Sony devices, and lets you "incorporate example programs in the LICENSED MATERIALS into the APPLICATION SOFTWARE in an inseparable way and distribute the APPLICATION SOFTWARE".
  - The same no-sharing, no-derivative-works and warranty-consent clauses as the SDK apply.
- Assessment:
  - Technically, Sony's PTP extension could be driven from Swift through ImageCaptureCore passthrough (USB) or an own PTP/IP stack, with no Sony binary.
  - Legally, publishing MPL-2.0 source that encodes Sony's command set may count as distributing part of the "LICENSED MATERIALS" or a derivative work. Access is also limited to corporate customers.

### 3.2 Canon

**Route A: EDSDK (a library, USB)**

- Evidence (Canon Singapore, "Updated as of April 2025") [C1]:
  - "USB wired control"; "60 types or more in the EOS/PowerShot Series".
  - "macOS v13.x -15.x (64bit) Console apps are not guaranteed to work. Apple Silicon Macs with macOS 13.0-13.2 installed can't connect to a camera. Please use macOS 13.3 or later. In macOS 14.0-14.1, connection failures occur. Please use macOS 14.2 or later. In macOS 15.x, there is an issue where connecting multiple units of the same model fails."
  - Sample code for macOS is in Objective-C and Swift.
- Evidence (Canon USA release notes) [C8]:
  - EDSDK v13.20.11 (14 May 2026): "Added support for macOS v26 / Stopped support for macOS v13".
  - v13.20.21 (23 July 2026): "Added support for the EOS R6V". EDSDK with RAW v13.20.10 added the EOS R6 Mark III.
- Evidence (Canon Europe FAQ) [C6]: "EDSDK doesn't support Wi-Fi connection to control camera." "You can distribute EDSDK DLLs and program headers with your application. You are not allowed to distribute other contents or EDSDK package itself."
- Evidence (how to get it): regional programmes [C5].
  - Canon Europe: EMEA residents only; register, complete a profile, request access. "Canon Europe Ltd. has distributed the Camera SDK only in EMEA."
  - Canon USA: registrants must be "an individual with a direct role in the design, development, or enhancement of a software program ... at least 18 ... reside in ... North America, South America, or the Caribbean" [C9].
  - Canon Singapore: "The Applicant must be a legally registered entity"; responses typically take 2–4 weeks [C1].
- Evidence (licence):
  - Canon Europe: "You will be able to view, read and print the Licence Agreement once you have been given access." [C4]. **Not visible without access.**
  - Canon Singapore's terms are public [C2]. They grant a "revocable license to use the SDK in object code format: a) Solely for the purpose as stated in the Form; b) To be used and distributed only in object code format; c) For use only within the country/region of application named in the Form". The SDK "may be distributed ... only as part of the Developer Software to end-users". Confidential information "shall not be disclosed to any other party" except employees. The licence runs for one year, renewing automatically.
- Assessment:
  - The binary can ship with an app (Europe FAQ), but the governing licence is unseen.
  - The Singapore territorial clause conflicts with worldwide App Store distribution.
  - USB use meets `ptpcamerad`.

**Route B: CCAPI (HTTP API over Wi-Fi)**

- Evidence: "No special libraries are needed for CCAPI. The supported cameras respond to CCAPI requests directly." "The supported cameras can communicate using CCAPI via Wi-Fi only. USB or Ethernet on cameras are not supported by CCAPI." "USB communication will be disabled when CCAPI is enabled on the camera." [C6]. Canon Singapore adds: "Only EOS-1D X Mark III and EOS R3 can be controlled via wired LAN" [C1].
- Evidence (versions and cameras): CCAPI 1.4.0f (9 July 2026) lists 26 models, including EOS R1, R5 Mark II, R6 Mark III, R6V, R50V, R8, R7, R3, 1D X Mark III and PowerShot V10 [C7].
- Evidence (activation): the CCAPI Operation Guide "explains how to activate the Camera Control API ... using the CCAPI Activation Tool". The camera is connected by USB, and "The CCAPI function will not activate if you are not connected to the internet." [C10]. The version we read lists Mac OS X 10.12–10.15 on Intel; Canon USA's notes record later "Activation Tool macOS 15.x Support" [C8]. A third-party app tells its users to obtain "the CCAPI Activation Tool as provided to you by PicThrive Support" [X7]. The EOS R50 V manual shows a "Camera Control API" menu entry [C11]. Whether newer bodies still need activation is **not verified**.
- Assessment:
  - An own Swift HTTP client is technically small.
  - But the API specification is under Canon's developer licence (confidentiality in the Singapore terms).
  - Every user's camera must be activated with a tool Canon gives to developers.
  - Local Network privacy applies (section 1.2).

### 3.3 Nikon

- Evidence: "We offer software development kits (SDKs) free of charge to those developing products and services that incorporate Nikon digital imaging products ... Nikon does not provide technical support for SDKs." The remote-control SDKs provide "Library Programs and Command API Specifications" [N1].
- Evidence (cameras and versions) [N1, N3]:
  - 31 March 2026: "a unified Remote Module SDK (Ver. 2.0.0) for all Z-series cameras", supporting "the Z9, Z8, Z6III, Z7II, Z6II, Z7, Z6, Z5II, Z5, Zf, Z50II, Z50, Z30, Zfc, and ZR". It "Added support for macOS Sequoia version 15", ended macOS 12 and ended Windows 10.
  - Per-model modules remain for 36 D-series and Nikon 1 bodies (D40 through D850, D6, Df, Nikon 1 V3), and for eight Z bodies that 2.0.0 also covers: 51 distinct bodies in total.
  - The SDKs "support all cameras that can be remotely controlled via NX Tether or Camera Control Pro 2", and "do not support multiple cameras at the same time" (FAQ).
- Evidence (Apple Silicon): the 7 December 2022 note on the per-model modules says "These modules run under Rosetta 2 on the Apple Silicon CPU." [N3]. For the Z-series 2.0.0 module, native arm64 is **not stated**. macOS 26 is not mentioned.
- Evidence (MTP documents): Nikon has distributed per-camera "Media Transfer Protocol (MTP) Specifications" documents in the SDK (2021 note) [N3].
- Evidence (licence): the application process requires you to "Read the SDK license agreement. You must agree to the terms of the license agreement to proceed to the next step" (step 3, after selecting an SDK) [N2]. FAQ: "All limitations you need to follow (if any) are written in the license agreements presented when you download the SDKs." [N3]. **Not read**: We stopped at the category-selection step.
- Transports: the public pages describe cameras "connected to a computer" and do not list transports. **Not verified**.
- Assessment: the route is technically promising (Command API and MTP specs included), but the licence terms are unknown. Rosetta 2 for older modules runs against an Apple Silicon-only app.

### 3.4 Fujifilm

- Evidence [F1]:
  - "FUJIFILM X Series and GFX System Digital Camera Control SDK"; version 1.34 (12 November 2025, adds GFX ETERNA 55); manual corrected 18 February 2026.
  - Interfaces: "USB (connecting a camera and a computer directly)" and "TCP/IP network (via a Wi-Fi access point)".
  - Operating systems include macOS 10.12 through "macOS 26(Tahoe)", Windows, Linux and Android (USB only). Apple Silicon support is **not stated** on the page.
  - "Information regarding the conversion of the RAW image data ... is not provided with this SDK."
- Evidence (cameras, 18): X-M5, X-T3, X-T4, X-Pro3, X-S10 (firmware 2.00+), X-H2S, X-H2, X-T5, X-S20, GFX 50S, GFX 50R, GFX100, GFX100S, GFX50S II, GFX100 II, GFX100S II, GFX100RF, GFX ETERNA 55. X100VI, X-T50, X-T30 III, X-E5 and X half are not listed [F1].
- Evidence (how to get it): separate "For Individuals" (agreement, then download) and "For Businesses" (a contact page, not read) paths. The page warns: "FOR INDIVIDUALS, PLEASE NOTE USING THIS SDK TO CONNECT TO, OR CONTROL, ANY COMPATIBLE FUJIFILM CAMERA, WILL VOID THE CAMERA'S LIMITED PRODUCT WARRANTY." [F1].
- Evidence (EULA, public; "Agree and Download" was not clicked "Agree and Download") [F2]:
  - The "Library" is the object code "in the "REDISTRIBUTABLE" folder".
  - 2(b) permits you to "sell, sublicense, provide, or distribute the Library ... to the Customer ONLY in the form of being incorporated into the Digital Imaging System in object code format; provided that you shall impose substantially the same obligations under this Agreement on such Customer".
  - 3.1 requires prompt Library upgrades when Fujifilm fixes bugs.
  - 3.4 forbids distributing the SDK "in whole or in part" otherwise.
  - 3.9: "you shall not subject the SDK to any open source license conditions such as those set forth in GNU General Public License (GPL) and GNU Lesser/Library GPL (LGPL)".
  - 5.2 and 5.3: a product controlled through the app "SHALL BE OUT OF SUCH MANUFACTURER-WARRANTY", and you "SHALL EXPLAIN AND MAKE SUCH CUSTOMER FULLY UNDERSTAND" this.
  - 7.4: on termination, "stop providing ... the Digital Imaging System". Japanese law, Tokyo arbitration.
- Fallback: X Acquire "has been integrated into "FUJIFILM TETHER APP"" [F3]; the Tether App's Mac version is 1.34.1 [F4].
- Assessment:
  - The public EULA permits shipping the library in object code inside an app. It must stay outside the MPL source tree; MPL-2.0 §3.3 allows that.
  - Imposing "substantially the same obligations" on App Store customers needs a custom EULA and counsel.
  - The warranty notice is a product decision for the owner.
  - The Wi-Fi transport avoids `ptpcamerad`.

### 3.5 Panasonic

- Evidence [PA1]:
  - LUMIX SDK, beta only. Beta 2.01 (8 August 2022) covers BGH1 and BS1H ("Supports USB & Ethernet interface"). Beta 1.00 (14 October 2020) covers S1R, S1, S1H, S5, S5M2, S5M2X, S9, GH5S, G9, G9M2, GH5, GH5M2, GH6 and GH7 over USB; S1RM2 also appears in the download form.
  - Operating environment: "Windows 10 (64bit)", Visual Studio 2015, Intel CPU. **No macOS.**
  - Download requires the camera's 11-character serial number; "we cannot respond to usage or technical questions".
- Evidence (licence, public, last updated 28 June 2021) [PA2]:
  - Article 1 permits you to "incorporate library files as a binary format ... into the Developed Software and distribute non-detachably".
  - Article 5: "This software may be used on one computer".
  - Article 8: "Licensee shall not use and incorporate any Open Source Software ... into the Software or the Developed Software". Open Source Software includes any licence requiring parties to "disclose or distribute to any third party all or part of the source code".
- Fallback: LUMIX Tether 2.12 (26 November 2025) runs on macOS 12.0–15.6 on Intel and Apple Silicon. Ethernet works on some bodies (several via a USB-LAN adapter) and Wi-Fi on BGH1 and BS1H. "Due to the specifications of macOS ... Multiple connection" does not work over USB [PA3].
- Assessment: not available on macOS. Article 8 also conflicts with an MPL-2.0 application.

### 3.6 Leica

- Evidence: Lightroom Classic 15.0 (27 October 2025) added native tethering for "Leica SL3, Leica SL3-S, Leica Q3 and Leica Q3 43", described as "the result of close collaboration between Leica Camera and Adobe" [L1].
- We found no public Leica camera-control SDK or PTP documentation in searches on 2026-10-05. Third-party news reports a Leica and Capture One tethering partnership; we did not verify it from a primary source.
- Assessment: no public SDK route. Standard PTP through ImageCaptureCore is untested. Users of Lightroom or Capture One can tether there and let Redlamp watch the output folder.

### 3.7 OM System / Olympus

- Evidence: OM Capture is "a tethering application which connects compatible OM SYSTEM (Olympus) products to a computer". It runs on "macOS v13-15, 26" with an "Apple M1 chip or later", connects by USB, and needs the camera serial number to download [O1]. "The OM-1 Mark II is available with wireless camera control via Wi-Fi." [O2].
- Evidence (legacy): Olympus's Camera Kit SDK served the Open Platform Camera OLYMPUS AIR A01. A third-party README says the A01 "was discontinued by the manufacturer on 2018-03-31" and that "OLYCameraKit.framework is released under the terms of OLYMPUS license" [X6]. The SDK documentation host it links (`dl-support.olympus-imaging.com`) did not resolve from our network.
- We found no current OM System camera-control SDK.
- Assessment: hot folder through OM Capture, or untested standard PTP through ImageCaptureCore.

### 3.8 Hasselblad

- Evidence: Phocus for Mac/PC supports tethered capture ("Tethered execution of Focus Bracketing sequences ... X, H and 907X cameras are supported") [H1]. The downloads page lists Phocus for Mac/PC and Phocus Mobile [H3].
- Evidence: the A6D aerial camera manual says "Phocus SDK for Windows available on request" [H2].
- We found no public SDK for the X system (X2D, X2D II, 907X).
- Assessment: hot folder through Phocus, or untested standard PTP.

### 3.9 Pentax / Ricoh

- Evidence (Ricoh news release, 16 May 2018; the original URL now redirects to Ricoh's release list, so an archived copy was read) [R1]:
  - Four SDKs: "RICOH Camera USB SDK for Microsoft® .NET Framework", "RICOH Camera USB SDK for C++", "RICOH Camera Wireless SDK for iOS" and "... for Android™".
  - Cameras: PENTAX 645Z (USB only), K-1 Mark II, K-1, KP, and K-70 (wireless only).
  - Downloads "free of charge" from `api.ricoh`, which did not resolve from our network.
- Evidence (licence, as packaged by Debian in **non-free**, `libricohcamerasdk` 1.1.0, a Linux binary via INDI) [R2, R3]:
  - 2.1(b): "You may copy and distribute the software library included in the Software ("Distributable Code") as part of the Application Software".
  - 3.2 forbids a program file that "contains code both the Distributable Code and the Open Source Software ... if such Open Source Software is licensed under a license that requires any "modifications" be made freely available".
  - California law.
- We found no macOS build of the USB SDK.
- Fallback: IMAGE Transmitter 2 version 2.6.2 for Windows and Mac OS covers the 645Z, K-1, KP, 645ZIR, K-1 Mark II, G900SE, K-3 Mark III and K-3 Mark III Monochrome [R4].
- Assessment: no macOS SDK. The EULA permits library redistribution but restricts mixing with copyleft code in one file. MPL-2.0 is file-level, so a separate library file may be acceptable; counsel should confirm if a macOS build ever appears.

### 3.10 Sigma

- Evidence: "The SIGMA Camera Control SDK ... allows users to control the operation of SIGMA fp from a computer via USB connection" (2 July 2020) [SG1]. The support catalogue lists "SIGMA Camera Control SDK for Mac (SDK Data) DMG 15.9MB" and a Windows ZIP under both the fp and fp L sections [SG2].
- Evidence (licence, shown in the download modal; read from its source, not accepted) [SG3]:
  - "you have a nontransferable, nonexclusive and non-sublicensable right to use the Licensed Software solely for your personal or internal business purposes, and not for any further resale, sublicense or other use by third parties".
  - "You agree to prevent and protect the contents of the Licensed Software and Documentation from any unauthorized disclosure or use."
  - No right to modify or create derivative works; Japanese law.
- Evidence (third party): the SDK "includes API documents, C/Objective-C headers, and compiled binary files for Windows and Mac" [X5]. The fp series speaks PTP (ISO 15740) [X5].
- Assessment: the licence gives no right to ship the library to users, and it imposes non-disclosure on the documentation. Redistribution through Redlamp is not available under these terms; standard PTP through ImageCaptureCore remains (untested).

### 3.11 Phase One

- Evidence: CameraSDK and ImageSDK. "Get started for free by signing up" [PO1]. Supported platforms are "Windows 10 & 11 (x64)" and "Linux (ARM64 & x86_64)"; cameras are the "iXM series, P5 series, IQ4 series". Revision 4.2.5 (CameraSDK 3.2.5) [PO2]. **No macOS.**
- Evidence (licence, public PDF, 18 April 2020) [PO3]:
  - 2.1: "non-sublicensable, revocable and nontransferable right to use the Software ... solely to develop, test, integrate to, and operate applications in connection to Phase One products".
  - 3.3: you "may distribute or sub-license the Software only (i) while combined with a Phase One product capability, (ii) compiled and linked inside such combined product package, (iii) while the API of the Software is embedded inside the combined product and not exposed or visible in any way to the user and (iv) subject to Phase One's prior written consent".
- Assessment: not available on macOS, and distribution needs written consent. IQ backs tether through Capture One, which Redlamp could follow as a hot folder.

## 4. Licence matrix

Verdict meanings used below:

- **Own Swift implementation possible:** Redlamp can write and publish the code from public documentation.
- **Maker's binary in a separate helper:** the licence lets the maker's library ship inside a distributed app. It would stay out of the MPL source tree, as an optional module or sandboxed helper, with the maker's obligations accepted.
- **Needs counsel:** terms are unseen, unclear, or in tension with MPL-2.0 open source or the Mac App Store. Legal review comes before engineering.
- **Not available:** no macOS route, or no right to redistribute.
- **ImageCaptureCore/hot folder only:** use standard PTP through ImageCaptureCore, or watch the folder that the maker's own tether app writes to.

| Route | Platforms | Transports | Cameras | Licence (source, key sentence) | Open-source fit | App Store/sandbox fit | Verdict |
|---|---|---|---|---|---|---|---|
| Apple ImageCaptureCore (discovery, take picture, PTP passthrough, events, download) | macOS 10.4+ (passthrough 10.15+, event handler 12+); iPadOS 13+ (no `requestTakePicture`) | USB; TCP/IP constant and Bonjour mask exist, network use unverified | Any PTP camera the OS recognises; standard capture only without vendor ops | Platform API [A1–A9]; no separate licence | Yes: Swift calling public API | Yes: `com.apple.security.device.usb` (macOS 14+), Photos Library entitlement per Apple [A1, A13, A15]; cooperates with `ptpcamerad` | **Own Swift implementation possible** |
| Standard PTP operations and properties (MTP 1.1 App. C/D, USB Still Image class) | Any (via ImageCaptureCore passthrough on macOS) | USB | Bodies that implement standard ops and properties (varies; test) | usb.org: "A LICENSE IS HEREBY GRANTED TO REPRODUCE THIS SPECIFICATION FOR INTERNAL USE ONLY" [P2, P4] | Yes, write code without copying text (Assessment) | Yes, through ImageCaptureCore | **Own Swift implementation possible** |
| PTP/IP (CIPA DC-005-2005) | macOS (Network framework) | Ethernet, Wi-Fi | Bodies with plain PTP/IP; vendor pairing not in the standard [P6] | CIPA disclaimer: no warranty of "no-infringement" [P5]; download gate not accepted | Yes for the transport; vendor pairing is not public | `network.client` (and `server` if the camera connects back), Local Network prompt, `NSBonjourServices` `_ptp._tcp` [A14, A17, A18] | **Own Swift implementation possible** (transport only) |
| Sony Camera Remote SDK 2.02.00 | macOS 14.1+/15.1+/26.0+ (arm64 per third parties [X2]) | USB, wired LAN, Wi-Fi | 32 (ILCE-1M2, ILCE-9M3, ILCE-7RM6, ILCE-7M5, ILCE-7M4, ILME-FX3, BURANO, ZV-E1, DSC-RX1RM3…) | [S2] "incorporate a binary form of the library file ... into the APPLICATION SOFTWARE in an inseparable way and distribute"; end-user warranty consent; no sharing of the SOFTWARE | Binary only; not in the repo; possible bundled LGPL libusb (third-party report, unverified) | USB meets `ptpcamerad` (no sandboxed workaround known); LAN/Wi-Fi need Local Network; consent at first connection, not at launch [A21] | **Needs counsel** (then a maker's binary in a separate helper) |
| Sony Camera Remote Command 2.02.00 | Any (PTP) | USB, wired LAN, Wi-Fi (PTP-IP since 2024) | 50 (adds ILCE-7M3, ILCE-6600, ZV-1, DSC-RX100M7…) | [S3] "only available for corporate customers"; [S4] "incorporate example programs ... in an inseparable way"; no sharing of the protocol documentation | Publishing open source that encodes Sony's commands is unclear | Feasible via ImageCaptureCore passthrough or own PTP/IP | **Needs counsel** |
| Canon EDSDK 13.20.x | macOS 14–26 (13 dropped 2026); Apple Silicon notes | USB only | 60+ EOS/PowerShot (R6V, R6 Mark III, R50V…) | [C4] licence visible "once you have been given access"; [C6] "You can distribute EDSDK DLLs and program headers with your application"; [C2] Singapore: object code only, territory of the application, confidentiality | Binary only; licence unseen | USB meets `ptpcamerad` | **Needs counsel** |
| Canon CCAPI 1.4.0f | Any HTTP client | Wi-Fi (wired LAN on 1D X III and R3 per [C1]) | 26 listed | Specification under the developer licence (unseen) [C4]; per-camera activation tool [C10] | Own HTTP client feasible; spec confidentiality unclear | `network.client`, Local Network prompt | **Needs counsel** |
| Nikon Remote SDK (Z 2.0.0; D-series modules) | macOS up to 15 stated; D-series modules under Rosetta 2 [N3] | Not stated publicly | 51 (15 Z incl. Z9, Z8, Z6III, Zf, ZR; 36 D/1-series) | [N2] licence shown only in the download flow; not read | Unknown | USB meets `ptpcamerad`; Rosetta modules not native | **Needs counsel** |
| Fujifilm Camera Control SDK 1.34 | macOS 10.12–26 (Apple Silicon not stated) | USB, TCP/IP via Wi-Fi access point | 18 (X-H2S, X-T5, GFX100 II, GFX ETERNA 55…) | [F2] distribute the Library "ONLY ... incorporated into the Digital Imaging System in object code format", imposing "substantially the same obligations" on customers; no open-source licence conditions on the SDK; warranty notice | Binary only, as a Larger Work [P9]; customer terms needed | USB meets `ptpcamerad`; Wi-Fi needs Local Network; custom EULA in App Store Connect | **Maker's binary in a separate helper** (after counsel on customer terms) |
| Panasonic LUMIX SDK Beta 2.01 / 1.00 | Windows 10 only | USB; Ethernet (BGH1, BS1H) | 16 | [PA2] "shall not use and incorporate any Open Source Software ... into ... the Developed Software" | Conflicts | n/a | **Not available** (hot folder via LUMIX Tether) |
| Leica | No public SDK found | n/a | n/a | n/a | n/a | n/a | **ImageCaptureCore/hot folder only** |
| OM System / Olympus | OM Capture (Mac); legacy AIR A01 kit discontinued | USB; Wi-Fi on OM-1 Mark II | n/a | No SDK found | n/a | n/a | **ImageCaptureCore/hot folder only** |
| Hasselblad X | Phocus (Mac); A6D SDK Windows-only, on request [H2] | USB | n/a | No public SDK found | n/a | n/a | **ImageCaptureCore/hot folder only** |
| Ricoh/Pentax camera SDKs (2018) | Windows/.NET, C++ (Linux build in Debian non-free), iOS, Android; no macOS found | USB; Wi-Fi (mobile SDKs) | 645Z, K-1 II, K-1, KP, K-70 | [R3] "You may copy and distribute ... Distributable Code as part of the Application Software"; no file mixing with copyleft | Possible as a separate file (Assessment) | n/a on macOS | **ImageCaptureCore/hot folder only** (IMAGE Transmitter 2 for Mac) |
| Sigma Camera Control SDK | Mac DMG and Windows ZIP | USB | fp, fp L | [SG3] use "solely for your personal or internal business purposes, and not for any further resale, sublicense or other use by third parties" | No redistribution right; non-disclosure | n/a | **ImageCaptureCore/hot folder only** (SDK not redistributable) |
| Phase One CameraSDK 3.2.5 | Windows 10/11, Linux; no macOS | n/a on Mac | IQ4, iXM, P5 | [PO3] distribution "subject to Phase One's prior written consent" | Consent needed | n/a | **Not available** (hot folder via Capture One) |

## 5. Open points

Things that need counsel:

- Whether MPL-2.0 source that encodes a maker's PTP extension, written from that maker's licensed documentation (Sony, Nikon, Canon), counts as distributing the documentation or a derivative of it.
- Whether "inseparable" (Sony) and "non-detachably" (Panasonic) allow a helper or optional module inside the app bundle.
- How to pass Fujifilm's "substantially the same obligations" to App Store customers.
- Whether the Sony and Fujifilm warranty-consent duties are acceptable for Redlamp.
- Whether an open-source project without a legal entity can obtain Sony Camera Remote Command (corporate customers only) or Canon Singapore access (registered entities only).

Things that need hardware tests:

- On macOS 26: ImageCaptureCore `requestTakePicture()` and `cameraDevice(_:didAdd:)` per maker; PTP passthrough of standard properties (F-Number, Exposure Time, Exposure Index); event delivery.
- Whether ImageCaptureCore sees PTP/IP cameras over Bonjour.
- Whether a sandboxed build needs the Photos Library entitlement, and what prompts appear.
- Whether any vendor SDK can claim a USB camera from a sandboxed process while `ptpcamerad` is running.

Things we could not verify:

- Sony's bundled open-source components (no list found [S5]).
- Native arm64 in Nikon's Z 2.0.0 module and in Fujifilm's macOS library.
- Whether newer Canon bodies still need CCAPI activation.
- Ricoh's current SDK site (`api.ricoh` did not resolve).
- Any OM System or Hasselblad X SDK.
- ISO or CIPA patent declarations.

Repository context (read-only): `docs/lightroom-comparison.md` lists "Tethered capture" as "Later"; the research tracker has no tethering row yet.

## Sources (all checked 2026-10-05)

Apple

- [A1] ImageCaptureCore framework overview: https://developer.apple.com/documentation/imagecapturecore (JSON: https://developer.apple.com/tutorials/data/documentation/ImageCaptureCore.json)
- [A2] ICCameraDevice: https://developer.apple.com/documentation/imagecapturecore/iccameradevice
- [A3] requestEnableTethering(): https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestenabletethering()
- [A4] requestDisableTethering(): https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestdisabletethering()
- [A5] tetheredCaptureEnabled: https://developer.apple.com/documentation/imagecapturecore/iccameradevice/tetheredcaptureenabled
- [A6] requestTakePicture(): https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requesttakepicture()
- [A7] requestSendPTPCommand(_:outData:completion:): https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand(_:outdata:completion:)
- [A8] ptpEventHandler: https://developer.apple.com/documentation/imagecapturecore/iccameradevice/ptpeventhandler
- [A9] ICCameraDeviceDelegate and cameraDevice(_:didReceivePTPEvent:): https://developer.apple.com/documentation/imagecapturecore/iccameradevicedelegate
- [A10] ICDeviceBrowser, requestControlAuthorization(completion:), requestContentsAuthorization(completion:), browsedDeviceTypeMask: https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser
- [A11] ICDeviceLocationTypeMask and ImageCaptureCore Constants: https://developer.apple.com/documentation/imagecapturecore/icdevicelocationtypemask, https://developer.apple.com/documentation/imagecapturecore/imagecapturecore-constants
- [A12] ICReturnPTPDeviceError: https://developer.apple.com/documentation/imagecapturecore/icreturnptpdeviceerror
- [A13] com.apple.security.device.usb: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.usb
- [A14] com.apple.security.network.client: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client
- [A15] Photos Library Entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.photos-library
- [A16] NSCameraUsageDescription: https://developer.apple.com/documentation/bundleresources/information-property-list/nscamerausagedescription
- [A17] NSLocalNetworkUsageDescription and NSBonjourServices: https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription, https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices
- [A18] TN3179, Understanding local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- [A19] App Sandbox: https://developer.apple.com/documentation/security/app-sandbox
- [A20] Embedding a command-line tool in a sandboxed app: https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
- [A21] App Review Guidelines (2.4.5, 2.5.1): https://developer.apple.com/app-store/review/guidelines/
- [A22] PTPPassThrough sample (retired, 2009): https://developer.apple.com/library/archive/samplecode/PTPPassThrough/Introduction/Intro.html
- [A23] Apple Developer Forums thread 656878 (user content): https://developer.apple.com/forums/thread/656878
- [A24] Apple Developer Forums thread 123176 (user content): https://developer.apple.com/forums/thread/123176
- [A25] Local system files on macOS 26.6.2 (25G83): `man 8 ptpcamerad`, `/System/Library/LaunchAgents/com.apple.ptpcamerad.plist`, `/System/Library/LaunchAgents/com.apple.icdd.plist`
- [A26] Camera entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.camera

Standards and licences

- [P1] USB-IF, MTP v1.1 spec and Adopters Agreement: https://www.usb.org/document-library/media-transfer-protocol-v11-spec-and-mtp-v11-adopters-agreement (zip: https://www.usb.org/sites/default/files/MTPv1_1.zip)
- [P2] MTP 1.1 specification, `MTPforUSB-IFv1.1.pdf` in the zip above
- [P3] MTP 1.1 Adopters Agreement, `MTP1_1 ADOPTERS AGREEMENT - Device Class Spec.pdf` in the zip above
- [P4] USB-IF, Still Image Capture Device Definition 1.0 and errata: https://www.usb.org/document-library/still-image-capture-device-definition-10-and-errata-16-mar-2007 (zip: https://www.usb.org/sites/default/files/usb_still_img10.zip)
- [P5] CIPA standards list and DC-005 download gate: https://www.cipa.jp/e/std/std-sec.html, https://www.cipa.jp/std/documents/download_e.html?CIPA_DC-005-2005
- [P6] CIPA DC-005 white paper: https://www.cipa.jp/std/documents/e/CIPA_DC-005_Whitepaper_ENG.pdf
- [P7] ISO 15740:2013: https://www.iso.org/standard/63602.html
- [P8] IS&T, PTP Standards and VEID registry: https://www.imaging.org/IST/IST/Standards/PTP_Standards.aspx
- [P9] Mozilla Public License 2.0 (§1.7, §3.3): https://www.mozilla.org/en-US/MPL/2.0/

Sony

- [S1] Camera Remote SDK: https://support.d-imaging.sony.co.jp/app/sdk/en/index.html
- [S2] Camera Remote SDK licence: https://support.d-imaging.sony.co.jp/app/sdk/licenseagreement/en.html
- [S3] Camera Remote Command: https://support.d-imaging.sony.co.jp/app/cameraremotecommand/en/index.html
- [S4] Camera Remote Command licence: https://support.d-imaging.sony.co.jp/app/cameraremotecommand/licenseagreement/en.html
- [S5] Sony source code distribution service: https://oss.sony.net/Products/Linux/common/search.html
- [S6] Sony Pro (UK) SDK download form: https://pro.sony/en_GB/digital-imaging/sdk-download

Canon

- [C1] Canon Singapore, Camera API Package overview: https://asia.canon/en/campaign/developerresources/camera/cap
- [C2] Canon Singapore, SDK terms and conditions: https://asia.canon/en/campaign/developerresources/terms-conditions-for-digital-camera-software-development-kit-sdk
- [C3] Canon Europe Developer Programme, Camera: https://developers.canon-europe.com/developers/s/camera
- [C4] Canon Europe, Licence Agreement article: https://developers.canon-europe.com/developers/s/article/licence-agreement-camera-general
- [C5] Canon Europe, How to Get Access to Camera SDK?: https://developers.canon-europe.com/developers/s/article/How-to-get-access-camera
- [C6] Canon Europe, Camera FAQ: https://developers.canon-europe.com/developers/s/article/camera-faq
- [C7] Canon Europe, Latest CCAPI: https://developers.canon-europe.com/developers/s/article/Latest-CCAPI
- [C8] Canon USA Developer Community (release notes on home page): https://developercommunity.usa.canon.com/s/
- [C9] Canon USA Developer Community, Registration Terms and Conditions: https://developercommunity.usa.canon.com/s/legal-main
- [C10] Canon, Camera Control API Operation Guide: https://downloads.canon.com/sdk/CameraControlAPI_OperationGuide_EN.pdf
- [C11] Canon EOS R50 V manual, Using Camera Control API: https://cam.start.canon/en/C021/manual/html/UG-07_Network_0070.html

Nikon

- [N1] Nikon SDK download service: https://sdk.nikonimaging.com/apply/
- [N2] Explanation of the SDK application process: https://sdk.nikonimaging.com/apply/guide
- [N3] Information and FAQ: https://sdk.nikonimaging.com/information/en/

Fujifilm

- [F1] Camera Control SDK: https://www.fujifilm-x.com/global/camera-control-sdk/
- [F2] SDK End User License Agreement: https://www.fujifilm-x.com/global/camera-control-sdk/agreement/
- [F3] FUJIFILM X Acquire: https://www.fujifilm-x.com/global/support/download/software/x-acquire/
- [F4] FUJIFILM TETHER APP: https://www.fujifilm-x.com/global/support/download/software/tether-app/

Panasonic

- [PA1] LUMIX SDK: https://av.jpn.support.panasonic.com/support/global/cs/soft/tool/sdk.html
- [PA2] LUMIX SDK Software License Agreement: https://av.jpn.support.panasonic.com/support/global/cs/soft/tool/license_sdk_v2.html
- [PA3] LUMIX Tether: https://av.jpn.support.panasonic.com/support/global/cs/soft/download/d_lumixtether.html

Leica, OM System, Hasselblad

- [L1] Leica press release, Lightroom Classic 15.0 native tethering (27 October 2025): https://leica-camera.com/sites/default/files/2025-10/Press_Release_Lightroom_Native-Tethering_October_2025.pdf
- [O1] OM Capture download: https://download.omsystem.com/pages/oc1download/en/
- [O2] OM Capture features: https://software.omsystem.com/omcapture/en/features.html
- [H1] Phocus for Mac/PC: https://www.hasselblad.com/phocus/phocus-for-pc-mac/
- [H2] Hasselblad A6D user manual: https://cdn.hasselblad.com/manuals/a6d/current/en.pdf
- [H3] Hasselblad downloads: https://www.hasselblad.com/downloads/

Ricoh / Pentax

- [R1] Ricoh news release, 16 May 2018 (original https://www.ricoh.com/release/2018/0516_1 redirects to https://www.ricoh.com/release/list; text read from the copy at https://docslib.org/doc/5725508/software-development-kits-for-pentax-digital-slr-cameras, a secondary host)
- [R2] Debian package tracker, libricohcamerasdk (non-free, 1.1.0-6): https://tracker.debian.org/pkg/libricohcamerasdk
- [R3] Debian copyright file containing Ricoh's EULA: https://metadata.ftp-master.debian.org/changelogs//non-free/libr/libricohcamerasdk/libricohcamerasdk_1.1.0-6_copyright
- [R4] Ricoh Imaging software downloads: https://www.ricoh-imaging.co.jp/english/support/download_digital.html

Sigma

- [SG1] SIGMA Camera Control SDK announcement (2 July 2020): https://www.sigma-global.com/en/news/2020/07/02/10916/
- [SG2] Sigma support catalogue, cameras: https://www.sigma-global.com/en/support/catalog/?category=cameras
- [SG3] Sigma SDK licence (download modal content): https://www.sigma-global.com/en/support/include/license_agreement/detail_9308.inc

Phase One

- [PO1] Phase One SDK overview: https://www.phaseone.com/resources-support-2/developer/sdk/
- [PO2] Phase One SDK documentation: https://developer.phaseone.com/sdk/index.html
- [PO3] Phase One SDK Software License Agreement (18 April 2020): https://www.phaseone.com/wp-content/uploads/2024/01/Phase-One-SDK-Software-License-Agreement.pdf

Third-party and secondary (used only where labelled)

- [X1] libgphoto2 issue #971 (discussion text only): https://github.com/gphoto/libgphoto2/issues/971
- [X2] eclipseClick, "Sony CrSDK on macOS Apple Silicon" (28 April 2026): https://eclipseclick.com/blog/sony-crsdk-macos-apple-silicon/
- [X3] davidanthoff/sonycam README: https://github.com/davidanthoff/sonycam
- [X4] Capture One support, Tethering troubleshooting (desktop): https://support.captureone.com/hc/en-us/articles/17686528663709-Tethering-troubleshooting-desktop
- [X5] sigma-ptpy README: https://github.com/makanikai/sigma-ptpy
- [X6] PlayOPC README: https://github.com/ura14h/PlayOPC
- [X7] PicThrive, Enable CCAPI on your Canon Camera: https://help.picthrive.com/article/9w6m8j2sly-enable-ccapi
