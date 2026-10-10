import Foundation
import RedlampEngineAPI

/// The user's mask effects, saved in user defaults as they change, as mask presets are; `shared`
/// is the app's.
@MainActor @Observable
final class MaskEffectStore {
    static let shared = MaskEffectStore()
    private static let defaultsKey = "app.redlamp.maskEffects"

    var effects: [MaskEffect] {
        didSet { defaults.set(try? JSONEncoder().encode(effects), forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        effects = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([MaskEffect].self, from: $0) } ?? []
    }
}

/// Effects for a mask's adjustments, as Lightroom's Effect menu has (UX-27): Redlamp's own and
/// the user's, each setting a mask's sliders and Curves.
public extension EditorModel {
    /// Redlamp's effects, then the user's.
    var maskEffects: [MaskEffect] {
        MaskEffect.builtIn + maskEffectStore.effects
    }

    /// The user's saved effects.
    var userMaskEffects: [MaskEffect] {
        maskEffectStore.effects
    }

    /// The effect whose sliders and Curves mask `id` has.
    func maskEffect(of id: UUID) -> MaskEffect? {
        guard let mask = recipe.mask(id) else { return nil }
        return maskEffects.first { !$0.isEmpty && mask.has($0) }
    }

    /// What the Effect menu shows for mask `id`: the effect it has, Custom when its sliders or
    /// Curves are its own, or None while they're untouched.
    func effectTitle(of id: UUID) -> String {
        if let effect = maskEffect(of: id) {
            return effect.name
        }
        return recipe.mask(id)?.isAdjusted == true ? "Custom" : "None"
    }

    /// Gives mask `id` the effect's sliders and Curves, as one step of its history.
    func applyMaskEffect(_ effect: MaskEffect, to id: UUID) {
        guard let index = recipe.masks.firstIndex(where: { $0.id == id }) else { return }
        var next = recipe
        next.masks[index].apply(effect)
        commit(next, .mask(nil), "Apply \(effect.name) to \(next.masks[index].name)")
    }

    /// Keeps mask `id`'s sliders and Curves as an effect called `name`, or the mask's own name when
    /// it's blank. One of the user's effects with the same name is replaced.
    func saveMaskEffect(from id: UUID, name: String) {
        guard let mask = recipe.mask(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let named = trimmed.isEmpty ? mask.name : trimmed
        var effects = maskEffectStore.effects
        effects.removeAll { $0.name == named }
        effects.append(MaskEffect(mask, name: named))
        maskEffectStore.effects = effects
    }

    func deleteMaskEffect(_ id: String) {
        maskEffectStore.effects.removeAll { $0.id == id }
    }
}
