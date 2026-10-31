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
