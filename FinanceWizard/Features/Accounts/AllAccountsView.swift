//
//  AllAccountsView.swift
//  Finance Wizard
//
//  Every transaction across every account, opened from the top of Accounts: period, totals,
//  income, and expenses, with plain and AI search.
//

import SwiftUI
import SwiftData

struct AllAccountsView: View {
    @Query private var transactions: [Transaction]
    @Query private var incomeRows: [Income]
    @Query private var bankAccounts: [BankAccount]
    @Environment(\.sampleData) private var sampleData
    @Environment(\.appWidth) private var appWidth

    // Same filter concepts as the widget (period + sort + search).
    @State private var period: SnapshotPeriod = .month
    /// Which week/month to show (any day in that period; months use month start).
    @State private var referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    @State private var sort: TransactionSort = .dateNewest
    @State private var searchText: String = ""

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

    private var totalSpend: Double {
        TransactionAnalytics.totalSpend(in: periodTransactions)
    }

    private var totalIncome: Double {
        IncomeAnalytics.totalEarned(in: periodIncome)
    }

    private var periodNet: Double {
        totalIncome - totalSpend
    }

    /// A sentence rather than a keyword, which the plain search can't read.
    private var aiSearchQuery: String? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.split(separator: " ").count >= 3,
              case .available = OnDeviceAI.availabilityStatus() else { return nil }
        return query
    }

    /// A single column wide enough for three totals side by side.
    private var showsTotalsAcross: Bool {
        appWidth >= LayoutWidth.roomy && appWidth < LayoutWidth.twoColumn
    }

    var body: some View {
        TwoColumnList {
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
            totalsSection
            incomeSection
        } right: {
            expensesSection
        }
        .navigationTitle("All accounts")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            // Always shown: beside a side tab bar there's no pull-down hint that it exists.
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Title, category, amount, last 4"
        )
        .task {
            InstitutionLogoCache.warmMemory(accounts: bankAccounts)
        }
        .toolbar {
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
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
    }

    // MARK: - Sections

    /// Spend from expenses only; income is a separate stream.
    @ViewBuilder
    private var totalsSection: some View {
        Section {
            if period != .all {
                PeriodStepper(period: period, referenceDate: $referenceDate)
            }
            if showsTotalsAcross {
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
                    totalRow("Total Spend", value: totalSpend, color: .primary, note: "Tap for categories")
                }
                totalRow("Total Income", value: totalIncome, color: totalIncome > 0.005 ? .green : .primary, note: "Earnings")
                totalRow("Net", value: periodNet, color: periodNet > 0.005 ? .green : .primary, note: "Income − spend")
            }
            Text(activityLine)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Summary")
        }
    }

    private var incomeSection: some View {
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
    }

    private var expensesSection: some View {
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

    // MARK: - Pieces

    private func totalRow(_ title: String, value: Double, color: Color, note: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(value)
                .font(.title2.bold())
                .foregroundStyle(color)
        }
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
            return "No expenses yet. Link a bank in Settings, then Sync on Home."
        }
        if periodTransactions.isEmpty {
            return "No expenses in \(period.sentenceLabel(referenceDate: referenceDate))."
        }
        return "No expenses match your search."
    }

    private var incomeEmptyMessage: String {
        if incomeRows.isEmpty {
            return "No income yet. Sync on Home after linking a bank."
        }
        return "No income in \(period.sentenceLabel(referenceDate: referenceDate))."
    }
}
