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
    /// Wide enough for a list beside its detail (iPad, Mac). Beside its side tab bar, the Duo's
    /// inner screen stays under this even turned sideways, and one column reads better there.
    static let twoColumn: CGFloat = 900
}

extension EnvironmentValues {
    /// Width of the app's window, set once at the root. Zero until the first layout.
    @Entry var appWidth: CGFloat = 0
}

/// A NavigationStack, or a list beside its detail once the window is wide enough.
/// Links inside the list open in the detail column there, so screens need no changes.
struct AdaptiveNavigation<Content: View>: View {
    @Environment(\.appWidth) private var appWidth
    @ViewBuilder var content: () -> Content

    var body: some View {
        if appWidth >= LayoutWidth.twoColumn {
            NavigationSplitView {
                content()
                    // The sidebar column would otherwise restyle the list as a plain sidebar.
                    .listStyle(.insetGrouped)
                    .navigationSplitViewColumnWidth(min: 340, ideal: 380, max: 440)
            } detail: {
                ContentUnavailableView("Nothing selected", systemImage: "sidebar.left", description: Text("Pick something from the list."))
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack {
                content()
            }
        }
    }
}
