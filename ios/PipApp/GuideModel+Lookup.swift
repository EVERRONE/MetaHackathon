import Foundation
import PipCore

/// Looking things up: when the answer depends on a product fact the guide does not know (it starts
/// its reply with a lookup tag), Pip searches the web, the manufacturer's pages first, and answers
/// from what it found, saying where from and for which products it holds.
extension GuideModel {
    /// A slow search gets one "still looking" after this long (searches took 8–26 s on 2 Nov).
    static let lookupFillerAfter: TimeInterval = 10

    /// What the screen shows of a search: under way, then the result. It stays up while Pip
    /// answers, and goes at the user's next question or after `searchCardKept`.
    struct SearchCard: Equatable {
        enum State: Equatable {
            case searching
            /// `holds`: for which products, as the card says it ("algemeen voor LG-wasmachines").
            case found(publisher: String, host: String, holds: String, official: Bool)
            /// `otherModels`: only sources for other models turned up.
            case nothing(otherModels: Bool)
            case failed
        }
        var asked: String
        var started: Date
        var state: State
    }

    /// How long the card with the result stays up (the answer takes 5–15 s to say).
    static let searchCardKept: TimeInterval = 30

    /// A search under way. It starts as soon as the model asks for it, while the model's turn is
    /// still streaming, and is answered once that turn is over.
    final class Search {
        let query: String
        /// The user's words, or the query itself for Pip's own turns.
        let asked: String
        let task: Task<Result<WebLookup.Answer, Error>, Never>
        var filler: Task<Void, Never>?
        let started = Date()

        init(query: String, asked: String, task: Task<Result<WebLookup.Answer, Error>, Never>) {
            self.query = query
            self.asked = asked
            self.task = task
        }

        func cancel() {
            task.cancel()
            filler?.cancel()
        }
    }

    /// `question`: the user's words, or Pip's own turn ("(step 3)") when a step needed the fact.
    func startSearch(_ query: String, question: String) -> Search {
        let known = facts.sorted { $0.key < $1.key }.filter { $0.value.source != "web" }.map { "\($0.key): \($0.value.value)" }
        let asked = question.hasPrefix("(") ? query : question
        let lookup = WebLookup(client: client, language: language)
        let task = Task { () -> Result<WebLookup.Answer, Error> in
            do { return .success(try await lookup.answer(query, asked: asked, facts: known)) } catch { return .failure(error) }
        }
        let search = Search(query: query, asked: asked, task: task)
        // The user's own words on the card; Pip's own turns show the question it searches.
        searchCard = SearchCard(asked: question.hasPrefix("(") ? query : question, started: search.started, state: .searching)
        search.filler = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lookupFillerAfter * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.say(self.phrases.stillLookingUp)
        }
        return search
    }

    /// Answers from the search once it is done. `saidBefore`: what Pip said in this turn before
    /// the model asked to look it up (a first guess, when the model did not start with the tag).
    func lookUp(_ search: Search, question: String, saidBefore: [String]) async {
        // The user asked something else meanwhile, or stopped Pip: the search is dropped.
        let result = await withTaskCancellationHandler { await search.task.value } onCancel: { search.cancel() }
        search.filler?.cancel()
        if Task.isCancelled {
            if searchCard?.started == search.started { searchCard = nil }
            return
        }
        showResult(result, of: search)
        let query = search.query, asked = search.asked

        var lines: [String] = []
        var spokenWithoutView: String?
        let earlier = saidBefore.joined(separator: " ")
        switch result {
        case .success(let a) where a.found:
            let source = a.best
            let from = source.map { Self.describe($0) } ?? "a website Pip could not check"
            let holds = Self.holds(a, publisher: source?.publisher)
            log(String(format: "lookup \"%@\": found in %.1fs from %@ (%d pages opened), holds for %@ (%@) · %@",
                       query, a.seconds, source?.url ?? "no checked page", a.cited.count, a.scope.rawValue, a.about, a.answer))
            facts["online: \(query.prefix(80))"] = Fact(value: "\(a.answer) (from \(from); \(holds))", source: "web")
            sessionLog.add(.lookedUp, step: runtime?.index, "\(query) → \(a.answer) (\(source?.url ?? "no checked source"); \(a.scope.rawValue))")
            lines = [
                "The user asked: \"\(asked)\". Pip looked it up online and found, from \(from), which \(holds): \"\(a.answer)\"",
                "Answer the user with this now, faithfully: keep every value, name, symbol and step exactly as found, and add nothing from your own knowledge.",
                "In your first sentence say where it comes from" + (a.official
                    ? ", like \"\(phrases.accordingTo(source?.publisher ?? "", manual: source?.isPDF == true))\"."
                    : ", and that it is not from the manufacturer, so they should double-check."),
            ]
            if a.scope == .range || a.scope == .brand {
                lines.append("Say in a few words that it is what the source gives for \(a.about.isEmpty ? "these products in general" : a.about), not specifically for this model. If you do not know the exact model yet (it is not under what you know, and the user did not say they cannot find the type plate), offer once to check it for their model when they show you the type plate.")
            }
            lines.append("Compare it with what you see now: where the image shows something different (a part on the other side, another label or button), say so and go by what you see. Point only at what is really there.")
            if !earlier.isEmpty {
                lines.append("Before searching you already said: \"\(earlier)\". If that differs from what was found, say plainly that it was not right, then give what was found.")
            }
            lines.append("Point at a part it mentions if you can see it. Do not add a lookup tag.")
            let qualified = (a.scope == .range || a.scope == .brand) ? " " + phrases.notThisModel(a.about) : ""
            spokenWithoutView = (a.official ? "\(phrases.accordingTo(source?.publisher ?? "", manual: source?.isPDF == true)) \(a.answer)" : phrases.unverified(a.answer)) + qualified
        case .success(let a):
            let otherModel = a.scope == .otherModel
            log(String(format: "lookup \"%@\": nothing reliable in %.1fs%@ · %@", query, a.seconds, otherModel ? " (only other models: \(a.about))" : "", a.answer))
            sessionLog.add(.lookedUp, step: runtime?.index, "\(query) → nothing reliable found" + (otherModel ? " (only other models: \(a.about))" : ""))
            // What another model's manual says is not repeated: it may be wrong for this one.
            let why = otherModel ? "it only found sources for other models (\(a.about)), which can differ" : (a.answer.isEmpty ? "" : a.answer)
            lines = [
                "The user asked: \"\(asked)\". Pip searched online for \"\(query)\" and found nothing reliable for this product\(why.isEmpty ? "" : " (\(why))").",
                "Say so in one short sentence. Do not guess values or steps, and do not say what other models do.",
                "If you do not know the exact model yet (it is not under what you know) and the user did not say they cannot find the type plate, ask to see it and say where it usually is. Otherwise suggest the paper manual or the manufacturer's service.",
            ]
            if !earlier.isEmpty { lines.append("Before searching you already said: \"\(earlier)\". Say plainly that this is not confirmed.") }
            lines.append("Do not add a lookup tag.")
        case .failure(let error):
            log("lookup \"\(query)\" failed: \(error)")
            lines = [
                "The user asked: \"\(asked)\". Pip could not search online just now. Say so in one short sentence.",
                "Do not guess values or steps; suggest trying again in a moment.",
            ]
            if !earlier.isEmpty { lines.append("Before searching you already said: \"\(earlier)\". Say plainly that this is not confirmed.") }
            lines.append("Do not add a lookup tag.")
        }
        guard let snapshot = ar.snapshot() else {
            say(spokenWithoutView ?? phrases.lookupNothing)
            return
        }
        // A fresh look: the user may have moved, and the answer can point at what it names.
        await look(question, snapshot: snapshot, started: Date(), directive: lines.joined(separator: " "), lookups: false)
    }

    /// The card shows what was found, then goes after a while unless a newer search replaced it.
    private func showResult(_ result: Result<WebLookup.Answer, Error>, of search: Search) {
        guard searchCard?.started == search.started else { return }
        let state: SearchCard.State
        switch result {
        case .success(let a) where a.found:
            let source = a.best
            state = .found(publisher: source?.publisher ?? a.about, host: source?.host ?? "",
                           holds: phrases.holds(a.scope, about: a.about), official: a.official)
        case .success(let a): state = .nothing(otherModels: a.scope == .otherModel)
        case .failure: state = .failed
        }
        searchCard?.state = state
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.searchCardKept * 1_000_000_000))
            guard let self, self.searchCard?.started == search.started else { return }
            self.searchCard = nil
        }
    }

    /// "the official manual from Philips (dam.versuni.com)", for the model to name the source.
    static func describe(_ s: WebLookup.Source) -> String {
        let kind = s.isPDF ? "the manual" : "a page"
        let who = s.official ? "\(kind) from \(s.publisher), the manufacturer" : "\(kind) from \(s.publisher)"
        return "\(who) (\(s.host))"
    }

    /// For which products the answer holds, as the model reads it in the directive.
    static func holds(_ a: WebLookup.Answer, publisher: String?) -> String {
        let about = a.about.isEmpty ? nil : a.about
        switch a.scope {
        case .exactModel: return "is for this exact model" + (about.map { " (\($0))" } ?? "")
        case .range: return "is for the range \(about ?? "this model belongs to"), not specifically this model"
        case .brand: return "is what \(publisher ?? "the manufacturer") gives for \(about ?? "all its products of this kind"), not specifically this model"
        case .general: return "holds for any such device"
        case .otherModel: return "is for another model" + (about.map { " (\($0))" } ?? "")
        }
    }
}
