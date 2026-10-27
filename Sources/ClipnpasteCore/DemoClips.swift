import Foundation
import CryptoKit

public enum DemoClips {
    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A dozen text clips, newest first (sortKey 0 is the front), spaced a few minutes apart.
    public static func make(now: Date = Date()) -> [Clip] {
        let items: [(String, String, String)] = [
            ("https://github.com/irfanabdulhameed/clover", "com.apple.Safari", "Safari"),
            ("Meeting moved to 4:30 on Thursday. Bring the updated numbers.", "com.apple.mail", "Mail"),
            ("func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {\n    min(max(v, lo), hi)\n}", "com.apple.dt.Xcode", "Xcode"),
            ("#1F6FEB", "com.figma.Desktop", "Figma"),
            ("git log --oneline --since=\"2 weeks ago\" --author=irfan", "com.apple.Terminal", "Terminal"),
            ("Thanks for getting back to me. I'll send the revised draft by end of day tomorrow.", "com.apple.mail", "Mail"),
            ("+91 98765 43210", "com.apple.MobileSMS", "Messages"),
            ("The quick brown fox jumps over the lazy dog.", "com.apple.Notes", "Notes"),
            ("SELECT id, created_at FROM clips ORDER BY created_at DESC LIMIT 200;", "com.apple.Terminal", "Terminal"),
            ("12 Park Street, Kolkata 700016", "com.apple.Maps", "Maps"),
            ("Ideas: pinned clips, drag to Finder, quick search by app name, image history.", "com.apple.Notes", "Notes"),
            ("npm install --save-dev vitest", "com.apple.Terminal", "Terminal"),
        ]
        return items.enumerated().map { i, item in
            Clip(
                kind: .text,
                plainText: item.0,
                sourceBundleID: item.1,
                sourceAppName: item.2,
                createdAt: now.addingTimeInterval(-Double(i) * 240),
                sortKey: Double(i),
                contentHash: hash(item.0)
            )
        }
    }
}
