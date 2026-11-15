//
//  DataRepairTests.swift
//  Finance Wizard
//
//  Repairs for data earlier versions left behind, and the rules found by checking a real
//  two-year backup: invisible spaces, Apple Card imported twice, catch-all categories,
//  cancelled bills that charge again, holds that never post, and Ask's card and year filters.
//

import XCTest
@testable import FinanceWizard

@MainActor
final class DataRepairTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    private func row(
        _ id: String,
        _ title: String,
        _ amount: Double,
        daysAgo: Double = 0,
        category: String = "Shopping",
        method: String = "Example Card"
    ) -> Transaction {
        Transaction(
            transactionId: id,
            title: title,
            amount: amount,
            date: Date().addingTimeInterval(-daysAgo * day),
            category: category,
            paymentMethod: method
        )
    }

    // MARK: - Invisible spaces

    func testNonBreakingSpaceStillMatchesTheCard() {
        let card = BankAccount(accountId: "a", itemId: "apple-wallet", name: "Apple\u{00A0}Card", type: "credit",
                               institutionName: "Apple", currentBalance: 0)
        XCTAssertEqual("Apple\u{00A0}Card".plainSpaces, "Apple Card")
        XCTAssertTrue(card.matchesPaymentMethod("Apple Card"))
        XCTAssertTrue(card.matchesPaymentMethod("Apple\u{00A0}Card"))
    }

    // MARK: - Apple Card imported twice

    func testWalletRowClaimsItsFileTwinOnce() {
        let wallet = [row("applewallet:1", "Example Theatre", -15.61, daysAgo: 10)]
        let file = [
            row("applecard:1", "Example Cinema Online", -15.61, daysAgo: 10.5),
            row("applecard:2", "Example Cinema Online", -15.61, daysAgo: 40),
            row("applecard:3", "Something Else", -9.99, daysAgo: 10),
        ]
        let pairs = DataRepair.importedDuplicates(wallet: wallet, file: file)
        XCTAssertEqual(pairs.map(\.file.transactionId), ["applecard:1"])

        // With the twin gone, a second run finds nothing.
        let remaining = file.filter { $0.transactionId != "applecard:1" }
        XCTAssertTrue(DataRepair.importedDuplicates(wallet: wallet, file: remaining).isEmpty)
    }

    // MARK: - Filing by merchant

    func testCatchAllTakesTheMerchantsUsualCategory() {
        let rows = [
            row("1", "Example Games", -10, category: "Entertainment"),
            row("2", "Example Games", -12, category: "Entertainment"),
            row("3", "Example Games", -14, category: "Entertainment"),
            row("4", "Example Games", -16, category: "Miscellaneous"),
        ]
        let changes = DataRepair.merchantFilings(in: rows)
        XCTAssertEqual(changes.map(\.row.transactionId), ["4"])
        XCTAssertEqual(changes.first?.category, "Entertainment")
    }

    func testLockedRowsAndMixedMerchantsStayPut() {
        let locked = row("4", "Example Games", -16, category: "Miscellaneous")
        locked.categoryLocked = true
        let mixed = [
            row("5", "Example Market", -5, category: "Groceries"),
            row("6", "Example Market", -6, category: "Shopping"),
            row("7", "Example Market", -7, category: "Miscellaneous"),
        ]
        let rows = [
            row("1", "Example Games", -10, category: "Entertainment"),
            row("2", "Example Games", -12, category: "Entertainment"),
            locked,
        ] + mixed
        XCTAssertTrue(DataRepair.merchantFilings(in: rows).isEmpty)
    }

    func testTransitAtAGasStationIsFuel() {
        let rows = [
            row("1", "Example Fuel Stop", -40, category: "Gas (Car)"),
            row("2", "Example Fuel Stop", -35, category: "Gas (Car)"),
            row("3", "Example Fuel Stop", -5, category: "Shopping"),
            row("4", "Example Fuel Stop", -45, category: "Gas (Car)"),
            row("5", "Example Fuel Stop", -50, category: "Transit"),
            row("6", "Example Fuel Stop", -48, category: "Transit"),
        ]
        let changes = DataRepair.merchantFilings(in: rows)
        XCTAssertEqual(Set(changes.map(\.row.transactionId)), ["5", "6"])
        XCTAssertTrue(changes.allSatisfy { $0.category == "Gas (Car)" })

        // A ride service's Transit stays Transit.
        let rides = [
            row("1", "Example Rides", -12, category: "Transit"),
            row("2", "Example Rides", -14, category: "Transit"),
            row("3", "Example Rides", -16, category: "Transit"),
        ]
        XCTAssertTrue(DataRepair.merchantFilings(in: rides).isEmpty)
    }

    // MARK: - Cancelled bills

    func testCancelledBillThatChargesAgainComesBack() {
        let old = row("1", "Example Stream", -11.99, daysAgo: 40)
        old.subscriptionCadenceOverride = "cancelled"
        let again = row("2", "Example Stream", -11.99, daysAgo: 5)
        let state = SubscriptionAnalytics.cancellations(in: [old, again])
        let vendor = SubscriptionAnalytics.normalizeVendor("Example Stream")
        XCTAssertTrue(state.chargedAgain.contains(vendor))
        XCTAssertFalse(state.cancelled.contains(vendor))
    }

    func testDifferentPurchaseFromACancelledVendorDoesNotUndoIt() {
        let old = row("1", "Example Stream", -11.99, daysAgo: 40)
        old.subscriptionCadenceOverride = "cancelled"
        let book = row("2", "Example Stream", -3.99, daysAgo: 5)
        let state = SubscriptionAnalytics.cancellations(in: [old, book])
        XCTAssertTrue(state.cancelled.contains(SubscriptionAnalytics.normalizeVendor("Example Stream")))
        XCTAssertTrue(state.chargedAgain.isEmpty)
    }

    // MARK: - Holds that never post

    func testOldPendingHoldIsNotSpending() {
        let stale = row("1", "Example Rides", -51.22, daysAgo: 20)
        stale.isPending = true
        let fresh = row("2", "Example Rides", -8, daysAgo: 2)
        fresh.isPending = true
        XCTAssertTrue(TransactionAnalytics.isStalePending(stale))
        XCTAssertEqual(TransactionAnalytics.spendOnly([stale, fresh]).map(\.transactionId), ["2"])
    }

    // MARK: - Deposits named by a code

    func testReferenceCodeDepositReadsAsItsKind() {
        XCTAssertTrue(Income.looksLikeReferenceCode("2C5FFA70"))
        XCTAssertFalse(Income.looksLikeReferenceCode("Example Employer"))
        XCTAssertFalse(Income.looksLikeReferenceCode("PAYROLL"))
    }

    // MARK: - Ask's card and year filters

    func testLastFourPicksOneCardAmongSameBank() {
        let cards = ["0820", "4103", "5663"].map {
            BankAccount(accountId: $0, itemId: "i", name: "CREDIT CARD", mask: $0, type: "credit",
                        institutionName: "Example Bank", currentBalance: 0)
        }
        let named = AskLedger.accountsNamed(in: "How much did I spend on my Example Bank 0820 card?", among: cards)
        XCTAssertEqual(named.map(\.accountId), ["0820"])
        XCTAssertTrue(AskLedger.namesAccount("Example Bank 0820 card", named[0]))
        XCTAssertFalse(AskLedger.namesAccount("Corner Cafe", named[0]))
    }

    func testThisYearMeansJanuaryThroughNow() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15)))
        let range = try XCTUnwrap(AskLedger.yearRange(in: "What did I spend at Example Shop this year?", now: now))
        XCTAssertEqual(calendar.component(.month, from: range.start), 1)
        XCTAssertEqual(calendar.component(.month, from: range.end), 12)
        let last = try XCTUnwrap(AskLedger.yearRange(in: "dining last year", now: now))
        XCTAssertEqual(calendar.component(.year, from: last.start), 2025)
        XCTAssertNil(AskLedger.yearRange(in: "dining last month", now: now))
    }
}
