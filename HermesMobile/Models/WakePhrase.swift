import Foundation

/// Configurable hands-free activation phrase.
///
/// The wake word is matched against on-device dictation transcripts, which
/// routinely mangle uncommon proper nouns. Each preset therefore carries the
/// canonical phrase plus the transcription variants that the on-device model is
/// known to emit (e.g. "Hermes" -> "ermes"/"hermis"/"é mesmo"). Custom phrases
/// fall back to normalization + a small per-word edit distance.
enum WakePhrasePreset: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case oiHermes
    case eiJarvis
    case oiAtlas
    case computador
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oiHermes: "Oi Hermes"
        case .eiJarvis: "Ei Jarvis"
        case .oiAtlas: "Oi Atlas"
        case .computador: "Computador"
        case .custom: "Personalizada"
        }
    }

    /// The phrase stored/edited for this preset. `nil` for `.custom` (the user
    /// supplies it in `WakePhrase.customText`).
    var canonicalPhrase: String? {
        switch self {
        case .oiHermes: "Oi Hermes"
        case .eiJarvis: "Ei Jarvis"
        case .oiAtlas: "Oi Atlas"
        case .computador: "Computador"
        case .custom: nil
        }
    }
}

/// A resolved, matcher-ready wake phrase.
///
/// The value is built from `WakePhrasePreset` + the optional custom text and is
/// cheap to rebuild whenever settings change. It is a pure value type so the
/// matching logic can be unit-tested without the audio stack.
struct WakePhrase: Equatable, Sendable {
    /// Words that may prefix the activation word ("oi", "ei", …). Prefixes are
    /// optional, but they must sit immediately before the activation word.
    static let optionalPrefixes: Set<String> = ["oi", "ei", "ok", "ola", "eai"]

    /// A prefix transcription may be dropped entirely; the activation word alone
    /// at the start of the segment is always accepted.
    let preset: WakePhrasePreset
    let rawPhrase: String
    /// Fully-folded words of the phrase (lower-case, no diacritics/punctuation).
    let words: [String]

    init(preset: WakePhrasePreset, customText: String = "") {
        let text: String
        switch preset {
        case .custom:
            text = customText
        default:
            text = preset.canonicalPhrase ?? WakePhrasePreset.oiHermes.canonicalPhrase ?? ""
        }
        self.preset = preset
        self.rawPhrase = text
        self.words = Self.foldWords(in: text)
    }

    static let defaultPhrase = WakePhrase(preset: .oiHermes)

    /// Whether the phrase has something matchable (custom phrases can be empty).
    var isUsable: Bool { !words.isEmpty }

    var displayText: String {
        rawPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Normalization

extension WakePhrase {
    /// Lower-cases and strips diacritics so "Hermès", "Érmes" and "hermes" agree.
    static func fold(_ word: String) -> String {
        word.lowercased().folding(options: .diacriticInsensitive, locale: .current)
    }

    /// Splits `text` into alphanumeric runs, folding each one.
    static func foldWords(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(fold(current))
                current = ""
            }
        }
        if !current.isEmpty { words.append(fold(current)) }
        return words
    }

    /// Damerau–Levenshtein distance, capped at 2 (we never accept more).
    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > 2 { return 3 }

        var previousPrevious = Array(0...b.count)
        var previous = previousPrevious
        for i in 1...a.count {
            var current = [i]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previousPrevious[j - 1] + cost
                )
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, previousPrevious[j - 2] + 1)
                }
                current.append(value)
            }
            previousPrevious = previous
            previous = current
        }
        return previous[b.count]
    }

    /// A word with at least `minLength` characters may differ by one character
    /// from `target`. Short words must match exactly (avoids "oi" ~ "ai").
    static func isNearVariant(_ word: String, of target: String, minLength: Int = 5) -> Bool {
        guard word.count >= minLength, target.count >= minLength else { return word == target }
        return editDistance(word, target) <= 1
    }
}

// MARK: - Matching

extension WakePhrase {
    /// Result of a successful match: the words after the activation phrase that
    /// belong to the same utterance/segment.
    struct Match: Equatable {
        let remainder: String
    }

    /// Variant words accepted for each preset activation word (beyond the
    /// canonical spelling itself).
    private static let variants: [WakePhrasePreset: Set<String>] = [
        .oiHermes: ["hermes", "ermes", "hermis"],
        .eiJarvis: ["jarvis", "jarves", "jarbas", "jarvi"],
        .oiAtlas: ["atlas"],
        .computador: ["computador"],
    ]

    /// True when `token` matches `target`, either exactly or — for the built-in
    /// variants of `preset` — via the known transcription list. Built-in presets
    /// also accept the small edit-distance tolerance so a one-letter dictation
    /// slip still fires. Custom phrases only rely on the edit distance (and are
    /// kept strict: one edit per word with >= 5 letters).
    static func tokenMatches(
        _ token: String,
        target: String,
        preset: WakePhrasePreset
    ) -> Bool {
        if token == target { return true }
        if let known = variants[preset], known.contains(token) { return true }
        if target.count >= 5 {
            return isNearVariant(token, of: target, minLength: 5)
        }
        return false
    }

    /// Returns the command/remainder that follows the wake phrase, or `nil` when
    /// `text` is not addressed to the wake phrase.
    ///
    /// Rule (matches the previous behaviour and is documented for the tests):
    /// the activation word must appear at the **start of a segment**. An optional
    /// prefix may precede it, but the activation word can never be buried in the
    /// middle of a sentence — so "o atlas geográfico é útil" does not trigger,
    /// while "atlas, que horas são" does.
    func match(in text: String) -> Match? {
        guard isUsable else { return nil }
        let tokens = Self.scan(text)
        guard !tokens.isEmpty else { return nil }

        // A single-word phrase is the activation word itself. The built-in
        // presets still allow a leading optional prefix ("oi"/"ei"/…) to be
        // present and dropped; custom single words are matched bare.
        let target = words

        // Try with the full phrase first (activation word may be preceded by an
        // optional prefix, but the phrase must start at the beginning).
        if let index = matchStart(tokens: tokens, target: target, preset: preset) {
            let activationEnd = tokens[index].range.upperBound
            return Match(remainder: Self.trimLeadingPunctuation(String(text[activationEnd...])))
        }

        // A prefix transcription can be lost entirely (e.g. "oi" swallowed).
        // Accept the activation word alone at the start for multi-word phrases:
        // "hermes, qual é a previsão" still triggers, but "o atlas …" does not
        // because "o" is an article, not our optional prefix.
        if target.count > 1, let activation = target.last,
           let index = matchStart(tokens: tokens, target: [activation], preset: preset) {
            let activationEnd = tokens[index].range.upperBound
            return Match(remainder: Self.trimLeadingPunctuation(String(text[activationEnd...])))
        }

        return nil
    }

    /// Finds the activation phrase starting at token index 0 (optionally after
    /// one optional prefix token). Returns the index of the *activation* word.
    private func matchStart(
        tokens: [(folded: String, range: Range<String.Index>)],
        target: [String],
        preset: WakePhrasePreset
    ) -> Int? {
        guard let activation = target.last, !activation.isEmpty else { return nil }

        // Full-phrase form: prefix + activation.
        if target.count > 1, tokens.count >= target.count {
            let prefix = target[target.count - 2]
            let prefixMatches = prefix == activation
                ? true
                : (Self.optionalPrefixes.contains(prefix)
                    && Self.tokenMatches(tokens[0].folded, target: prefix, preset: preset))
            if prefixMatches {
                let candidateIndex = target.count - 1
                if Self.tokenMatches(tokens[candidateIndex].folded, target: activation, preset: preset) {
                    return candidateIndex
                }
            }
        }

        // Bare activation word at the very start.
        if Self.tokenMatches(tokens[0].folded, target: activation, preset: preset) {
            return 0
        }

        // Multi-word phrases also accept the activation word at the start when
        // the prefix was transcribed as our optional prefix but the phrase order
        // differs (defensive, e.g. "oi, hermes" -> tokens ["oi","hermes"]).
        return nil
    }

    private static func scan(_ text: String) -> [(folded: String, range: Range<String.Index>)] {
        var tokens: [(folded: String, range: Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, !text[index].isLetter, !text[index].isNumber {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, text[index].isLetter || text[index].isNumber {
                index = text.index(after: index)
            }
            tokens.append((folded: fold(String(text[start..<index])), range: start..<index))
        }
        return tokens
    }

    private static func trimLeadingPunctuation(_ text: String) -> String {
        var slice = Substring(text)
        while let first = slice.first, !first.isLetter, !first.isNumber {
            slice = slice.dropFirst()
        }
        return String(slice).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
