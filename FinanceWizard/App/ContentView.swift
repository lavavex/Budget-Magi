//
//  ContentView.swift
//  Finance Wizard
//
//  Main app UI after onboarding: tab bar (Transactions, Accounts, Budget, Recurring, Settings),
//  the full Transactions tab (filters, Plaid sync), and income row/detail views.
//

import SwiftUI
import SwiftData

// MARK: - Root tabs

/// Which main tab is selected.
private enum AppTab: String, Hashable {
    case transactions
    case accounts
    case budget
    case subscriptions
    case settings
}

/// Root of the main UI: a TabView with lazy-loaded secondary tabs for faster launch.
struct ContentView: View {
    @AppStorage(ScreenshotPrivacy.storageKey) private var screenshotPrivacy = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedTab: AppTab = Self.launchTab
    /// Only build heavy tabs after the user opens them (first switch is still work; launch is not).
    @State private var loadedTabs: Set<AppTab> = [.transactions, Self.launchTab]
    /// Set when the Ask field sends a question or reopens the chat, which opens the Ask sheet.
    @State private var askRequest: AskRequest?
    @State private var hasAskChat = false
    /// The question bar above the keyboard, open while a question is being typed.
    @State private var isAsking = false
    @State private var showStoreRecovered = AppStoreRecovery.needsNotice
    /// Folding or unfolding the Duo changes this, and the tabs re-lay themselves out.
    @State private var appWidth: CGFloat = 0

    /// Transactions, unless a Debug build was launched with `-screen <tab>`.
    private static var launchTab: AppTab {
        #if DEBUG
        // "upcoming" names the tab as it reads now; "subscriptions" still works.
        let screen = DemoMode.launchScreen == "upcoming" ? AppTab.subscriptions.rawValue : DemoMode.launchScreen
        if let tab = screen.flatMap(AppTab.init(rawValue:)) {
            return tab
        }
        #endif
        return .transactions
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
            AllTransactionsView()
                .tabItem { Label("Transactions", systemImage: "list.bullet") }
                .tag(AppTab.transactions)

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

// MARK: - All transactions tab

/// Primary “Finances” screen: period filters, totals, income + expense lists, and Plaid sync.
struct AllTransactionsView: View {
    @Query private var transactions: [Transaction]
    @Query private var incomeRows: [Income]
    @Query private var bankAccounts: [BankAccount]
    @Environment(\.modelContext) private var modelContext

    @State private var linkError: String?
    @State private var isSyncing = false

    @State private var syncStatusTitle: String = ""
    @State private var syncStatusDetail: String = ""
    /// The counters behind a finished sync, kept out of sight unless asked for.
    @State private var syncStatusCounters: String = ""
    @State private var syncStatusKind: SyncStatusKind = .idle
    /// Keeps the status section visible after a run until the next Sync.
    @State private var showSyncStatus = false
    @State private var showLinkSheet = false

    // Same filter concepts as the widget (period + sort + search).
    @State private var period: SnapshotPeriod = .month
    /// Which week/month to show (any day in that period; months use month start).
    @State private var referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    @State private var sort: TransactionSort = .dateNewest
    @State private var searchText: String = ""
    /// Heavy scan (review queue) — not computed every body pass.
    @State private var reviewCount: Int = 0

    private var visibleTransactions: [Transaction] {
        let base = TransactionAnalytics.filter(
            transactions,
            period: period,
            referenceDate: referenceDate,
            excludedCards: [],
            sort: sort
        )
        return TransactionSearch.filter(base, query: searchText, accounts: bankAccounts)
    }

    // Period-only set for totals — ignores search so totals stay “whole period”.
    private var periodTransactions: [Transaction] {
        TransactionAnalytics.inPeriod(transactions, period: period, referenceDate: referenceDate)
    }

    // Income for the same period (never mixed into spend).
    private var periodIncome: [Income] {
        IncomeAnalytics.inPeriod(incomeRows, period: period, referenceDate: referenceDate)
    }

    private var visibleIncome: [Income] {
        let base = IncomeAnalytics.filter(
            incomeRows,
            period: period,
            referenceDate: referenceDate,
            sort: sort
        )
        return IncomeSearch.filter(base, query: searchText)
    }

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    // Expenses only (all cards in the period).
    private var totalSpend: Double {
        TransactionAnalytics.totalSpend(in: periodTransactions)
    }

    // Money earned in the period (always positive).
    private var totalIncome: Double {
        IncomeAnalytics.totalEarned(in: periodIncome)
    }

    private var periodNet: Double {
        totalIncome - totalSpend
    }

    /// A sentence rather than a keyword, which the plain search can't read.
    @Environment(\.sampleData) private var sampleData

    private var aiSearchQuery: String? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.split(separator: " ").count >= 3,
              case .available = OnDeviceAI.availabilityStatus() else { return nil }
        return query
    }

    var body: some View {
        AdaptiveNavigation {
            List {
                if sampleData.isActive {
                    SampleDataBanner()
                }

                if let aiSearchQuery {
                    Section {
                        NavigationLink {
                            AITransactionSearchView(query: aiSearchQuery)
                        } label: {
                            Label("Search with AI", systemImage: "apple.intelligence")
                        }
                    }
                }

                if showSyncStatus || isSyncing {
                    Section("Sync Status") {
                        HStack(alignment: .top, spacing: 12) {
                            if isSyncing {
                                ProgressView()
                            } else {
                                Image(systemName: syncStatusKind.systemImage)
                                    .foregroundStyle(syncStatusKind.color)
                                    .font(.title3)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(syncStatusTitle.isEmpty ? "Working…" : syncStatusTitle)
                                    .font(.subheadline.weight(.semibold))
                                if !syncStatusDetail.isEmpty {
                                    Text(syncStatusDetail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                            if !isSyncing {
                                Button("Dismiss", systemImage: "xmark.circle.fill") { showSyncStatus = false }
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.secondary)
                                    .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 2)
                        if !isSyncing, !syncStatusCounters.isEmpty {
                            DisclosureGroup("Details") {
                                Text(syncStatusCounters)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.caption)
                        }
                    }
                }

                // Totals — spend from expenses only; income is a separate stream.
                Section {
                    if period != .all {
                        PeriodStepper(period: period, referenceDate: $referenceDate)
                    }
                    if showsTotalsAcross {
                        // One row of three on a wide single column, such as the Duo's inner screen.
                        HStack(alignment: .top, spacing: 16) {
                            NavigationLink {
                                CategorySpendView(period: period, referenceDate: referenceDate)
                            } label: {
                                totalTile("Total Spend", value: totalSpend, color: .primary, note: "Tap for categories")
                            }
                            .buttonStyle(.plain)
                            Divider()
                            totalTile("Total Income", value: totalIncome, color: totalIncome > 0.005 ? .green : .primary, note: "Earnings")
                            Divider()
                            totalTile("Net", value: periodNet, color: periodNet > 0.005 ? .green : .primary, note: "Income − spend")
                        }
                        .padding(.vertical, 4)
                    } else {
                        NavigationLink {
                            CategorySpendView(period: period, referenceDate: referenceDate)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Total Spend")
                                        .font(.headline)
                                    Text(periodLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Tap for category chart")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                MoneyText(totalSpend)
                                    .font(.title2.bold())
                                    .foregroundStyle(.primary)
                            }
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Total Income")
                                    .font(.headline)
                                Text(periodLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(totalIncome)
                                .font(.title2.bold())
                                .foregroundStyle(totalIncome > 0.005 ? .green : .primary)
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Net")
                                    .font(.subheadline.weight(.semibold))
                                Text("Income − spend")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            MoneyText(periodNet)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(periodNet > 0.005 ? .green : .primary)
                        }
                    }
                    Text(activityLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        ReviewQueueView()
                    } label: {
                        HStack {
                            Label("Needs review", systemImage: "checklist")
                            Spacer()
                            if reviewCount > 0 {
                                Text("\(reviewCount)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.orange)
                            } else {
                                Text("Clear")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink {
                        MonthlyRecapView()
                    } label: {
                        Label("Monthly recap", systemImage: "calendar.badge.clock")
                    }
                } header: {
                    Text("Tools")
                }

                Section("Income") {
                    if visibleIncome.isEmpty {
                        Text(incomeEmptyMessage)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleIncome) { row in
                            NavigationLink {
                                IncomeDetailView(income: row, bankAccounts: bankAccounts)
                            } label: {
                                // Match income row to a known bank account (mask or name).
                                let matched = bankAccounts.first { account in
                                    if let mask = row.accountMask, let am = account.mask, mask == am {
                                        return true
                                    }
                                    if let name = row.accountName, account.matchesPaymentMethod(name) {
                                        return true
                                    }
                                    return false
                                }
                                IncomeRowView(
                                    income: row,
                                    institutionId: matched?.institutionId,
                                    institutionName: matched?.institutionName ?? row.sourceInstitution,
                                    accountLabel: matched?.displayName
                                )
                            }
                        }
                    }
                }

                Section("Expenses") {
                    if visibleTransactions.isEmpty {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleTransactions) { transaction in
                            NavigationLink {
                                TransactionDetailView(transaction: transaction)
                            } label: {
                                let matched = BankAccount.matching(
                                    paymentMethod: transaction.paymentMethod,
                                    in: bankAccounts
                                )
                                TransactionRowView(
                                    transaction: transaction,
                                    institutionId: matched?.institutionId,
                                    institutionName: matched?.institutionName,
                                    account: matched
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Finances")
            .searchable(
                text: $searchText,
                // Always shown: beside a side tab bar there's no pull-down hint that it exists.
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Title, category, amount, last 4"
            )
            .refreshable {
                guard !sampleData.isActive else { return }
                await syncFromPlaid(resetCursors: false)
            }
            .task {
                InstitutionLogoCache.warmMemory(accounts: bankAccounts)
                InstitutionLogoCache.prefetch(accounts: bankAccounts)
                refreshToolStats()
            }
            // FIX: resolving a queue item changes a row's category, not the count, so the
            // badge kept its old number until a sync added or removed a transaction.
            .onChange(of: transactions.count) { _, _ in
                refreshToolStats()
            }
            .onChange(of: transactions.map(\.category).joined(separator: "|")) { _, _ in
                refreshToolStats()
            }
            .onChange(of: bankAccounts.count) { _, _ in
                InstitutionLogoCache.warmMemory(accounts: bankAccounts)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !sampleData.isActive {
                    if isSyncing {
                        ProgressView()
                    } else {
                        Menu {
                            Button {
                                Task { await syncFromPlaid(resetCursors: false, forceRefresh: false) }
                            } label: {
                                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            }
                            Button {
                                Task { await syncFromPlaid(resetCursors: false, forceRefresh: true) }
                            } label: {
                                Label("Force bank refresh", systemImage: "bolt.horizontal.circle")
                            }
                            Button {
                                Task { await syncFromPlaid(resetCursors: true, forceRefresh: false) }
                            } label: {
                                Label("Full re-sync", systemImage: "arrow.down.circle")
                            }
                            Divider()
                            Button {
                                showLinkSheet = true
                            } label: {
                                Label("Link bank account", systemImage: "building.columns")
                            }
                        } label: {
                            Text("Sync")
                        }
                        .disabled(isSyncing)
                    }
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    PeriodFilterMenu(
                        period: $period,
                        referenceDate: $referenceDate,
                        transactions: transactions,
                        showTitle: false
                    )

                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(TransactionSort.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
            .alert(
                "Couldn't link bank",
                isPresented: Binding(
                    get: { linkError != nil },
                    set: { if !$0 { linkError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { linkError = nil }
            } message: {
                Text(linkError ?? "")
            }
            .sheet(isPresented: $showLinkSheet) {
                PlaidLinkSheet { result in
                    if case .failure(let error) = result {
                        linkError = error.localizedDescription
                    }
                }
            }
        } detail: {
            // Beside the list, the category chart fills the space until a row is opened.
            CategorySpendView(period: period, referenceDate: referenceDate)
        }
    }

    @Environment(\.appWidth) private var appWidth

    /// A single column wide enough for three totals side by side, but not split into two columns.
    private var showsTotalsAcross: Bool {
        appWidth >= LayoutWidth.roomy && appWidth < LayoutWidth.twoColumn
    }

    private func totalTile(_ title: String, value: Double, color: Color, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            MoneyText(value)
                .font(.title2.bold())
                .foregroundStyle(color)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var activityLine: String {
        let expenses = TransactionAnalytics.spendOnly(periodTransactions).count
        let income = periodIncome.count
        let when = period.sentenceLabel(referenceDate: referenceDate)
        guard expenses > 0 || income > 0 else { return "No activity in \(when)" }
        let expenseText = expenses == 1 ? "1 expense" : "\(expenses) expenses"
        let incomeText = income == 1 ? "1 deposit" : "\(income) deposits"
        return "\(expenseText) · \(incomeText) in \(when)"
    }

    private var emptyMessage: String {
        if transactions.isEmpty {
            return "No expenses yet. Link a bank in Settings, then tap Sync."
        }
        if periodTransactions.isEmpty {
            return "No expenses in \(period.sentenceLabel(referenceDate: referenceDate))."
        }
        return "No expenses match your search."
    }

    private var incomeEmptyMessage: String {
        if incomeRows.isEmpty {
            return "No income yet. Tap Sync after linking a bank."
        }
        return "No income in \(period.sentenceLabel(referenceDate: referenceDate))."
    }

    // MARK: - Sync

    private enum SyncStatusKind {
        case idle
        case running
        case success
        case warning
        case failure

        var systemImage: String {
            switch self {
            case .idle: return "ellipsis.circle"
            case .running: return "arrow.triangle.2.circlepath"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failure: return "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .idle: return .secondary
            case .running: return .accentColor
            case .success: return .green
            case .warning: return .orange
            case .failure: return .red
            }
        }
    }

    @MainActor
    private func setSyncStatus(_ kind: SyncStatusKind, title: String, detail: String = "", counters: String = "") {
        showSyncStatus = true
        syncStatusKind = kind
        syncStatusTitle = title
        syncStatusDetail = detail
        syncStatusCounters = counters
    }

    /// Pull transactions directly from the user’s Plaid developer account.
    /// - Parameter resetCursors: if true, re-download full history for each Item.
    /// - Parameter forceRefresh: call `/transactions/refresh` first (on-demand bank pull).
    private func syncFromPlaid(resetCursors: Bool, forceRefresh: Bool = false) async {
        guard !isSyncing else { return }
        await MainActor.run {
            isSyncing = true
            let title: String = {
                if resetCursors { return "Full re-sync…" }
                if forceRefresh { return "Force refreshing banks…" }
                return "Syncing with Plaid…"
            }()
            setSyncStatus(
                .running,
                title: title,
                detail: PlaidCredentialsStore.isConfigured
                    ? "Environment: \(PlaidCredentialsStore.environment.displayName)"
                    : "Missing credentials"
            )
        }

        let outcome = await AppSync.run(
            modelContext: modelContext,
            resetCursors: resetCursors,
            forceRefresh: forceRefresh
        ) { message in
            Task { @MainActor in
                setSyncStatus(.running, title: "Syncing…", detail: message)
            }
        }

        if outcome.succeeded {
            let warned = !(outcome.report?.warnings.isEmpty ?? true)
            setSyncStatus(
                warned ? .warning : .success,
                title: warned ? "Sync finished with warnings" : "Sync complete",
                detail: outcome.headline,
                counters: outcome.counters
            )
            refreshToolStats()
        } else {
            setSyncStatus(.failure, title: "Sync failed", detail: outcome.headline)
        }
        isSyncing = false
    }

    /// Review queue count is expensive; never run it in `body`.
    @MainActor
    private func refreshToolStats() {
        let txModels = transactions

        // Review queue needs live models (reasons attach to Transaction rows).
        // Yield first so the current scroll frame can finish.
        Task(priority: .utility) { @MainActor in
            await Task.yield()
            reviewCount = ReviewQueueAnalytics.count(in: txModels)
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
