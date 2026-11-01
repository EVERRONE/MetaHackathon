import Foundation

/// Whether the words someone asks for name a remembered place: its own name ("gouden beeldjes") or
/// the model's phrase for it ("golden statue"). A place found again this way is moved onto the
/// object that was found, so a wrong match loses the place: its head noun (the last word, in
/// Dutch and English alike) must be among the words asked for, give or take a plural or diminutive
/// ending. A shared beginning is not enough: a tablet is no table, a coffee mug no coffee table.
public enum PlaceName {
    static let ignored: Set<String> = ["the", "user", "users", "your", "where", "and", "with", "mijn", "van", "het", "een", "die", "dat", "deze"]

    /// The words that say what a thing is: lowercased, without a possessive 's, three letters or more.
    static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "’s", with: "")
            .split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { $0.count >= 3 && !ignored.contains($0) }
    }

    /// A word without its plural, diminutive or adjective endings ("beeldjes" and "beeldje" both
    /// "beeld", "statues" and "statue" both "statu", "golden" "gold", "keys" "key"), never shorter
    /// than three letters.
    static func stem(_ word: String) -> String {
        var w = word
        while let ending = ["tjes", "jes", "tje", "je", "en", "es", "s", "e"].first(where: { w.hasSuffix($0) && w.count - $0.count >= 3 }) {
            w.removeLast(ending.count)
        }
        return w
    }

    /// How well `asked` names a place with these names (its name, the model's phrase for it): 0 when
    /// none of their head nouns is asked for, else how many of their words are.
    public static func score(_ asked: String, names: [String]) -> Int {
        let wanted = Set(words(asked).map(stem))
        let heads = names.compactMap { words($0).last.map(stem) }
        guard heads.contains(where: wanted.contains) else { return 0 }
        return Set(names.flatMap { words($0).map(stem) }).intersection(wanted).count
    }
}
