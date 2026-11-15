//
//  ContentView.swift
//  Finance Wizard
//
//  Main app UI after onboarding: the tab bar (Home, Accounts, Budget, Upcoming, Settings) and
//  the Ask field that sits with it.
//

import SwiftUI
import SwiftData

/// Root of the main UI: a TabView with lazy-loaded secondary tabs for faster launch.
struct ContentView: View {
    @AppStorage(ScreenshotPrivacy.storageKey) private var screenshotPrivacy = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedTab: AppTab = Self.launchTab
    /// Only build heavy tabs after the user opens them (first switch is still work; launch is not).
    @State private var loadedTabs: Set<AppTab> = [.home, Self.launchTab]
    /// Set when the Ask field sends a question or reopens the chat, which opens the Ask sheet.
    @State private var askRequest: AskRequest?
    @State private var hasAskChat = false
    /// The question bar above the keyboard, open while a question is being typed.
    @State private var isAsking = false
    @State private var showStoreRecovered = AppStoreRecovery.needsNotice
    /// Folding or unfolding the Duo changes this, and the tabs re-lay themselves out.
    @State private var appWidth: CGFloat = 0

    /// Home, unless a Debug build was launched with `-screen <tab>`.
    private static var launchTab: AppTab {
        #if DEBUG
        // Tabs by what they read now; "transactions" and "subscriptions" still work.
        let aliases = ["upcoming": AppTab.subscriptions, "transactions": .home]
        if let screen = DemoMode.launchScreen,
           let tab = aliases[screen] ?? AppTab(rawValue: screen) {
            return tab
        }
        #endif
        return .home
    }

    /// Custom Binding so selecting a tab also marks it “loaded” before assignment.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                loadedTabs.insert(newValue)
                selectedTab = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            // First tab always built at launch (not lazy).
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)

            lazyTab(.accounts) {
                CardsView()
            }
            .tabItem { Label("Accounts", systemImage: "building.columns") }
            .tag(AppTab.accounts)

            lazyTab(.budget) {
                BudgetView()
            }
            .tabItem { Label("Budget", systemImage: "chart.pie.fill") }
            .tag(AppTab.budget)

            lazyTab(.subscriptions) {
                SubscriptionsView()
            }
            .tabItem { Label("Upcoming", systemImage: "calendar.badge.clock") }
            .tag(AppTab.subscriptions)

            lazyTab(.settings) {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .environment(\.screenshotPrivacy, screenshotPrivacy)
        .environment(\.appWidth, appWidth)
        .environment(\.selectTab, SelectTabAction { tab in tabSelection.wrappedValue = tab })
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { appWidth = $0 }
        // With a side tab bar (iPhone Duo, iPad, Mac) the Ask field floats over the bottom of each
        // list, so lists get room to scroll their last rows clear of it. A bottom tab bar
        // already reserves that space.
        .contentMargins(.bottom, sizeClass == .regular ? 72 : 0, for: .scrollContent)
        // Opening a .fwbackup from Files jumps to Settings (where restore UI lives).
        .onReceive(NotificationCenter.default.publisher(for: PlaidConnectionBackup.openFileNotification)) { _ in
            loadedTabs.insert(.settings)
            selectedTab = .settings
        }
        // The system places this above the bottom tab bar, or in a small bubble beside a side tab bar.
        // The chat opens only once there's a question, so a tap doesn't cover the screen.
        .tabViewBottomAccessory {
            AskField(hasChat: hasAskChat) {
                isAsking = true
            } openChat: {
                askRequest = AskRequest(question: nil)
            }
            // With a hardware keyboard nothing covers it, and the composer would show doubled.
            .opacity(isAsking ? 0 : 1)
        }
        // Typing happens in a bar of its own, because the accessory stays put behind the keyboard.
        .overlay(alignment: .bottom) {
            if isAsking {
                AskComposer(isPresented: $isAsking) { question in
                    askRequest = AskRequest(question: question)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: isAsking)
        .onChange(of: selectedTab) { isAsking = false }
        .sheet(item: $askRequest, onDismiss: refreshAskChat) { request in
            OnDeviceAIChatView(initialQuestion: request.question)
        }
        .task { refreshAskChat() }
        .alert("Your data couldn’t be opened", isPresented: $showStoreRecovered) {
            Button("OK", role: .cancel) { AppStoreRecovery.needsNotice = false }
        } message: {
            Text("A copy was kept on this iPhone and the app started empty. Sync downloads your bank history again. To get budgets, payoff plans, and edits back, restore a backup in Settings.")
        }
    }

    private func refreshAskChat() {
        let turns = (try? ModelContext(AskStore.container).fetchCount(FetchDescriptor<AskTurn>())) ?? 0
        hasAskChat = turns > 0
    }

    @ViewBuilder
    private func lazyTab<Content: View>(
        _ tab: AppTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if loadedTabs.contains(tab) {
            content()
        } else {
            // Placeholder until first selection — avoids building all tabs at launch.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// What the Ask sheet opens with: a question to send, or nil to show the chat as it is.
private struct AskRequest: Identifiable {
    let id = UUID()
    let question: String?
}

/// Ask in the tab bar: reads like a search field and opens the question bar when tapped.
private struct AskField: View {
    let hasChat: Bool
    let startAsking: () -> Void
    let openChat: () -> Void

    @State private var hintIndex = 0

    /// Shorter than the chat's hints, which got cut off in the Duo's small accessory bubble.
    static let hints = ["Ask about your money", "Biggest category?", "Spent this month?", "Bills coming up?"]

    var body: some View {
        HStack(spacing: 8) {
            Button(action: startAsking) {
                HStack(spacing: 8) {
                    AskGlyph()
                    Text(Self.hints[hintIndex])
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ask about your money")
            if hasChat {
                Button("Open chat", systemImage: "bubble.left.and.text.bubble.right", action: openChat)
                    .labelStyle(.iconOnly)
            }
        }
        .padding(.horizontal, 14)
        // Beside a side tab bar, the system's bubble is only as wide as this and has no padding
        // of its own, so a field sized to its text would be too narrow to read.
        .frame(minWidth: 280)
        .task { await cycleHints() }
    }

    private func cycleHints() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeInOut(duration: 0.4)) {
                hintIndex = (hintIndex + 1) % Self.hints.count
            }
        }
    }
}

/// The bar a question is typed into. It sits above the keyboard and sends to the chat.
private struct AskComposer: View {
    @Binding var isPresented: Bool
    let ask: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            AskGlyph()
            TextField(AskField.hints[0], text: $draft)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Cancel", systemImage: "xmark.circle.fill") { isPresented = false }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            } else {
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .onAppear { focused = true }
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        isPresented = false
        ask(question)
    }
}

private struct AskGlyph: View {
    var body: some View {
        Image(systemName: "apple.intelligence")
            .foregroundStyle(
                LinearGradient(
                    colors: [.orange, .pink, .purple, .cyan],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}
