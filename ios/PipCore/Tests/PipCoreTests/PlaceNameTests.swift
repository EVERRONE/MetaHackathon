import Testing
@testable import PipCore

/// A remembered place is found again by name only when the thing asked for is that thing.
@Suite struct PlaceNameTests {
    @Test func theSameThingInOtherWordsIsFound() {
        // The model's words for the statues the user named in Dutch.
        #expect(PlaceName.score("taller golden statue", names: ["gouden beeldjes", "gold statue"]) == 2)
        #expect(PlaceName.score("mijn gouden beeldje", names: ["gouden beeldjes", ""]) == 2)
        #expect(PlaceName.score("the user's keys", names: ["keys", ""]) == 1)
        #expect(PlaceName.score("glasses", names: ["reading glass", ""]) == 1)
    }

    @Test func aSharedBeginningOrAnotherThingOfTheSameKindIsNot() {
        // 1 Nov review: four shared letters moved "kitchen table" onto a tablet.
        #expect(PlaceName.score("tablet", names: ["kitchen table", "wooden table"]) == 0)
        #expect(PlaceName.score("coffee mug", names: ["coffee table", ""]) == 0)
        #expect(PlaceName.score("gold ring", names: ["golden statue", ""]) == 0)
        // A different word that happens to end alike stays different.
        #expect(PlaceName.score("bus", names: ["bush", ""]) == 0)
    }

    @Test func endingsComeOffButNeverTheWord() {
        #expect(PlaceName.stem("beeldjes") == "beeld")
        #expect(PlaceName.stem("kopje") == "kop")
        #expect(PlaceName.stem("statues") == PlaceName.stem("statue"))
        #expect(PlaceName.stem("glasses") == PlaceName.stem("glass"))
        #expect(PlaceName.stem("bus") == "bus")
        #expect(PlaceName.stem("key") == "key")
    }
}
