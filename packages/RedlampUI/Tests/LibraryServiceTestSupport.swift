import Foundation
import RedlampLibrary
@_spi(Harness) @testable import RedlampUI

extension LibraryService {
    /// `close`, then the index closed as well, waiting up to 30 s for it: what a test does before it removes the
    /// library's folder, as SQLite needs the index's files until it has closed them.
    func closeWithIndex() {
        close()
        guard let index = core?.index else { return }
        let closed = DispatchSemaphore(value: 0)
        Task.detached {
            await index.close()
            closed.signal()
        }
        _ = closed.wait(timeout: .now() + 30)
    }
}
