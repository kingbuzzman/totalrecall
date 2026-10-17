import Foundation
import Testing

@testable import Transcribe

struct SpeechLocaleTests {
    private static let supported = ["en-US", "en-GB", "es-ES", "es-MX", "es-US", "fr-CA", "pt-BR"].map(Locale.init)

    @Test(arguments: [
        ("es-MX", "US", "es-MX"),
        ("es", "US", "es-US"),
        ("es", "DE", "es-ES"),
        ("pt", "US", "pt-BR"),
        ("fr", "US", "fr-CA"),
        ("en", "GB", "en-GB"),
    ])
    func picksTheRegionTheUserMeant(language: String, currentRegion: String, expected: String) throws {
        let locale = try speechLocale(
            for: language,
            among: Self.supported,
            currentRegion: Locale.Region(currentRegion)
        )

        #expect(locale.identifier(.bcp47) == expected)
    }

    @Test func suggestsTheRegionsItHasForAnUnsupportedOne() {
        #expect {
            try speechLocale(for: "es-AR", among: Self.supported, currentRegion: nil)
        } throws: { error in
            error.localizedDescription == "no speech model for es-AR; try es-ES, es-MX, es-US"
        }
    }

    @Test func pointsAtTheListForAnUnsupportedLanguage() {
        #expect {
            try speechLocale(for: "xx", among: Self.supported, currentRegion: nil)
        } throws: { error in
            error.localizedDescription == "no speech model for xx; see transcribe --list-languages"
        }
    }
}
