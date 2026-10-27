import Foundation
import ClipnpasteCore

/// The strings a card shows, from the copy deck.
enum ClipText {
    private static let gb = Locale(identifier: "en_GB")

    /// First 1,000 characters, leading blank lines trimmed, runs of spaces and tabs collapsed.
    static func preview(_ text: String) -> String {
        let isBlank: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        var s = Substring(text.prefix(4000))
        while let nl = s.firstIndex(where: \.isNewline), s[..<nl].allSatisfy(isBlank) {
            s = s[s.index(after: nl)...]
        }
        var out = ""
        var run = ""
        var count = 0
        for ch in s {
            if isBlank(ch) {
                run.append(ch)
                continue
            }
            if !run.isEmpty {
                out += run.count > 1 ? " " : run
                count += 1
                run = ""
            }
            out.append(ch)
            count += 1
            if count >= 1000 { break }
        }
        if !run.isEmpty, count < 1000 { out += run.count > 1 ? " " : run }
        return String(out.prefix(1000))
    }

    /// "now", "2 min", "1 h", "Yesterday", "26 Oct".
    static func time(_ date: Date, now: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        let ago = now.timeIntervalSince(date)
        if days <= 0 {
            if ago < 60 { return "now" }
            if ago < 3600 { return "\(Int(ago / 60)) min" }
            return "\(Int(ago / 3600)) h"
        }
        if days == 1 { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(gb))
    }

    /// "1,284 characters".
    static func characters(_ n: Int) -> String {
        "\(n.formatted(.number.locale(gb))) \(n == 1 ? "character" : "characters")"
    }

    static func dimensions(_ w: Int, _ h: Int) -> String { "\(w) × \(h)" }

    /// The accessibility label of a card.
    static func spoken(_ clip: Clip, now: Date, missing: Bool) -> String {
        let kind = clip.kind == .text ? "Text" : "Image"
        let app = clip.sourceAppName.map { " from \($0)" } ?? ""
        return "\(kind)\(app), \(time(clip.createdAt, now: now))\(missing ? ", file missing" : "")"
    }
}
