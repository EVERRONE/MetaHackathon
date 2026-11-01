import Foundation
import PipCore

/// Looking things up: when the guide is not sure of a fact (it adds a lookup tag), Pip searches
/// the web, the manufacturer's pages first, and answers from what it found, saying where from.
extension GuideModel {
    /// A slow search gets one "still looking" after this long (searches took 7–12 s on 1 Nov).
    static let lookupFillerAfter: TimeInterval = 10

    /// `question`: the user's words, or Pip's own turn ("(step 3)") when a step needed the fact.
    func lookUp(_ query: String, question: String) async {
        let shownBefore = preparing
        preparing = phrases.lookingUp
        defer { if preparing == phrases.lookingUp { preparing = shownBefore } }
        let known = facts.sorted { $0.key < $1.key }.filter { $0.value.source != "web" }.map { "\($0.key): \($0.value.value)" }
        let asked = question.hasPrefix("(") ? query : question
        let filler = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lookupFillerAfter * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.say(self.phrases.stillLookingUp)
        }
        let result: Result<WebLookup.Answer, Error>
        do {
            result = .success(try await WebLookup(client: client, language: language).answer(query, asked: asked, facts: known))
        } catch {
            result = .failure(error)
        }
        filler.cancel()
        // The user asked something else meanwhile: that question is answered instead.
        if Task.isCancelled { return }

        let directive: String
        var spokenWithoutView: String?
        switch result {
        case .success(let a) where a.found:
            let source = a.best
            let from = source.map { Self.describe($0) } ?? "a website Pip could not check"
            log(String(format: "lookup \"%@\": found in %.1fs from %@ (%d pages opened) · %@", query, a.seconds, source?.url ?? "no checked page", a.cited.count, a.answer))
            facts["online: \(query.prefix(80))"] = Fact(value: "\(a.answer) (from \(from))", source: "web")
            sessionLog.add(.lookedUp, step: runtime?.index, "\(query) → \(a.answer) (\(source?.url ?? "no checked source"))")
            directive = """
            The user asked: "\(asked)". Pip looked it up online and found, from \(from): "\(a.answer)" \
            Answer the user with this now, faithfully: keep every value, name, symbol and step exactly as found. \
            In your first sentence say where it comes from\(a.official ? ", like \"\(phrases.accordingTo(source?.publisher ?? "", manual: source?.isPDF == true))\"" : ", and that it is not from the manufacturer, so they should double-check"). \
            Point at a part it mentions if you can see it. Do not add a lookup tag.
            """
            spokenWithoutView = a.official ? "\(phrases.accordingTo(source?.publisher ?? "", manual: source?.isPDF == true)) \(a.answer)" : phrases.unverified(a.answer)
        case .success(let a):
            log(String(format: "lookup \"%@\": nothing reliable in %.1fs · %@", query, a.seconds, a.answer))
            sessionLog.add(.lookedUp, step: runtime?.index, "\(query) → nothing reliable found")
            directive = """
            The user asked: "\(asked)". Pip searched online for "\(query)" and found nothing reliable\(a.answer.isEmpty ? "" : " (\(a.answer))"). \
            Say so in one short sentence. Do not guess values or steps; say what would help instead, like the exact model from the type plate or the paper manual. \
            Do not add a lookup tag.
            """
        case .failure(let error):
            log("lookup \"\(query)\" failed: \(error)")
            directive = """
            The user asked: "\(asked)". Pip could not search online just now. Say so in one short sentence. \
            Do not guess values or steps; suggest trying again in a moment. Do not add a lookup tag.
            """
        }
        guard let snapshot = ar.snapshot() else {
            say(spokenWithoutView ?? phrases.lookupNothing)
            return
        }
        // A fresh look: the user may have moved, and the answer can point at what it names.
        await look(question, snapshot: snapshot, started: Date(), directive: directive, lookups: false)
    }

    /// "the official manual from Philips (dam.versuni.com)", for the model to name the source.
    static func describe(_ s: WebLookup.Source) -> String {
        let kind = s.isPDF ? "the manual" : "a page"
        let who = s.official ? "\(kind) from \(s.publisher), the manufacturer" : "\(kind) from \(s.publisher)"
        return "\(who) (\(s.host))"
    }
}
