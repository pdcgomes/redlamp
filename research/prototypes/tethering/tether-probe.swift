// What a camera offers through Apple's ImageCaptureCore with standard PTP alone, and how fast a capture arrives.
//
//   swiftc -O tether-probe.swift -o build/tether-probe
//   build/tether-probe                      lists cameras and dumps each one's PTP DeviceInfo
//   build/tether-probe watch [options]      keeps a session open: logs PTP events and new files,
//                                           downloads each new file and times it
//     --shoot N        asks the camera to take N pictures (requestTakePicture), 6 s apart
//     --minutes M      how long to watch (default 3)
//     --dir PATH       where downloads go (default /tmp/tether-probe)
//     --json PATH      also writes the DeviceInfo and the timings as JSON
//
// Only standard PTP is sent (GetDeviceInfo); its codes are named from the MTP 1.1 specification
// (USB-IF), which publishes PTP's operations, events and properties. Vendor codes are printed as
// numbers only. Serial numbers are never printed or written.

import Foundation
import ImageCaptureCore

// MARK: - Standard PTP names (MTP 1.1, sections 5 and Appendix B to D)

let operationNames: [UInt16: String] = [
    0x1001: "GetDeviceInfo", 0x1002: "OpenSession", 0x1003: "CloseSession", 0x1004: "GetStorageIDs",
    0x1005: "GetStorageInfo", 0x1006: "GetNumObjects", 0x1007: "GetObjectHandles", 0x1008: "GetObjectInfo",
    0x1009: "GetObject", 0x100A: "GetThumb", 0x100B: "DeleteObject", 0x100C: "SendObjectInfo",
    0x100D: "SendObject", 0x100E: "InitiateCapture", 0x100F: "FormatStore", 0x1010: "ResetDevice",
    0x1011: "SelfTest", 0x1012: "SetObjectProtection", 0x1013: "PowerDown", 0x1014: "GetDevicePropDesc",
    0x1015: "GetDevicePropValue", 0x1016: "SetDevicePropValue", 0x1017: "ResetDevicePropValue",
    0x1018: "TerminateOpenCapture", 0x1019: "MoveObject", 0x101A: "CopyObject", 0x101B: "GetPartialObject",
    0x101C: "InitiateOpenCapture",
    0x9801: "GetObjectPropsSupported", 0x9802: "GetObjectPropDesc", 0x9803: "GetObjectPropValue",
    0x9804: "SetObjectPropValue", 0x9805: "GetObjectPropList", 0x9806: "SetObjectPropList",
    0x9807: "GetInterdependentPropDesc", 0x9808: "SendObjectPropList", 0x9810: "GetObjectReferences",
    0x9811: "SetObjectReferences",
]

let eventNames: [UInt16: String] = [
    0x4001: "CancelTransaction", 0x4002: "ObjectAdded", 0x4003: "ObjectRemoved", 0x4004: "StoreAdded",
    0x4005: "StoreRemoved", 0x4006: "DevicePropChanged", 0x4007: "ObjectInfoChanged",
    0x4008: "DeviceInfoChanged", 0x4009: "RequestObjectTransfer", 0x400A: "StoreFull", 0x400B: "DeviceReset",
    0x400C: "StorageInfoChanged", 0x400D: "CaptureComplete", 0x400E: "UnreportedStatus",
]

let propertyNames: [UInt16: String] = [
    0x5001: "BatteryLevel", 0x5002: "FunctionalMode", 0x5003: "ImageSize", 0x5004: "CompressionSetting",
    0x5005: "WhiteBalance", 0x5006: "RGBGain", 0x5007: "FNumber", 0x5008: "FocalLength",
    0x5009: "FocusDistance", 0x500A: "FocusMode", 0x500B: "ExposureMeteringMode", 0x500C: "FlashMode",
    0x500D: "ExposureTime", 0x500E: "ExposureProgramMode", 0x500F: "ExposureIndex",
    0x5010: "ExposureBiasCompensation", 0x5011: "DateTime", 0x5012: "CaptureDelay",
    0x5013: "StillCaptureMode", 0x5014: "Contrast", 0x5015: "Sharpness", 0x5016: "DigitalZoom",
    0x5017: "EffectMode", 0x5018: "BurstNumber", 0x5019: "BurstInterval", 0x501A: "TimelapseNumber",
    0x501B: "TimelapseInterval", 0x501C: "FocusMeteringMode", 0x501D: "UploadURL", 0x501E: "Artist",
    0x501F: "CopyrightInfo",
]

func hex(_ code: UInt16) -> String {
    String(format: "0x%04X", code)
}

func describe(_ codes: [UInt16], _ names: [UInt16: String]) -> (standard: [String], vendor: [String]) {
    var standard: [String] = [], vendor: [String] = []
    for code in codes {
        if let name = names[code] {
            standard.append(name)
        } else {
            vendor.append(hex(code))
        }
    }
    return (standard, vendor)
}

// MARK: - PTP containers (little-endian)

struct Reader {
    let data: Data
    var offset = 0
    init(_ data: Data) {
        self.data = data
    }

    mutating func u8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func u16() -> UInt16? {
        guard let a = u8(), let b = u8() else { return nil }
        return UInt16(a) | UInt16(b) << 8
    }

    mutating func u32() -> UInt32? {
        guard let a = u16(), let b = u16() else { return nil }
        return UInt32(a) | UInt32(b) << 16
    }

    mutating func string() -> String? {
        guard let count = u8() else { return nil }
        var units: [UInt16] = []
        for _ in 0 ..< Int(count) {
            guard let unit = u16() else { return nil }
            if unit != 0 {
                units.append(unit)
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    mutating func u16Array() -> [UInt16]? {
        guard let count = u32(), count < 10000 else { return nil }
        var values: [UInt16] = []
        for _ in 0 ..< count {
            guard let value = u16() else { return nil }
            values.append(value)
        }
        return values
    }
}

func operationRequest(code: UInt16, transaction: UInt32, parameters: [UInt32] = []) -> Data {
    var data = Data()
    func put32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    func put16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    put32(UInt32(12 + 4 * parameters.count))
    put16(1) // command block
    put16(code)
    put32(transaction)
    parameters.forEach(put32)
    return data
}

/// The data phase, with its container header taken off if ImageCaptureCore left one on.
func payload(_ data: Data) -> Data {
    var reader = Reader(data)
    if data.count >= 12, let length = reader.u32(), Int(length) == data.count, reader.u16() == 2 {
        return data.dropFirst(12)
    }
    return data
}

struct DeviceInfo: Codable {
    var standardVersion: UInt16
    var vendorExtensionID: UInt32
    var vendorExtensionVersion: UInt16
    var vendorExtensionDescription: String
    var functionalMode: UInt16
    var operations: [UInt16]
    var events: [UInt16]
    var properties: [UInt16]
    var captureFormats: [UInt16]
    var imageFormats: [UInt16]
    var manufacturer: String
    var model: String
    var deviceVersion: String
}

func parseDeviceInfo(_ data: Data) -> DeviceInfo? {
    var r = Reader(payload(data))
    guard let standardVersion = r.u16(), let vendorID = r.u32(), let vendorVersion = r.u16(),
          let vendorDescription = r.string(), let functionalMode = r.u16(),
          let operations = r.u16Array(), let events = r.u16Array(), let properties = r.u16Array(),
          let captureFormats = r.u16Array(), let imageFormats = r.u16Array(),
          let manufacturer = r.string(), let model = r.string(), let deviceVersion = r.string()
    else { return nil }
    // The serial number follows; it is deliberately not read.
    return DeviceInfo(
        standardVersion: standardVersion, vendorExtensionID: vendorID, vendorExtensionVersion: vendorVersion,
        vendorExtensionDescription: vendorDescription, functionalMode: functionalMode, operations: operations,
        events: events, properties: properties, captureFormats: captureFormats, imageFormats: imageFormats,
        manufacturer: manufacturer, model: model, deviceVersion: deviceVersion,
    )
}

// MARK: - Options

struct Options {
    var watch = false
    var shoot = 0
    var minutes = 3.0
    var directory = URL(fileURLWithPath: "/tmp/tether-probe")
    var json: URL?

    init(_ arguments: [String]) {
        var rest = arguments.dropFirst()
        if rest.first == "watch" {
            watch = true; rest = rest.dropFirst()
        }
        while let flag = rest.popFirst() {
            let value = rest.popFirst() ?? ""
            switch flag {
            case "--shoot": shoot = Int(value) ?? 0
            case "--minutes": minutes = Double(value) ?? minutes
            case "--dir": directory = URL(fileURLWithPath: value)
            case "--json": json = URL(fileURLWithPath: value)
            default:
                FileHandle.standardError.write(Data("unknown option \(flag)\n".utf8))
                exit(2)
            }
        }
    }
}

// MARK: - Probe

struct Timing: Codable {
    var file: String
    var bytes: Int
    var requestedAt: Double? // seconds since the session opened: requestTakePicture
    var firstEventAt: Double? // the first PTP event after it
    var itemAddedAt: Double // didAddItems
    var downloadedAt: Double // the file complete on disk
}

final class Probe: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    let options: Options
    let browser = ICDeviceBrowser()
    var cameras: [ICCameraDevice] = []
    var sessionStart = Date()
    var ready = false
    var transaction: UInt32 = 1
    var report: [String: Any] = [:]
    var timings: [Timing] = []
    var lastRequest: Double?
    var firstEventAfterRequest: Double?
    var known = Set<String>()

    init(options: Options) {
        self.options = options
        super.init()
    }

    func now() -> Double {
        Date().timeIntervalSince(sessionStart)
    }

    func log(_ message: String) {
        print(String(format: "[%8.3f] ", now()) + message)
        fflush(stdout)
    }

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue
                | ICDeviceLocationTypeMask.local.rawValue
                | ICDeviceLocationTypeMask.bonjour.rawValue,
        )!
        browser.start()
        log("browsing for cameras (USB and Bonjour)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            if self.cameras.isEmpty {
                self.log("no camera found in 12 s; is it on, connected, and in PC Remote or MTP/PTP USB mode?")
                self.finish()
            }
        }
    }

    // MARK: ICDeviceBrowserDelegate

    func deviceBrowser(_: ICDeviceBrowser, didAdd device: ICDevice, moreComing _: Bool) {
        guard let camera = device as? ICCameraDevice, cameras.isEmpty else { return }
        cameras.append(camera)
        let transport = camera.transportType ?? "?"
        log("found \(camera.name ?? "camera") (\(camera.productKind ?? "?"), transport \(transport), "
            +
            "usb vendor \(String(format: "0x%04X", camera.usbVendorID)) product \(String(format: "0x%04X", camera.usbProductID)))")
        report["name"] = camera.name
        report["transport"] = transport
        report["usbVendorID"] = camera.usbVendorID
        report["usbProductID"] = camera.usbProductID
        camera.delegate = self
        sessionStart = Date()
        camera.ptpEventHandler = { [weak self] data in self?.event(data) }
        camera.requestOpenSession()
    }

    func deviceBrowser(_: ICDeviceBrowser, didRemove device: ICDevice, moreGoing _: Bool) {
        log("removed \(device.name ?? "device")")
    }

    // MARK: ICDeviceDelegate

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error {
            log("open session failed: \(error)")
            finish()
            return
        }
        log("session open; capabilities: \(device.capabilities.sorted().joined(separator: ", "))")
        report["capabilities"] = device.capabilities.sorted()
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard !ready else { return }
        ready = true
        let files = device.mediaFiles?.count ?? 0
        known = Set(device.mediaFiles?.compactMap { ($0 as? ICCameraFile)?.name } ?? [])
        log("catalog complete: \(files) files on the camera; tetheredCaptureEnabled \(device.tetheredCaptureEnabled); "
            + "battery \(device.batteryLevelAvailable ? "\(device.batteryLevel)%" : "n/a")")
        report["filesOnCamera"] = files
        report["tetheredCaptureEnabled"] = device.tetheredCaptureEnabled
        report["catalogSeconds"] = now()
        getDeviceInfo(device)
    }

    func getDeviceInfo(_ camera: ICCameraDevice) {
        let command = operationRequest(code: 0x1001, transaction: transaction)
        transaction += 1
        let sent = now()
        camera.requestSendPTPCommand(command, outData: nil) { data, response, error in
            DispatchQueue.main.async { self.deviceInfo(camera, data, response, error, sent) }
        }
    }

    func deviceInfo(_ camera: ICCameraDevice, _ data: Data, _ response: Data, _ error: Error?, _ sent: Double) {
        var r = Reader(response)
        _ = r.u32(); _ = r.u16()
        let code = r.u16() ?? 0
        log(String(
            format: "GetDeviceInfo: %d bytes, response %@ in %.0f ms%@",
            data.count,
            hex(code),
            (now() - sent) * 1000,
            error.map { ", error \($0)" } ?? "",
        ))
        guard let info = parseDeviceInfo(data) else {
            log(
                "could not parse DeviceInfo (first bytes: \(data.prefix(16).map { String(format: "%02X", $0) }.joined()))",
            )
            report["deviceInfoRaw"] = data.prefix(64).map { String(format: "%02X", $0) }.joined()
            return afterInfo(camera)
        }
        let ops = describe(info.operations, operationNames)
        let events = describe(info.events, eventNames)
        let props = describe(info.properties, propertyNames)
        print("""
        ---- DeviceInfo
        manufacturer   \(info.manufacturer)
        model          \(info.model)
        version        \(info.deviceVersion)
        PTP version    \(info.standardVersion)
        vendor ext.    ID \(info.vendorExtensionID), version \(info.vendorExtensionVersion), "\(info
            .vendorExtensionDescription)"
        functional     \(info.functionalMode)
        operations     \(info.operations.count): standard \(ops.standard.joined(separator: " "))
                       vendor (\(ops.vendor.count)): \(ops.vendor.joined(separator: " "))
        events         \(info.events.count): standard \(events.standard.joined(separator: " "))
                       vendor (\(events.vendor.count)): \(events.vendor.joined(separator: " "))
        properties     \(info.properties.count): standard \(props.standard.joined(separator: " "))
                       vendor (\(props.vendor.count)): \(props.vendor.joined(separator: " "))
        capture fmts   \(info.captureFormats.map(hex).joined(separator: " "))
        image fmts     \(info.imageFormats.map(hex).joined(separator: " "))
        ----
        """)
        if let encoded = try? JSONEncoder().encode(info),
           let object = try? JSONSerialization.jsonObject(with: encoded) {
            report["deviceInfo"] = object
        }
        afterInfo(camera)
    }

    func afterInfo(_ camera: ICCameraDevice) {
        guard options.watch else { return finish() }
        try? FileManager.default.createDirectory(at: options.directory, withIntermediateDirectories: true)
        log("watching for \(options.minutes) min; press the shutter on the camera"
            + (options.shoot > 0 ? ", or wait for \(options.shoot) requested pictures" : ""))
        for index in 0 ..< options.shoot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + 6 * Double(index)) {
                guard camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue) else {
                    self.log("requestTakePicture skipped: the camera doesn't report ICCameraDeviceCanTakePicture")
                    return
                }
                self.lastRequest = self.now()
                self.firstEventAfterRequest = nil
                self.log("requestTakePicture")
                camera.requestTakePicture()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + options.minutes * 60) { self.finish() }
    }

    func event(_ data: Data) {
        var r = Reader(data)
        _ = r.u32(); _ = r.u16()
        let code = r.u16() ?? 0
        _ = r.u32()
        var parameters: [String] = []
        while let value = r.u32() {
            parameters.append(String(format: "0x%08X", value))
        }
        DispatchQueue.main.async {
            if self.lastRequest != nil, self.firstEventAfterRequest == nil {
                self.firstEventAfterRequest = self.now()
            }
            self.log("event \(eventNames[code] ?? hex(code)) \(parameters.joined(separator: " "))")
        }
    }

    // MARK: ICCameraDeviceDelegate

    func cameraDevice(_: ICCameraDevice, didAdd items: [ICCameraItem]) {
        guard ready else { return }
        for case let file as ICCameraFile in items where !known.contains(file.name ?? "") {
            known.insert(file.name ?? "")
            let added = now()
            log("new file \(file.name ?? "?") (\(file.fileSize) bytes, \(file.uti ?? "?"))")
            guard options.watch else { continue }
            let requested = lastRequest, firstEvent = firstEventAfterRequest
            _ = file.requestDownload(
                options: [.downloadsDirectoryURL: options.directory, .overwrite: true],
            ) { name, error in
                DispatchQueue.main.async {
                    let done = self.now()
                    if let error {
                        self.log("download of \(file.name ?? "?") failed: \(error)")
                        return
                    }
                    let timing = Timing(
                        file: name ?? file.name ?? "?",
                        bytes: Int(file.fileSize),
                        requestedAt: requested,
                        firstEventAt: firstEvent,
                        itemAddedAt: added,
                        downloadedAt: done,
                    )
                    self.timings.append(timing)
                    let mbps = Double(file.fileSize) / 1_000_000 / max(done - added, 0.001)
                    self.log(String(
                        format: "downloaded %@: %.2f s after it appeared (%.0f MB/s)%@",
                        timing.file,
                        done - added,
                        mbps,
                        requested.map { String(format: "; %.2f s after requestTakePicture", done - $0) } ?? "",
                    ))
                }
            }
        }
    }

    func cameraDevice(_: ICCameraDevice, didRemove items: [ICCameraItem]) {
        log("removed \(items.count) items")
    }

    func cameraDevice(_: ICCameraDevice, didReceiveThumbnail _: CGImage?, for _: ICCameraItem, error _: Error?) {}
    func cameraDevice(
        _: ICCameraDevice,
        didReceiveMetadata _: [AnyHashable: Any]?,
        for _: ICCameraItem,
        error _: Error?,
    ) {}
    func cameraDevice(_: ICCameraDevice, didRenameItems _: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        log("capabilities changed: \(camera.capabilities.sorted().joined(separator: ", "))")
    }

    func cameraDevice(_: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        event(eventData)
    }

    func cameraDeviceDidRemoveAccessRestriction(_: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_: ICDevice) {}
    func didRemove(_ device: ICDevice) {
        log("camera disconnected: \(device.name ?? "?")")
    }

    func device(_: ICDevice, didCloseSessionWithError _: Error?) {}
    func device(_: ICDevice, didEncounterError error: Error?) {
        log("device error: \(error.map { "\($0)" } ?? "?")")
    }

    func finish() {
        report["timings"] = timings.map { timing -> [String: Any] in
            var entry: [String: Any] = [
                "file": timing.file,
                "bytes": timing.bytes,
                "itemAddedAt": timing.itemAddedAt,
                "downloadedAt": timing.downloadedAt,
            ]
            entry["requestedAt"] = timing.requestedAt
            entry["firstEventAt"] = timing.firstEventAt
            return entry
        }
        report["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
        if let url = options.json, let data = try? JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys],
        ) {
            try? data.write(to: url)
            log("wrote \(url.path)")
        }
        cameras.first?.requestCloseSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
}

let probe = Probe(options: Options(CommandLine.arguments))
probe.start()
RunLoop.main.run()
