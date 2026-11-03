import Testing
@testable import PipCore

@Suite struct UtteranceTests {
    @Test func languageFromFunctionWords() {
        #expect(Utterance.language(of: "Ik probeer de alt-key te vinden of de add voor het invoeren van mijn e-mailadres.") == "Dutch")
        #expect(Utterance.language(of: "Show me where to get the add key for my Gmail.") == "English")
        #expect(Utterance.language(of: "How do I close a tab?") == "English")
        #expect(Utterance.language(of: "Waar heb ik mijn sleutels gelegd?") == "Dutch")
        // Too short or mixed: keep the current language.
        #expect(Utterance.language(of: "Mac,") == nil)
        #expect(Utterance.language(of: "Oké.") == nil)
        #expect(Utterance.language(of: "IKEA PAX") == nil)
    }

    @Test func acknowledgements() {
        #expect(Utterance.acknowledgement("Okay.") == .okay)
        #expect(Utterance.acknowledgement("Oké.") == .okay)
        #expect(Utterance.acknowledgement("Oh, great. Thank you.") == .thanks)
        #expect(Utterance.acknowledgement("Okay, thank you.") == .thanks)
        #expect(Utterance.acknowledgement("Dank je wel!") == .thanks)
        #expect(Utterance.acknowledgement("All right") == .okay)
        // Questions and requests are not acknowledgements.
        #expect(Utterance.acknowledgement("Okay, and now?") == nil)
        #expect(Utterance.acknowledgement("Thank you, where is the drill?") == nil)
        #expect(Utterance.acknowledgement("I guess.") == nil)
        #expect(Utterance.acknowledgement("you") == nil)
        #expect(Utterance.acknowledgement("") == nil)
    }

    @Test func yesWithMore() {
        #expect(Utterance.startsWithYes("Yes, I'm now at settings."))
        #expect(Utterance.startsWithYes("Ja, de stroom is af"))
        #expect(Utterance.startsWithYes("Let's go"))
        #expect(!Utterance.startsWithYes("Ja, maar wacht even"))
        #expect(!Utterance.startsWithYes("Yes but not now"))
        #expect(!Utterance.startsWithYes("Nee"))
        #expect(!Utterance.startsWithYes("Japan is far"))
    }
}

@Suite struct EchoLikenessTests {
    /// Pip's own words heard back with one word wrong are still Pip's (3 Nov: "I point the").
    @Test func pipsOwnWordsMisheardAreStillItsOwn() {
        let said = "Yes, I point that way only for remembered places. Your fancy pen is ahead, lower down, about 1.3 metres."
        #expect(Utterance.likeness("I point the", within: said) >= 0.85)
        #expect(Utterance.likeness("your fancy pen is a head", within: said) >= 0.85)
        #expect(Utterance.likeness("place a receptacle under the spout", within: "Place a receptacle under the coffee spout.") >= 0.85)
    }

    /// A question of the user's that shares Pip's words is not taken for its echo.
    @Test func aQuestionThatSharesPipsWordsIsTheUsers() {
        let said = "According to the JURA manual: plug in, add a receptacle, then press On/Off. Then press the On/Off button Q to switch it on."
        #expect(Utterance.likeness("Where is the on off button?", within: said) < 0.85)
        #expect(Utterance.likeness("No, that's the wrong book", within: "I see your book beside the light wooden box.") < 0.85)
        #expect(Utterance.likeness("where is the let them book", within: "The Let Them Theory book is straight ahead, about four metres away.") < 0.85)
    }
}
