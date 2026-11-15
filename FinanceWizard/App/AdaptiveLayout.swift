//
//  AdaptiveLayout.swift
//  Finance Wizard
//
//  Layout by the app's real width rather than size class. The iPhone Duo's cover screen
//  (466 pt) and inner screen (669 pt, or 951 pt turned sideways) all report a regular width,
//  so size class can't tell a phone-sized column from a tablet-sized one.
//

import SwiftUI

enum LayoutWidth {
    /// Wide enough for totals side by side, but still one column (the Duo's inner screen).
    static let roomy: CGFloat = 600
    /// Wide enough for a list beside its detail: the Duo's inner screen turned sideways (867 pt
    /// beside its tab bar), iPad, Mac.
    static let twoColumn: CGFloat = 800
}

extension EnvironmentValues {
    /// Width of the app's window, set once at the root. Zero until the first layout.
    @Entry var appWidth: CGFloat = 0
}

/// A NavigationStack, or a list beside its detail once the window is wide enough.
/// Links inside the list open in the detail column there, so screens need no changes.
struct AdaptiveNavigation<Content: View, Detail: View>: View {
    @Environment(\.appWidth) private var appWidth
    @ViewBuilder var content: () -> Content
    /// What the right column shows before anything in the list is opened.
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        if appWidth >= LayoutWidth.twoColumn {
            NavigationSplitView {
                content()
                    // The sidebar column would otherwise restyle the list as a plain sidebar,
                    // with gray rows on a light panel instead of the app's light cards on gray.
                    .listStyle(.insetGrouped)
                    .containerBackground(Color(.systemGroupedBackground), for: .navigation)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 420)
                    // Both columns stay up; there's room for them and nothing to hide.
                    .toolbar(removing: .sidebarToggle)
            } detail: {
                NavigationStack {
                    detail()
                        .containerBackground(Color(.systemGroupedBackground), for: .navigation)
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack {
                content()
            }
        }
    }
}

extension AdaptiveNavigation where Detail == AdaptivePlaceholder {
    init(placeholder: String = "Pick something from the list.", systemImage: String = "sidebar.left", @ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.detail = { AdaptivePlaceholder(text: placeholder, systemImage: systemImage) }
    }
}

/// The right column's prompt before anything is opened.
struct AdaptivePlaceholder: View {
    let text: String
    let systemImage: String

    var body: some View {
        ZStack {
            // The same gray as the list beside it. The detail column is an elevated surface,
            // where the plain grouped background turns white.
            Color(uiColor: .baseGroupedBackground)
                .ignoresSafeArea()
            ContentUnavailableView(text, systemImage: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}

extension UIColor {
    /// The grouped background's base-level values (light and dark). The detail column is an
    /// elevated surface, where `systemGroupedBackground` resolves to white instead.
    static let baseGroupedBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .black
            : UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)
    }
}
