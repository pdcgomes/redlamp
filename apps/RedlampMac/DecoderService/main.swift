import Foundation
import RedlampServices

/// Redlamp's decode service: raw and bitmap decoding in a sandboxed process with no file system
/// access, sent each file's bytes by the app (see `DecodeServiceClient`).
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: DecodeServiceProtocol.self)
        connection.exportedObject = DecodeService()
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
