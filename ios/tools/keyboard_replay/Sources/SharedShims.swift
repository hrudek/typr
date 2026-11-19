import Foundation

// Stand-ins for shared files that need app-only frameworks.

/// KeyboardBridge.swift needs SwiftUI and Metal. Only default arguments name the App Group, and the
/// replay passes its own; this suite keeps any accidental use away from Typr's data.
enum KeyboardBridge {
    nonisolated static let appGroup = "dev.rudek.typr.keyboard-replay"
}

/// AccentPicker.swift also holds a UIKit view. Only the key view opens accent menus, which the
/// replay never does; with no options no menu opens.
nonisolated enum AccentCatalog {
    static let periodKey: [String] = []
    static func options(for base: String, uppercase: Bool) -> [String]? { nil }
}

nonisolated struct AccentMenu: Equatable, Sendable {
    let options: [String]
    var selectedIndex: Int
    var selectedOption: String { options[selectedIndex] }

    static func build(for keyFrame: CGRect, rawOptions: [String], in layoutWidth: CGFloat,
                      horizontalInset: CGFloat = 0) -> AccentMenu {
        AccentMenu(options: rawOptions, selectedIndex: 0)
    }

    func index(for x: CGFloat) -> Int { selectedIndex }
}
