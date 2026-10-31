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

    static let yesStarts: [[String]] = [
        ["ja"], ["jawel"], ["jazeker"], ["yes"], ["yeah"], ["yep"], ["sure"], ["ok"], ["okay"], ["oke"], ["prima"], ["goed"],
        ["zeker"], ["graag"], ["let's", "go"], ["lets", "go"], ["go", "ahead"], ["start"], ["begin"], ["doe", "maar"], ["of", "course"],
    ]
    /// Words that turn a yes into something else ("ja, maar…", "yes, but not…").
    static let qualifiers: Set<String> = ["maar", "but", "behalve", "except", "niet", "not", "nog", "geen", "no", "nee", "wacht", "wait", "eerst", "first"]

    /// "Yes, I'm in Settings now": an unqualified yes followed by more words. nil when the
    /// utterance does not start with yes or the rest qualifies it.
    public static func startsWithYes(_ text: String) -> Bool {
        let w = words(text)
        guard let start = yesStarts.first(where: { w.starts(with: $0) }) else { return false }
        return !w.dropFirst(start.count).contains(where: { qualifiers.contains($0) })
    }
}
