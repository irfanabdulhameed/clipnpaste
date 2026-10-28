import Foundation

/// The welcome tour's fifteen steps, one feature each, in order.
enum WelcomeStep: Int, CaseIterable, Sendable {
    case welcome, saved, shortcut, move, paste, copy, delete, reorder, dragOut, taller, history, settings
    case accessibility, chooseShortcut, tryIt

    static let count = allCases.count

    /// `--welcome N` counts from 1, as the progress does.
    init?(number: Int) { self.init(rawValue: number - 1) }

    var number: Int { rawValue + 1 }
    var isFirst: Bool { self == .welcome }
    var isLast: Bool { self == .tryIt }
    var next: WelcomeStep? { WelcomeStep(rawValue: rawValue + 1) }
    var previous: WelcomeStep? { WelcomeStep(rawValue: rawValue - 1) }

    var title: String {
        switch self {
        case .welcome: "Welcome to Clipnpaste"
        case .saved: "Everything you copy is saved"
        case .shortcut: "Open it with your shortcut"
        case .move: "Move between cards"
        case .paste: "Paste"
        case .copy: "Copy without pasting"
        case .delete: "Delete a card"
        case .reorder: "Reorder"
        case .dragOut: "Drag into any app"
        case .taller: "Make it taller"
        case .history: "History by day"
        case .settings: "Make it yours"
        case .accessibility: "Allow pasting"
        case .chooseShortcut: "Choose your shortcut"
        case .tryIt: "Try it now"
        }
    }

    /// One or two plain sentences. `shortcut` is the current shortcut's label, e.g. "⌃⌘V".
    func body(shortcut: String) -> String {
        switch self {
        case .welcome:
            "Your clipboard, with a memory. Everything you copy waits in one place, ready to paste again."
        case .saved:
            "Text and images are kept the moment you copy them, newest first."
        case .shortcut:
            "Press \(shortcut) in any app and your clips rise from the bottom of the screen."
        case .move:
            "Use the arrow keys, or scroll sideways with your trackpad or mouse."
        case .paste:
            "Press Return or click a card. It pastes straight into the app you were using."
        case .copy:
            "The copy button puts a card on the clipboard without pasting it, so you can paste it later."
        case .delete:
            "Press ⌘⌫ or click the remove button. The other cards close the gap."
        case .reorder:
            "Drag a card sideways to move it. The others make room."
        case .dragOut:
            "Drag a card out of the panel and drop it into any app. The panel shrinks to a strip while you drag."
        case .taller:
            "Drag the pill at the top upwards to see two or three rows of cards."
        case .history:
            "Press ⌘Y to see everything you have copied, grouped by day."
        case .settings:
            "Press ⌘, to change how it looks and behaves. Auto-clear removes old clips so storage stays tidy."
        case .accessibility:
            "To paste for you, Clipnpaste needs Accessibility access. Until you allow it, Return copies the card and you press ⌘V yourself."
        case .chooseShortcut:
            "Click the field and press the keys you want. Confirm saves it."
        case .tryIt:
            "Press \(shortcut) to open your clipboard."
        }
    }

    /// The keys this step teaches, shown as a small keycap row under the text. Nil for none.
    var legend: [String]? {
        switch self {
        case .move: ["←", "→"]
        case .paste: ["↩"]
        case .delete: ["⌘", "⌫"]
        case .history: ["⌘", "Y"]
        case .settings: ["⌘", ","]
        default: nil
        }
    }

    /// The primary button's title.
    var nextTitle: String {
        switch self {
        case .welcome: "Get Started"
        case .chooseShortcut: "Confirm"
        case .tryIt: "Done"
        default: "Next"
        }
    }

    /// What the moving picture shows, for VoiceOver.
    var visualDescription: String {
        switch self {
        case .welcome: "The Clipnpaste panel rises with your clips."
        case .saved: "A line of text and a photo are copied and drop into the panel as new cards."
        case .shortcut: "The shortcut keys are pressed and the panel rises."
        case .move: "The selection ring slides from card to card."
        case .paste: "A card flies up into a text field."
        case .copy: "The pointer clicks a card's copy button, which turns into a checkmark."
        case .delete: "A card is removed and the others close the gap."
        case .reorder: "A card is dragged sideways and the others part to make room."
        case .dragOut: "A card tilts as it is dragged out of the panel into a window, while the panel shrinks to a strip."
        case .taller: "The pill is dragged up and the panel grows to three rows."
        case .history: "History opens, with clips grouped under Today and Yesterday."
        case .settings: "The Settings window opens and auto-clear is set."
        case .accessibility: "Clipnpaste is switched on in Accessibility."
        case .chooseShortcut: "The shortcut recorder."
        case .tryIt: "The shortcut keys are pressed and the panel rises."
        }
    }
}
