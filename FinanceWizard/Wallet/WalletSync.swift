//
//  WalletSync.swift
//  Finance Wizard
//
//  Apple Card through FinanceKit. Wallet hands the app the card's balance and transactions on
//  this iPhone after the user allows it. There is no sign-in and nothing goes over the network.
//  FinanceKit needs an entitlement Apple grants per app, and it has data only on an iPhone.
//

import FinanceKit
import Foundation
import SwiftData
import WidgetKit

struct WalletSyncReport {
    var lines: [String] = []
}

enum WalletSyncError: LocalizedError {
    case unavailable
    case notAllowed

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple Card data isn't available on this device."
        case .notAllowed: return "Budget Magi isn't allowed to read Wallet. Turn it on in Settings → Privacy & Security → Wallet."
        }
    }
}

@MainActor
enum WalletSync {
    /// Stands in for a Plaid Item on the accounts Wallet provides, so account cleanup can tell
    /// them from a bank that was unlinked.
    nonisolated static let itemId = "apple-wallet"
    private static let connectedKey = "wallet.connected"

    /// False on iPad, Mac, and the simulator, and wherever Wallet has no financial data.
    static var isAvailable: Bool { FinanceStore.isDataAvailable(.financialData) }

    /// Whether the user turned Apple Card on in the app. Wallet's own permission is checked each sync.
    static var isConnected: Bool {
        get { isAvailable && UserDefaults.standard.bool(forKey: connectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: connectedKey) }
    }

    static func accountId(_ id: UUID) -> String { "applewallet:\(id.uuidString)" }

    /// Shows Wallet's permission sheet the first time.
    static func connect() async throws {
        guard isAvailable else { throw WalletSyncError.unavailable }
        guard try await FinanceStore.shared.requestAuthorization() == .authorized else {
            throw WalletSyncError.notAllowed
        }
        isConnected = true
    }

    /// Removes the Apple Card account. Its transactions stay, like those of an unlinked bank.
    static func disconnect(modelContext: ModelContext) {
        isConnected = false
        for account in ((try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []) where account.itemId == itemId {
            modelContext.delete(account)
        }
        try? modelContext.save()
    }

    @discardableResult
    static func sync(modelContext: ModelContext) async throws -> WalletSyncReport {
        guard isAvailable else { throw WalletSyncError.unavailable }
        guard try await FinanceStore.shared.authorizationStatus() == .authorized else {
            throw WalletSyncError.notAllowed
        }
        var report = WalletSyncReport()
        // Apple Card is the liability account. Apple Cash and Savings are assets and aren't imported.
        let cards = try await FinanceStore.shared.accounts(query: AccountQuery()).compactMap(\.liabilityAccount)
        let balances = try await FinanceStore.shared.accountBalances(query: AccountBalanceQuery())
        let cardIds = Set(cards.map(\.id))
        let all = try await FinanceStore.shared.transactions(query: TransactionQuery())
            .filter { cardIds.contains($0.accountID) && $0.status != .rejected }

        // FinanceKit marks each line credit or debit without saying which one is a purchase on
        // a card. Purchases far outnumber refunds, so the commoner mark at a till is a charge.
        let atTill = all.filter { $0.transactionType == .pointOfSale }
        let chargeMark: CreditDebitIndicator =
            atTill.filter { $0.creditDebitIndicator == .debit }.count >= atTill.filter { $0.creditDebitIndicator == .credit }.count
            ? .debit : .credit

        let existingAccounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        for card in cards {
            let id = accountId(card.id)
            let balance = balances.first { $0.accountID == card.id }.flatMap { $0.booked ?? $0.available }
            let owed = balance.map { amount($0.amount) * ($0.creditDebitIndicator == chargeMark ? 1 : -1) }
            let credit = card.creditInformation
            let account = existingAccounts.first { $0.accountId == id } ?? {
                let created = BankAccount(
                    accountId: id, itemId: itemId, name: card.displayName, type: "credit",
                    subtype: "credit card", institutionName: card.institutionName, currentBalance: owed ?? 0
                )
                modelContext.insert(created)
                return created
            }()
            account.name = card.displayName
            account.institutionName = card.institutionName
            if let owed { account.currentBalance = owed }
            account.creditLimit = credit.creditLimit.map(amount)
            account.minimumPaymentAmount = credit.minimumNextPaymentAmount.map(amount)
            account.nextPaymentDueDate = credit.nextPaymentDueDate
            account.isOverdue = credit.overduePaymentAmount.map { amount($0) > 0 }
            account.lastSyncedAt = .now
            account.liabilitiesSyncedAt = .now
            report.lines.append("\(card.displayName): owes \(AskLedger.money(account.currentBalance))")
        }

        let labels = Dictionary(cards.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let incoming = all.map { line -> WalletTransaction in
            let title = line.merchantName?.isEmpty == false ? line.merchantName! : line.transactionDescription
            return WalletTransaction(
                id: "applewallet:\(line.id.uuidString)",
                accountId: accountId(line.accountID),
                title: title,
                bankLine: line.originalTransactionDescription,
                amount: amount(line.transactionAmount),
                kind: WalletFiling.kind(
                    type: String(describing: line.transactionType),
                    isCharge: line.creditDebitIndicator == chargeMark,
                    title: line.originalTransactionDescription.isEmpty ? title : line.originalTransactionDescription
                ),
                date: line.transactionDate,
                isPending: line.status != .booked,
                merchantCategoryCode: line.merchantCategoryCode.map { Int($0.rawValue) }
            )
        }
        let counts = store(incoming, labels: Dictionary(uniqueKeysWithValues: labels.map { (accountId($0.key), $0.value) }), modelContext: modelContext)
        report.lines.append("Apple Card: +\(counts.added) new / \(counts.updated) updated / \(counts.skipped) already imported")

        PlaidSyncEngine.pairVaguePaymentsWithCards(modelContext: modelContext)
        try modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
        return report
    }

    private static func amount(_ value: CurrencyAmount) -> Double {
        abs(NSDecimalNumber(decimal: value.amount).doubleValue)
    }

    /// Adds new lines and refreshes ones seen before. A category the user set stays.
    static func store(
        _ incoming: [WalletTransaction],
        labels: [String: String],
        modelContext: ModelContext
    ) -> (added: Int, updated: Int, skipped: Int) {
        let rows = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        let payments = (try? modelContext.fetch(FetchDescriptor<CreditCardPayment>())) ?? []
        let byId = Dictionary(rows.map { ($0.transactionId, $0) }, uniquingKeysWith: { first, _ in first })
        let legacy = rows.filter { $0.transactionId.hasPrefix("applecard:") }.map { (amount: $0.amount, date: $0.date) }
        let fresh = incoming.filter { byId[$0.id] == nil }
        let duplicates = WalletFiling.alreadyImported(fresh, legacy: legacy)
        var counts = (added: 0, updated: 0, skipped: duplicates.count)

        for line in incoming where !duplicates.contains(line.id) {
            let method = labels[line.accountId] ?? "Apple Card"
            let filed = WalletFiling.row(for: line, paymentMethod: method)
            if let row = byId[line.id] {
                row.title = line.title
                row.amount = filed.amount
                row.date = line.date
                row.paymentMethod = method
                row.isPending = line.isPending
                if !row.isCategoryLocked {
                    row.category = filed.category
                    if filed.locksCategory {
                        row.categoryLocked = true
                        row.overrideSource = filed.overrideSource
                    }
                }
                counts.updated += 1
            } else {
                modelContext.insert(Transaction(
                    transactionId: line.id, title: line.title, amount: filed.amount, date: line.date,
                    category: filed.category, paymentMethod: method, categoryLocked: filed.locksCategory,
                    overrideSource: filed.overrideSource, plaidAccountId: line.accountId,
                    merchantName: line.title, isPending: line.isPending
                ))
                counts.added += 1
            }
            // The card's side of a payment, which is what a bank's bare "PAYMENT" line is matched to.
            if line.kind == .payment {
                if let payment = payments.first(where: { $0.transactionId == line.id }) {
                    payment.amount = line.amount
                    payment.date = line.date
                } else {
                    modelContext.insert(CreditCardPayment(
                        transactionId: line.id, amount: line.amount, date: line.date, cardName: method,
                        title: line.title, creditAccountId: line.accountId, institutionName: "Apple"
                    ))
                }
            }
        }
        return counts
    }
}
