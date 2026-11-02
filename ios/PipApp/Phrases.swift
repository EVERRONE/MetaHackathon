import Foundation
import PipCore

/// Fixed sentences Pip says during a task, in the conversation language. They come from the
/// runtime, not from a model, so they are instant and always the same.
struct Phrases {
    let dutch: Bool

    init(language: String) { dutch = language.lowercased() == "dutch" }

    func searching(_ product: String) -> String {
        dutch ? "Ik zoek de officiële handleiding van \(product)." : "I'm looking up the official manual for \(product)."
    }
    func reading(_ publisher: String) -> String {
        dutch ? "Gevonden, bij \(publisher). Ik lees de handleiding en maak een stappenplan." : "Found it, from \(publisher). I'm reading it and making a step plan."
    }
    var noManual: String {
        dutch ? "Ik vind geen officiële handleiding. Ik zoek verder online en maak er een plan van, niet uit een gecontroleerde bron."
              : "I can't find an official manual. I'll search further online and make a plan, not from a verified source."
    }
    var drafting: String { dutch ? "Ik maak een stappenplan." : "I'm making a step plan." }
    func offer(_ steps: Int, source: Procedure.SourceKind) -> String {
        let from: String
        switch source {
        case .pdf: from = dutch ? ", uit de officiële handleiding" : ", from the official manual"
        case .page: from = dutch ? ", van de officiële supportpagina" : ", from the official support page"
        case .web: from = dutch ? ", uit wat ik online vond (niet gecontroleerd)" : ", from what I found online (not verified)"
        case .images, .text: from = dutch ? ", uit jouw instructies" : ", from your instructions"
        case .none: from = ""
        }
        return dutch ? "Het plan heeft \(steps) stappen\(from). Zullen we beginnen?" : "The plan has \(steps) steps\(from). Shall we start?"
    }
    func mismatch(_ note: String) -> String { dutch ? "Let op: \(note)" : "Note: \(note)" }
    var manualUnreadable: String {
        dutch ? "De handleiding kan ik niet lezen. Ik maak een plan uit algemene kennis, niet uit een gecontroleerde bron."
              : "I can't read the manual. I'll make a plan from general knowledge, not from a verified source."
    }
    var welcome: String { dutch ? "Graag gedaan." : "You're welcome." }
    var prepareFailed: String { dutch ? "Het stappenplan lukte niet. Probeer het nog eens." : "I couldn't make the plan. Please try again." }
    var cancelled: String { dutch ? "Oké, dan niet." : "Okay, we won't." }
    // While Pip maps the room on its own: only when the mapping needs the user's help.
    var moveSlower: String { dutch ? "Beweeg je iPhone iets trager, dan onthoud ik de kamer beter." : "Move your iPhone a little slower, so I can remember the room." }
    var moreFeatures: String { dutch ? "Richt even op de kamer, niet op een kale muur." : "Point at the room for a moment, not at a bare wall." }
    func gate(_ condition: String) -> String { dutch ? "Eerst dit: \(condition). Is dat zo?" : "First this: \(condition). Is that so?" }
    var waitForGate: String { dutch ? "Dan wachten we. Zeg ja zodra het zo is." : "Then we wait. Say yes as soon as it is." }
    func askResult(_ expected: String) -> String { dutch ? "Ik zie het niet goed. Klopt dit: \(expected)?" : "I can't see it clearly. Is this right: \(expected)?" }
    func cannotCheck(_ expected: String) -> String { dutch ? "Dit kan ik niet zien. Controleer zelf: \(expected)." : "I can't see this. Please check it yourself: \(expected)." }
    var verified: String { dutch ? "Gezien, goed zo." : "I see it, well done." }
    var confirmed: String { dutch ? "Top." : "Great." }
    var finished: String { dutch ? "Klaar, alle stappen zijn gedaan. De samenvatting staat op het scherm." : "Done, every step is finished. The summary is on the screen." }
    var paused: String { dutch ? "Ik wacht. Zeg 'ga verder' als je klaar bent." : "I'll wait. Say 'continue' when you're ready." }
    var resumed: String { dutch ? "We gaan verder." : "Let's continue." }
    var stopped: String { dutch ? "De taak is gestopt." : "The task is stopped." }
    // Looking things up online (GuideModel+Lookup).
    var lookingUp: String { dutch ? "Ik zoek het op…" : "Looking it up…" }
    var stillLookingUp: String { dutch ? "Ik zoek nog even verder." : "Still looking." }
    var lookupNothing: String { dutch ? "Ik vond daar online niets betrouwbaars over." : "I couldn't find anything reliable about that online." }
    /// The start of an answer from the manufacturer: "Volgens de handleiding van Philips:".
    func accordingTo(_ publisher: String, manual: Bool) -> String {
        let who = publisher.isEmpty ? (dutch ? "de fabrikant" : "the manufacturer") : publisher
        if dutch { return manual ? "Volgens de handleiding van \(who):" : "Volgens de site van \(who):" }
        return manual ? "According to the \(who) manual:" : "According to \(who)'s website:"
    }
    func unverified(_ answer: String) -> String {
        dutch ? "Online vond ik dit, niet van de fabrikant, dus controleer het even: \(answer)" : "I found this online, not from the manufacturer, so please double-check: \(answer)"
    }
    func searchingMemory(_ what: String) -> String { dutch ? "Ik kijk terug waar ik \(what) zag." : "I'm looking back for \(what)." }
    var searchingFurther: String { dutch ? "Ik kijk verder terug." : "I'm looking further back." }

    /// "zonet", "12 minuten geleden", "gisteren": how long ago, in the conversation language.
    func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 90 { return dutch ? "zonet" : "just now" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: dutch ? "nl_BE" : "en_GB")
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f.localizedString(for: date, relativeTo: Date())
    }
    func found(_ what: String, at date: Date, where place: String) -> String {
        dutch ? "Ik zag \(what) \(ago(date)): \(place). Volg de pijl. Het kan intussen verplaatst zijn."
              : "I saw \(what) \(ago(date)): \(place). Follow the arrow. It may have been moved since."
    }
    /// Seen in a room this session has not recognised: where it was, from the snapshot, but no way
    /// there (Pip does not know where that room is from here).
    func foundElsewhere(_ what: String, at date: Date, place: String?) -> String {
        // Looking round helps Pip recognise where it is (2 Nov, 20:33: at a round table with glass
        // walls, the room was recognised once the kitchen island and cupboards came into view).
        if let place {
            return dutch ? "Ik zag \(what) \(ago(date)) \(place). Waar dat van hieruit is, weet ik nog niet: kijk even rustig rond, dan wijs ik het aan zodra ik herken waar we zijn."
                         : "I saw \(what) \(ago(date)) \(place). I don't know where that is from here yet: look around slowly, and I'll point it out as soon as I recognise where we are."
        }
        return dutch ? "Ik zag \(what) \(ago(date)), in een ruimte die ik nu nog niet herken. Kijk even rustig rond, dan wijs ik het aan zodra ik herken waar we zijn."
                     : "I saw \(what) \(ago(date)), in a room I haven't recognised yet this time. Look around slowly, and I'll point it out as soon as I recognise where we are."
    }
    /// A find that saw `what` in a room not recognised then: the room is recognised now.
    func recognisedNow(_ what: String, where place: String) -> String {
        dutch ? "Ik weet nu waar we zijn: \(what) ligt op \(place). Volg de pijl."
              : "I know where we are now: \(what) is \(place). Follow the arrow."
    }
    func notFound(_ what: String, since date: Date?) -> String {
        guard let date else {
            return dutch ? "Ik heb \(what) nog niet gezien. Waar was je het laatst?" : "I haven't seen \(what) yet. Where were you last?"
        }
        return dutch ? "Ik heb \(what) niet gezien sinds \(ago(date)). Waar was je het laatst?"
                     : "I haven't seen \(what) since \(ago(date)). Where were you last?"
    }
    func gotItem(_ item: String) -> String { dutch ? "\(item), afgevinkt." : "\(item), got it." }
    func wrongItem(_ item: String, seen: String) -> String { dutch ? "Let op: ik zie \(seen). Op je lijst staat \(item)." : "Careful: I see \(seen). Your list says \(item)." }
    var listComplete: String { dutch ? "Alles van je lijst ligt in je mand." : "Everything on your list is in your basket." }
    var askMemory: String {
        dutch ? "Zal ik dit ook onthouden voor de volgende keer? Alleen op je iPhone." : "Shall I remember this for next time too? Only on your iPhone."
    }
    var memoryYes: String { dutch ? "Goed, ik onthoud het." : "Good, I'll remember it." }
    var memoryNo: String { dutch ? "Oké, ik vergeet het na deze sessie." : "Okay, I'll forget it after this session." }
    func page(_ n: Int) -> String { dutch ? "Pagina \(n)." : "Page \(n)." }
    func readingStatus(_ n: Int) -> String { dutch ? "Ik lees mee: \(n) pagina's. Zeg 'klaar' als je alles getoond hebt." : "Reading along: \(n) pages. Say 'done' when you've shown them all." }
    var noPages: String { dutch ? "Ik heb nog geen pagina gezien. Houd een pagina even stil in beeld." : "I haven't seen a page yet. Hold a page still in view for a moment." }
    func readPages(_ n: Int) -> String { dutch ? "Ik heb \(n) pagina's gelezen. Ik maak er een stappenplan van." : "I read \(n) pages. I'm making a step plan from them." }

    /// Pip's job when it gives a step: spoken in its own words, pointing at the targets.
    func instruct(step: Int, of count: Int, _ s: ProcedureStepText) -> String {
        """
        Give step \(step) of \(count) now: "\(s.instruction)".\(s.why.map { " Why: \($0)." } ?? "") \
        \(s.targets.isEmpty ? "" : "Point at \(s.targets) if you can see it.") \
        \(s.cautions.isEmpty ? "" : "Warn about: \(s.cautions).") \
        Say it in your own words in at most three short sentences; mention the step number once at most. \
        If the result of this step is already clearly visible, say so in one short sentence instead and set step=done in the state tag.
        """
    }

    /// Pip's job when the user says a step is done: look and say what is visible.
    func verify(step: Int, expected: String) -> String {
        """
        The user says step \(step) is done. Look carefully: is this visible now? "\(expected)". \
        Say in one or two short sentences what you see. In the state tag set step=done only if you clearly see it, \
        with your confidence; otherwise step=not_done and say what is still missing.
        """
    }
}

/// The parts of a step that go into Pip's directive.
struct ProcedureStepText {
    var instruction: String
    var why: String?
    /// "the wall rail (printed: 10116976) and the screws"
    var targets: String
    var cautions: String
}
