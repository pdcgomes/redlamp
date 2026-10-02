#if DEBUG || REDLAMP_PROFILING
    import Darwin
    import Foundation
    import Synchronization

    /// The process's memory, broken down with in-process APIs only: `vmmap`, `footprint`, `heap`
    /// and `leaks` may not be allowed to run where Redlamp is measured.
    ///
    /// - Ledgers (`task_info(TASK_VM_INFO)`): the kernel's own accounts. `phys_footprint` is what
    ///   macOS charges the app for (Activity Monitor's Memory; what memory pressure and jetsam act
    ///   on). GPU memory Redlamp owns (Metal heaps, buffers, textures, IOSurfaces) is charged
    ///   through the graphics ledger, whether or not it is mapped into the process.
    /// - Regions (`mach_vm_region_recurse`): every region's dirty and compressed pages, grouped by
    ///   the tag its allocator gave it. Anonymous memory counts when dirty or compressed (pages
    ///   malloc marked reusable aren't dirty); a mapped file only for pages written to it privately.
    ///   Memory shared between regions counts once.
    /// - malloc (`malloc_zone_statistics`): bytes in live blocks. Its regions' pages beyond those
    ///   are memory malloc keeps for reuse, which on macOS 26 includes freed blocks of every size:
    ///   they stay in the footprint until reused (see the Memory budgets in
    ///   docs/plans/2026-10-02-folders-design.md).
    ///
    /// What can't be attributed in-process: which code owns a malloc block (that needs
    /// MallocStackLogging and `heap`), GPU memory that isn't mapped into the process (only its
    /// total, in the graphics ledger), and the kernel's page tables and IOKit memory (left in
    /// "not in a region").
    struct MemorySnapshot: Sendable {
        struct Ledgers: Sendable {
            var footprint: UInt64 = 0
            /// The highest footprint since launch, kept by the kernel.
            var lifetimePeak: UInt64 = 0
            /// Resident anonymous memory (the kernel's "internal" pages).
            var anonymous: UInt64 = 0
            var compressed: UInt64 = 0
            var reusable: UInt64 = 0
            var purgeableNonvolatile: UInt64 = 0
            /// Purgeable memory the system may take back at any time, which doesn't count.
            var purgeableVolatile: UInt64 = 0
            var graphics: UInt64 = 0
            var media: UInt64 = 0
            var neural: UInt64 = 0
            var virtualSize: UInt64 = 0
            var regionCount = 0
        }

        struct Pages: Sendable {
            var dirty: UInt64 = 0
            var compressed: UInt64 = 0
            var reusable: UInt64 = 0
            var resident: UInt64 = 0

            /// What these pages add to the footprint. Pages malloc marked reusable are no longer
            /// dirty, so they're already left out.
            var footprint: UInt64 {
                dirty + compressed
            }

            static func += (lhs: inout Pages, rhs: Pages) {
                lhs.dirty += rhs.dirty
                lhs.compressed += rhs.compressed
                lhs.reusable += rhs.reusable
                lhs.resident += rhs.resident
            }
        }

        struct Zone: Sendable {
            var name: String
            var inUse: UInt64
            var allocated: UInt64
            var blocks: Int
        }

        /// One of Redlamp's own measures, read on the main thread.
        struct Counter: Sendable {
            var label: String
            var value: Double
            var isBytes: Bool

            static func bytes(_ label: String, _ value: Int) -> Counter {
                Counter(label: label, value: Double(value), isBytes: true)
            }

            static func count(_ label: String, _ value: Int) -> Counter {
                Counter(label: label, value: Double(value), isBytes: false)
            }
        }

        var ledgers: Ledgers
        var categories: [MemoryCategory: Pages] = [:]
        /// Anonymous regions by tag, for the details.
        var tags: [UInt32: Pages] = [:]
        var zones: [Zone] = []
        var counters: [Counter] = []
        /// How long the region walk took.
        var walkSeconds: Double = 0
        var isDetailed = false

        var footprint: UInt64 {
            ledgers.footprint
        }

        var regionsFootprint: UInt64 {
            categories.values.reduce(0) { $0 + $1.footprint }
        }

        var mallocFootprint: UInt64 {
            MemoryCategory.malloc.reduce(0) { $0 + (categories[$1]?.footprint ?? 0) }
        }

        var mallocInUse: UInt64 {
            zones.reduce(0) { $0 + $1.inUse }
        }

        /// The ledgers and counters only: cheap enough to take at any time.
        static func light(counters: [Counter] = []) -> MemorySnapshot {
            MemorySnapshot(ledgers: readLedgers(), counters: counters)
        }

        /// Everything: walks every VM region (tens of milliseconds), so take it off the main thread.
        static func detailed(counters: [Counter] = []) -> MemorySnapshot {
            let started = ContinuousClock.now
            var snapshot = MemorySnapshot(ledgers: readLedgers(), counters: counters)
            (snapshot.categories, snapshot.tags) = walkRegions()
            snapshot.zones = mallocZones()
            let elapsed = ContinuousClock.now - started
            snapshot.walkSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            snapshot.isDetailed = true
            return snapshot
        }

        static func footprint() -> UInt64 {
            vmInfo()?.phys_footprint ?? 0
        }

        private static func vmInfo() -> task_vm_info_data_t? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info : nil
        }

        private static func readLedgers() -> Ledgers {
            guard let info = vmInfo() else { return Ledgers() }
            func bytes(_ values: Int64...) -> UInt64 {
                UInt64(max(values.reduce(0, +), 0))
            }
            return Ledgers(
                footprint: info.phys_footprint,
                lifetimePeak: bytes(info.ledger_phys_footprint_peak),
                anonymous: info.internal,
                compressed: info.compressed,
                reusable: info.reusable,
                purgeableNonvolatile: bytes(
                    info.ledger_purgeable_nonvolatile, info.ledger_purgeable_novolatile_compressed,
                ),
                purgeableVolatile: bytes(info.ledger_purgeable_volatile, info.ledger_purgeable_volatile_compressed),
                graphics: bytes(info.ledger_tag_graphics_footprint, info.ledger_tag_graphics_footprint_compressed),
                media: bytes(info.ledger_tag_media_footprint, info.ledger_tag_media_footprint_compressed),
                neural: bytes(info.ledger_tag_neural_footprint, info.ledger_tag_neural_footprint_compressed),
                virtualSize: info.virtual_size,
                regionCount: Int(info.region_count),
            )
        }

        private static func walkRegions() -> ([MemoryCategory: Pages], [UInt32: Pages]) {
            let page = UInt64(getpagesize())
            var categories: [MemoryCategory: Pages] = [:]
            var tags: [UInt32: Pages] = [:]
            var seen = Set<UInt64>()
            var address: mach_vm_address_t = 0
            var depth: natural_t = 0
            while true {
                var size: mach_vm_size_t = 0
                var info = vm_region_submap_info_data_64_t()
                var count = mach_msg_type_number_t(
                    MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size,
                )
                let result = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                        mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, $0, &count)
                    }
                }
                guard result == KERN_SUCCESS else { break }
                if info.is_submap != 0 {
                    depth += 1
                    continue
                }
                defer { address += size }
                let mode = Int32(info.share_mode)
                guard mode != SM_EMPTY else { continue }
                let shared = mode == SM_SHARED || mode == SM_TRUESHARED || mode == SM_SHARED_ALIASED
                if shared, info.object_id_full != 0, !seen.insert(info.object_id_full).inserted {
                    continue
                }
                let pages = Pages(
                    dirty: UInt64(info.pages_dirtied) * page,
                    compressed: UInt64(info.pages_swapped_out) * page,
                    reusable: UInt64(info.pages_reusable) * page,
                    resident: UInt64(info.pages_resident) * page,
                )
                let category: MemoryCategory
                if depth > 0 {
                    category = .sharedCache
                } else if info.external_pager != 0 {
                    category = .mappedFiles
                } else {
                    category = MemoryCategory(tag: info.user_tag, shared: shared)
                    tags[info.user_tag, default: Pages()] += pages
                }
                categories[category, default: Pages()] += pages
            }
            return (categories, tags)
        }

        private static func mallocZones() -> [Zone] {
            var addresses: UnsafeMutablePointer<vm_address_t>?
            var count: UInt32 = 0
            guard malloc_get_all_zones(mach_task_self_, nil, &addresses, &count) == KERN_SUCCESS, let addresses
            else { return [] }
            return (0 ..< Int(count)).compactMap { index in
                guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(addresses[index])) else {
                    return nil
                }
                var statistics = malloc_statistics_t()
                malloc_zone_statistics(zone, &statistics)
                return Zone(
                    name: malloc_get_zone_name(zone).map { String(cString: $0) } ?? "zone \(index)",
                    inUse: UInt64(statistics.size_in_use),
                    allocated: UInt64(statistics.size_allocated),
                    blocks: Int(statistics.blocks_in_use),
                )
            }
        }

        /// Frees 16 blocks of 1 MB and reports how much of them the footprint still holds: macOS 26's
        /// allocator keeps freed blocks for reuse rather than returning them.
        static func mallocKeepsFreedBlocks() -> Double {
            let size = 1 << 20
            let before = footprint()
            let blocks = (0 ..< 16).compactMap { _ in malloc(size) }
            for block in blocks {
                memset(block, 1, size)
            }
            let allocated = footprint()
            blocks.forEach { free($0) }
            let freed = footprint()
            guard allocated > before else { return 0 }
            return Double(Int64(freed) - Int64(before)) / Double(allocated - before)
        }
    }

    /// Where a region's pages are counted, by the tag its allocator gave it.
    enum MemoryCategory: String, CaseIterable, Sendable {
        case mallocTiny = "malloc tiny and nano"
        case mallocSmall = "malloc small"
        case mallocMedium = "malloc medium"
        case mallocLarge = "malloc large and huge"
        case mallocOther = "malloc, other"
        case imageIO = "ImageIO"
        case coreGraphics = "CoreGraphics and CGImage"
        case coreAnimation = "Core Animation"
        case coreImage = "Core Image"
        case gpu = "IOKit, IOSurface, IOAccelerator"
        case stacks = "Thread stacks"
        case runtime = "dyld, Swift, Objective-C"
        case otherTags = "Other tagged VM"
        case untagged = "Untagged anonymous VM"
        case shared = "Shared anonymous memory"
        case mappedFiles = "Mapped files, written pages"
        case sharedCache = "Shared cache, written pages"

        static let malloc: [MemoryCategory] = [.mallocTiny, .mallocSmall, .mallocMedium, .mallocLarge, .mallocOther]

        private static let byTag: [Int32: MemoryCategory] = {
            let groups: [MemoryCategory: [Int32]] = [
                .mallocTiny: [VM_MEMORY_MALLOC_TINY, VM_MEMORY_MALLOC_NANO],
                .mallocSmall: [VM_MEMORY_MALLOC_SMALL],
                .mallocMedium: [VM_MEMORY_MALLOC_MEDIUM],
                .mallocLarge: [
                    VM_MEMORY_MALLOC_LARGE, VM_MEMORY_MALLOC_LARGE_REUSABLE, VM_MEMORY_MALLOC_LARGE_REUSED,
                    VM_MEMORY_MALLOC_HUGE,
                ],
                .mallocOther: [VM_MEMORY_MALLOC, VM_MEMORY_REALLOC, VM_MEMORY_MALLOC_PROB_GUARD],
                .imageIO: [VM_MEMORY_IMAGEIO],
                .coreGraphics: [
                    VM_MEMORY_CGIMAGE, VM_MEMORY_COREGRAPHICS, VM_MEMORY_COREGRAPHICS_DATA,
                    VM_MEMORY_COREGRAPHICS_SHARED, VM_MEMORY_COREGRAPHICS_FRAMEBUFFERS,
                    VM_MEMORY_COREGRAPHICS_BACKINGSTORES, VM_MEMORY_COREGRAPHICS_XALLOC,
                ],
                .coreAnimation: [VM_MEMORY_LAYERKIT],
                .coreImage: [VM_MEMORY_COREIMAGE],
                .gpu: [VM_MEMORY_IOKIT, VM_MEMORY_IOSURFACE, VM_MEMORY_IOACCELERATOR],
                .stacks: [VM_MEMORY_STACK, VM_MEMORY_GUARD],
                .runtime: [
                    VM_MEMORY_DYLD, VM_MEMORY_DYLD_MALLOC, VM_MEMORY_SWIFT_RUNTIME, VM_MEMORY_SWIFT_METADATA,
                    VM_MEMORY_OBJC_DISPATCHERS,
                ],
            ]
            return Dictionary(groups.flatMap { category, tags in tags.map { ($0, category) } }) { first, _ in first }
        }()

        init(tag: UInt32, shared: Bool) {
            if tag == 0 {
                self = shared ? .shared : .untagged
            } else {
                self = Self.byTag[Int32(tag)] ?? .otherTags
            }
        }

        /// A tag's name, as `vmmap` shows it.
        static func name(ofTag tag: UInt32) -> String {
            let names: [Int32: String] = [
                VM_MEMORY_MALLOC: "MALLOC", VM_MEMORY_MALLOC_SMALL: "MALLOC_SMALL",
                VM_MEMORY_MALLOC_LARGE: "MALLOC_LARGE", VM_MEMORY_MALLOC_HUGE: "MALLOC_HUGE",
                VM_MEMORY_MALLOC_TINY: "MALLOC_TINY", VM_MEMORY_MALLOC_LARGE_REUSABLE: "MALLOC_LARGE_REUSABLE",
                VM_MEMORY_MALLOC_LARGE_REUSED: "MALLOC_LARGE_REUSED", VM_MEMORY_MALLOC_NANO: "MALLOC_NANO",
                VM_MEMORY_MALLOC_MEDIUM: "MALLOC_MEDIUM", VM_MEMORY_MALLOC_PROB_GUARD: "MALLOC_PROB_GUARD",
                VM_MEMORY_MACH_MSG: "Mach message", VM_MEMORY_IOKIT: "IOKit", VM_MEMORY_VM_RECLAIM: "VM reclaim",
                VM_MEMORY_STACK: "Stack", VM_MEMORY_GUARD: "Guard", VM_MEMORY_SHARED_PMAP: "Shared pmap",
                VM_MEMORY_DYLIB: "Dylib", VM_MEMORY_OBJC_DISPATCHERS: "ObjC dispatchers",
                VM_MEMORY_UNSHARED_PMAP: "Unshared pmap", VM_MEMORY_APPKIT: "AppKit",
                VM_MEMORY_FOUNDATION: "Foundation",
                VM_MEMORY_COREGRAPHICS: "CoreGraphics", VM_MEMORY_CORESERVICES: "CoreServices",
                VM_MEMORY_LAYERKIT: "CoreAnimation", VM_MEMORY_CGIMAGE: "CG image",
                VM_MEMORY_COREGRAPHICS_DATA: "CG raster data", VM_MEMORY_COREGRAPHICS_SHARED: "CG shared",
                VM_MEMORY_COREGRAPHICS_BACKINGSTORES: "CG backing stores", VM_MEMORY_DYLD: "dyld",
                VM_MEMORY_DYLD_MALLOC: "dyld private memory", VM_MEMORY_SQLITE: "SQLite",
                VM_MEMORY_COREIMAGE: "CoreImage", VM_MEMORY_IMAGEIO: "ImageIO",
                VM_MEMORY_OS_ALLOC_ONCE: "OS alloc once",
                VM_MEMORY_LIBDISPATCH: "Dispatch continuations", VM_MEMORY_ACCELERATE: "Accelerate",
                VM_MEMORY_COREUI: "CoreUI", VM_MEMORY_COREUIFILE: "CoreUI file",
                VM_MEMORY_GENEALOGY: "Activity tracing",
                VM_MEMORY_RAWCAMERA: "RawCamera", VM_MEMORY_SWIFT_RUNTIME: "Swift runtime",
                VM_MEMORY_SWIFT_METADATA: "Swift metadata", VM_MEMORY_SKYWALK: "Skywalk",
                VM_MEMORY_IOSURFACE: "IOSurface",
                VM_MEMORY_IOACCELERATOR: "IOAccelerator", VM_MEMORY_COREUI_CACHED_IMAGE_DATA: "CoreUI image data",
                VM_MEMORY_COLORSYNC: "ColorSync",
            ]
            return names[Int32(tag)] ?? "tag \(tag)"
        }
    }

    func mb(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_048_576
    }
#endif
