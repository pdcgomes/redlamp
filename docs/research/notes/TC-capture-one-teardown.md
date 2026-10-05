# Capture One's tethered capture: teardown

Evidence for the [tethered capture findings](../tethering-findings.md): what Capture One's tethering does, which cameras it covers, and when each part arrived. Written on 5 October 2026 from Capture One's own help centre, read through its public API (`support.captureone.com/api/v2/help_center/…`) because the pages refuse scripted requests. Every claim links the article it comes from; "Assessment" marks our reading.

## 1. Camera coverage

**Evidence.** [Camera Models and RAW Files Supported by Capture One](https://support.captureone.com/hc/en-us/articles/360002718118) (updated 4 October 2026) lists each model with the version that added it, its raw formats and three flags: Tethered, Live View and Wireless. [`capture_one_cameras.py`](../../../research/prototypes/tethering/capture_one_cameras.py) parses it into [`capture-one-cameras.json`](../../../research/prototypes/tethering/data/capture-one-cameras.json) (checked 5 October 2026):

| Maker | Models listed | Tethered | Live View | Wireless |
| --- | --- | --- | --- | --- |
| Canon | 115 | 63 | 63 | 22 |
| Nikon | 90 | 54 | 47 | 7 |
| Phase One and Phase One Industrial | 53 | 53 | 42 | 2 |
| Sony | 108 | 50 | 24 | 15 |
| Fujifilm | 64 | 21 | 20 | 8 |
| Leica | 52 | 15 | 7 | 0 |
| Mamiya and Leaf | 35 | 7 | 4 | 0 |
| Panasonic | 102 | 3 | 3 | 3 |
| Apple iPhone | 3 | 3 | 0 | 0 |
| Sigma | 3 | 2 | 0 | 0 |
| OM System and Olympus, Pentax, Ricoh, Samsung, Konica Minolta, Hasselblad, other | 143 | 0 | 0 | 0 |
| **Total** | **768** | **271** | **210** | **57** |

- The article's notes qualify some flags: the Nikon D2X and D200 tether on Windows only; Leica has no wireless tethering at all; Phase One's wireless and network tethering is IQ4 only; Panasonic's wireless needs recent camera firmware; the Sigma fp and fp L lost Live View after 16.2.6; older Mamiya and Leaf backs stopped tethering at 12.1. The three iPhones tether only to Capture One's mobile app over USB-C.
- Recent bodies carry "ReTether is supported" (Canon EOS R1, R5 Mark II, R6 Mark III, R6 V, R50 V, C50; Nikon ZR), and the EOS R1 "ethernet tethering".
- New bodies arrive within weeks: the Sony α7R VI (16.8.1, June 2026, wired with Live View), the Leica SL3-P (16.8.2), the Canon EOS R8 Mark II with "day-zero support" (16.8.6), from the [16.8.x release notes](https://support.captureone.com/hc/en-us/articles/31141690629917).
- Tethering flags by the major version that added the model: of the 271, 51 came in 16.x (2022 to 2026) and 220 before; of the 57 wireless, 32 came in 16.x.

**Assessment.** Four makers, Canon, Nikon, Sony and Fujifilm, are 188 of the 271 tethered models (69%). Phase One's 53 are Capture One's sister company's backs. Sony's 50 include bodies back to the α7 and α5000 (2013 and 2014), of which only 24 have Live View, so older Sony bodies tether through a narrower protocol than current ones. "Matching Capture One's coverage" in practice means the four big makers' current bodies, Leica's recent ones, and keeping up with new releases within weeks.

## 2. Features, by area

### Camera control

- **Evidence.** The [Tether tool tab](https://support.captureone.com/hc/en-us/articles/7618979247389) gives "complete control over the available settings of your compatible camera, such as the exposure and metering modes, exposure compensation, ISO, white balance and release the shutter". The [Camera Settings tool](https://support.captureone.com/hc/en-us/articles/360002562957) shows "any property sent by the camera", so the settings available depend on the model ([Connecting camera and adjusting camera settings](https://support.captureone.com/hc/en-us/articles/360002777437)). **Save Destination** (16.4.0) sends raws to the computer and the card, or only JPEGs to the computer, for Canon, Nikon and Sony; on Sony, "JPEG to Capture One / RAW to Card will only bring in a small 2MB JPEG".
- [What operations can I perform whilst shooting tethered?](https://support.captureone.com/hc/en-us/articles/360002411197) tabulates the controls by maker: remote capture everywhere; shutter, aperture, ISO, exposure compensation, white balance and file format for Canon, Nikon and Sony (Fujifilm has no shutter speed or ISO control there); autofocus for Canon, Nikon and Sony; zoom and pan in Live View for Canon and Nikon but not Sony or Fujifilm; camera focus, a Focus Cursor, drive mode and the in-camera crop for Fujifilm only (16.7).
- Battery status shows in the Camera tool.

### Live View

- **Evidence.** A separate [Live View](https://support.captureone.com/hc/en-us/articles/360002566797) window and workspace, "created to work in a studio environment": orientation, lightness and quality, a monochrome view, a white-balance picker that changes only the Live View image, a Focus Meter, the camera's autofocus through Camera Focus buttons, an [Overlay](https://support.captureone.com/hc/en-us/articles/360002567218) (a layout image over the frame for composition), zoom and pan, and capture from Live View ([cursor tools](https://support.captureone.com/hc/en-us/articles/360002832617)). Fujifilm's Focus Cursor focuses where you click (16.7).

### The next captures

- **Evidence.** **Next Capture Adjustments** ([adding adjustments](https://support.captureone.com/hc/en-us/articles/360002556677)): Defaults, Copy from Last (the default), Copy from Primary, Copy from Clipboard, and "Copy specific from Last…" or "…from Primary…" with a checklist; plus an ICC profile, orientation, metadata and styles. **Auto Alignment** straightens and corrects keystone at capture, now for every camera ([article](https://support.captureone.com/hc/en-us/articles/27712089898397)). **Next Capture Naming** (tokens and a counter) and **Next Capture Location** (the capture folder and subfolders). In Capture One Studio only: **Next Capture Metadata**, **Keywords** and **Backup** (a second copy of each original to another drive, with a queue that survives a relaunch; [Backup](https://support.captureone.com/hc/en-us/articles/360002676938)).
- [Tethering with a supported camera](https://support.captureone.com/hc/en-us/articles/360002549697) recommends **Sessions** (plain folders on disk: Capture, Selects, Output, Trash) over Catalogs for tethering.

### Cameras it doesn't support

- **Evidence.** A **Hot Folder** ([article](https://support.captureone.com/hc/en-us/articles/360002562437)): the maker's own capture utility writes into a folder Capture One watches, and new files come in as captures, "however, support for Capture One's tethering tools and features is greatly reduced".

### Wireless and reliability

- **Evidence.** Wireless tethering arrived maker by maker: Canon in 22 (15.0.0, December 2021, also over a network cable), Sony in 15.3 (June 2022), the Nikon Z9 and D6 in 15.4.0 (September 2022, with the WT-6 transmitter or a cable), Fujifilm in 16.2.0 (May 2023, also over the FT-HX grip's network port) and Panasonic in 16.6.3 (June 2025, "teamed up with Panasonic", new camera firmware required). Sony's newer firmware needs its network **Access Authentication** turned off for Capture One ([Sony guide](https://support.captureone.com/hc/en-us/articles/5473534946461)).
- Speed: on a Canon R5 over Wi-Fi 5, "~5-10 seconds from trigger to ready", 3 to 6 s with the WFT-R10 grip ([best practices](https://support.captureone.com/hc/en-us/articles/4409336949649)).
- **2nd Gen Wireless Tethering for Canon** (16.8, May 2026, "created in collaboration with Canon, this pending patent feature"): the camera sends "a smaller RAW file … immediately after capture", which appears "in as little as one to two seconds" against "10 to 25 seconds per RAW file" before, and is fully editable; the full raw follows in the background and replaces it, keeping the edits; a badge marks photos still waiting ([article](https://support.captureone.com/hc/en-us/articles/35841313187357)). EOS R5 Mark II, R1, R3 and R6 Mark III.
- **ReTether** (16.3, October 2023; Canon and Nikon over USB): unplug, shoot to the card for up to two hours, and on reconnection the new frames are imported with Next Capture Adjustments and Naming applied. From 16.8 it recovers wireless drops and "replaces partial files with complete ones" ([ReTether](https://support.captureone.com/hc/en-us/articles/14075830227229)).
- 16.5.0: "if a connected camera has a non-empty memory card, the Camera Tool will notify you if the connection is slowed down by macOS … related to Spotlight indexing that we can't work around."
- 16.8: "When Preview Is Ready puts your image on screen the moment it is received while AI adjustments run in the background."
- FireWire tethering ended at 14.2.0 (May 2021): "Apple and Microsoft have made updates to their architecture and we can no longer maintain firewire tethering support on ARM and Intel based computers."

### Review and clients

- **Evidence.** **Exposure Evaluation** and the **Focus** tool and Focus Mask for checking captures. **Assisted Review during tethering** (16.8.6, September 2026) tags frames with "closed eyes, missed focus, or flash misfires" as they arrive.
- **Client Viewers** (Studio, 16.4.0): up to three more viewer windows that pin a photo, follow the selection or follow the latest capture, fully rendered with edits ([article](https://support.captureone.com/hc/en-us/articles/18155251834013)).
- **Live for Studio**, a free iPad app on the local network, "no internet required", where anyone can view, follow, rate and colour-tag ([About Capture One Studio](https://support.captureone.com/hc/en-us/articles/17932082795037)).
- **Capture One Live** (15.1.0): a cloud service sharing a session's photos in real time to a browser for viewing, rating, tagging and comments; free for one 24-hour session at a time, Unlimited at US$5 a month ([overview](https://support.captureone.com/hc/en-us/articles/4403611619985), [FAQ](https://support.captureone.com/hc/en-us/articles/4404366517393)).
- **Capture Pilot**, the older iOS app and web viewer on the local network, which also controls Phase One XF cameras ([overview](https://support.captureone.com/hc/en-us/articles/360002574498)).

### iPad and iPhone

- **Evidence.** Capture One for iPad and the iPhone app tether by cable and wirelessly, "the same cameras as Capture One Pro" ([mobile cameras](https://support.captureone.com/hc/en-us/articles/12628082004381)); wired needs an iPhone X or later and Apple's camera adapter on Lightning models ([equipment](https://support.captureone.com/hc/en-us/articles/12628216723869)). Phase One backs tether to the iPad only as IQ4 over Ethernet or Wi-Fi.

### Studio and Enterprise extras

- **Evidence.** Barcode scanning into file names (Studio for Enterprise), Tool Locks, a Guides tool, multi-user sessions (beta) and Actions ([product variants](https://support.captureone.com/hc/en-us/articles/360002465337)).

### What Capture One doesn't do

- **Evidence.** No focus stacking: "you can use Capture One to select the appropriate sequence and then export the images to the dedicated focus stacking application Helicon Focus" ([FAQ](https://support.captureone.com/hc/en-us/articles/360007362838)). HDR merge and panorama stitching came in 22 (15.0.0).

## 3. Upkeep

**Evidence.** Of the 111 release notes and "what's new" pages in the help centre (Capture One 12 to 16.8.6), 88 mention tethering, Live View, wireless or the Next Capture tools, mostly fixes: "tethered capture could lock up if auto focus could not find a focus point" (13.0.0), "live view could hang when using a Sony a9 II" (13.1.0), "M1-macs only: Tethering does not work on Thunderbolt ports using USB3.x cables with some Canon cameras" (14.2.0), "a crash that could occur during tethering when adjusting a slider while images were being ingested" and "specific Sony cameras … crash during tethering with Live View enabled" (16.7.1). Standing known issues: "Live View over USB can stall without the use of a repeater", "do not reconnect a camera until the Camera tool status changes". The [troubleshooting guide](https://support.captureone.com/hc/en-us/articles/17686528663709) starts with macOS permissions (`tccutil reset All com.captureone.captureone16`), then cables, hubs and power.

**Assessment.** Tethering is a standing maintenance line for Capture One, not a feature finished once: each new body, firmware and macOS release brings fixes, and the maker partnerships (Canon's small raws, Panasonic's firmware) show it works with the makers directly.

## 4. What parity means

**Assessment.** To match Capture One, Redlamp needs, in order of what photographers would notice:

1. A new capture on screen, developed with the next-capture settings, within a second or two over USB, and the shoot never losing a frame (writes to disk first, card backup, reconnection).
2. Next Capture Adjustments (defaults, copy from last, a recipe, a checklist), naming and location, in a session that is a plain folder.
3. Camera settings, shutter, autofocus and Live View with overlays and zoom for Canon, Nikon, Sony and Fujifilm current bodies, then Leica and Panasonic.
4. Wireless for the bodies that offer it.
5. A hot folder for everything else.
6. Client viewing on a second display and an iPad on the local network (Capture One's cloud Live is a subscription service Redlamp wouldn't run).

Where Redlamp could go beyond: tethered focus brackets straight into its own stacking (Capture One sends them to Helicon Focus), focus peaking and clipping in Live View, recipes and Copy Settings' checklist for the next captures, and published, community-checked camera support.

The rest of the study's evidence is in the notes beside this one; what it adds up to is in the [findings](../tethering-findings.md).

## Sources

All from support.captureone.com, read on 5 October 2026 through the help centre API; the release notes and the 232 articles read are those whose titles mention tethering, Live View, capture, sessions, wireless, Studio or release notes. Article IDs are in the links above.
