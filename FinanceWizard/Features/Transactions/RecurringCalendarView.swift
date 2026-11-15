//
//  RecurringCalendarView.swift
//  Finance Wizard
//
//  Native month calendar for the Recurring tab (system UICalendarView).
//

import SwiftUI
import UIKit

struct RecurringCalendarView: UIViewRepresentable {

    var chargeDays: Set<DateComponents>
    /// Card payment due dates, marked in orange so they stand apart from bills.
    var cardDueDays: Set<DateComponents> = []
    @Binding var selectedDay: DateComponents?
    func makeUIView(context: Context) -> UICalendarView {
        let grid = UICalendarView()
        grid.calendar = Calendar.current
        grid.delegate = context.coordinator
        let selection = UICalendarSelectionSingleDate(delegate: context.coordinator)
        grid.selectionBehavior = selection
        // Without this the calendar keeps its preferred width and clips in a narrow row,
        // such as beside the side tab bar on iPhone Duo.
        grid.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return grid
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICalendarView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
    }
    
    func updateUIView(_ uiView: UICalendarView, context: Context) {
        // FIX: reloading only the *current* set never re-asks the delegate about a day that
        // was removed, so its dot stayed on the calendar. Reload the union of both sets.
        let stale = context.coordinator.chargeDays.union(context.coordinator.cardDueDays)
        context.coordinator.chargeDays = chargeDays
        context.coordinator.cardDueDays = cardDueDays
        uiView.reloadDecorations(forDateComponents: Array(stale.union(chargeDays).union(cardDueDays)), animated: true)
        // Clear from SwiftUI (the Clear button) also clears the highlighted day.
        if selectedDay == nil, let selection = uiView.selectionBehavior as? UICalendarSelectionSingleDate,
           selection.selectedDate != nil {
            selection.setSelected(nil, animated: true)
        }
        
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(chargeDays: chargeDays, cardDueDays: cardDueDays, selectedDay: $selectedDay)

    }
    
    class Coordinator: NSObject, UICalendarViewDelegate, UICalendarSelectionSingleDateDelegate {
        var chargeDays: Set<DateComponents>
        var cardDueDays: Set<DateComponents>
        var selectedDay: Binding<DateComponents?>
        init(chargeDays: Set<DateComponents>, cardDueDays: Set<DateComponents>, selectedDay: Binding<DateComponents?>) {
            self.chargeDays = chargeDays
            self.cardDueDays = cardDueDays
            self.selectedDay = selectedDay
        }
        
        func dateSelection(_ selection: UICalendarSelectionSingleDate, didSelectDate dateComponents: DateComponents?) {
            selectedDay.wrappedValue = dateComponents
        }

        
        func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
            func contains(_ days: Set<DateComponents>) -> Bool {
                days.contains {
                    $0.year == dateComponents.year && $0.month == dateComponents.month && $0.day == dateComponents.day
                }
            }
            if contains(cardDueDays) { return .default(color: .systemOrange, size: .large) }
            if contains(chargeDays) { return .default() }
            return nil
        }
    }
}


#Preview {
    RecurringCalendarView(chargeDays: [Calendar.current.dateComponents([.year, .month, .day], from: Date())], selectedDay: .constant(nil))
}
