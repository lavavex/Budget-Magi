//
//  WalletFiling.swift
//  Finance Wizard
//
//  How a Wallet transaction becomes a row in the app. Plain values in and out, so the rules
//  can be tested without FinanceKit, which only runs on an iPhone with the entitlement.
//

import Foundation

/// One Apple Card transaction as FinanceKit reports it.
struct WalletTransaction: Equatable {
    enum Kind: Equatable {
        case purchase, payment, refund, interest, fee, installment
    }

    var id: String
    var accountId: String
    var title: String
    /// The line as the bank wrote it.
    var bankLine: String
    /// Always positive.
    var amount: Double
    var kind: Kind
    var date: Date
    var isPending: Bool
    var merchantCategoryCode: Int?
}

/// What to store for one Wallet transaction.
struct WalletFiledRow: Equatable {
    var category: String
    /// Signed the way the app stores it: spending and card payments negative, refunds positive.
    var amount: Double
    var locksCategory: Bool
    var overrideSource: String?
}

enum WalletFiling {
    /// What kind of line this is. FinanceKit's type alone isn't enough: a payment can arrive
    /// as a transfer or a deposit, and installments have no type of their own.
    /// - Parameters:
    ///   - isCharge: True when the line adds to what's owed.
    ///   - hasMerchantCode: Whether the card network tagged the line with a merchant category.
    static func kind(type: String, isCharge: Bool, title: String, hasMerchantCode: Bool = true) -> WalletTransaction.Kind {
        let lower = title.lowercased()
        if PayoffPlanRecognition.looksLikeInstallmentBillingTitle(title) || lower.contains("monthly installments") {
            return .installment
        }
        // Wallet reports each month's Apple Card installment as an untyped charge under the
        // store's name, with no merchant code, since nothing was bought that day.
        if type == "unknown", isCharge, !hasMerchantCode { return .installment }
        if type == "interest" || lower.contains("interest charge") { return .interest }
        // A charge-side adjustment takes back rewards and the like.
        if type == "fee" || (type == "adjustment" && isCharge) { return .fee }
        guard !isCharge else { return .purchase }
        let paymentTypes = ["billPayment", "transfer", "deposit", "directDeposit", "standingOrder", "directDebit"]
        if paymentTypes.contains(type) || lower.contains("payment") || lower.contains("ach deposit")
            || lower.contains("internet transfer") {
            return .payment
        }
        return .refund
    }

    static func row(for transaction: WalletTransaction, paymentMethod: String) -> WalletFiledRow {
        switch transaction.kind {
        case .payment:
            return WalletFiledRow(
                category: TransactionAnalytics.creditCardPaymentCategory,
                amount: -transaction.amount, locksCategory: true, overrideSource: "credit-payment"
            )
        case .refund:
            return WalletFiledRow(
                category: KnownCategory.refund.rawValue,
                amount: transaction.amount, locksCategory: true, overrideSource: "adjustment"
            )
        case .installment:
            // The purchase was already counted when it was made.
            return WalletFiledRow(
                category: KnownCategory.installment.rawValue,
                amount: -transaction.amount, locksCategory: true, overrideSource: "adjustment"
            )
        case .interest, .fee:
            return WalletFiledRow(category: KnownCategory.fees.rawValue, amount: -transaction.amount, locksCategory: false, overrideSource: nil)
        case .purchase:
            if let rule = VendorRulesStore.match(vendor: transaction.title, paymentMethod: paymentMethod, amount: transaction.amount) {
                return WalletFiledRow(category: rule.category, amount: -transaction.amount, locksCategory: false, overrideSource: "rule")
            }
            let fromCode = transaction.merchantCategoryCode.flatMap(category(forMerchantCategoryCode:))
            let category = fromCode ?? TitleCategoryHints.refine(category: KnownCategory.miscellaneous.rawValue, title: transaction.title)
            return WalletFiledRow(category: category, amount: -transaction.amount, locksCategory: false, overrideSource: nil)
        }
    }

    /// Card networks tag each merchant with a four-digit code. These are the ranges that map
    /// cleanly onto the app's categories, and anything else is left to the merchant's name.
    static func category(forMerchantCategoryCode code: Int) -> String? {
        let category: KnownCategory?
        switch code {
        case 5411, 5422, 5441, 5451, 5462, 5499: category = .groceries
        case 5811...5814: category = .dining
        case 5541, 5542, 5983: category = .gas
        case 4111, 4112, 4121, 4131, 4784, 4789, 7523: category = .transit
        case 3000...3350, 3351...3500, 3501...3999, 4411, 4511, 4722, 7011, 7012, 7512: category = .travel
        case 4900: category = .utilities
        case 4812, 4814, 4816, 4899: category = .homeInternet
        case 5912, 8011...8099: category = .health
        case 7230, 7297, 7298: category = .personalCare
        case 8211...8299: category = .education
        case 742, 5995: category = .pets
        case 6300, 5960: category = .insurance
        case 8398, 8641, 8661: category = .giftsDonations
        case 5200, 5211, 5231, 5251, 5261, 1520...1799: category = .homeImprovement
        case 7832, 7841, 7922, 7929, 7932, 7933, 7941, 7991...7999, 5815...5818: category = .entertainment
        case 5000...5999: category = .shopping
        default: category = nil
        }
        return category?.rawValue
    }

    /// Wallet lines that an earlier Apple Card file import already brought in. Each old row
    /// accounts for one new line of the same amount within a day.
    static func alreadyImported(_ incoming: [WalletTransaction], legacy: [(amount: Double, date: Date)], calendar: Calendar = .current) -> Set<String> {
        var remaining = legacy
        var matched = Set<String>()
        for transaction in incoming.sorted(by: { $0.date < $1.date }) {
            let cents = Int((transaction.amount * 100).rounded())
            let day = calendar.startOfDay(for: transaction.date)
            guard let index = remaining.firstIndex(where: { old in
                Int((abs(old.amount) * 100).rounded()) == cents
                    && abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: old.date), to: day).day ?? 9) <= 1
            }) else { continue }
            remaining.remove(at: index)
            matched.insert(transaction.id)
        }
        return matched
    }
}
