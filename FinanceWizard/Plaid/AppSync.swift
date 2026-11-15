//
//  AppSync.swift
//  Finance Wizard
//
//  The one Sync every screen runs: Apple Card first, so its payments are there for the bank
//  rows to be matched against, then each linked Plaid bank.
//

import Foundation
import SwiftData

enum AppSync {
    struct Outcome {
        /// Nil when Plaid failed, or when only Apple Card is connected.
        var report: PlaidSyncReport?
        var error: Error?
        var walletLines: [String] = []
        /// Appended to the headline, e.g. " Apple Card is up to date too."
        var walletNote = ""

        /// With only Apple Card connected there are no banks to sync, and that isn't a failure.
        var succeeded: Bool {
            report != nil || (!walletLines.isEmpty && PlaidItemStore.linkedItemIDs.isEmpty)
        }

        /// One plain sentence for a banner or status card.
        var headline: String {
            if let report { return report.headline + walletNote }
            if succeeded { return "Apple Card up to date." }
            return (walletLines + [error?.localizedDescription ?? "Sync failed."]).joined(separator: "\n")
        }

        /// The counters behind the headline, for a Details disclosure.
        var counters: String {
            (walletLines + [report?.summary].compactMap { $0 }).joined(separator: "\n")
        }
    }

    @MainActor
    static func run(
        modelContext: ModelContext,
        resetCursors: Bool = false,
        forceRefresh: Bool = false,
        progress: ((String) -> Void)? = nil
    ) async -> Outcome {
        var outcome = Outcome()
        if WalletSync.isConnected {
            do {
                outcome.walletLines = try await WalletSync.sync(modelContext: modelContext).lines
                outcome.walletNote = " Apple Card is up to date too."
            } catch {
                outcome.walletLines = ["Apple Card: \(error.localizedDescription)"]
                outcome.walletNote = " Apple Card couldn't update: \(error.localizedDescription)"
            }
        }
        do {
            outcome.report = try await PlaidSyncEngine.syncAll(
                modelContext: modelContext,
                resetCursors: resetCursors,
                includePending: true,
                forceRefresh: forceRefresh,
                progress: progress
            )
        } catch {
            outcome.error = error
        }
        return outcome
    }
}
