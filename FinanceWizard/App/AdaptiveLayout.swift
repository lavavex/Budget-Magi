//
//  AdaptiveLayout.swift
//  Finance Wizard
//
//  Layout by the app's real width rather than size class. The iPhone Duo's cover screen
//  (466 pt) and inner screen all report a regular width, so size class can't tell a
//  phone-sized column from a tablet-sized one.
//

import SwiftUI

enum LayoutWidth {
    /// Wide enough for totals side by side, but still one column (the Duo's inner screen upright).
    static let roomy: CGFloat = 600
    /// Wide enough for two columns: the Duo's inner screen turned sideways (867 pt beside its
    /// tab bar), iPad, Mac.
    static let twoColumn: CGFloat = 800
}

extension EnvironmentValues {
    /// Width of the app's window, set once at the root. Zero until the first layout.
    @Entry var appWidth: CGFloat = 0
}

/// A screen's sections as two equal columns when the window is wide, or one list when it isn't.
/// Both columns start on the same line and meet in a gap the size of their outer margins.
/// Anything opened from either column pushes full width, on the screen's own NavigationStack.
struct TwoColumnList<Left: View, Right: View>: View {
    @Environment(\.appWidth) private var appWidth
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    var body: some View {
        if appWidth >= LayoutWidth.twoColumn {
            HStack(alignment: .top, spacing: 0) {
                List { left() }
                    .contentMargins(.trailing, 10, for: .scrollContent)
                    .frame(maxWidth: .infinity)
                List { right() }
                    .contentMargins(.leading, 10, for: .scrollContent)
                    .frame(maxWidth: .infinity)
            }
        } else {
            List {
                left()
                right()
            }
        }
    }
}

/// The root tabs. Raw values are what `-screen <tab>` accepts in Debug builds.
enum AppTab: String, Hashable {
    case home
    case accounts
    case budget
    case subscriptions
    case settings
}

/// Switches the root tab, for shortcuts like Home's "See everything on Upcoming".
struct SelectTabAction {
    var perform: (AppTab) -> Void = { _ in }

    func callAsFunction(_ tab: AppTab) { perform(tab) }
}

extension EnvironmentValues {
    @Entry var selectTab = SelectTabAction()
}
