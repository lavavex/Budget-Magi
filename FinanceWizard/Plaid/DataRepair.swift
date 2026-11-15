//
//  DataRepair.swift
//  Finance Wizard
//
//  Repairs for data that earlier versions of the app left behind: names that differ only by
//  an invisible space, Apple Card purchases imported twice, and old rows stuck in
//  Miscellaneous. Each pass is safe to run again; it changes nothing the second time.
//

import Foundation
import SwiftData

@MainActor
enum DataRepair {
    /// Bump when a pass is added or changed, so launch runs them once more.
    private static let version = 1
    private static let versionKey = "dataRepair.version"

    /// At launch: every pass, once per `version`.
    static func runIfNeeded(modelContext: ModelContext) {
        guard !DemoMode.isActive,
              UserDefaults.standard.integer(forKey: versionKey) < version else { return }
        runAll(modelContext: modelContext)
        UserDefaults.standard.set(version, forKey: versionKey)
    }

    /// After a Sync, since new rows can need the same repairs.
    @discardableResult
    static func runAll(modelContext: ModelContext) -> Int {
        guard !DemoMode.isActive else { return 0 }
        let changed = normalizeSpaces(modelContext: modelContext)
            + removeImportedDuplicates(modelContext: modelContext)
            + fileByMerchant(modelContext: modelContext)
        try? modelContext.save()
        return changed
    }

    // MARK: - Invisible spaces

    /// Wallet names Apple Card "Apple\u{00A0}Card"; the older file import used a plain space, so
    /// one card showed as two. Rewrites stored names with plain spaces.
    static func normalizeSpaces(modelContext: ModelContext) -> Int {
        var changed = 0
        for row in (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? [] where row.paymentMethod != row.paymentMethod.plainSpaces {
            row.paymentMethod = row.paymentMethod.plainSpaces
            changed += 1
        }
        for payment in (try? modelContext.fetch(FetchDescriptor<CreditCardPayment>())) ?? [] {
            if payment.cardName != payment.cardName.plainSpaces {
                payment.cardName = payment.cardName.plainSpaces
                changed += 1
            }
            if let source = payment.sourceAccount, source != source.plainSpaces {
                payment.sourceAccount = source.plainSpaces
                changed += 1
            }
        }
        for account in (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? [] where account.name != account.name.plainSpaces {
            account.name = account.name.plainSpaces
            changed += 1
        }
        return changed
    }

    // MARK: - Apple Card imported twice

    /// The file import and Wallet can both hold the same purchase. Import skips a Wallet line
    /// that a file row covers, but only for lines it hasn't seen, so rows from earlier versions
    /// stayed doubled. Pairs each Wallet row with a file row (same cents, within a day, the
    /// import's own rule) and deletes the file copy, keeping a category the user set on it.
    static func removeImportedDuplicates(modelContext: ModelContext) -> Int {
        let rows = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        let pairs = importedDuplicates(
            wallet: rows.filter { $0.transactionId.hasPrefix("applewallet:") },
            file: rows.filter { $0.transactionId.hasPrefix("applecard:") }
        )
        for (wallet, file) in pairs {
            if file.isCategoryLocked, !wallet.isCategoryLocked {
                wallet.category = file.category
                wallet.categoryLocked = true
                wallet.overrideSource = file.overrideSource
            }
            modelContext.delete(file)
        }
        return pairs.count
    }

    /// Each Wallet row claims at most one file row, the nearest in time.
    static func importedDuplicates(
        wallet: [Transaction],
        file: [Transaction],
        calendar: Calendar = .current
    ) -> [(wallet: Transaction, file: Transaction)] {
        func cents(_ row: Transaction) -> Int { Int((row.amount * 100).rounded()) }
        var remaining = Dictionary(grouping: file, by: cents)
        var pairs: [(Transaction, Transaction)] = []
        for row in wallet.sorted(by: { $0.date < $1.date }) {
            let day = calendar.startOfDay(for: row.date)
            let candidates = remaining[cents(row)] ?? []
            let nearest = candidates.enumerated()
                .compactMap { index, old -> (index: Int, gap: Int)? in
                    let gap = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: old.date), to: day).day ?? 9)
                    return gap <= 1 ? (index, gap) : nil
                }
                .min { $0.gap < $1.gap }
            guard let nearest else { continue }
            pairs.append((row, candidates[nearest.index]))
            remaining[cents(row)]?.remove(at: nearest.index)
        }
        return pairs
    }

    // MARK: - Filing by merchant

    /// Rows left in a catch-all category, mostly from the old Apple Card file, while the same
    /// merchant is filed consistently everywhere else. Also fuel that Plaid filed as Transit at a
    /// merchant that's nearly always Gas. Leaves rows the user set alone.
    static func fileByMerchant(modelContext: ModelContext) -> Int {
        let rows = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        let changes = merchantFilings(in: rows)
        for (row, category) in changes {
            row.category = category
            row.overrideSource = "merchant"
        }
        return changes.count
    }

    /// The share of a merchant's other rows one category needs before it's used.
    static let merchantShare = 0.75

    static func merchantFilings(in rows: [Transaction]) -> [(row: Transaction, category: String)] {
        let byMerchant = Dictionary(grouping: rows) { SubscriptionAnalytics.normalizeVendor($0.title) }
        var changes: [(Transaction, String)] = []
        for (merchant, group) in byMerchant where merchant.count >= 3 {
            for row in group where !row.isCategoryLocked && row.overrideSource != "user" {
                let isWeak = ReviewQueueAnalytics.looksWeakCategory(row.category)
                let isTransit = row.category == KnownCategory.transit.rawValue
                // For Transit, the question is whether those rows are fuel, so other Transit
                // rows at the merchant aren't evidence either way.
                let others = group.filter { $0 !== row && !(isTransit && $0.category == row.category) }
                guard isWeak || isTransit,
                      !MoneyInsights.looksLikeVaguePayment(row.title),
                      let usual = usualCategory(of: others)
                else { continue }
                if isWeak, usual != row.category {
                    changes.append((row, usual))
                } else if isTransit, usual == KnownCategory.gas.rawValue {
                    changes.append((row, usual))
                }
            }
        }
        return changes
    }

    /// The category most of a merchant's other spending sits in, when one clearly does.
    private static func usualCategory(of others: [Transaction]) -> String? {
        let filed = others.filter {
            !ReviewQueueAnalytics.looksWeakCategory($0.category)
                && !TransactionAnalytics.isExcludedFromSpendCategory($0.category)
                && $0.category != TransactionAnalytics.refundCategory
        }
        guard filed.count >= 2 else { return nil }
        let counts = Dictionary(grouping: filed, by: \.category).mapValues(\.count)
        guard let top = counts.max(by: { $0.value < $1.value }),
              Double(top.value) / Double(filed.count) >= merchantShare else { return nil }
        return top.key
    }
}
