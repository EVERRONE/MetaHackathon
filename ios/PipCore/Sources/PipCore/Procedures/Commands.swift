import Foundation

/// Short spoken commands during a task, recognised without a model call so they act at once.
/// Anything longer than a few words is a question for the model, not a command.
public enum Command: Equatable, Sendable {
    case done, back, repeatStep, skip, pause, resume, stop, yes, no

    static let phrases: [(Command, [String])] = [
        // Order matters: the first match wins, so more specific phrases come first.
        (.repeatStep, ["herhaal", "nog eens", "nog een keer", "wat moest ik doen", "repeat", "say again", "again please", "what was it"]),
        (.skip, ["sla over", "overslaan", "skip", "skip it", "skip this"]),
        (.back, ["vorige stap", "ga terug", "terug", "vorige", "go back", "previous step", "previous", "back"]),
        (.pause, ["pauze", "wacht even", "even wachten", "pause", "hold on", "wait a moment"]),
        (.resume, ["ga verder", "doe verder", "hervat", "resume", "continue", "carry on"]),
        (.stop, ["stop de taak", "stoppen", "annuleer", "cancel", "quit", "stop the task"]),
        (.done, ["klaar", "gedaan", "gelukt", "het is gelukt", "dat is gebeurd", "volgende", "volgende stap", "verder",
                 "done", "finished", "i did it", "it's done", "next", "next step", "ok done"]),
        (.yes, ["ja", "jawel", "jazeker", "klopt", "inderdaad", "dat is zo", "ja hoor", "yes", "yeah", "yep", "correct", "it is", "right"]),
        (.no, ["nee", "neen", "nog niet", "niet", "no", "nope", "not yet", "it isn't", "it is not"]),
    ]

    /// The command in a short utterance, or nil if it is a question for the model.
    public static func parse(_ utterance: String) -> Command? {
        let words = utterance.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        guard !words.isEmpty, words.count <= 5 else { return nil }
        let text = " " + words.joined(separator: " ") + " "
        for (command, list) in phrases {
            for p in list where text.contains(" " + p + " ") {
                // "nee, de linker" is an answer with more to it: leave that to the model.
                if (command == .yes || command == .no), words.count > 3 { continue }
                return command
            }
        }
        return nil
    }
}
