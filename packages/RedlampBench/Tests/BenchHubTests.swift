import Foundation
import RedlampBench
import Testing

/// The hub and the phone's library talking over the loopback interface, as they do across the
/// local network.
@Suite(.serialized)
struct BenchHubTests {
    /// A started hub on any free port, with a client pointed at it.
    private func hub(
        _ scratch: Scratch,
        asked: AsyncStream<BenchHub.PairingRequest>.Continuation? = nil,
    ) async throws -> (BenchHub, BenchClient, BenchStore) {
        let store = BenchStore(root: scratch.file("store"))
        let ready = AsyncStream<UInt16>.makeStream()
        let hub = BenchHub(store: store, name: "Test Lab") { event in
            switch event {
            case let .state(.ready(port)): ready.continuation.yield(port)
            case let .pairingRequested(request): asked?.yield(request)
            default: break
            }
        }
        try await hub.start(port: nil, advertise: false)
        var port: UInt16 = 0
        for await value in ready.stream {
            port = value
            break
        }
        let client = try BenchClient(base: #require(URL(string: "http://127.0.0.1:\(port)/")))
        return (hub, client, store)
    }

    @Test func `Only a paired phone sees the outbox, and a wrong code pairs nothing`() async throws {
        let scratch = Scratch()
        let (hub, client, store) = try await hub(scratch)
        defer { Task { await hub.stop() } }
        try makeTask(in: scratch, store: store)

        let info = try await client.info()
        #expect(info.name == "Test Lab")
        #expect(!info.paired)
        await #expect(throws: BenchClientError.self) { try await client.listings() }
        await #expect(throws: BenchClientError.self) { try await client.pair(code: "000000x", device: "Phone") }

        let reply = try await client.pair(code: hub.code, device: "Pedro's iPhone")
        var paired = client
        paired.token = reply.token
        #expect(try await paired.info().paired)
        let listings = try await paired.listings()
        #expect(listings.map(\.id) == ["2026-10-08-sky-masks"])
        #expect(listings[0].files.first?.path == BenchManifest.fileName)
        #expect(listings[0].files.count == 4)
        #expect(await hub.devices.map(\.name) == ["Pedro's iPhone"])
    }

    @Test func `A phone allowed in the Lab pairs without a code`() async throws {
        let scratch = Scratch()
        let asked = AsyncStream<BenchHub.PairingRequest>.makeStream()
        let (hub, client, _) = try await hub(scratch, asked: asked.continuation)
        defer { Task { await hub.stop() } }

        let pairing = Task { try await client.pairByApproval(device: "Pedro's iPhone") }
        var request: BenchHub.PairingRequest?
        for await value in asked.stream {
            request = value
            break
        }
        #expect(request?.device == "Pedro's iPhone")
        #expect(await hub.requests.count == 1)
        #expect(await hub.devices.isEmpty)
        try await hub.approve(#require(request).id)

        let reply = try await pairing.value
        #expect(reply.hub == "Test Lab")
        var paired = client
        paired.token = reply.token
        #expect(try await paired.info().paired)
        #expect(await hub.devices.map(\.name) == ["Pedro's iPhone"])
        #expect(await hub.requests.isEmpty)
    }

    @Test func `A phone the Lab doesn't allow gets no token, and an unknown request has expired`() async throws {
        let scratch = Scratch()
        let asked = AsyncStream<BenchHub.PairingRequest>.makeStream()
        let (hub, client, _) = try await hub(scratch, asked: asked.continuation)
        defer { Task { await hub.stop() } }

        let pairing = Task { try await client.pairByApproval(device: "Someone's iPhone") }
        for await request in asked.stream {
            await hub.deny(request.id)
            break
        }
        await #expect(throws: BenchClientError.http(403, "the Lab didn't allow this phone")) {
            try await pairing.value
        }
        #expect(await hub.devices.isEmpty)
        let status = try await client.pairingStatus("no-such-request")
        #expect(status.state == .expired)
        #expect(status.token == nil)
    }

    @Test func `A task goes to the phone, pairs its results and comes back to Done once complete`() async throws {
        let scratch = Scratch()
        let (hub, client, store) = try await hub(scratch)
        defer { Task { await hub.stop() } }
        let task = try makeTask(in: scratch, store: store)
        var phone = client
        phone.token = try await client.pair(code: hub.code, device: "Phone").token
        let library = BenchLibrary(root: scratch.file("phone"))

        let report = try await library.pull(phone)
        #expect(report.added == [task.id])
        var local = try #require(library.folder(task.id))
        #expect(local.validate().isEmpty)
        #expect(try await library.pull(phone).added.isEmpty)

        let pairer = BenchPairer(folder: local)
        for (seed, asset) in [(UInt64(3), "photo-3"), (1, "photo-1"), (2, "photo-2")] {
            let export = try TestImages.write(
                TestImages.darkenedLeft(TestImages.filtered(TestImages.photo(seed: seed))),
                to: scratch.file("\(asset).jpg"), jpeg: true,
            )
            let result = try local.addResult(copying: export, originalName: "\(asset).jpg", pairer: pairer)
            #expect(result.asset == asset)
        }
        #expect(local.isComplete)
        #expect(library.enqueueIfComplete(local))

        let outcomes = await library.sendQueued(phone)
        let receipt = try #require(try outcomes[task.id]?.get())
        #expect(receipt.complete)
        #expect(receipt.summary == "3 results, all paired")
        #expect(library.queue.isEmpty)
        #expect(store.folder(task.id, in: .done)?.results.results.count == 3)
        #expect(store.folder(task.id, in: .outbox) == nil)
        #expect(try await phone.receipt(task.id)?.resultsDigest == local.resultsDigest)

        library.enqueue(local)
        #expect(library.queue.isEmpty)
    }

    @Test func `A withdrawn task leaves the phone unless it has results`() async throws {
        let scratch = Scratch()
        let (hub, client, store) = try await hub(scratch)
        defer { Task { await hub.stop() } }
        let task = try makeTask(in: scratch, store: store)
        var phone = client
        phone.token = try await client.pair(code: hub.code, device: "Phone").token
        let library = BenchLibrary(root: scratch.file("phone"))
        _ = try await library.pull(phone)
        try store.withdraw(task.id)
        #expect(try await library.pull(phone).withdrawn == [task.id])
        #expect(library.folder(task.id) == nil)
    }

    @Test func `A second hub on a taken port listens on another`() async throws {
        let scratch = Scratch()
        func started(_ name: String) async throws -> (BenchHub, UInt16) {
            let ready = AsyncStream<UInt16>.makeStream()
            let hub = BenchHub(store: BenchStore(root: scratch.file(name)), name: name) { event in
                if case let .state(.ready(port)) = event {
                    ready.continuation.yield(port)
                }
            }
            try await hub.start(port: 18765, advertise: false)
            for await port in ready.stream {
                return (hub, port)
            }
            return (hub, 0)
        }
        let (first, firstPort) = try await started("first")
        let (second, secondPort) = try await started("second")
        defer { Task { await first.stop(); await second.stop() } }
        #expect(firstPort == 18765)
        #expect(secondPort != 18765 && secondPort != 0)
        let info = try await BenchClient(base: #require(URL(string: "http://127.0.0.1:\(secondPort)/"))).info()
        #expect(info.name == "second")
    }

    @Test func `A damaged archive is refused with a reason and nothing reaches Done`() async throws {
        let scratch = Scratch()
        let (hub, client, store) = try await hub(scratch)
        defer { Task { await hub.stop() } }
        var phone = client
        phone.token = try await client.pair(code: hub.code, device: "Phone").token
        let folder = try makeTask(in: scratch)
        try Data("tampered".utf8).write(to: folder.url.appending(path: folder.manifest.assets[0].file))
        await #expect {
            try await phone.send(folder)
        } throws: { error in
            guard case let BenchClientError.http(status, message) = error else { return false }
            return status == 422 && (message.contains("SHA-256") || message.contains("bytes"))
        }
        #expect(store.folders(.done).isEmpty)
    }
}
