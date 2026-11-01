import Foundation

/// Rules enforced in code, whatever a model says. Pip escalates instead of improvising.
///
/// Matching is on whole words and phrases, never substrings ("remains" is not "mains", a
/// "rookmelder" is no smoke). A keyword ending in `*` matches words that start with it.
public enum SafetyPolicy {
    public enum Classification: Equatable, Sendable {
        case allowed
        /// Allowed, with safety conditions the user must confirm before certain steps.
        case allowedWithGates
        case refused(reason: String)
    }

    /// The reasons Pip gives for refusing; the compiler's schema uses the same words.
    public static let refusalReasons = ["medical", "gas", "mains", "structural", "other"]

    /// Task kinds Pip never guides, with the professional to call instead.
    static let refusedKinds: [(words: [String], reason: String)] = [
        (["medicijn", "medicijnen", "medicatie", "insuline", "dosis", "doseren medicijn*", "wonde", "wond", "verband aanleggen",
          "een verband", "reanimat*", "symptoom", "symptomen", "pijn",
          "medication", "medicine", "medicines", "insulin", "dose", "dosage", "wound", "bandage", "symptom", "symptoms", "injury", "cpr"],
         "medical"),
        (["gasleiding", "gaslek", "gaskraan", "gasketel openen", "gasfornuis aansluiten", "gas aansluiten", "gasmeter",
          "gas pipe", "gas leak", "gas line", "gas valve", "connect the gas", "gas meter"],
         "gas"),
        (["bedrading", "zekeringkast openen", "verdeelkast openen", "onder spanning", "rewire", "rewiring", "wiring", "live wire", "mains",
          "open the fuse box", "open the consumer unit"],
         "mains"),
        (["draagmuur", "dragende muur", "steunbalk", "load-bearing", "load bearing", "structural beam"],
         "structural"),
    ]

    /// Mains work written as a verb and an object in any order ("vervang het stopcontact",
    /// "replace the outlet", "install a ceiling light").
    static let mainsObjects = ["stopcontact", "stopcontacten", "wandcontactdoos", "lichtschakelaar", "schakelaar", "lichtpunt",
                               "plafondlamp", "plafonnière", "outlet", "outlets", "socket", "sockets", "light switch", "ceiling light",
                               "light fixture", "wall switch"]
    static let mainsVerbs = ["vervang*", "replace*", "install*", "installeer*", "aansluit*", "aansluiten", "sluit", "connect*", "wire",
                             "bedraad*", "plaats*", "monteer*", "swap", "change"]
    /// Phrases that make a keyword harmless.
    static let harmless = ["medicine cabinet", "medicijnkast*", "doorbell wiring", "speaker wiring", "network wiring", "low voltage",
                           "laagspanning", "deurbel*", "luidspreker*", "usb", "smoke alarm", "smoke alarms", "smoke detector",
                           "smoke detectors", "spark plug", "spark plugs", "bougie*", "rookmelder*", "in verband met"]

    /// Electrical or pressurised work that is fine with a confirmed safety condition first.
    static let gatedWords = ["zekering*", "automaat", "automaten", "differentieel", "verliesschakelaar", "ketel", "boiler", "liftinstallatie",
                             "elektr*", "breaker", "breakers", "fuse", "fuses", "rcd", "water heater", "elevator", "electric*", "stroom*"]

    // MARK: Matching

    /// The text as lower-case words with single spaces, padded so phrases match on word boundaries.
    static func normalized(_ text: String) -> [String] { Utterance.words(text) }

    /// A keyword's words, folded like the user's (lower case, no accents: "plafonnière" must
    /// match the spoken "plafonniere"). A trailing `*` stays.
    static func keywordParts(_ keyword: String) -> [String] {
        keyword.lowercased().folding(options: .diacriticInsensitive, locale: nil).split(separator: " ").map(String.init)
    }

    /// Whether `keyword` (a word, a phrase, or a prefix ending in `*`) occurs in `words`.
    static func contains(_ words: [String], _ keyword: String) -> Bool {
        let parts = keywordParts(keyword)
        guard !parts.isEmpty, parts.count <= words.count else { return false }
        for start in 0...(words.count - parts.count) {
            var all = true
            for (k, part) in parts.enumerated() {
                let w = words[start + k]
                let hit = part.hasSuffix("*") ? w.hasPrefix(String(part.dropLast())) : w == part
                if !hit { all = false; break }
            }
            if all { return true }
        }
        return false
    }

    /// `words` with harmless phrases blanked out.
    static func withoutHarmless(_ words: [String]) -> [String] {
        var out = words
        for phrase in harmless {
            let parts = keywordParts(phrase)
            guard parts.count <= out.count else { continue }
            for start in 0...(out.count - parts.count) {
                let hit = parts.enumerated().allSatisfy { k, part in
                    part.hasSuffix("*") ? out[start + k].hasPrefix(String(part.dropLast())) : out[start + k] == part
                }
                if hit { for k in 0..<parts.count { out[start + k] = "_" } }
            }
        }
        return out
    }

    public static func classify(_ goal: String) -> Classification {
        let words = withoutHarmless(normalized(goal))
        for kind in refusedKinds where kind.words.contains(where: { contains(words, $0) }) {
            return .refused(reason: kind.reason)
        }
        if mainsObjects.contains(where: { contains(words, $0) }), mainsVerbs.contains(where: { contains(words, $0) }) {
            return .refused(reason: "mains")
        }
        if gatedWords.contains(where: { contains(words, $0) }) { return .allowedWithGates }
        // In Dutch a "lift" is an elevator; in English it is only a verb.
        if contains(words, "lift"), Utterance.language(of: goal) == "Dutch" { return .allowedWithGates }
        return .allowed
    }

    // MARK: What Pip says

    /// What Pip says when it will not guide a task.
    public static func refusal(_ reason: String, language: String) -> String {
        let dutch = language.lowercased() == "dutch"
        switch reason {
        case "medical":
            return dutch ? "Daar help ik niet mee: dat is een medische vraag. Bel je huisarts, of 112 bij nood."
                         : "I can't help with that: it's a medical question. Call your doctor, or the emergency number if it is urgent."
        case "gas":
            return dutch ? "Aan gas werk ik niet mee. Bel een erkend installateur. Ruik je gas: verlaat het huis en bel 112."
                         : "I don't guide gas work. Call a certified installer. If you smell gas, leave the building and call the emergency number."
        case "mains":
            return dutch ? "Werken aan bedrading onder netspanning laat je aan een elektricien. Ik kan wel helpen met zekeringen en de verliesschakelaar."
                         : "Work on mains wiring is for an electrician. I can help with breakers and the RCD."
        default:
            return dutch ? "Dit is werk voor een vakman. Daar begeleid ik je niet bij."
                         : "This is a job for a professional. I won't guide it."
        }
    }

    /// What Pip says when a hazard is seen or mentioned: stop, step back, who to call.
    public static func escalation(_ hazard: String, language: String) -> String {
        let dutch = language.lowercased() == "dutch"
        let words = normalized(hazard)
        let electrical = ["vonk*", "spark*", "rook", "smoke", "brand*", "burn*", "draad", "draden", "wire*", "water", "electr*", "elektr*", "schok", "shock*"]
            .contains { contains(words, $0) }
        if dutch {
            return "Stop. Raak niets meer aan. " + (electrical
                ? "Schakel als het veilig kan de hoofdschakelaar uit en bel een elektricien. Bij brand of rook: 112."
                : "Ga op een veilige afstand staan en bel een vakman. Bij gevaar: 112.")
        }
        return "Stop. Don't touch anything else. " + (electrical
            ? "If it is safe, switch off the main switch and call an electrician. With fire or smoke, call the emergency number."
            : "Step back to a safe distance and call a professional. If anyone is in danger, call the emergency number.")
    }

    /// Words in the user's speech that stop the task at once.
    static let spokenHazards = ["rook", "rookt", "vonk", "vonken", "vonkt", "brandgeur", "brandlucht", "schroeilucht", "er is brand",
                                "in brand", "vlammen", "gaslucht", "gaslek", "ruik gas", "rook gas", "gas lekt", "schok gekregen",
                                "een schok", "elektrische schok", "kreeg stroom", "krijg stroom", "stroom gekregen", "geelektrocuteerd",
                                "ik ben gewond", "gewond", "bloed", "bloedt",
                                "smoke", "smoking", "sparks", "spark", "sparking", "burning smell", "smells burnt", "smells like burning",
                                "on fire", "caught fire", "a fire", "flames", "smell gas", "gas leak", "got a shock", "electric shock",
                                "shocked me", "got shocked", "get shocked", "getting shocked", "electrocuted",
                                "i'm hurt", "im hurt", "i am hurt", "injured", "bleeding"]
    /// A smell of gas or of burning, in either order within the clause: "it smells like gas", "I
    /// smell burning", "ik ruik iets branden", "ik denk dat het naar gas ruikt".
    static let smellWords: Set<String> = ["smell", "smells", "smelling", "smelled", "stink", "stinks", "ruik", "ruikt", "ruiken",
                                          "riekt", "rieken", "stinkt"]
    static let smelled: [String: String] = [
        "gas": "gaslucht",
        "burning": "brandgeur", "burnt": "brandgeur", "burned": "brandgeur", "burn": "brandgeur", "brand": "brandgeur",
        "branden": "brandgeur", "brandt": "brandgeur", "verbrand": "brandgeur", "aangebrand": "brandgeur",
        "geschroeid": "brandgeur", "schroeien": "brandgeur",
    ]
    /// A negation of the hazard: right before it, or with at most two of these between ("no smoke",
    /// "there isn't any smoke", "geen enkele vonk", "I can't see any smoke", "it doesn't smell like
    /// smoke"). Further away it is about something else: "ik weet niet waarom het vonkt".
    static let negations: Set<String> = ["geen", "niet", "niks", "niets", "no", "not", "never", "nothing", "zonder", "without"]
    static let negationFillers: Set<String> = ["any", "more", "a", "single", "real", "visible", "like", "see", "smell", "notice",
                                               "hear", "feel", "enkele", "meer", "een", "echte", "zichtbare", "naar", "zie", "ruik",
                                               "hoor", "voel"]
    /// A negation right after it, which only Dutch word order has ("ik rook niks", "het vonkt niet").
    /// Only the very next word: in "de rook gaat niet weg" the "niet" is about going away. In
    /// English a "not" after the hazard contrasts it ("smoke, not steam"): still a hazard.
    static let negationsAfter: Set<String> = ["niet", "niks", "niets"]

    public static func spokenHazard(in utterance: String) -> String? {
        // A negation counts only in the hazard's own clause: "no smoke" is calm, but in "Oh no,
        // sparks!" or "No! It's on fire" the "no" is a cry, not a negation.
        let clauses = utterance.split(whereSeparator: { ".,!?;:…\n".contains($0) })
        for clause in clauses {
            if let hazard = spokenHazard(inClause: withoutHarmless(normalized(String(clause)))) { return hazard }
        }
        return nil
    }

    private static func spokenHazard(inClause words: [String]) -> String? {
        for hazard in spokenHazards {
            let parts = hazard.split(separator: " ").map(String.init)
            guard parts.count <= words.count else { continue }
            for start in 0...(words.count - parts.count) where Array(words[start..<start + parts.count]) == parts {
                let end = start + parts.count
                // "geen rook", "no smoke", "ik rook niks": not a hazard.
                if negated(words, before: start) || (end < words.count && negationsAfter.contains(words[end])) { continue }
                return hazard
            }
        }
        for (g, word) in words.enumerated() {
            // "smells brand new" is no fire.
            guard let hazard = smelled[word], !(word == "brand" && g + 1 < words.count && words[g + 1] == "new") else { continue }
            for s in words.indices where smellWords.contains(words[s]) {
                let lo = min(s, g), hi = max(s, g)
                // "ik ruik geen gas", "it doesn't smell like gas": calm.
                if words[lo...hi].contains(where: isNegation) || negated(words, before: lo) { continue }
                return hazard
            }
        }
        return nil
    }

    static func isNegation(_ word: String) -> Bool { negations.contains(word) || word.hasSuffix("n't") }

    /// Whether the words just before `index` negate what starts there. "Oh no" is a cry.
    static func negated(_ words: [String], before index: Int) -> Bool {
        var i = index - 1, between = 0
        while i >= 0 {
            if isNegation(words[i]) { return !(words[i] == "no" && i > 0 && words[i - 1] == "oh") }
            guard between < 2, negationFillers.contains(words[i]) else { return false }
            between += 1
            i -= 1
        }
        return false
    }
}
