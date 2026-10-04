// The writer and checker for scripts/sidecar-kill-loop.py, which kills the writer at random
// moments and checks what each kill left on disk.
//
// writer <image> <mode>: saves the photo's sidecar forever, a new 64 KB mask bitmap and history
//   step each time, and appends each finished save's number to <image>.log (fsync'd). Mode
//   `update` saves over a package; `fresh` deletes the sidecar first, so each save builds a new
//   package; `convert` replaces it with a single-file sidecar first, which the save turns into a
//   package.
// check <image>: removes leftovers as a folder open does, then prints a verdict on what survived
//   against the log: `ok`, `ok-absent` (killed between a delete and the next save) or
//   `ok-history-ahead` (killed between the history file and the edit), or a problem.
import Foundation
import RedlampDocument
import RedlampEngineAPI

let fileManager = FileManager.default
let store = SidecarStore()
let arguments = CommandLine.arguments
let image = URL(fileURLWithPath: arguments[2])
let logURL = image.appendingPathExtension("log")

func mask(_ version: Int) -> MaskLayer {
    let png = Data(repeating: UInt8(version % 251), count: 64 * 1024) + Data("\(version)".utf8)
    return MaskLayer(name: "Subject", components: [MaskComponent(shape: .ai(AIMask(
        kind: .subject, provider: "test", revision: 1, analysisHash: "0", center: ImagePoint(x: 0.5, y: 0.5),
        bitmap: MaskBitmap(png: png, width: 4, height: 2),
    )))])
}

/// Version `version` of the edit: its exposure is the version in thousandths.
func sidecar(_ version: Int, session: UUID) -> Sidecar {
    var recipe = EditRecipe()
    recipe[.exposure] = Double(version) / 1000
    recipe.masks = [mask(version)]
    let steps = [
        HistoryStep(action: .open, title: "Import", recipe: EditRecipe()),
        HistoryStep(action: .adjustment(.exposure), title: "Exposure", before: "", after: "\(version)", recipe: recipe),
    ]
    var sidecar = Sidecar(
        recipe: recipe, metadata: PhotoMetadata(rating: version % 6), session: HistorySession(steps: steps),
    )
    sidecar.session?.id = session
    return sidecar
}

func version(_ recipe: EditRecipe) -> Int {
    Int((recipe[.exposure] * 1000).rounded())
}

/// One history session across writer restarts, as one editing session would be.
func sessionID() -> UUID {
    let file = image.appendingPathExtension("session")
    if let text = try? String(contentsOf: file, encoding: .utf8), let id = UUID(uuidString: text) {
        return id
    }
    let id = UUID()
    try! id.uuidString.write(to: file, atomically: true, encoding: .utf8)
    return id
}

/// A single-file sidecar's bytes, in the store's own encoding: saved as a package elsewhere,
/// then its edit.json taken.
func singleFileData(_ sidecar: Sidecar) -> Data {
    let scratch = fileManager.temporaryDirectory.appending(path: "single-\(UUID().uuidString).ARW")
    defer { try? fileManager.removeItem(at: store.url(for: scratch)) }
    try! store.save(sidecar, for: scratch)
    return try! Data(contentsOf: store.editURL(for: scratch))
}

func log(_ descriptor: Int32, _ line: String) {
    _ = (line + "\n").withCString { write(descriptor, $0, strlen($0)) }
    fsync(descriptor)
}

switch arguments[1] {
case "writer":
    let mode = arguments[3]
    let descriptor = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    let session = sessionID()
    var next = (try? String(contentsOf: logURL, encoding: .utf8))?
        .split(separator: "\n").compactMap { Int($0.split(separator: " ")[0]) }.max() ?? 0
    while true {
        next += 1
        if mode == "fresh" {
            log(descriptor, "\(next) deleting")
            store.delete(for: image)
            log(descriptor, "\(next) deleted")
            next += 1
        } else if mode == "convert" {
            log(descriptor, "\(next) deleting")
            store.delete(for: image)
            var single = sidecar(next, session: session)
            single.recipe.masks = []
            single.session = nil
            try! singleFileData(single).write(to: store.url(for: image), options: .atomic)
            log(descriptor, "\(next) single")
            next += 1
        }
        try! store.save(sidecar(next, session: session), for: image)
        log(descriptor, "\(next)")
    }
case "check":
    let lines = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n")
    let last = lines.last.map { Int($0.split(separator: " ")[0])! } ?? 0
    let lastKind = lines.last.map { $0.split(separator: " ").dropFirst().first.map(String.init) ?? "saved" } ?? "none"
    let folder = image.deletingLastPathComponent()
    SidecarStore.removeLeftovers(in: folder, olderThan: 0)
    let leftovers = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix(".") }
    var isDirectory: ObjCBool = false
    let present = fileManager.fileExists(atPath: store.url(for: image).path, isDirectory: &isDirectory)
    let verdict: String
    if !present {
        verdict = lastKind == "deleted" || lastKind == "deleting" || last == 0 ? "ok-absent" : "MISSING"
    } else if let loaded = store.load(for: image) {
        let saved = version(loaded.recipe)
        let bitmapsPresent = loaded.recipe.masks.allSatisfy { layer in
            layer.components.allSatisfy { component in
                guard case let .ai(mask) = component.shape else { return true }
                return mask.bitmap.png != nil
            }
        }
        let session = sessionID()
        let history = store.loadHistory(for: image).first { $0.id == session }?.steps.last.map { version($0.recipe) }
        let versionMatches = saved == last || saved == last + 1 || (lastKind == "deleting" && saved == last - 1)
        verdict = if !versionMatches {
            "WRONG-VERSION"
        } else if !bitmapsPresent {
            "MISSING-BITMAP"
        } else if !isDirectory.boolValue || loaded.recipe.masks.isEmpty || history == saved {
            "ok"
        } else if let history, history == saved + 1 {
            "ok-history-ahead"
        } else if let history, history < saved {
            "HISTORY-BEHIND"
        } else {
            "HISTORY-MISMATCH"
        }
    } else {
        verdict = lastKind == "deleting" ? "PARTIAL-DELETE" : "UNDECODABLE"
    }
    print(verdict, "leftovers=\(leftovers.count)")
default:
    fatalError("usage: sidecar-kill-save writer <image> <update|fresh|convert> | check <image>")
}
