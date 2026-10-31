import Foundation

/// Short spoken commands during a task, recognised without a model call so they act at once.
/// A command is a command phrase plus filler words only ("ok, klaar", "ga terug alsjeblieft").
/// Anything with more to it ("next to the sink", "terug naar stap 2", "ja maar welke?") is a
/// question for the model, and a negation ("klopt niet", "nog niet klaar") is never a yes or done.
public enum Command: Equatable, Sendable {
    case done, back, repeatStep, skip, pause, resume, stop, yes, no

    static let phrases: [(Command, [String])] = [
        // Order matters: the first match wins, so more specific phrases come first.
        (.repeatStep, ["herhaal", "nog eens", "nog een keer", "wat moest ik doen", "repeat", "say again", "say that again", "again please", "what was it"]),
        (.skip, ["sla over", "sla deze over", "overslaan", "skip", "skip it", "skip this"]),
        (.stop, ["stop de taak", "stoppen", "annuleer", "annuleren", "cancel", "quit", "stop the task"]),
        (.back, ["vorige stap", "ga terug", "terug", "vorige", "go back", "previous step", "previous", "back"]),
        // A bare "stop" or "wacht" holds the task; it does not end it.
        (.pause, ["pauze", "wacht even", "even wachten", "wacht", "stop", "pause", "hold on", "wait a moment", "wait"]),
        (.resume, ["ga verder", "doe verder", "hervat", "resume", "continue", "carry on"]),
        (.done, ["klaar", "ik ben klaar", "gedaan", "gelukt", "het is gelukt", "dat is gebeurd", "volgende", "volgende stap", "verder",
                 "done", "i'm done", "finished", "i did it", "it's done", "next", "next step", "ok done"]),
        (.yes, ["ja", "jawel", "jazeker", "ja hoor", "inderdaad", "klopt", "dat klopt", "dat is zo", "zeker",
                "yes", "yeah", "yep", "yup", "correct", "that's right", "that's correct", "right", "it is", "sure"]),
        (.no, ["nee", "neen", "nope", "no"]),
    ]

    /// Words that may surround a command without changing it.
    static let fillers: Set<String> = [
        "ok", "okay", "oke", "ja", "yes", "pip", "hey", "please", "alsjeblieft", "aub", "even", "dan", "nu", "now", "then",
        "so", "zo", "oh", "the", "de", "het", "a", "een", "step", "stap", "deze", "this", "that", "dat", "dit", "eens",
        "ik", "ben", "i", "am", "i'm", "it", "it's", "that's", "is", "we", "let's", "gewoon", "just", "hoor", "well", "good", "goed",
    ]

    /// Negations: an utterance with one of these is never a yes or a done.
    static let negations: Set<String> = [
        "niet", "nee", "neen", "geen", "nooit", "niks", "niets", "not", "no", "nope", "never", "nah", "isn't", "isnt",
        "don't", "dont", "doesn't", "aren't", "wasn't", "won't", "can't", "cannot", "nothing",
    ]
    /// What a short negative answer may contain ("nog niet klaar", "it is not", "dat klopt niet").
    static let negativeAnswerWords: Set<String> = [
        "nog", "yet", "klaar", "done", "gedaan", "finished", "klopt", "right", "correct", "zo", "so", "really", "echt",
        "helemaal", "quite", "sorry", "wrong", "fout",
    ]

    /// The command in a short utterance, or nil if it is a question for the model.
    public static func parse(_ utterance: String) -> Command? {
        let words = Utterance.words(utterance)
        guard !words.isEmpty, words.count <= 5 else { return nil }
        // A number or a place is more than a command ("terug naar stap 2", "next to the sink").
        let places: Set<String> = ["naar", "naast", "in", "into", "onder", "boven", "achter", "under", "behind", "above", "below",
                                   "beside", "to", "met", "with", "bij", "van", "from", "of", "welke", "which", "waar", "where"]
        if words.contains(where: { places.contains($0) || $0.allSatisfy(\.isNumber) }) { return nil }
        let question = utterance.contains("?")

        if words.contains(where: { negations.contains($0) }) {
            // "nee", "nog niet", "klopt niet", "not done yet": a plain no. Anything else is for the model.
            let rest = words.filter { !negations.contains($0) && !fillers.contains($0) && !negativeAnswerWords.contains($0) }
            return rest.isEmpty && !question ? .no : nil
        }
        for (command, list) in phrases {
            // A question is only ever "what was it?" or "say again?".
            if question && command != .repeatStep { continue }
            for p in list {
                let phrase = p.split(separator: " ").map(String.init)
                guard let range = firstRange(of: phrase, in: words) else { continue }
                let rest = words[..<range.lowerBound] + words[range.upperBound...]
                if rest.allSatisfy({ fillers.contains($0) }) { return command }
            }
        }
        return nil
    }

    private static func firstRange(of phrase: [String], in words: [String]) -> Range<Int>? {
        guard phrase.count <= words.count else { return nil }
        for start in 0...(words.count - phrase.count) where Array(words[start..<start + phrase.count]) == phrase {
            return start..<start + phrase.count
        }
        return nil
    }
}
