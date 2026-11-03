import Foundation

/// Quick reads of what the user said that need no model call: the language they speak, a plain
/// acknowledgement ("okay", "thanks") that needs no look, and an answer that starts with yes.
public enum Utterance {
    /// Lower-case words without accents; apostrophes stay ("it's").
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    // Function words only one of the two languages has ("of", "is", "in", "we", "me" and "die" are
    // in both, so they count for neither).
    static let dutchWords: Set<String> = [
        "ik", "je", "jij", "jou", "jouw", "u", "uw", "de", "het", "een", "niet", "geen", "wat", "hoe", "waar", "wanneer",
        "waarom", "welke", "welk", "mijn", "dat", "dit", "deze", "van", "en", "op", "met", "voor", "naar", "zijn", "ben",
        "bent", "kan", "kun", "kunt", "moet", "moeten", "wil", "wilt", "heb", "hebt", "heeft", "er", "maar", "ook", "nog",
        "wel", "om", "zo", "als", "dan", "hier", "daar", "nu", "toch", "even", "ja", "nee", "neen", "alsjeblieft", "bedankt",
        "dank", "mag", "laat", "toon", "zie", "zoek", "gaat", "doe", "wordt", "kunnen", "zou", "hoeveel", "eerst",
        "waarmee", "staat", "ligt", "gelegd", "gezet", "zet", "leg", "klaar", "gedaan", "volgende", "vorige", "zeg",
    ]
    static let englishWords: Set<String> = [
        "i", "you", "your", "the", "a", "an", "not", "what", "how", "where", "when", "why", "which", "my", "that", "this",
        "these", "those", "and", "on", "with", "for", "to", "are", "am", "can", "could", "should", "must", "want", "have",
        "has", "there", "but", "also", "still", "so", "if", "then", "here", "now", "please", "yes", "no", "thanks", "thank",
        "do", "does", "did", "it", "it's", "i'm", "show", "find", "where's", "what's", "let", "get", "got", "will", "would",
        "just", "don't", "can't", "put", "left", "next", "first", "say", "done", "from", "at", "be", "was", "were",
    ]

    /// "Dutch" or "English" when the words clearly say so; nil for short or mixed utterances
    /// ("Mac," or a product name), so one word never switches the conversation.
    /// How much `heard` reads like some stretch of `said`, letter by letter (1: exactly a stretch of
    /// it). Pip's own voice comes back through the microphone with the speech service's mistakes:
    /// "I point the" for its "I point that way" (3 Nov), one word off, so a comparison by whole words
    /// took it for the user and Pip answered itself.
    public static func likeness(_ heard: String, within said: String) -> Double {
        let a = Array(words(heard).joined(separator: " ")), b = Array(words(said).joined(separator: " "))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        // The fewest edits from `a` to any stretch of `b` (free start and end in `b`).
        var previous = Array(0...a.count), column = [Int](repeating: 0, count: a.count + 1)
        var best = a.count
        for j in 1...b.count {
            column[0] = 0
            for i in 1...a.count {
                column[i] = min(previous[i] + 1, column[i - 1] + 1, previous[i - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            best = min(best, column[a.count])
            swap(&previous, &column)
        }
        return 1 - Double(best) / Double(a.count)
    }

    public static func language(of text: String) -> String? {
        let w = words(text)
        let d = w.filter { dutchWords.contains($0) }.count
        let e = w.filter { englishWords.contains($0) }.count
        if d >= 2, d >= 2 * e + 1 { return "Dutch" }
        if e >= 2, e >= 2 * d + 1 { return "English" }
        return nil
    }

    public enum Acknowledgement: Equatable, Sendable {
        /// "Okay", "great": the user heard Pip. Nothing to answer.
        case okay
        /// "Thank you": a short reply, no look.
        case thanks
    }

    static let ackWords: Set<String> = [
        "ok", "okay", "oke", "okey", "okidoki", "alright", "all", "right", "great", "good", "nice", "cool", "super", "top",
        "perfect", "perfekt", "fine", "prima", "goed", "mooi", "fijn", "oh", "ah", "aha", "mm", "hm", "hmm", "zo",
        "so", "thanks", "thank", "you", "very", "much", "a", "lot", "bedankt", "dank", "je", "u", "wel", "dankjewel",
        "dankuwel", "merci", "cheers", "awesome", "lovely", "wow", "allright", "allez", "akkoord", "tof", "heel", "erg",
    ]
    static let thanksWords: Set<String> = ["thanks", "thank", "bedankt", "dank", "dankjewel", "dankuwel", "merci", "cheers"]

    /// The utterance is only an acknowledgement: no question, no request.
    public static func acknowledgement(_ text: String) -> Acknowledgement? {
        let w = words(text)
        guard !w.isEmpty, w.count <= 6, w.allSatisfy({ ackWords.contains($0) }) else { return nil }
        // "you" or "a lot" alone are no acknowledgement.
        guard w.contains(where: { !["you", "a", "lot", "very", "much", "je", "u", "wel", "all", "right", "so", "zo", "heel", "erg"].contains($0) })
            || w == ["all", "right"] else { return nil }
        return w.contains(where: { thanksWords.contains($0) }) ? .thanks : .okay
    }

    /// A plain yes, or a go-ahead.
    static let yesStarts: [[String]] = [
        ["ja"], ["jawel"], ["jazeker"], ["yes"], ["yeah"], ["yep"], ["yup"], ["zeker"], ["graag"], ["klopt"], ["correct"],
        ["let's", "go"], ["lets", "go"], ["let's", "do", "it"], ["lets", "do", "it"], ["let's", "start"], ["lets", "start"],
        ["go", "ahead"], ["start", "maar"], ["begin", "maar"], ["start"], ["begin"], ["doe", "maar"], ["ga", "maar"], ["ga", "je", "gang"],
        ["of", "course"],
    ]
    /// As much "I heard you" as yes: "okay, let me check" has not answered anything yet, so after
    /// these only a plain yes ("oké, doe maar") or filler ("oké dan") may follow.
    static let weakYesStarts: [[String]] = [["ok"], ["okay"], ["oke"], ["okey"], ["sure"], ["prima"], ["goed"], ["alright"], ["fine"]]
    static let fillers: Set<String> = ["dan", "then", "hoor", "he", "hey", "great", "good", "fine", "perfect", "prima", "goed",
                                       "mooi", "top", "super", "cool", "nice", "thanks", "bedankt", "merci"]
    /// Words that turn a yes into something else: a but or a not ("ja, maar…", "yeah, I don't think
    /// so", "yes, it's still on"), a doubt ("ja, denk het"), or a promise instead of an answer
    /// ("yes, let me check", "ja, momentje", "ja, ik zal het doen"). Words ending in n't count too.
    static let qualifiers: Set<String> = [
        "maar", "but", "behalve", "except", "niet", "not", "nog", "geen", "no", "nee", "none", "never", "nooit", "nothing",
        "niks", "niets", "still", "yet", "wacht", "wait", "eerst", "first", "if", "unless", "tenzij",
        "think", "denk", "guess", "maybe", "misschien", "probably", "waarschijnlijk", "perhaps", "believe", "geloof", "hope",
        "hoop", "hopelijk", "hopefully", "almost", "bijna", "nearly",
        "let", "let's", "lets", "lemme", "check", "kijken", "kijk", "moment", "momentje", "sec", "second", "seconde",
        "secondje", "minute", "minuutje", "hold", "straks", "later", "soon", "dadelijk", "zometeen", "try", "probeer",
        "going", "gonna", "will", "i'll", "zal", "ga",
    ]
    /// Words that make the rest a question ("okay, where is the breaker?"): no answer to anything.
    static let questionWords: Set<String> = ["where", "where's", "what", "what's", "which", "how", "why", "when", "who",
                                             "waar", "wat", "welke", "welk", "hoe", "waarom", "wanneer", "wie", "hoeveel"]

    /// "Yes, I'm in Settings now": an unqualified yes, maybe followed by more words. False when
    /// the utterance does not start with yes, the rest qualifies it, it is a question, or only a
    /// weak "okay" starts something else ("okay, let me check").
    public static func startsWithYes(_ text: String) -> Bool {
        guard !text.contains("?") else { return false }
        var rest = ArraySlice(words(text))
        var plain = false, weak = false
        while true {
            if let start = yesStarts.first(where: { rest.starts(with: $0) }) {
                rest = rest.dropFirst(start.count)
                plain = true
            } else if let start = weakYesStarts.first(where: { rest.starts(with: $0) }) {
                rest = rest.dropFirst(start.count)
                weak = true
            } else {
                break
            }
        }
        if !plain { return weak && rest.allSatisfy { fillers.contains($0) } }
        return !rest.contains { qualifiers.contains($0) || questionWords.contains($0) || $0.hasSuffix("n't") }
    }
}
