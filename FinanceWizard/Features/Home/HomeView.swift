//
//  HomeView.swift
//  Finance Wizard
//
//  The first tab: this month at a glance, where your money stands, what's due next, and what
//  needs a look. Details live on Accounts, Budget, and Upcoming; Sync starts here.
//

import SwiftUI
import SwiftData

struct HomeView: View {
    @Query private var transactions: [Transaction]
    @Query private var incomeRows: [Income]
    @Query private var accounts: [BankAccount]
    @Query private var payoffPlans: [PayoffPlan]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.sampleData) private var sampleData
    @Environment(\.selectTab) private var selectTab

    @State private var referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    @State private var plan: BudgetPlan?
    /// Bills from the same detection Upcoming runs, for "next bill".
    @State private var bills: [SubscriptionCandidate] = []
    /// Heavy scan (review queue) — not computed every body pass.
    @State private var reviewCount = 0

    @State private var isSyncing = false
    @State private var syncStatus: SyncStatus?
    @State private var showLinkSheet = false
    @State private var linkError: String?

    // MARK: - Numbers

    private var snapshot: BudgetSnapshot? {
        guard let plan else { return nil }
        return BudgetAnalytics.snapshot(
            plan: plan,
            transactions: transactions,
            incomeRows: incomeRows,
            period: .month,
            referenceDate: referenceDate
        )
    }

    private var isThisMonth: Bool {
        Calendar.current.isDate(referenceDate, equalTo: Date(), toGranularity: .month)
    }

    private var cash: Double {
        accounts.filter { $0.subtype == "checking" || $0.subtype == "savings" }
            .reduce(0) { $0 + ($1.availableBalance ?? $1.currentBalance) }
    }

    private var credit: [BankAccount] { accounts.filter(\.isCredit) }

    private var owed: Double {
        credit.reduce(0) { $0 + max(0, $1.currentBalance) }
    }

    private var utilization: Double? {
        let limit = credit.compactMap(\.creditLimit).reduce(0, +)
        guard limit > 0 else { return nil }
        return min(max(owed / limit, 0), 1)
    }

    private var nextCardPayment: BankAccount? {
        AccountsBoard.upcomingCardPayments(accounts).first
    }

    /// The bill charging soonest that's still on schedule, as Upcoming lists it.
    private var nextBill: (bill: SubscriptionCandidate, date: Date)? {
        bills
            .filter { !SubscriptionAnalytics.isOverdue($0) }
            .compactMap { bill in SubscriptionAnalytics.nextChargeDate(for: bill).map { (bill, $0) } }
            .filter { $0.1 >= Calendar.current.startOfDay(for: Date()) }
            .min { $0.1 < $1.1 }
            .map { (bill: $0.0, date: $0.1) }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            TwoColumnList {
                if sampleData.isActive {
                    SampleDataBanner()
                }
                if let syncStatus {
                    syncSection(syncStatus)
                }
                monthSection
                moneySection
            } right: {
                nextSection
                todoSection
                categoriesSection
            }
            .navigationTitle("Home")
            .refreshable {
                guard !sampleData.isActive else { return }
                await sync()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !sampleData.isActive {
                        syncMenu
                    }
                }
            }
            .task {
                plan = BudgetStore.loadOrCreate(in: modelContext)
                InstitutionLogoCache.warmMemory(accounts: accounts)
                InstitutionLogoCache.prefetch(accounts: accounts)
                refreshReviewCount()
                await scanBills()
            }
            // Resolving a queue item changes a row's category, not the count.
            .onChange(of: transactions.map(\.category).joined(separator: "|")) { _, _ in
                refreshReviewCount()
            }
            .alert(
                "Couldn't link bank",
                isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })
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
        }
    }

    // MARK: - This month

    private var monthSection: some View {
        Section {
            PeriodStepper(period: .month, referenceDate: $referenceDate)
            if let snapshot {
                NavigationLink {
                    CategorySpendView(period: .month, referenceDate: referenceDate)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Spent")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                MoneyText(snapshot.totalSpent)
                                    .font(.title2.weight(.bold))
                            }
                            Spacer()
                            if let remaining = snapshot.totalRemaining {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(snapshot.isOverTotal ? "Over budget" : "Left in budget")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    MoneyText(abs(remaining))
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(snapshot.isOverTotal ? .red : .green)
                                }
                            }
                        }
                        if let fraction = snapshot.totalFraction {
                            ProgressView(value: min(fraction, 1))
                                .tint(snapshot.isOverTotal ? .red : .accentColor)
                        }
                    }
                    .padding(.vertical, 2)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Income")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        MoneyText(snapshot.income)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(snapshot.income > 0.005 ? .green : .primary)
                    }
                    Spacer()
                    if isThisMonth, snapshot.expectedSoFar > 0.005 || snapshot.expectedIncome > 0.005,
                       let delta = snapshot.incomeVsExpected {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(delta >= -0.005 ? "Ahead of expected" : "Behind expected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            MoneyText(abs(delta))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(delta >= -0.005 ? .green : .orange)
                        }
                    }
                }

                let net = snapshot.income - snapshot.totalSpent
                LabeledContent("Net") {
                    MoneyText(net)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(net > 0.005 ? .green : .primary)
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("At a glance")
        }
    }

    // MARK: - Money position

    private var moneySection: some View {
        Section {
            LabeledContent("Cash") {
                MoneyText(cash)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            LabeledContent("Owed on cards") {
                MoneyText(owed)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            if let utilization {
                UtilizationBar(value: utilization, label: "Overall utilization")
            }
            Button {
                selectTab(.accounts)
            } label: {
                Label("See accounts", systemImage: "building.columns")
            }
        } header: {
            Text("Money")
        } footer: {
            Text("Cash is what's available in checking and savings.")
        }
    }

    // MARK: - What's next

    private var nextSection: some View {
        Section {
            if let card = nextCardPayment {
                UpcomingCardLink(
                    account: card,
                    methods: Set(transactions.map(TransactionAnalytics.cardName(for:))),
                    plans: payoffPlans
                )
            }
            if let next = nextBill {
                Button {
                    selectTab(.subscriptions)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "repeat.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.bill.displayVendor)
                                .font(.body.weight(.semibold))
                                .lineLimit(1)
                            Text("Next bill · \(next.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        MoneyText(next.bill.typicalAmount, prefix: next.bill.amountVaries ? "~" : "")
                            .font(.body.weight(.semibold))
                            .fixedSize()
                    }
                }
                .buttonStyle(.plain)
            }
            if nextCardPayment == nil, nextBill == nil {
                Text("Nothing coming up.")
                    .foregroundStyle(.secondary)
            }
            Button {
                selectTab(.subscriptions)
            } label: {
                Label("See everything on Upcoming", systemImage: "calendar.badge.clock")
            }
        } header: {
            Text("What's next")
        }
    }

    // MARK: - To do

    private var todoSection: some View {
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
            Text("To do")
        }
    }

    // MARK: - Top categories

    @ViewBuilder
    private var categoriesSection: some View {
        let top = (snapshot?.categories ?? []).sorted { $0.spent > $1.spent }.prefix(3)
        if !top.isEmpty {
            Section {
                ForEach(Array(top)) { row in
                    NavigationLink {
                        CategorySpendView(period: .month, referenceDate: referenceDate)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: CategoryStyle.symbolName(for: row.category))
                                .foregroundStyle(CategoryStyle.color(for: row.category))
                                .frame(width: 22)
                            Text(row.category)
                            Spacer()
                            MoneyText(row.spent)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Top categories")
            }
        }
    }

    // MARK: - Sync

    struct SyncStatus {
        enum Kind { case running, success, warning, failure }
        var kind: Kind
        var title: String
        var detail = ""
        /// The counters behind a finished sync, kept out of sight unless asked for.
        var counters = ""

        var systemImage: String {
            switch kind {
            case .running: "arrow.triangle.2.circlepath"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failure: "xmark.circle.fill"
            }
        }

        var color: Color {
            switch kind {
            case .running: .accentColor
            case .success: .green
            case .warning: .orange
            case .failure: .red
            }
        }
    }

    private func syncSection(_ status: SyncStatus) -> some View {
        Section("Sync") {
            HStack(alignment: .top, spacing: 12) {
                if isSyncing {
                    ProgressView()
                } else {
                    Image(systemName: status.systemImage)
                        .foregroundStyle(status.color)
                        .font(.title3)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.title)
                        .font(.subheadline.weight(.semibold))
                    if !status.detail.isEmpty {
                        Text(status.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if !isSyncing {
                    Button("Dismiss", systemImage: "xmark.circle.fill") { syncStatus = nil }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 2)
            if !isSyncing, !status.counters.isEmpty {
                DisclosureGroup("Details") {
                    Text(status.counters)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var syncMenu: some View {
        if isSyncing {
            ProgressView()
        } else {
            Menu {
                Button {
                    Task { await sync() }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    Task { await sync(forceRefresh: true) }
                } label: {
                    Label("Force bank refresh", systemImage: "bolt.horizontal.circle")
                }
                Button {
                    Task { await sync(resetCursors: true) }
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
        }
    }

    /// Apple Card, then each linked bank. See `AppSync`.
    private func sync(resetCursors: Bool = false, forceRefresh: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        syncStatus = SyncStatus(
            kind: .running,
            title: resetCursors ? "Full re-sync…" : forceRefresh ? "Force refreshing banks…" : "Syncing…",
            detail: PlaidCredentialsStore.isConfigured
                ? "Environment: \(PlaidCredentialsStore.environment.displayName)"
                : "Missing credentials"
        )
        let outcome = await AppSync.run(
            modelContext: modelContext,
            resetCursors: resetCursors,
            forceRefresh: forceRefresh
        ) { message in
            Task { @MainActor in
                syncStatus = SyncStatus(kind: .running, title: "Syncing…", detail: message)
            }
        }
        if outcome.succeeded {
            let warned = !(outcome.report?.warnings.isEmpty ?? true)
            syncStatus = SyncStatus(
                kind: warned ? .warning : .success,
                title: warned ? "Sync finished with warnings" : "Sync complete",
                detail: outcome.headline,
                counters: outcome.counters
            )
            refreshReviewCount()
            await scanBills()
        } else {
            syncStatus = SyncStatus(kind: .failure, title: "Sync failed", detail: outcome.headline)
        }
        isSyncing = false
    }

    // MARK: - Background work

    /// Review queue count is expensive; never run it in `body`.
    private func refreshReviewCount() {
        let rows = transactions
        Task(priority: .utility) { @MainActor in
            await Task.yield()
            reviewCount = ReviewQueueAnalytics.count(in: rows)
        }
    }

    /// The same detection Upcoming uses, off the main thread.
    private func scanBills() async {
        let snaps = SubscriptionAnalytics.snapshots(from: transactions)
        let cancelled = SubscriptionAnalytics.cancelledVendors(in: transactions)
        let found = await Task.detached(priority: .utility) {
            SubscriptionAnalytics.detectAll(snapshots: snaps)
        }.value
        bills = found.filter { SubscriptionAnalytics.isActive($0) && !cancelled.contains($0.normalizedVendor) }
    }
}
