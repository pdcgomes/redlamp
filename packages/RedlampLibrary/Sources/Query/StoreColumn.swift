import Darwin

/// One of the column store's columns (LIB-44): its values side by side in whole pages of memory of
/// their own, allocated or mapped from the store's snapshot, where pages read from the file belong
/// to the file cache, which takes them back under memory pressure and reads them again when they're
/// touched. A value, as `ContiguousArray` is: copies share the pages until one of them changes, and
/// the one that changes takes a copy of them from the system (`vm_remap`), which copies each page
/// only once it's written.
public struct StoreColumn<Element: FixedWidthInteger & Sendable>: Sendable {
    private var pages: ColumnPages
    public private(set) var count: Int

    init() {
        pages = .empty
        count = 0
    }

    init(repeating value: Element, count: Int) {
        self.init(pages: .allocate(count * Self.stride), count: count)
        if value != 0, let start {
            start.update(repeating: value, count: count)
        }
    }

    init(_ elements: some Sequence<Element>) {
        self.init()
        append(contentsOf: elements)
    }

    /// The column of `count` values at the start of `pages`, which it takes.
    init(pages: ColumnPages, count: Int) {
        pages.base?.bindMemory(to: Element.self, capacity: pages.size / Self.stride)
        self.pages = pages
        self.count = count
    }

    private static var stride: Int {
        MemoryLayout<Element>.stride
    }

    private var start: UnsafeMutablePointer<Element>? {
        pages.base?.assumingMemoryBound(to: Element.self)
    }

    /// Values it has room for before its pages grow.
    var capacity: Int {
        pages.size / Self.stride
    }

    /// Bytes its pages take, mapped or allocated.
    var bytes: Int {
        pages.size
    }

    /// Pages holding its values that are the process's own memory rather than the file's, in memory
    /// or paged out: written since they were mapped, or allocated (`mincore`).
    var ownPages: Int {
        guard let base = pages.base, count > 0 else { return 0 }
        let length = ColumnPages.rounded(count * Self.stride)
        var flags = [CChar](repeating: 0, count: length / ColumnPages.pageSize)
        guard mincore(base, length, &flags) == 0 else { return 0 }
        return flags.count { flag in
            let bits = Int32(UInt8(bitPattern: flag))
            return bits & MINCORE_ANONYMOUS != 0 && bits & (MINCORE_INCORE | MINCORE_PAGED_OUT) != 0
        }
    }

    // MARK: - Reading

    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(start: start, count: count))
    }

    public func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows
        -> R? {
        try withUnsafeBufferPointer(body)
    }

    // MARK: - Writing

    /// Makes the pages its own, with room for `needed` values.
    private mutating func makeUnique(room needed: Int) {
        guard !isKnownUniquelyReferenced(&pages) || needed > capacity else { return }
        let room = needed > capacity ? Swift.max(needed, capacity * 2, ColumnPages.pageSize / Self.stride) : capacity
        let copy = pages.copy(atLeast: room * Self.stride)
        copy.base?.bindMemory(to: Element.self, capacity: copy.size / Self.stride)
        pages = copy
    }

    public mutating func withUnsafeMutableBufferPointer<R>(
        _ body: (inout UnsafeMutableBufferPointer<Element>) throws -> R,
    ) rethrows -> R {
        makeUnique(room: count)
        var buffer = UnsafeMutableBufferPointer(start: start, count: count)
        return try body(&buffer)
    }

    public mutating func withContiguousMutableStorageIfAvailable<R>(
        _ body: (inout UnsafeMutableBufferPointer<Element>) throws -> R,
    ) rethrows -> R? {
        try withUnsafeMutableBufferPointer(body)
    }

    /// Writes `value` at `index` only if it isn't there already, so a page whose values don't change
    /// is never copied.
    mutating func write(_ value: Element, at index: Int) {
        if self[index] != value {
            self[index] = value
        }
    }

    mutating func append(_ value: Element) {
        makeUnique(room: count + 1)
        start.unsafelyUnwrapped[count] = value
        count += 1
    }

    mutating func append(contentsOf elements: some Sequence<Element>) {
        let copied: Void? = elements.withContiguousStorageIfAvailable { values in
            guard !values.isEmpty else { return }
            makeUnique(room: count + values.count)
            (start.unsafelyUnwrapped + count).update(from: values.baseAddress.unsafelyUnwrapped, count: values.count)
            count += values.count
        }
        guard copied == nil else { return }
        makeUnique(room: count + elements.underestimatedCount)
        for value in elements {
            append(value)
        }
    }

    mutating func reserveCapacity(_ room: Int) {
        if room > capacity {
            makeUnique(room: room)
        }
    }

    /// Makes its values `values`, writing only the pages where they differ.
    mutating func update(from values: UnsafeBufferPointer<Element>) {
        if values.count > capacity {
            makeUnique(room: values.count)
        }
        let perPage = ColumnPages.pageSize / Self.stride
        var unique = false
        var index = 0
        while index < values.count {
            let end = Swift.min(index + perPage, values.count)
            let source = values.baseAddress.unsafelyUnwrapped + index
            if memcmp(start.unsafelyUnwrapped + index, source, (end - index) * Self.stride) != 0 {
                if !unique {
                    makeUnique(room: values.count)
                    unique = true
                }
                (start.unsafelyUnwrapped + index).update(from: source, count: end - index)
            }
            index = end
        }
        count = values.count
    }
}

extension StoreColumn: RandomAccessCollection, MutableCollection {
    public typealias Index = Int
    public typealias Indices = Range<Int>

    public var startIndex: Int {
        0
    }

    public var endIndex: Int {
        count
    }

    public subscript(index: Int) -> Element {
        get {
            precondition(index >= 0 && index < count, "Index out of range")
            return start.unsafelyUnwrapped[index]
        }
        set {
            precondition(index >= 0 && index < count, "Index out of range")
            makeUnique(room: count)
            start.unsafelyUnwrapped[index] = newValue
        }
    }
}

/// A column's pages: a region of the process's memory that's the column's alone, unmapped with it.
final class ColumnPages: @unchecked Sendable {
    /// Page-aligned; nil for none.
    let base: UnsafeMutableRawPointer?
    /// Bytes, whole pages.
    let size: Int

    static let empty = ColumnPages(base: nil, size: 0)
    static let pageSize = Int(getpagesize())

    init(base: UnsafeMutableRawPointer?, size: Int) {
        self.base = base
        self.size = size
    }

    deinit {
        if let base, size > 0 {
            munmap(base, size)
        }
    }

    static func rounded(_ bytes: Int) -> Int {
        (bytes + pageSize - 1) / pageSize * pageSize
    }

    /// New pages of zeros, at least `bytes` of them.
    static func allocate(_ bytes: Int) -> ColumnPages {
        guard bytes > 0 else { return .empty }
        let size = rounded(bytes)
        guard let base = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), base != MAP_FAILED
        else { fatalError("the column store couldn't map \(size) bytes") }
        return ColumnPages(base: base, size: size)
    }

    /// A copy of these pages, at least `bytes` long, that shares them with these until either side
    /// writes one, when the system copies that page for it.
    func copy(atLeast bytes: Int) -> ColumnPages {
        guard let base, size > 0 else { return .allocate(bytes) }
        if bytes <= size {
            var address: vm_address_t = 0
            var current: vm_prot_t = 0
            var maximum: vm_prot_t = 0
            let remapped = vm_remap(
                mach_task_self_, &address, vm_size_t(size), 0, VM_FLAGS_ANYWHERE, mach_task_self_,
                vm_address_t(UInt(bitPattern: base)), 1, &current, &maximum, VM_INHERIT_DEFAULT,
            )
            if remapped == KERN_SUCCESS, let copy = UnsafeMutableRawPointer(bitPattern: UInt(address)) {
                return ColumnPages(base: copy, size: size)
            }
        }
        let grown = ColumnPages.allocate(max(bytes, size))
        let destination = grown.base.unsafelyUnwrapped
        let copied = vm_copy(
            mach_task_self_, vm_address_t(UInt(bitPattern: base)), vm_size_t(size),
            vm_address_t(UInt(bitPattern: destination)),
        )
        if copied != KERN_SUCCESS {
            destination.copyMemory(from: base, byteCount: size)
        }
        return grown
    }
}
