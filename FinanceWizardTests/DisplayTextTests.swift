//
//  DisplayTextTests.swift
//  Finance Wizard
//
//  Wording and numbers the screens show: income expected so far, due dates that have gone by,
//  and period names inside a sentence.
//

import XCTest
@testable import FinanceWizard

final class DisplayTextTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ month: Int, _ day: Int) -> Date {
        DateComponents(calendar: calendar, year: 2026, month: month, day: day, hour: 12).date!
    }

    func testExpectedIncomeSoFarCountsOnlyPaydaysBeforeToday() {
        // Wednesdays in November 2026: the 4th, 11th, 18th, and 25th.
        let paycheck = ExpectedIncomeStream(label: "Paycheck", amount: 700, frequency: .weekly, weekday: 4)
        let whole = paycheck.expectedAmount(in: .month, referenceDate: date(11, 14), calendar: calendar)
        let soFar = paycheck.expectedAmount(in: .month, referenceDate: date(11, 14), before: date(11, 14), calendar: calendar)
        XCTAssertEqual(whole, 2_800)
        XCTAssertEqual(soFar, 1_400)
        // A payday that is today hasn't been missed yet.
        XCTAssertEqual(paycheck.expectedAmount(in: .month, referenceDate: date(11, 11), before: date(11, 11), calendar: calendar), 700)
    }

    func testPassedDueDateIsStaleUnlessTheBankSaysOverdue() {
        let card = BankAccount(
            accountId: "card", itemId: "item", name: "Example Card", type: "credit",
            institutionName: "Example Bank", currentBalance: 100,
            nextPaymentDueDate: Calendar.current.date(byAdding: .day, value: -3, to: Date())
        )
        XCTAssertTrue(card.dueDateIsStale)
        card.isOverdue = true
        XCTAssertFalse(card.dueDateIsStale)
        card.isOverdue = nil
        card.nextPaymentDueDate = Calendar.current.date(byAdding: .day, value: 5, to: Date())
        XCTAssertFalse(card.dueDateIsStale)
    }

    func testGenericCardNamesReadAsTheBankAndLastFour() {
        let generic = BankAccount(
            accountId: "generic-test", itemId: "item", name: "CREDIT CARD", mask: "4103", type: "credit",
            institutionName: "Example Bank", currentBalance: 0
        )
        XCTAssertEqual(generic.defaultDisplayName, "Example Bank ···4103")
        // Transactions store this as their payment method, so it must not change.
        XCTAssertEqual(generic.plaidDisplayName, "CREDIT CARD ···4103")

        let named = BankAccount(
            accountId: "named-test", itemId: "item", name: "Example Rewards", mask: "1002", type: "credit",
            institutionName: "Example Bank", currentBalance: 0
        )
        XCTAssertEqual(named.defaultDisplayName, "Example Rewards ···1002")
    }

    func testPeriodNamesKeepTheirCapitalMidSentence() {
        XCTAssertEqual(SnapshotPeriod.month.sentenceLabel(referenceDate: date(11, 14), now: date(11, 14), calendar: calendar), "this month")
        XCTAssertEqual(SnapshotPeriod.month.sentenceLabel(referenceDate: date(9, 10), now: date(11, 14), calendar: calendar), "September 2026")
        XCTAssertEqual(SnapshotPeriod.all.sentenceLabel(), "all time")
    }
}
