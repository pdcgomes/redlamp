import Foundation
import RedlampDocument
import Testing
@testable import RedlampLibrary

/// Lightroom Classic's last stacking commands (LIB-28): Unstack taking whole stacks apart, Remove from Stack taking
/// photos out of theirs, Split Stack, and a photo moved up or down its stack or to another's place, the order kept in
/// each photo's place in the stack, a raw and its JPEG moving as one.
struct StackOrderTests {
    /// A burst of four frames an eighth of a second apart, the second a raw beside its JPEG, and four photos taken
    /// an hour apart, alone.
    private struct Shoot {
        var library = StackLibrary()
        var burst: [Int64] = []
        var jpeg: Int64 = 0
        var alone: [Int64] = []

        init() {
            burst.append(library.add("IMG_0001.CR3", at: 1000))
            let pair = library.addPair("IMG_0002", at: 1000.125)
            (jpeg, burst) = (pair.jpeg, burst + [pair.raw])
            burst += [library.add("IMG_0003.CR3", at: 1000.25), library.add("IMG_0004.CR3", at: 1000.375)]
            alone = (0 ..< 4).map { library.add("SOLO_\($0).CR3", folder: 2, at: 5000 + Double($0) * 3600) }
        }
    }

    @Test func `Unstack takes apart every stack holding a photo, and Remove from Stack takes out only the photos`() {
        let shoot = Shoot()
        var choices = StackChoices()
        #expect(shoot.library.find(choices).photos(.burst) == [shoot.burst])

        let removed = choices.remove([shoot.burst[2]], in: shoot.library.find(choices))
        #expect(removed == [shoot.burst[2]])
        var stacks = shoot.library.find(choices)
        #expect(stacks.photos(.burst) == [[shoot.burst[0], shoot.burst[1], shoot.burst[3]]])
        #expect(stacks.stack(containing: shoot.burst[2]) == nil, "the photo stands alone, in no burst")

        choices.stack(shoot.alone[0 ... 2], top: shoot.alone[0], in: stacks)
        stacks = shoot.library.find(choices)
        #expect(stacks.photos(.manual) == [Array(shoot.alone[0 ... 2])])
        choices.remove([shoot.alone[1]], in: stacks)
        stacks = shoot.library.find(choices)
        #expect(stacks.photos(.manual) == [[shoot.alone[0], shoot.alone[2]]], "the others stay stacked")

        let unstacked = choices.unstack([shoot.alone[2], shoot.jpeg, shoot.alone[3]], in: stacks)
        #expect(Set(unstacked) == Set([shoot.alone[0], shoot.alone[2], shoot.alone[3], shoot.jpeg] + shoot.burst)
            .subtracting([shoot.burst[2]]))
        stacks = shoot.library.find(choices)
        #expect(stacks.photos(.manual).isEmpty && stacks.photos(.burst).isEmpty)
        #expect(stacks.photos(.pair) == [[shoot.burst[1], shoot.jpeg]], "a raw and its JPEG stay one photo")
        #expect(Set(shoot.burst.compactMap { choices[$0]?.id }).count == 4, "each frame stands alone")
    }

    @Test func `Split Stack keeps the photos above one a stack, and makes it and those below one with it on top`() {
        let shoot = Shoot()
        var choices = StackChoices()
        let burst = shoot.burst
        #expect(choices.split(before: burst[0], in: shoot.library.find(choices)).isEmpty, "nothing is above the top")

        choices.split(before: burst[2], in: shoot.library.find(choices))
        var stacks = shoot.library.find(choices)
        #expect(stacks.photos(.burst).isEmpty)
        #expect(Set(stacks.photos(.manual)) == [[burst[0], burst[1]], [burst[2], burst[3]]])
        #expect(choices[shoot.jpeg] == choices[burst[1]], "the JPEG goes with its raw")

        choices.split(before: burst[3], in: stacks)
        stacks = shoot.library.find(choices)
        #expect(stacks.photos(.manual) == [[burst[0], burst[1]]], "a part of one photo stands alone")
        #expect(stacks.stack(containing: burst[3]) == nil && stacks.stack(containing: burst[2]) == nil)

        choices.split(before: shoot.jpeg, in: stacks)
        stacks = shoot.library.find(choices)
        #expect(stacks.photos(.manual).isEmpty, "split at the JPEG, before its raw")
    }

    @Test func `a photo moved up or down its stack keeps the order in each photo's place, the first on top`() {
        let shoot = Shoot()
        var choices = StackChoices()
        let solo = shoot.alone
        choices.stack(solo[0 ... 2], top: solo[0], in: shoot.library.find(choices))
        func order() -> [Int64] {
            shoot.library.find(choices).photos(.manual).first ?? []
        }
        #expect(order() == [solo[0], solo[1], solo[2]])

        choices.move(solo[2], by: -1, in: shoot.library.find(choices))
        #expect(order() == [solo[0], solo[2], solo[1]])
        #expect([solo[0], solo[2], solo[1]].map { choices[$0]?.position } == [0, 1, 2])
        #expect(choices[solo[0]]?.top == true && choices[solo[2]]?.top == false)
        choices.move(solo[2], by: -1, in: shoot.library.find(choices))
        #expect(order() == [solo[2], solo[0], solo[1]] && choices[solo[2]]?.top == true, "moved up to the top")
        #expect(choices[solo[0]]?.top == false)
        #expect(choices.move(solo[2], by: -1, in: shoot.library.find(choices)).isEmpty, "the top goes no higher")
        choices.move(solo[2], by: 5, in: shoot.library.find(choices))
        #expect(order() == [solo[0], solo[1], solo[2]], "down as far as the stack goes")

        choices.setTop(solo[1], in: shoot.library.find(choices))
        #expect(order() == [solo[1], solo[0], solo[2]], "the top shown first, the others in their places")
    }

    @Test func `a burst moved in becomes a stack made by hand in its order, a raw and its JPEG moving as one`() {
        let shoot = Shoot()
        var choices = StackChoices()
        let burst = shoot.burst
        let changed = choices.move(shoot.jpeg, by: 1, in: shoot.library.find(choices))
        #expect(Set(changed) == Set(burst + [shoot.jpeg]))
        let stacks = shoot.library.find(choices)
        #expect(stacks.photos(.burst).isEmpty)
        #expect(stacks.photos(.manual) == [[burst[0], burst[2], burst[1], burst[3]]])
        #expect(choices[shoot.jpeg] == choices[burst[1]] && choices[shoot.jpeg]?.position == 2)
        #expect(stacks.allPhotos(of: stacks[stacks.stackIndex(containing: burst[0]) ?? 0]).count == 5)
    }

    @Test func `a move counts only the photos a view shows, when it's given them`() {
        let shoot = Shoot()
        var choices = StackChoices()
        let burst = shoot.burst
        choices.move(burst[3], by: -1, among: [burst[0], burst[3]], in: shoot.library.find(choices))
        #expect(shoot.library.find(choices).photos(.manual) == [[burst[3], burst[0], burst[1], burst[2]]])
        choices.move(burst[0], by: 1, among: [burst[3], burst[0], shoot.jpeg], in: shoot.library.find(choices))
        #expect(
            shoot.library.find(choices).photos(.manual) == [[burst[3], burst[1], burst[0], burst[2]]],
            "past the raw its JPEG stands for",
        )
    }

    @Test func `photos dragged to another's place go before it from below and after it from above, in their order`() {
        let shoot = Shoot()
        var choices = StackChoices()
        let solo = shoot.alone
        choices.stack(solo, top: solo[0], in: shoot.library.find(choices))
        func order() -> [Int64] {
            shoot.library.find(choices).photos(.manual).first ?? []
        }
        choices.place([solo[3]], at: solo[1], in: shoot.library.find(choices))
        #expect(order() == [solo[0], solo[3], solo[1], solo[2]])
        choices.place([solo[0]], at: solo[2], in: shoot.library.find(choices))
        #expect(order() == [solo[3], solo[1], solo[2], solo[0]] && choices[solo[3]]?.top == true)
        choices.place([solo[2], solo[1]], at: solo[0], in: shoot.library.find(choices))
        #expect(order() == [solo[3], solo[0], solo[1], solo[2]], "several keep their order")

        let stacks = shoot.library.find(choices)
        #expect(choices.place([solo[1]], at: solo[1], in: stacks).isEmpty)
        #expect(choices.place([shoot.burst[0]], at: solo[1], in: stacks).isEmpty, "a photo of another stack stays")
        #expect(choices.place([solo[0], solo[1]], at: solo[1], in: stacks).isEmpty)
    }

    @Test func `a stacked list finds a photo in its open stacks from those stacks alone`() {
        let shoot = Shoot()
        var stacked = StackedList(shoot.library.list, stacks: shoot.library.find())
        #expect(!stacked.anyOpenStack { $0 == shoot.burst[1] }, "the burst is closed")
        _ = stacked.open(shoot.burst[0])
        #expect(stacked.anyOpenStack { $0 == shoot.jpeg }, "the JPEG beside a raw in the open burst")
        #expect(!stacked.anyOpenStack { shoot.alone.contains($0) }, "photos in no stack")
        _ = stacked.close(shoot.burst[0])
        #expect(!stacked.anyOpenStack { $0 == shoot.burst[1] })
    }

    @Test func `a stack's photos with places come first in their order, those without after them by capture time`() {
        let shoot = Shoot()
        let solo = shoot.alone
        let id = UUID()
        let choices = StackChoices([
            solo[0]: .init(id: id), solo[1]: .init(id: id, position: 1), solo[2]: .init(id: id, position: 0),
            solo[3]: .init(id: id),
        ])
        #expect(shoot.library.find(choices).photos(.manual) == [[solo[2], solo[1], solo[0], solo[3]]])
    }
}
