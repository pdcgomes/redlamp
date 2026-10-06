import Foundation
import Synchronization

extension LibraryIndexer {
    /// The folders a run has yet to list: those asked for first (and the folders above them, which
    /// lead there), then the newest by modification date. It's finished once none wait and none are
    /// being listed, since only a listing finds more.
    final class WalkQueue: Sendable {
        struct Item: Sendable {
            let path: String
            let parent: String?
            let root: Int64
            /// Its subfolders are listed too, not only those the index doesn't have.
            let recursive: Bool
            let modified: Date
            /// It leads to a folder asked for that the walk hadn't reached when it was added: the photo
            /// queue holds the other folders' photos until it's listed.
            var ahead = false
        }

        private struct State {
            var waiting = Heap<Item> { $0.modified > $1.modified }
            var listing = 0
            var closed = false
            var waiters: [CheckedContinuation<Item?, Never>] = []
        }

        private let prioritised: @Sendable () -> Set<String>
        private let state = Mutex(State())

        init(prioritised: @escaping @Sendable () -> Set<String>) {
            self.prioritised = prioritised
        }

        func add(_ items: [Item]) {
            let handed = state.withLock { state -> [(CheckedContinuation<Item?, Never>, Item)] in
                guard !state.closed else { return [] }
                for item in items {
                    state.waiting.insert(item)
                }
                var handed: [(CheckedContinuation<Item?, Never>, Item)] = []
                while !state.waiters.isEmpty, let item = take(&state) {
                    handed.append((state.waiters.removeFirst(), item))
                }
                return handed
            }
            for (waiter, item) in handed {
                waiter.resume(returning: item)
            }
        }

        /// The next folder to list, waiting while others are being listed; nil once the walk is done.
        func next() async -> Item? {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> Item?? in
                    if let item = take(&state) {
                        return .some(item)
                    }
                    if state.closed || state.listing == 0 {
                        state.closed = true
                        return .some(nil)
                    }
                    state.waiters.append(continuation)
                    return nil
                }
                if let ready {
                    finishIfDone()
                    continuation.resume(returning: ready)
                }
            }
        }

        /// The folder handed out by `next` is listed, and what it found added.
        func done() {
            state.withLock { $0.listing -= 1 }
            finishIfDone()
        }

        /// Stops the walk: what waits is dropped.
        func close() {
            let waiters = state.withLock { state -> [CheckedContinuation<Item?, Never>] in
                state.closed = true
                state.waiting = Heap { $0.modified > $1.modified }
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }

        private func finishIfDone() {
            let waiters = state.withLock { state -> [CheckedContinuation<Item?, Never>] in
                guard state.listing == 0, state.waiting.isEmpty else { return [] }
                state.closed = true
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }

        private func take(_ state: inout State) -> Item? {
            guard !state.closed || !state.waiting.isEmpty else { return nil }
            let wanted = state.waiting.isEmpty ? [] : prioritised()
            let item = wanted.isEmpty ? state.waiting.popFirst()
                : state.waiting.remove { item in wanted.contains { $0 == item.path || $0.hasPrefix(item.path + "/") } }
                ?? state.waiting.popFirst()
            if item != nil {
                state.listing += 1
            }
            return item
        }
    }

    /// The photos a run has yet to read, folder by folder: the folders asked for first, then the
    /// newest, each folder's photos in Finder's order. While a listing on the way to a folder asked
    /// for is waiting or under way, only the folders asked for are read: the others' photos would
    /// otherwise be read, and their folders finished, before the folders asked for were even listed.
    final class PhotoQueue: Sendable {
        private struct Folder {
            let path: String
            let modified: Date
            var jobs: [PhotoJob]
            var next = 0
        }

        private struct State {
            var folders: [String: Folder] = [:]
            var order = Heap<(path: String, modified: Date)> { $0.modified > $1.modified }
            var adding = true
            /// Listings on the way to folders asked for, not yet done.
            var holds = 0
            var waiters: [CheckedContinuation<PhotoJob?, Never>] = []
        }

        private typealias Handed = [(CheckedContinuation<PhotoJob?, Never>, PhotoJob)]

        private let prioritised: @Sendable () -> Set<String>
        private let state = Mutex(State())

        init(prioritised: @escaping @Sendable () -> Set<String>) {
            self.prioritised = prioritised
        }

        func add(_ jobs: [PhotoJob], folder path: String, modified: Date) {
            guard !jobs.isEmpty else { return }
            let handed = state.withLock { state -> Handed in
                guard state.adding else { return [] }
                if state.folders[path] == nil {
                    state.folders[path] = Folder(path: path, modified: modified, jobs: jobs)
                    state.order.insert((path, modified))
                } else {
                    state.folders[path]?.jobs += jobs
                }
                return hand(&state)
            }
            resume(handed)
        }

        /// Holds the photos of the folders not asked for back until `release` is called as often: a
        /// listing on the way to a folder asked for is waiting or under way.
        func hold() {
            state.withLock { $0.holds += 1 }
        }

        func release() {
            let handed = state.withLock { state -> Handed in
                state.holds = max(state.holds - 1, 0)
                return state.holds == 0 ? hand(&state) : []
            }
            resume(handed)
        }

        /// What's waiting, handed to the readers waiting for it.
        private func hand(_ state: inout State) -> Handed {
            var handed: Handed = []
            while !state.waiters.isEmpty, let job = take(&state) {
                handed.append((state.waiters.removeFirst(), job))
            }
            return handed
        }

        private func resume(_ handed: Handed) {
            for (waiter, job) in handed {
                waiter.resume(returning: job)
            }
        }

        /// The next photo to read, waiting while more may come; nil once the queue is finished and empty.
        func next() async -> PhotoJob? {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> PhotoJob?? in
                    if let job = take(&state) {
                        return .some(job)
                    }
                    if !state.adding {
                        return .some(nil)
                    }
                    state.waiters.append(continuation)
                    return nil
                }
                if let ready {
                    continuation.resume(returning: ready)
                }
            }
        }

        /// No more jobs will be added: the workers stop once the queue is empty.
        func finish() {
            let (handed, waiters) = state.withLock { state -> (Handed, [CheckedContinuation<PhotoJob?, Never>]) in
                state.adding = false
                state.holds = 0
                let handed = hand(&state)
                defer { state.waiters = [] }
                return (handed, state.waiters)
            }
            resume(handed)
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
        }

        /// Stops at once: the jobs waiting are dropped and returned.
        func close() -> [PhotoJob] {
            let (dropped, waiters) = state.withLock { state -> ([PhotoJob], [CheckedContinuation<PhotoJob?, Never>]) in
                state.adding = false
                let dropped = state.folders.values.flatMap { $0.jobs[$0.next...] }
                state.folders = [:]
                state.order = Heap { $0.modified > $1.modified }
                defer { state.waiters = [] }
                return (dropped, state.waiters)
            }
            for waiter in waiters {
                waiter.resume(returning: nil)
            }
            return dropped
        }

        private func take(_ state: inout State) -> PhotoJob? {
            if !state.folders.isEmpty {
                for path in prioritised() {
                    if let job = takeJob(from: path, &state) {
                        return job
                    }
                }
            }
            guard state.holds == 0 else { return nil }
            while let top = state.order.first {
                if let job = takeJob(from: top.path, &state) {
                    return job
                }
                _ = state.order.popFirst()
            }
            return nil
        }

        private func takeJob(from path: String, _ state: inout State) -> PhotoJob? {
            guard var folder = state.folders[path] else { return nil }
            guard folder.next < folder.jobs.count else {
                state.folders.removeValue(forKey: path)
                return nil
            }
            let job = folder.jobs[folder.next]
            folder.next += 1
            state.folders[path] = folder.next < folder.jobs.count ? folder : nil
            return job
        }
    }
}

/// A binary heap: `first` is the element `precedes` puts before every other.
struct Heap<Element> {
    private var elements: [Element] = []
    private let precedes: (Element, Element) -> Bool

    init(_ precedes: @escaping (Element, Element) -> Bool) {
        self.precedes = precedes
    }

    var isEmpty: Bool {
        elements.isEmpty
    }

    var count: Int {
        elements.count
    }

    var first: Element? {
        elements.first
    }

    mutating func insert(_ element: Element) {
        elements.append(element)
        siftUp(elements.count - 1)
    }

    mutating func popFirst() -> Element? {
        guard !elements.isEmpty else { return nil }
        elements.swapAt(0, elements.count - 1)
        let first = elements.removeLast()
        siftDown(0)
        return first
    }

    /// Takes out the first element, in heap order, that `matches` accepts.
    mutating func remove(where matches: (Element) -> Bool) -> Element? {
        guard let index = elements.indices.filter({ matches(elements[$0]) })
            .min(by: { precedes(elements[$0], elements[$1]) })
        else { return nil }
        elements.swapAt(index, elements.count - 1)
        let removed = elements.removeLast()
        if index < elements.count {
            siftDown(index)
            siftUp(index)
        }
        return removed
    }

    private mutating func siftUp(_ start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(elements[child], elements[parent]) else { return }
            elements.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var first = parent
            if left < elements.count, precedes(elements[left], elements[first]) {
                first = left
            }
            if right < elements.count, precedes(elements[right], elements[first]) {
                first = right
            }
            guard first != parent else { return }
            elements.swapAt(parent, first)
            parent = first
        }
    }
}
