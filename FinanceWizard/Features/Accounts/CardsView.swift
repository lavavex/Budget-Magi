//
//  CardsView.swift
//  Finance Wizard
//
//  Accounts: every transaction (All accounts), the credit summary and cards, checking and
//  savings, and payment methods that aren't linked. Upcoming has what's coming due.
//

import SwiftUI
import SwiftData

// MARK: - Accounts tab (formerly Cards)

/// Root Accounts tab: overview totals, upcoming bills, and navigable account rows.
struct CardsView: View {
    @Query private var transactions: [Transaction]
    @Query(sort: \BankAccount.name) private var accounts: [BankAccount]
    @Query(sort: \CreditCardPayment.date, order: .reverse) private var payments: [CreditCardPayment]
    @Query private var payoffPlans: [PayoffPlan]
    @Environment(\.modelContext) private var modelContext

    // Filters / sort shared with detail screens via NavigationLink parameters.
    @State private var period: SnapshotPeriod = .month
    @State private var referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    @State private var sort: TransactionSort = .dateNewest
    // Bump counter: queries alone may not notice CardLabelStore nickname changes.
    @State private var nicknameEpoch = 0
    @State private var isSyncing = false
    @State private var syncBanner: String?

    /// Prebuilt board — body only reads this, never re-walks all transactions per section.
    @State private var board = AccountsBoard()
    @State private var isBuildingBoard = true

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    // Reading nicknameEpoch ties refresh to rename events.
    private var creditAccounts: [BankAccount] {
        _ = nicknameEpoch // intentional read so body re-evaluates after renames
        return accounts.filter(\.isCredit)
    }

    /// Dependency string for .task(id:): when any piece changes, rebuild the board.
    /// FIX: this keyed on counts alone, so editing a payoff plan's monthly payment or syncing
    /// new balances from another tab left the token identical and the board stale — the card
    /// row kept showing the old "includes $350.39 loan/installment". Fold in the newest
    /// mutation stamps so content changes invalidate it too.
    private var refreshToken: String {
        let planStamp = payoffPlans.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        let accountStamp = accounts.map(\.lastSyncedAt).max()?.timeIntervalSince1970 ?? 0
        return "\(period.rawValue)|\(referenceDate.timeIntervalSince1970)|\(transactions.count)|\(accounts.count)|\(payments.count)|\(payoffPlans.count)|\(planStamp)|\(accountStamp)|\(nicknameEpoch)"
    }

    var body: some View {
        NavigationStack {
            TwoColumnList {
                // MARK: Every transaction
                Section {
                    NavigationLink {
                        AllAccountsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("All accounts")
                                    .font(.body.weight(.semibold))
                                Text("Every transaction, with search")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "list.bullet.rectangle.portrait")
                        }
                    }
                } header: {
                    Text("Transactions")
                }

                // MARK: Credit summary
                if !creditAccounts.isEmpty {
                    Section {
                        if period != .all {
                            PeriodStepper(period: period, referenceDate: $referenceDate)
                        }
                        creditSummary
                        TotalPaidDisclosure(
                            total: board.totalPaidInPeriod,
                            payments: board.periodPayments,
                            periodLabel: periodLabel,
                            institutionId: nil,
                            resolveInstitutionId: { institutionId(for: $0) }
                        )
                    } header: {
                        Text("Credit")
                    }
                }

                if let syncBanner {
                    Section {
                        Text(syncBanner)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: Checking / savings
                Section {
                    if board.depositoryRows.isEmpty {
                        Text("No checking or savings accounts linked yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(board.depositoryRows) { row in
                            accountNavigationLink(row: row)
                        }
                    }
                } header: {
                    Text("Checking & savings")
                }

                if !board.otherSpendRows.isEmpty {
                    Section {
                        ForEach(board.otherSpendRows) { row in
                            accountNavigationLink(row: row)
                        }
                    } header: {
                        Text("Other spend")
                    } footer: {
                        Text("Payment methods with spending in \(TotalPaidDisclosure.inSentence(periodLabel)) that aren't a linked account.")
                    }
                }
            } right: {
                // MARK: Credit cards
                Section {
                    if isBuildingBoard && board.creditRows.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Loading accounts…")
                                .foregroundStyle(.secondary)
                        }
                    } else if board.creditRows.isEmpty {
                        ContentUnavailableView(
                            "No credit cards",
                            systemImage: "creditcard",
                            description: Text("Link a bank in Settings, then Sync on Home.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(board.creditRows) { row in
                            accountNavigationLink(row: row)
                        }
                    }
                } header: {
                    Text("Credit cards")
                }
            }
            .navigationTitle("Accounts")
            .refreshable {
                await syncFromPlaid()
            }
            .toolbar {
                // Same order as Transactions: period, then sort (which applies inside each account).
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PeriodFilterMenu(
                        period: $period,
                        referenceDate: $referenceDate,
                        transactions: transactions,
                        // Additional dates keep the month list useful even with few purchases.
                        additionalDates: payments.map(\.date),
                        showTitle: false
                    )
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(TransactionSort.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .task(id: refreshToken) {
                // Clear orphan/duplicate deposit accounts (e.g. X Money after Relink)
                if PlaidSyncEngine.cleanupStaleBankAccounts(modelContext: modelContext) > 0 {
                    try? modelContext.save()
                }
                InstitutionLogoCache.prefetch(accounts: accounts)
                if !DemoMode.isActive {
                    CardLabelStore.backfillCardKeys(accounts.map { ($0.accountId, $0.institutionName, $0.mask) })
                }
                rebuildBoard()
            }
        }
    }

    /// Balance, limit, utilization, and what's due across every card.
    private var creditSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Credit balance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MoneyText(board.totalOwed)
                        .font(.title3.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Limit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MoneyText(board.totalLimit > 0 ? board.totalLimit : 0)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if let util = board.totalUtilization {
                UtilizationBar(value: util, label: "Overall utilization")
            }
            if board.totalMinimumDue > 0 || board.soonestDueDate != nil {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Min payments")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if board.totalMinimumDue > 0 {
                            MoneyText(board.totalMinimumDue)
                                .font(.subheadline.weight(.semibold))
                        } else {
                            Text("—")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(board.anyOverdue ? "Overdue" : "Next due")
                            .font(.caption)
                            .foregroundStyle(board.anyOverdue ? .red : .secondary)
                        if let due = board.soonestDueDate {
                            Text(due, style: .date)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(board.anyOverdue ? .red : .primary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Board rebuild

    /// Snapshot inputs, yield to the run loop, then assign a new AccountsBoard on the main actor.
    @MainActor
    private func rebuildBoard() {
        isBuildingBoard = board.creditRows.isEmpty && board.depositoryRows.isEmpty
        // Copy @State/@Query values into locals so the Task closure captures stable snapshots.
        let period = self.period
        let referenceDate = self.referenceDate
        let accounts = self.accounts
        let transactions = self.transactions
        let payments = self.payments
        let payoffPlans = self.payoffPlans
        _ = nicknameEpoch

        Task { @MainActor in
            // Task.yield() lets SwiftUI paint once before the potentially heavy build.
            await Task.yield()
            PayoffPlanProgress.applyStatementProgress(plans: payoffPlans, accounts: accounts)
            try? modelContext.save()
            board = AccountsBoard.build(
                accounts: accounts,
                transactions: transactions,
                payments: payments,
                period: period,
                referenceDate: referenceDate,
                payoffPlans: payoffPlans
            )
            isBuildingBoard = false
        }
    }

    /// The same Sync as Transactions (Apple Card, then banks), with its headline as a short banner.
    private func syncFromPlaid() async {
        guard !isSyncing else { return }
        isSyncing = true
        syncBanner = "Syncing…"
        let outcome = await AppSync.run(modelContext: modelContext)
        syncBanner = outcome.headline
        isSyncing = false
        guard outcome.succeeded else { return }
        nicknameEpoch += 1 // force board rebuild via refreshToken
        try? await Task.sleep(for: .seconds(2.5))
        syncBanner = nil
    }

    @ViewBuilder
    private func accountNavigationLink(row: UnifiedCardRow) -> some View {
        NavigationLink {
            CardDetailView(
                displayName: row.displayName,
                rawPaymentMethod: row.rawPaymentMethod,
                matchingPaymentMethods: row.matchingPaymentMethods,
                sort: sort,
                creditAccount: row.creditAccount,
                bankAccount: row.bankAccount ?? row.creditAccount,
                onNicknameChanged: { nicknameEpoch += 1 }
            )
        } label: {
            UnifiedCardLabel(row: row)
        }
    }

    /// Resolve a Plaid institution id for logos on bill-payment rows.
    private func institutionId(for payment: CreditCardPayment) -> String? {
        if let id = payment.creditAccountId,
           let account = accounts.first(where: { $0.accountId == id }) {
            return account.institutionId
        }
        // OLD: return payment.cardName.contains(mask)
        if let maskMatch = creditAccounts.first(where: { account in
            guard let mask = account.mask, !mask.isEmpty else { return false }
            // Standalone last-four only — see BankAccount.containsStandaloneMask.
            return BankAccount.containsStandaloneMask(payment.cardName, mask: mask)
        }) {
            return maskMatch.institutionId
        }
        return accounts.first { $0.institutionName == payment.institutionName }?.institutionId
    }
}

#Preview {
    CardsView()
        .modelContainer(
            for: [Transaction.self, BankAccount.self, CreditCardPayment.self],
            inMemory: true
        )
}
