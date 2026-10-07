// When does People fall back on Vision's person segmentation, and is anyone there? (MSK-29)
//
// People makes one mask per person from Vision's person instances; when those find nobody (or
// four or more), it falls back on the person segmentation, which covers whatever stands out: on
// the evaluation set it masks ducks and a kingfisher as people. For every photo of the set, this
// prints the person instances found, and the human bodies and faces Vision detects, so a gate on
// the fallback can be judged on the photos it would change.
//
//     swift research/prototypes/masking/people_fallback.swift > build/logs/people-fallback.tsv

import Foundation
import ImageIO
import Vision

/// Run from the checkout's root.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let manifest = try JSONSerialization.jsonObject(
    with: Data(contentsOf: root.appending(path: "research/mask-eval/manifest.json")),
) as! [String: Any]
var photos: [(URL, String)] = (manifest["images"] as! [[String: Any]]).map {
    (root.appending(path: "build/mask-eval").appending(path: $0["file"] as! String), $0["cell"] as! String)
}

photos += (manifest["lookDev"] as? [[String: Any]] ?? []).map {
    (root.appending(path: "build/look-dev").appending(path: $0["file"] as! String), "look-dev")
}

print(["photo", "cell", "instances", "humans", "faces"].joined(separator: "\t"))
for (url, cell) in photos {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
              kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
    else { continue }
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let instances = VNGeneratePersonInstanceMaskRequest()
    let humans = VNDetectHumanRectanglesRequest()
    humans.upperBodyOnly = false
    let faces = VNDetectFaceRectanglesRequest()
    try? handler.perform([instances, humans, faces])
    let found = instances.results?.first?.allInstances.count ?? 0
    print([
        url.deletingPathExtension().lastPathComponent,
        cell,
        "\(found)",
        "\(humans.results?.count ?? 0)",
        "\(faces.results?.count ?? 0)",
    ].joined(separator: "\t"))
}
