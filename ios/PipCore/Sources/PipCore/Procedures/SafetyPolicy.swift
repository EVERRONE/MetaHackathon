import Foundation

/// Rules enforced in code, whatever a model says. Pip escalates instead of improvising.
public enum SafetyPolicy {
    public enum Classification: Equatable, Sendable {
        case allowed
        /// Allowed, with safety conditions the user must confirm before certain steps.
        case allowedWithGates
        case refused(reason: String)
    }

    /// Task kinds Pip never guides, with the professional to call instead.
    static let refusedKinds: [(words: [String], reason: String)] = [
        (["medicijn", "medicatie", "insuline", "dosis", "wonde", "verband", "reanimat", "symptoom", "pijn",
          "medication", "medicine", "insulin", "dose", "wound", "bandage", "symptom", "injury", "cpr"],
         "medical"),
        (["gasleiding", "gaslek", "gaskraan", "gasketel openen", "gasfornuis aansluiten", "gas pipe", "gas leak", "gas line", "gas valve", "connect the gas"],
         "gas"),
        (["bedrading", "stopcontact vervangen", "stopcontact aansluiten", "schakelaar aansluiten", "lichtpunt aansluiten",
          "zekeringkast openen", "verdeelkast openen", "onder spanning", "rewire", "wiring", "replace a socket", "replace an outlet",
          "install a light fixture", "open the fuse box", "open the consumer unit", "live wire", "mains"],
         "mains"),
        (["draagmuur", "dragende muur", "steunbalk", "load-bearing", "structural beam"],
         "structural"),
    ]

    /// Electrical or pressurised work that is fine with a confirmed safety condition first.
    static let gatedWords = ["zekering", "automaat", "differentieel", "verliesschakelaar", "ketel", "boiler", "lift", "elektr",
                             "breaker", "fuse", "rcd", "boiler", "water heater", "elevator", "electric"]

    public static func classify(_ goal: String) -> Classification {
        let text = goal.lowercased()
        for kind in refusedKinds where kind.words.contains(where: { text.contains($0) }) {
            return .refused(reason: kind.reason)
        }
        return gatedWords.contains(where: { text.contains($0) }) ? .allowedWithGates : .allowed
    }

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
        let text = hazard.lowercased()
        let electrical = ["vonk", "spark", "rook", "smoke", "brand", "burn", "draad", "wire", "water", "electr", "elektr"].contains { text.contains($0) }
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
    static let spokenHazards = ["rook", "vonk", "brandgeur", "het brandt", "gaslucht", "ruik gas", "schok gekregen", "ik ben gewond", "bloed",
                                "smoke", "spark", "burning smell", "on fire", "smell gas", "got a shock", "i'm hurt", "bleeding"]

    public static func spokenHazard(in utterance: String) -> String? {
        let text = utterance.lowercased()
        return spokenHazards.first { text.contains($0) }
    }
}
