//
//  SubscriptionsView.swift
//  Finance Wizard
//
//  Recurring charges tab: detect subscriptions and variable bills,
//  mark Not Recurring vs Cancelled.
//

import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Query private var transactions: [Transaction]
    @Query private var payoffPlans: [PayoffPlan]
    @Query private var accounts: [BankAccount]

    @State private var candidates: [SubscriptionCandidate] = []
    @State private var ended: [SubscriptionCandidate] = []
    @State private var isScanning = true
    @State private var isSpinning = false
    @State private var workFinished = false
    @State private var workStartedAt: Date?
    @State private var path = NavigationPath()
    @State private var selectedDay: DateComponents? = nil
    /// A bill and the override waiting on the confirmation dialog.
    @State private var pendingOverride: (item: SubscriptionCandidate, value: String)?
    @State private var workTitle = ""

    @Environment(\.modelContext) private var modelContext

    private var monthlySummaryLabel: String {
        if isScanning { return "Scanning…" }
        return current.count == 1 ? "1 bill" : "\(current.count) bills"
    }

    private var issuerPlans: [PayoffPlan] {
        payoffPlans.filter { $0.isActive && $0.kind.followsCardStatement }
            .sorted { $0.installmentTotal > $1.installmentTotal }
    }

    private var extraPayoffPlans: [PayoffPlan] {
        payoffPlans.filter { $0.isActive && !$0.kind.followsCardStatement }
            .sorted { $0.installmentTotal > $1.installmentTotal }
    }

    private var endedPayoffPlans: [PayoffPlan] {
        payoffPlans.filter { !$0.isActive }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Bills charging on schedule. One that skipped its date is listed apart and not counted,
    /// the same way Ask treats it.
    private var current: [SubscriptionCandidate] {
        candidates.filter { !SubscriptionAnalytics.isOverdue($0) }
    }

    private var lapsed: [SubscriptionCandidate] {
        candidates.filter { SubscriptionAnalytics.isOverdue($0) }
    }

    /// Cash besides the card bill: subscriptions + extra principal plans.
    private var extraMonthly: Double {
        current.reduce(0) { $0 + $1.estimatedMonthly }
            + extraPayoffPlans.reduce(0) { $0 + $1.monthlyPayment }
    }

    /// Already inside card minima — not extra cash leaving checking twice.
    private var onCardMonthly: Double {
        issuerPlans.reduce(0) { $0 + $1.installmentTotal }
    }

    private var activePayoffPlans: [PayoffPlan] {
        payoffPlans.filter(\.isActive).sorted { $0.installmentTotal > $1.installmentTotal }
    }
    
    /// Every upcoming charge for the next year, so paging the calendar ahead still shows bills.
    private var chargeDays: Set<DateComponents> {
        var days: Set<DateComponents> = []
        for item in current {
            for date in upcomingChargeDates(for: item) {
                days.insert(Calendar.current.dateComponents([.year, .month, .day], from: date))
            }
        }
        for plan in activePayoffPlans {
            if let next = plan.nextPaymentDate(cardDueDate: cardDueDate(for: plan)) {
                days.insert(Calendar.current.dateComponents([.year, .month, .day], from: next))
            }
        }
        return days
    }

    private var payoffOnSelectedDay: [PayoffPlan] {
        guard selectedDay != nil else { return [] }
        return activePayoffPlans.filter { plan in
            guard let next = plan.nextPaymentDate(cardDueDate: cardDueDate(for: plan)) else { return false }
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: next)
            return parts.year == selectedDay?.year
                && parts.month == selectedDay?.month
                && parts.day == selectedDay?.day
        }
    }
    /// Same bills as the calendar's dots, so a marked day never opens empty.
    private var chargesOnSelectedDay: [SubscriptionCandidate] {
        guard let selectedDay else { return [] }
        return current.filter { item in
            upcomingChargeDates(for: item).contains { date in
                let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
                return parts.year == selectedDay.year && parts.month == selectedDay.month && parts.day == selectedDay.day
            }
        }
    }
    /// Calendar beside the bills when the window is wide, like the Duo's inner screen.
    @Environment(\.appWidth) private var appWidth

    private var calendarBesideBills: Bool { appWidth >= LayoutWidth.roomy }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if calendarBesideBills {
                    HStack(spacing: 0) {
                        List { calendarSections }
                            .frame(width: 380)
                        List { billSections }
                    }
                } else {
                    List {
                        calendarSections
                        billSections
                    }
                }
            }
            .navigationTitle("Recurring")
            .navigationDestination(for: String.self) { id in
                if let item = candidates.first(where: { $0.id == id }) {
                    recurringDetail(item, showCancelledButton: true)
                } else if let item = ended.first(where: { $0.id == id }) {
                    recurringDetail(item, showCancelledButton: false)
                }
            }
            .task {
                await rescan()
            }
        }
        .overlay {
            if isSpinning {
                workingOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.4), value: isSpinning)
    }

    @ViewBuilder
    private var calendarSections: some View {
        Section {
            RecurringCalendarView(chargeDays: chargeDays, selectedDay: $selectedDay)
                .frame(minHeight: 240)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .padding(.vertical, -16)
                // Beside the bills, keep the month arrows off the other column's edge.
                .padding(.horizontal, calendarBesideBills ? 12 : 0)
        }
        if let selectedDay {
            Section {
                if chargesOnSelectedDay.isEmpty && payoffOnSelectedDay.isEmpty {
                    Text("No recurring charges on this day.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(payoffOnSelectedDay, id: \.planId) { plan in
                        NavigationLink {
                            PayoffPlanEditorView(existing: plan)
                        } label: {
                            PayoffPlanRowView(plan: plan, cardDueDate: cardDueDate(for: plan))
                        }
                    }
                    ForEach(chargesOnSelectedDay) { item in
                        NavigationLink(value: item.id) {
                            subscriptionRow(item)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(Calendar.current.date(from: selectedDay)?.formatted(date: .abbreviated, time: .omitted) ?? "Selected day")
                    Spacer()
                    Button("Clear") { self.selectedDay = nil }
                        .font(.subheadline)
                        .textCase(nil)
                }
            }
        }
    }

    @ViewBuilder
    private var billSections: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Extra bills")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MoneyText(extraMonthly)
                        .font(.title2.weight(.bold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(monthlySummaryLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if onCardMonthly > 0.005 {
                        Text("+\(onCardMonthly.formatted(.currency(code: "USD"))) on cards")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Extra bills are subscriptions and other charges besides the card payment. Loans and installments are already in the card minimum.")
        }

        if !issuerPlans.isEmpty {
            Section {
                ForEach(issuerPlans, id: \.planId) { plan in
                    NavigationLink {
                        PayoffPlanEditorView(existing: plan)
                    } label: {
                        PayoffPlanRowView(plan: plan, cardDueDate: cardDueDate(for: plan))
                    }
                }
            } header: {
                Text("On your cards")
            } footer: {
                Text("Due with the statement. Included in the card minimum — not extra cash.")
            }
        }

        if !extraPayoffPlans.isEmpty {
            Section {
                ForEach(extraPayoffPlans, id: \.planId) { plan in
                    NavigationLink {
                        PayoffPlanEditorView(existing: plan)
                    } label: {
                        PayoffPlanRowView(plan: plan, cardDueDate: cardDueDate(for: plan))
                    }
                }
            } header: {
                Text("Pay off extra")
            }
        }

        Section {
            if isScanning && candidates.isEmpty {
                ProgressView("Scanning…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
            } else if current.isEmpty {
                ContentUnavailableView(
                    "No repeating bills yet",
                    systemImage: "repeat.circle",
                    description: Text("Subscriptions and marked monthly bills show up here.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(current) { item in
                    NavigationLink(value: item.id) {
                        subscriptionRow(item)
                    }
                }
            }
        } header: {
            Text("Bills")
        }

        if !lapsed.isEmpty {
            Section {
                ForEach(lapsed) { item in
                    NavigationLink(value: item.id) {
                        subscriptionRow(item)
                    }
                }
            } header: {
                Text("Hasn't charged lately")
            } footer: {
                Text("These missed their usual date, so they aren't counted in Extra bills. If one has ended, open it and mark it cancelled.")
            }
        }

        if !ended.isEmpty || !endedPayoffPlans.isEmpty {
            Section {
                ForEach(ended) { item in
                    NavigationLink(value: item.id) {
                        subscriptionRow(item)
                    }
                }
                ForEach(endedPayoffPlans, id: \.planId) { plan in
                    NavigationLink {
                        PayoffPlanEditorView(existing: plan)
                    } label: {
                        PayoffPlanRowView(plan: plan, cardDueDate: cardDueDate(for: plan))
                    }
                }
            } header: {
                Text("Ended")
            }
        }
    }

    private func recurringDetail(_ item: SubscriptionCandidate, showCancelledButton: Bool) -> some View {
        // Skip the expensive charge scan while the overlay is up so each
        // SwiftData write does not rebuild Times Seen + the charge list.
        let matches = isSpinning ? [] : matchingTransactions(for: item)
        let wasCancelled = matches.contains { $0.subscriptionCadenceOverride == "cancelled" }
        return List {
            Section {
                LabeledContent("Repeats", value: item.cadence.displayName)
                LabeledContent("Amount") {
                    MoneyText(item.typicalAmount, prefix: item.amountVaries ? "About " : "")
                }
                if !isSpinning {
                    LabeledContent("Charges found", value: "\(matches.count)")
                }
                LabeledContent("Last charged", value: item.lastDate.formatted(date: .abbreviated, time: .omitted))
                if let next = nextChargeDate(for: item), next > Date() {
                    LabeledContent("Next charge", value: next.formatted(date: .abbreviated, time: .omitted))
                }
            } footer: {
                Text(item.confidenceNote)
            }
            Section {
                if wasCancelled {
                    Button("Mark active again") {
                        Task { await applyOverride(nil, on: item) }
                    }
                    .disabled(isSpinning)
                } else if showCancelledButton {
                    Button("It's cancelled") { pendingOverride = (item, "cancelled") }
                        .disabled(isSpinning)
                }
                Button("Not a recurring bill", role: .destructive) { pendingOverride = (item, "none") }
                    .disabled(isSpinning)
            } footer: {
                Text("Cancelled keeps it under Ended. Not a recurring bill hides it from this tab. Either one applies to every charge from \(item.displayVendor).")
            }
            if !isSpinning {
                Section("Charges") {
                    ForEach(matches) { tx in
                        NavigationLink {
                            TransactionDetailView(transaction: tx)
                        } label: {
                            TransactionRowView(
                                transaction: tx,
                                account: BankAccount.matching(paymentMethod: tx.paymentMethod, in: accounts)
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle(item.displayVendor)
        .confirmationDialog(
            pendingOverride?.value == "cancelled"
                ? "Mark \(item.displayVendor) as cancelled?"
                : "Stop treating \(item.displayVendor) as a recurring bill?",
            isPresented: Binding(
                get: { pendingOverride != nil },
                set: { if !$0 { pendingOverride = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = pendingOverride {
                Button(pending.value == "cancelled" ? "Mark cancelled" : "Not recurring", role: .destructive) {
                    pendingOverride = nil
                    Task { await applyOverride(pending.value, on: pending.item) }
                }
            }
            Button("Cancel", role: .cancel) { pendingOverride = nil }
        }
    }

    @ViewBuilder
    private func subscriptionRow(_ item: SubscriptionCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "repeat.circle.fill")
                .font(.title3)
                .foregroundStyle(item.isUserDeclared ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayVendor)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                if let next = nextChargeDate(for: item), next > Date() {
                    Text("\(item.cadence.displayName) · next \(next.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(item.cadence.displayName) · last \(item.lastDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(item.typicalAmount, prefix: item.amountVaries ? "~" : "")
                    .font(.body.weight(.semibold))
                // A monthly bill's amount already is its monthly cost.
                if item.cadence != .monthly {
                    MoneyText(item.estimatedMonthly, prefix: "~", suffix: "/mo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var workingOverlay: some View {
        if isSpinning {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    Spacer()
                    BundleGIFView(resource: "WorkingOverlay")
                        .frame(width: 240, height: 164)
                    Text(workFinished ? "Done" : workTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.horizontal, 16)
            }
            .allowsHitTesting(true)
        }
    }

    private func cardDueDate(for plan: PayoffPlan) -> Date? {
        if let id = plan.accountId {
            if let match = accounts.first(where: { $0.accountId == id }) {
                return match.nextPaymentDueDate
            }
        }
        return accounts.first { $0.matchesPaymentMethod(plan.paymentMethod) }?.nextPaymentDueDate
    }

    @MainActor
    private func detectGroups() async -> (active: [SubscriptionCandidate], ended: [SubscriptionCandidate]) {
        await logWork("Snapshotting \(transactions.count) transactions")
        let snaps = SubscriptionAnalytics.snapshots(from: transactions)
        await logWork("Detecting recurring charges")
        let found = await Task.detached(priority: .userInitiated) {
            SubscriptionAnalytics.detectAll(snapshots: snaps)
        }.value
        await logWork("Detector returned \(found.count) group(s)")
        await logWork("Building cancelled-vendor set")
        let cancelledVendors = SubscriptionAnalytics.cancelledVendors(in: transactions)
        await logWork("\(cancelledVendors.count) cancelled vendor(s)")
        let active = found.filter { SubscriptionAnalytics.isActive($0) && !cancelledVendors.contains($0.normalizedVendor) }
        let endedGroups = found.filter { !SubscriptionAnalytics.isActive($0) || cancelledVendors.contains($0.normalizedVendor) }
        await logWork("Active \(active.count), ended \(endedGroups.count)")
        return (active, endedGroups)
    }

    @MainActor
    private func rescan(showScanning: Bool = true) async {
        if showScanning { isScanning = true }
        PayoffPlanProgress.applyStatementProgress(
            plans: Array(payoffPlans),
            accounts: Array(accounts)
        )
        try? modelContext.save()
        let groups = await detectGroups()
        candidates = groups.active
        ended = groups.ended
        isScanning = false
    }

    private func matchingTransactions(for item: SubscriptionCandidate) -> [Transaction] {
        transactions
            .filter { tx in
                if tx.isDeclaredNotSubscription { return false }
                guard SubscriptionAnalytics.charge(title: tx.title, category: tx.category, belongsTo: item.normalizedVendor)
                else { return false }
                // User-marked or variable bills (phone, electric): amount may change.
                if item.isUserDeclared || item.amountVaries { return true }
                let tol = max(0.25, item.typicalAmount * 0.01)
                return abs(abs(tx.amount) - item.typicalAmount) <= tol
            }
            .sorted { $0.date > $1.date }
    }

    private func nextChargeDate(for item: SubscriptionCandidate) -> Date? {
        chargeDate(for: item, step: 1)
    }

    private func chargeDate(for item: SubscriptionCandidate, step: Int) -> Date? {
        let cal = Calendar.current
        switch item.cadence {
        case .weekly:
            return cal.date(byAdding: .day, value: 7 * step, to: item.lastDate)
        case .monthly:
            return cal.date(byAdding: .month, value: step, to: item.lastDate)
        case .yearly:
            return cal.date(byAdding: .year, value: step, to: item.lastDate)
        }
    }

    /// Projected charges from today through a year out.
    private func upcomingChargeDates(for item: SubscriptionCandidate) -> [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        guard let horizon = Calendar.current.date(byAdding: .year, value: 1, to: today) else { return [] }
        var dates: [Date] = []
        var step = 1
        while let date = chargeDate(for: item, step: step), date <= horizon, step <= 60 {
            if date >= today { dates.append(date) }
            step += 1
        }
        return dates
    }

    /// Recurring radar: `"none"` hides the vendor, `"cancelled"` keeps it under Ended, and nil
    /// clears either so detection decides again.
    @MainActor
    private func applyOverride(_ value: String?, on item: SubscriptionCandidate) async {
        workStartedAt = Date()
        workFinished = false
        workTitle = switch value {
        case "cancelled": "Marking \(item.displayVendor) cancelled…"
        case "none": "Removing \(item.displayVendor) from Recurring…"
        default: "Marking \(item.displayVendor) active…"
        }
        isSpinning = true
        defer {
            isSpinning = false
            workFinished = false
        }
        let matches = matchingTransactions(for: item)
        await logWork("Writing \(value ?? "nil") on \(matches.count) charge(s)")
        for tx in matches {
            tx.subscriptionCadenceOverride = value
        }
        try? modelContext.save()
        let groups = await detectGroups()
        workFinished = true
        try? await Task.sleep(for: .seconds(1))
        path = NavigationPath()
        candidates = groups.active
        ended = groups.ended
        isScanning = false
    }

    /// Timing for the Xcode console only; the overlay just says what's happening.
    @MainActor
    private func logWork(_ message: String) async {
        #if DEBUG
        guard isSpinning, let start = workStartedAt else { return }
        print("[Recurring] \(String(format: "+%5.2fs", Date().timeIntervalSince(start)))  \(message)")
        #endif
    }
}

#Preview {
    SubscriptionsView()
}
