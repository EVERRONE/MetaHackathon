import Foundation

/// A cue bound to the word it should appear with.
public struct TimedCue: Equatable, Sendable {
    public var cue: Cue
    /// UTF-16 offset in the sentence's clean text where the bound word starts.
    public var anchor: Int
    public var raw: String
}

/// One sentence ready to speak: clean text plus the cues to show while it is spoken.
public struct SpokenSentence: Equatable, Sendable {
    public var text: String
    public var cues: [TimedCue]
}

public enum CueStreamEvent: Equatable, Sendable {
    case sentence(SpokenSentence)
    /// `[[state]]`, `[[locate]]` and `[[need_view]]`: for the runtime, not drawn.
    case sideChannel(Cue, raw: String)
    case invalidTag(CueError)
}

/// Turns Spark's streamed text with inline `[[cue]]` tags into speakable sentences.
///
/// - Tags are removed from the spoken text.
/// - A drawn cue binds to the next word after the tag. If no word follows in the same
///   sentence, it binds to the sentence's last word, so it is never shown late.
/// - Sentences end at `.`, `!`, `?` or `…` followed by whitespace, or at a newline.
/// - Partial tags split across stream chunks are held until complete.
public struct CueStreamParser: Sendable {
    private var pending = ""
    private var text = ""
    private var cues: [TimedCue] = []

    public init() {}

    public mutating func feed(_ delta: String) -> [CueStreamEvent] {
        pending += delta
        var events: [CueStreamEvent] = []
        while !pending.isEmpty {
            guard let open = pending.range(of: "[[") else {
                // Hold a trailing "[" that may start a tag in the next chunk.
                if pending.hasSuffix("[") {
                    appendText(String(pending.dropLast()), into: &events)
                    pending = "["
                } else {
                    appendText(pending, into: &events)
                    pending = ""
                }
                break
            }
            appendText(String(pending[..<open.lowerBound]), into: &events)
            guard let close = pending.range(of: "]]", range: open.upperBound..<pending.endIndex) else {
                pending = String(pending[open.lowerBound...])
                // A runaway tag is not a tag: give up after a generous length.
                if pending.count > 240 {
                    events.append(.invalidTag(CueError(raw: String(pending.prefix(40)) + "…", reason: "unterminated tag")))
                    pending = String(pending.dropFirst(2))
                    continue
                }
                break
            }
            let body = String(pending[open.upperBound..<close.lowerBound])
            pending = String(pending[close.upperBound...])
            handleTag(body, into: &events)
        }
        return events
    }

    /// Flushes the rest of the stream as a final sentence.
    public mutating func finish() -> [CueStreamEvent] {
        var events: [CueStreamEvent] = []
        if !pending.isEmpty {
            if pending.hasPrefix("[[") {
                events.append(.invalidTag(CueError(raw: pending, reason: "unterminated tag")))
            } else {
                appendText(pending, into: &events)
            }
            pending = ""
        }
        emitSentence(upTo: text.endIndex, into: &events)
        return events
    }

    private mutating func handleTag(_ body: String, into events: inout [CueStreamEvent]) {
        guard let tag = CueTag.parse(body) else {
            events.append(.invalidTag(CueError(raw: "[[\(body)]]", reason: "malformed tag")))
            return
        }
        switch Cue.from(tag) {
        case .failure(let error):
            events.append(.invalidTag(error))
        case .success(let cue) where !cue.isDrawn:
            events.append(.sideChannel(cue, raw: tag.raw))
        case .success(let cue):
            cues.append(TimedCue(cue: cue, anchor: text.utf16.count, raw: tag.raw))
        }
    }

    private mutating func appendText(_ chunk: String, into events: inout [CueStreamEvent]) {
        guard !chunk.isEmpty else { return }
        var chunk = Substring(chunk)
        // Removing a tag must not leave a double space.
        if text.isEmpty || text.last?.isWhitespace == true {
            chunk = chunk.drop(while: { $0 == " " || $0 == "\t" })
        }
        text += chunk
        while let end = sentenceEnd(in: text) {
            emitSentence(upTo: end, into: &events)
        }
    }

    /// Index just past a sentence terminator that is followed by whitespace, or past a newline.
    private func sentenceEnd(in s: String) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\n" { return s.index(after: i) }
            if c == "." || c == "!" || c == "?" || c == "…" {
                var j = s.index(after: i)
                // Swallow repeated terminators and closing quotes/brackets.
                while j < s.endIndex, ".!?…\"'”’)]".contains(s[j]) { j = s.index(after: j) }
                guard j < s.endIndex else { return nil } // need to see what follows
                if s[j].isWhitespace { return j }
                i = j
                continue
            }
            i = s.index(after: i)
        }
        return nil
    }

    private mutating func emitSentence(upTo end: String.Index, into events: inout [CueStreamEvent]) {
        let head = String(text[..<end])
        let rest = String(text[end...])
        let headUTF16 = head.utf16.count

        let leading = head.prefix(while: { $0.isWhitespace })
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let shift = leading.utf16.count

        var own: [TimedCue] = []
        var later: [TimedCue] = []
        for cue in cues {
            // A cue placed right at the boundary belongs to this sentence (bound to its last word).
            if cue.anchor <= headUTF16 { own.append(cue) } else { later.append(cue) }
        }

        let restLeading = rest.prefix(while: { $0.isWhitespace })
        let consumed = headUTF16 + restLeading.utf16.count
        text = String(rest.dropFirst(restLeading.count))

        if trimmed.isEmpty {
            // Nothing to speak: carry the cues over to the next sentence's first word.
            cues = own.map { TimedCue(cue: $0.cue, anchor: 0, raw: $0.raw) } + later.map { shifted($0, by: -consumed) }
            return
        }

        let bound = own.map { cue -> TimedCue in
            var c = cue
            c.anchor = wordStart(atOrAfter: max(0, cue.anchor - shift), in: trimmed)
            return c
        }
        events.append(.sentence(SpokenSentence(text: trimmed, cues: bound)))
        cues = later.map { shifted($0, by: -consumed) }
    }

    private func shifted(_ cue: TimedCue, by delta: Int) -> TimedCue {
        var c = cue
        c.anchor = max(0, c.anchor + delta)
        return c
    }

    /// Start of the first word at or after `offset`; the last word if there is none.
    private func wordStart(atOrAfter offset: Int, in s: String) -> Int {
        let units = Array(s.utf16)
        func isWordUnit(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return true } // surrogate halves: part of a word
            return CharacterSet.alphanumerics.contains(scalar)
        }
        var i = min(offset, units.count)
        while i < units.count, !isWordUnit(units[i]) { i += 1 }
        if i < units.count {
            // Step back to the start of this word if the offset landed inside it.
            while i > 0, isWordUnit(units[i - 1]) { i -= 1 }
            return i
        }
        // No word follows: bind to the last word.
        var j = units.count
        while j > 0, !isWordUnit(units[j - 1]) { j -= 1 }
        while j > 0, isWordUnit(units[j - 1]) { j -= 1 }
        return j
    }
}
