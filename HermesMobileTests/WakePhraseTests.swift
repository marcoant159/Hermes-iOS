import Foundation
import Testing
@testable import HermesMobile

/// Unit tests for the configurable wake phrase matcher (`WakePhrase`).
///
/// These exercise the pure matching logic only — no audio stack — covering the
/// built-in presets, their on-device transcription variants, the custom-phrase
/// edit-distance rule and the false-positive boundary documented on `match`.
struct WakePhraseTests {

    // MARK: - Presets

    @Test func defaultPhraseIsOiHermes() {
        let phrase = WakePhrase.defaultPhrase
        #expect(phrase.preset == .oiHermes)
        #expect(phrase.words == ["oi", "hermes"])
        #expect(phrase.isUsable)
        #expect(phrase.displayText == "Oi Hermes")
    }

    @Test func presetCanonicalPhrases() {
        #expect(WakePhrase(preset: .oiHermes).words == ["oi", "hermes"])
        #expect(WakePhrase(preset: .eiJarvis).words == ["ei", "jarvis"])
        #expect(WakePhrase(preset: .oiAtlas).words == ["oi", "atlas"])
        #expect(WakePhrase(preset: .computador).words == ["computador"])
    }

    @Test func emptyCustomPhraseIsNotUsable() {
        let phrase = WakePhrase(preset: .custom, customText: "   ")
        #expect(!phrase.isUsable)
        #expect(phrase.match(in: "oi hermes") == nil)
    }

    // MARK: - Built-in variants

    @Test func hermesAcceptsKnownTranscriptionVariants() {
        let phrase = WakePhrase(preset: .oiHermes)
        #expect(phrase.match(in: "oi hermes") != nil)
        #expect(phrase.match(in: "oi ermes") != nil)
        #expect(phrase.match(in: "oi Hermès") != nil)
        #expect(phrase.match(in: "oi hermis") != nil)
        #expect(phrase.match(in: "ÓI ÉRMES") != nil)
        #expect(phrase.match(in: "oi érmes") != nil)
    }

    @Test func jarvisAcceptsKnownTranscriptionVariants() {
        let phrase = WakePhrase(preset: .eiJarvis)
        #expect(phrase.match(in: "ei jarvis") != nil)
        #expect(phrase.match(in: "ei jarves") != nil)
        #expect(phrase.match(in: "ei jarbas") != nil)
        #expect(phrase.match(in: "ei jarvi") != nil)
    }

    @Test func atlasAcceptsAccentedSpelling() {
        let phrase = WakePhrase(preset: .oiAtlas)
        #expect(phrase.match(in: "oi atlas") != nil)
        #expect(phrase.match(in: "oi átlas") != nil)
    }

    @Test func computadorIsASingleActivationWord() {
        let phrase = WakePhrase(preset: .computador)
        #expect(phrase.match(in: "computador, liga a luz") != nil)
        #expect(phrase.match(in: "hermes, liga a luz") == nil)
    }

    // MARK: - Prefix tolerance

    @Test func activationWordAloneAtStartActivates() {
        // The greeting can be swallowed by the transcriber; a bare name at the
        // very start of the segment is still accepted.
        let phrase = WakePhrase(preset: .oiHermes)
        #expect(phrase.match(in: "hermes") != nil)
        #expect(phrase.match(in: "ermes, que horas são") != nil)
    }

    @Test func knownPrefixVariantStillActivates() {
        // "é mesmo" folds to ["e", "mesmo"]: "e" is a known prefix and "mesmo"
        // is within one edit of "hermes".
        let phrase = WakePhrase(preset: .oiHermes)
        #expect(phrase.match(in: "é mesmo, tudo bem") != nil)
    }

    @Test func optionalPrefixesAreAcceptedForCustomPhrases() {
        let phrase = WakePhrase(preset: .custom, customText: "Atlas")
        #expect(phrase.match(in: "oi atlas") != nil)
        #expect(phrase.match(in: "e aí atlas") != nil)
        #expect(phrase.match(in: "atlas") != nil)
    }

    // MARK: - Command extraction

    @Test func commandAfterPhraseIsReturned() {
        let phrase = WakePhrase(preset: .oiHermes)
        #expect(phrase.match(in: "oi hermes, que horas são")?.remainder == "que horas são")
        #expect(phrase.match(in: "oi ermes liga a luz")?.remainder == "liga a luz")
        #expect(phrase.match(in: "hermes como está o tempo?")?.remainder == "como está o tempo?")
    }

    @Test func barePhraseHasEmptyRemainder() {
        let phrase = WakePhrase(preset: .oiHermes)
        #expect(phrase.match(in: "oi hermes")?.remainder == "")
        #expect(phrase.match(in: "hermes")?.remainder == "")
    }

    // MARK: - False positives

    @Test func activationWordInTheMiddleDoesNotActivate() {
        // Documented rule: the activation word must start the segment. An article
        // or any other word before it means the phrase was not addressed to us.
        let phrase = WakePhrase(preset: .oiHermes)
        #expect(phrase.match(in: "o hermes é um deus grego") == nil)
        #expect(phrase.match(in: "eu acho o hermes legal") == nil)

        let atlas = WakePhrase(preset: .oiAtlas)
        #expect(atlas.match(in: "o atlas geográfico é útil") == nil)
        #expect(atlas.match(in: "abri o atlas agora") == nil)
    }

    @Test func unrelatedPhrasesDoNotActivate() {
        let phrase = WakePhrase(preset: .oiHermes)
        #expect(phrase.match(in: "oi tudo bem") == nil)
        #expect(phrase.match(in: "jarvis, me ajuda") == nil)
        #expect(phrase.match(in: "") == nil)
        #expect(phrase.match(in: "   ") == nil)
    }

    @Test func shortWordsAreNotFuzzyMatched() {
        // A three-letter activation word is never matched by edit distance, so
        // unrelated short words do not trigger it.
        let phrase = WakePhrase(preset: .custom, customText: "ana")
        #expect(phrase.match(in: "ana") != nil)
        #expect(phrase.match(in: "eba") == nil)
    }

    // MARK: - Custom edit distance

    @Test func customPhraseAcceptsOneEditPerWord() {
        let phrase = WakePhrase(preset: .custom, customText: "Computador")
        #expect(phrase.match(in: "computador") != nil)
        #expect(phrase.match(in: "computadorr") != nil)  // insertion
        #expect(phrase.match(in: "compuador") != nil)    // deletion
    }

    @Test func customPhraseRejectsFarMisses() {
        let phrase = WakePhrase(preset: .custom, customText: "Hermes")
        // "termos" differs from "hermes" by 2 edits -> rejected.
        #expect(phrase.match(in: "termos") == nil)
    }

    // MARK: - Normalization helpers

    @Test func foldingStripsAccentsAndCase() {
        #expect(WakePhrase.fold("Hermès") == "hermes")
        #expect(WakePhrase.fold("ÉRMES") == "ermes")
        #expect(WakePhrase.foldWords(in: "Oi, Hermes!") == ["oi", "hermes"])
    }

    @Test func editDistanceBasics() {
        #expect(WakePhrase.editDistance("hermes", "hermes") == 0)
        #expect(WakePhrase.editDistance("hermes", "ermes") == 1)
        #expect(WakePhrase.editDistance("hermes", "hermis") == 1)
        #expect(WakePhrase.editDistance("hermes", "termos") == 2)
    }
}
