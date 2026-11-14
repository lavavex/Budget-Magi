//
//  WalletFilingTests.swift
//  Finance Wizard
//
//  How Apple Card lines from Wallet are filed and stored. FinanceKit itself only runs on an
//  iPhone with the entitlement, so these cover everything after it hands the lines over.
//

import XCTest
import SwiftData
@testable import FinanceWizard

@MainActor
final class WalletFilingTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var savedRules: Data?

    override func setUpWithError() throws {
        container = try SharedStore.makeContainer(inMemory: true)
        context = ModelContext(container)
        savedRules = UserDefaults.standard.data(forKey: "plaid.vendorRules")
        VendorRulesStore.save([])
    }

    override func tearDown() {
        UserDefaults.standard.set(savedRules, forKey: "plaid.vendorRules")
    }

    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_790_000_000 + Double(offset) * 86_400)
    }

    private func line(_ title: String, _ amount: Double, _ kind: WalletTransaction.Kind, day offset: Int = 0, code: Int? = nil, id: String = UUID().uuidString) -> WalletTransaction {
        WalletTransaction(
            id: "applewallet:\(id)", accountId: "applewallet:card", title: title, bankLine: title,
            amount: amount, kind: kind, date: day(offset), isPending: false, merchantCategoryCode: code
        )
    }

    func testKindComesFromTypeDirectionAndWording() {
        XCTAssertEqual(WalletFiling.kind(type: "pointOfSale", isCharge: true, title: "EXAMPLE MARKET"), .purchase)
        XCTAssertEqual(WalletFiling.kind(type: "pointOfSale", isCharge: false, title: "EXAMPLE MARKET (RETURN)"), .refund)
        XCTAssertEqual(WalletFiling.kind(type: "transfer", isCharge: false, title: "ACH DEPOSIT INTERNET TRANSFER FROM ACCOUNT ENDING IN 1111"), .payment)
        XCTAssertEqual(WalletFiling.kind(type: "unknown", isCharge: false, title: "ACH DEPOSIT INTERNET TRANSFER FROM ACCOUNT ENDING IN 1111"), .payment)
        XCTAssertEqual(WalletFiling.kind(type: "interest", isCharge: true, title: "INTEREST CHARGE"), .interest)
        XCTAssertEqual(WalletFiling.kind(type: "unknown", isCharge: true, title: "MONTHLY INSTALLMENTS (3 OF 12)"), .installment)
        XCTAssertEqual(WalletFiling.kind(type: "unknown", isCharge: false, title: "DAILY CASH ADJUSTMENT"), .refund)
    }

    func testRowsAreSignedAndFiledByKind() {
        let purchase = WalletFiling.row(for: line("Example Diner", 20, .purchase, code: 5812), paymentMethod: "Apple Card")
        XCTAssertEqual(purchase, WalletFiledRow(category: "Dining", amount: -20, locksCategory: false, overrideSource: nil))

        let payment = WalletFiling.row(for: line("ACH DEPOSIT", 500, .payment), paymentMethod: "Apple Card")
        XCTAssertEqual(payment.category, KnownCategory.creditCardPayment.rawValue)
        XCTAssertEqual(payment.amount, -500)
        XCTAssertTrue(payment.locksCategory)

        XCTAssertEqual(WalletFiling.row(for: line("Example Shop", 9, .refund), paymentMethod: "Apple Card").amount, 9)
        XCTAssertEqual(WalletFiling.row(for: line("MONTHLY INSTALLMENTS (3 OF 12)", 27.41, .installment), paymentMethod: "Apple Card").category, KnownCategory.installment.rawValue)
        XCTAssertEqual(WalletFiling.row(for: line("INTEREST CHARGE", 19.03, .interest), paymentMethod: "Apple Card").category, KnownCategory.fees.rawValue)
    }

    func testALearnedRuleOutranksTheMerchantCode() {
        VendorRulesStore.upsert(vendor: "Example Diner", paymentMethod: nil, category: "Groceries")
        let row = WalletFiling.row(for: line("Example Diner", 20, .purchase, code: 5812), paymentMethod: "Apple Card")
        XCTAssertEqual(row.category, "Groceries")
        XCTAssertEqual(WalletFiling.category(forMerchantCategoryCode: 5411), "Groceries")
        XCTAssertEqual(WalletFiling.category(forMerchantCategoryCode: 5732), "Shopping")
        XCTAssertNil(WalletFiling.category(forMerchantCategoryCode: 9399))
    }

    func testLinesAnOlderFileImportBroughtInAreNotAddedTwice() throws {
        context.insert(Transaction(
            transactionId: "applecard:old", title: "Example Cinema 265", amount: -16.55, date: day(0),
            category: "Entertainment", paymentMethod: "Apple Card"
        ))
        try context.save()

        let counts = WalletSync.store([
            line("Example Cinema", 16.55, .purchase, day: 1, id: "same"),
            line("Example Cinema", 16.55, .purchase, day: 1, id: "second-visit"),
            line("Example Diner", 20, .purchase, day: 1, id: "new"),
        ], labels: ["applewallet:card": "Apple Card"], modelContext: context)

        XCTAssertEqual(counts.skipped, 1)
        XCTAssertEqual(counts.added, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transaction>()), 3)
    }

    func testASecondSyncUpdatesInPlaceAndKeepsTheUsersCategory() throws {
        let first = [line("Example Diner", 20, .purchase, code: 5812, id: "a")]
        WalletSync.store(first, labels: [:], modelContext: context)
        try context.save()
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first)
        row.category = "Groceries"
        row.categoryLocked = true

        var posted = first
        posted[0].amount = 22
        let counts = WalletSync.store(posted, labels: [:], modelContext: context)

        XCTAssertEqual(counts.updated, 1)
        XCTAssertEqual(counts.added, 0)
        XCTAssertEqual(row.amount, -22)
        XCTAssertEqual(row.category, "Groceries")
    }

    func testACardPaymentExplainsTheBanksBarePaymentLine() throws {
        context.insert(BankAccount(
            accountId: "applewallet:card", itemId: WalletSync.itemId, name: "Apple Card", type: "credit",
            institutionName: "Apple", currentBalance: 400
        ))
        context.insert(Transaction(
            transactionId: "bank-side", title: "PAYMENT", amount: -934.71, date: day(3),
            category: "Miscellaneous", paymentMethod: "Checking ···1111", plaidAccountId: "checking"
        ))
        WalletSync.store([line("ACH DEPOSIT INTERNET TRANSFER FROM ACCOUNT ENDING IN 1111", 934.71, .payment, id: "card-side")], labels: [:], modelContext: context)
        try context.save()

        XCTAssertEqual(PlaidSyncEngine.pairVaguePaymentsWithCards(modelContext: context), 1)
        let bank = try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first { $0.transactionId == "bank-side" })
        XCTAssertEqual(bank.category, KnownCategory.creditCardPayment.rawValue)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CreditCardPayment>()).map(\.transactionId), ["applewallet:card-side"])

        // Cleanup treats accounts with no linked bank as leftovers, and Wallet's isn't one.
        PlaidSyncEngine.pruneOrphanBankAccounts(modelContext: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BankAccount>()), 1)
    }
}
