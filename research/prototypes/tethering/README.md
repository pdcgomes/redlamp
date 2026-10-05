# Tethered capture prototypes

Evidence behind the [tethered capture findings](../../../docs/research/tethering-findings.md). Nothing here ships.

## Capture One's camera list

`capture_one_cameras.py` (Python standard library only) reads Capture One's "Camera Models and RAW Files Supported by Capture One" through its help centre's public API and writes one record per model: maker, version added, raw formats, and whether it tethers, has Live View and tethers wirelessly, with the article's notes. It prints a summary by maker.

```bash
research/prototypes/tethering/capture_one_cameras.py --out research/prototypes/tethering/data/capture-one-cameras.json
```

`data/capture-one-cameras.json` is the snapshot of 5 October 2026 (article updated 4 October): 768 models, 271 tethered, 210 with Live View, 57 wireless.

## The probe

`tether-probe.swift` asks a camera, through Apple's ImageCaptureCore, what it supports with standard PTP alone, and times captures. It sends one PTP operation, GetDeviceInfo, and names the operations, events and properties the camera reports from the MTP 1.1 specification (USB-IF), which publishes standard PTP's codes. Vendor codes are printed as numbers only, and the serial number is never read.

```bash
cd research/prototypes/tethering
swiftc -O tether-probe.swift -o build/tether-probe
build/tether-probe --json /tmp/tether-probe-info.json                 # list the camera, dump DeviceInfo
build/tether-probe watch --minutes 3 --json /tmp/tether-probe-watch.json   # press the shutter on the camera
build/tether-probe watch --shoot 5 --json /tmp/tether-probe-shoot.json     # the Mac asks for 5 pictures
```

`watch` logs every PTP event and new file with its time since the session opened, downloads each new file to `/tmp/tether-probe`, and reports how long the download took and, for requested pictures, the time from `requestTakePicture` to the file on disk.

For a Sony body, run it in each of the camera's USB connection modes (Setup, USB Connection Mode, or Network, PC Remote Function): **PC Remote**, then **MTP** (or Mass Storage, which ImageCaptureCore doesn't see as a PTP camera). In PC Remote mode, set Still Img. Save Dest. to PC+Camera so frames also reach the card.

What the SDK says, from `ImageCaptureCore.framework/Headers` (macOS 26.5 SDK):

- `requestEnableTethering` and `requestDisableTethering` are deprecated since macOS 14: "Third party cameras that support the standard take picture command will have the capability enabled by default."
- `requestTakePicture` exists only on macOS; on iPadOS a picture can be asked for only with a PTP command.
- The contents and control authorisation calls are iOS-only. On macOS, ImageCaptureCore has no prompt of its own.
- `requestUploadFile` is deprecated: "Sandbox restrictions prohibit writing directly to device hardware".

## Results

Run on 5 October 2026 (no camera connected yet): the probe builds with the Xcode 26.6 toolchain, runs from Cursor's sandboxed shell and browses for cameras; with nothing connected it finds none. Whether it sees a camera from inside that sandbox is still to be tried.

Developing a raw once it is on disk, the second half of shutter to screen: `redlamp bench --runs 5` on the Sony α7 III fixture (24 MP, 26 MB ARW), Release build, M1 Ultra with the Mac busy (load average 26 to 45): open (decode, upload, demosaic, pyramid) 502 ms, render at Fit 3.3 ms, render the whole photo at 1:1 10.7 ms. The README's figure for an unloaded Mac is 70 to 250 ms to open.
