import Foundation

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
        dutch ? "Ik vind geen officiële handleiding. Ik maak een plan uit algemene kennis, niet uit een gecontroleerde bron."
              : "I can't find an official manual. I'll make a plan from general knowledge, not from a verified source."
    }
    var drafting: String { dutch ? "Ik maak een stappenplan." : "I'm making a step plan." }
    func offer(_ steps: Int, verified: Bool) -> String {
        dutch ? "Het plan heeft \(steps) stappen\(verified ? ", uit de officiële handleiding" : ""). Zullen we beginnen?"
              : "The plan has \(steps) steps\(verified ? ", from the official manual" : ""). Shall we start?"
    }
    func mismatch(_ note: String) -> String { dutch ? "Let op: \(note)" : "Note: \(note)" }
    var prepareFailed: String { dutch ? "Het stappenplan lukte niet. Probeer het nog eens." : "I couldn't make the plan. Please try again." }
    var cancelled: String { dutch ? "Oké, dan niet." : "Okay, we won't." }
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
    func searchingMemory(_ what: String) -> String { dutch ? "Ik kijk terug waar ik \(what) zag." : "I'm looking back for \(what)." }
    func found(_ what: String, minutes: Int, where place: String) -> String {
        let ago = minutes < 1 ? (dutch ? "net" : "just now") : (dutch ? "\(minutes) minuten geleden" : "\(minutes) minutes ago")
        return dutch ? "Ik zag \(what) \(ago): \(place). Volg de pijl. Het kan intussen verplaatst zijn."
                     : "I saw \(what) \(ago): \(place). Follow the arrow. It may have been moved since."
    }
    func notFound(_ what: String, minutes: Int) -> String {
        dutch ? "Ik heb \(what) niet gezien in de laatste \(max(1, minutes)) minuten. Waar was je het laatst?"
              : "I haven't seen \(what) in the last \(max(1, minutes)) minutes. Where were you last?"
    }
    func gotItem(_ item: String) -> String { dutch ? "\(item), afgevinkt." : "\(item), got it." }
    func wrongItem(_ item: String, seen: String) -> String { dutch ? "Let op: ik zie \(seen). Op je lijst staat \(item)." : "Careful: I see \(seen). Your list says \(item)." }
    var listComplete: String { dutch ? "Alles van je lijst ligt in je mand." : "Everything on your list is in your basket." }
    func listMissing(_ items: [String]) -> String {
        dutch ? "Je hebt nog niet: \(items.joined(separator: ", "))." : "You still need: \(items.joined(separator: ", "))."
    }
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
        Say it in your own words in at most three short sentences; mention the step number once at most.
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
