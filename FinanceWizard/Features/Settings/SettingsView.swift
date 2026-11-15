//
//  SettingsView.swift
//  Finance Wizard
//

import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var clientID: String = ""
    @State private var secret: String = ""
    @State private var environment: PlaidEnvironment = .sandbox
    @State private var redirectURI: String = ""
    @State private var didSave = false
    @State private var showSecret = false
    /// Relink must capture the Item here so the sheet doesn’t fall back to `.new`.
    @State private var linkSheetRequest: LinkSheetRequest?
    @State private var linkedItems: [PlaidLinkedItem] = []
    @Query private var bankAccounts: [BankAccount]
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var itemPendingDelete: PlaidLinkedItem?

    @State private var isExportingDebug = false
    @State private var debugExportURL: URL?
    @State private var showDebugShare = false
    @State private var showDebugExportConfirm = false

    @State private var showBackupPasswordSheet = false
    @State private var showRestorePasswordSheet = false
    @State private var showRestoreFilePicker = false
    @State private var showRestoreConfirm = false
    @State private var isWorkingPlaidBackup = false
    @State private var plaidBackupShareURL: URL?
    @State private var showPlaidBackupShare = false
    @State private var pendingRestoreURL: URL?
    @State private var appleCardConnected = WalletSync.isConnected
    @State private var appleCardError: String?
    @State private var isConnectingAppleCard = false
    @State private var pendingRestorePayload: PlaidConnectionBackup.Payload?
    @State private var showRestorePlanSheet = false
    @State private var restorePolicy: PlaidConnectionBackup.RestorePolicy = .safeMerge

    @AppStorage(ScreenshotPrivacy.storageKey) private var screenshotPrivacy = false
    @Environment(\.sampleData) private var sampleData
    @State private var showsDeveloperTools = false
    @State private var showEraseAllData = false

    @Environment(\.appWidth) private var appWidth
    private var twoColumns: Bool { appWidth >= LayoutWidth.twoColumn }

    /// The page shown beside the sidebar when Settings has two columns.
    @State private var page: SettingsPage? = .banks

    var body: some View {
        Group {
            if twoColumns {
                twoColumnSettings
            } else {
                NavigationStack {
                    Form {
                        if sampleData.isActive {
                            SampleDataBanner()
                        }
                        privacySection
                        // Sample data has no keys, banks, or backups of its own.
                        if !sampleData.isActive {
                            plaidSection
                            banksSection
                            statusSection
                            appleCardSection
                            backupSection
                            eraseSection
                        }
                        aboutSection
                        aiSection
                        developerSection
                    }
                    .navigationTitle("Settings")
                }
            }
        }
            .task { showsDeveloperTools = await DeveloperTools.isAvailable() }
            .sheet(isPresented: $showEraseAllData, onDismiss: reload) {
                EraseAllDataView()
            }
            .onAppear {
                reload()
                consumeIncomingBackupIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: PlaidConnectionBackup.openFileNotification)) { _ in
                consumeIncomingBackupIfNeeded()
            }
            .onChange(of: pendingRestoreURL) { oldURL, _ in
                PlaidConnectionBackup.discardTemporaryFile(oldURL)
            }
            .sheet(item: $linkSheetRequest, onDismiss: reload) { request in
                PlaidLinkSheet(mode: request.mode) { result in
                    switch result {
                    case .success(let item):
                        statusIsError = false
                        switch request.mode {
                        case .new:
                            statusMessage = "Linked \(item.institutionName). Tap Sync on Transactions."
                            Task { await reconcileAfterRelink(item) }
                        case .update:
                            statusMessage = "Relinked \(item.institutionName). Refreshing accounts…"
                            Task { await reconcileAfterRelink(item) }
                        }
                    case .failure(let error):
                        statusIsError = true
                        statusMessage = error.localizedDescription
                    }
                    reload()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .plaidItemsReplaced)) { note in
                let ids = (note.userInfo?["itemIds"] as? [String]) ?? []
                guard !ids.isEmpty else { return }
                let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
                for account in all where ids.contains(account.itemId) {
                    modelContext.delete(account)
                }
                try? modelContext.save()
                reload()
            }
            .confirmationDialog(
                "Unlink \(itemPendingDelete?.institutionName ?? "bank")?",
                isPresented: Binding(
                    get: { itemPendingDelete != nil },
                    set: { if !$0 { itemPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Unlink", role: .destructive) {
                    if let item = itemPendingDelete {
                        unlink(item)
                    }
                    itemPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    itemPendingDelete = nil
                }
            } message: {
                Text("Unlinks this bank from Budget Magi. You can also remove it from your Plaid account.")
            }
            .confirmationDialog(
                "Export debug data?",
                isPresented: $showDebugExportConfirm,
                titleVisibility: .visible
            ) {
                Button("Export & Share") {
                    Task { await runDebugExport() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Shares a local copy of your data for troubleshooting. Secrets and bank login tokens are not included.")
            }
            .confirmationDialog(
                "Restore from backup?",
                isPresented: $showRestoreConfirm,
                titleVisibility: .visible
            ) {
                Button("Choose backup file…") {
                    showRestoreFilePicker = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You’ll enter the backup password, then review a restore plan. Safe merge never overwrites access tokens already on this phone. Wipe device, then restore deletes local data first so the backup is the only copy.")
            }
            .sheet(isPresented: $showDebugShare, onDismiss: {
                debugExportURL = nil
                DebugDataExporter.discardTemporaryFiles()
            }) {
                if let debugExportURL {
                    ShareSheet(items: [debugExportURL]) {
                        showDebugShare = false
                    }
                }
            }
            .sheet(isPresented: $showPlaidBackupShare, onDismiss: {
                PlaidConnectionBackup.discardTemporaryFile(plaidBackupShareURL)
                plaidBackupShareURL = nil
            }) {
                if let plaidBackupShareURL {
                    ShareSheet(items: [plaidBackupShareURL]) {
                        showPlaidBackupShare = false
                    }
                }
            }
            .sheet(isPresented: $showBackupPasswordSheet) {
                PlaidBackupPasswordSheet(
                    mode: .createBackup,
                    isWorking: $isWorkingPlaidBackup
                ) { password in
                    try await runPlaidBackup(password: password)
                }
            }
            .sheet(isPresented: $showRestorePasswordSheet, onDismiss: {
                // Drop the security-scoped file if the user cancelled without decrypting.
                if !isWorkingPlaidBackup && pendingRestorePayload == nil {
                    pendingRestoreURL = nil
                }
            }) {
                PlaidBackupPasswordSheet(
                    mode: .restore,
                    isWorking: $isWorkingPlaidBackup
                ) { password in
                    try await decryptRestorePayload(password: password)
                }
            }
            .sheet(isPresented: $showRestorePlanSheet, onDismiss: {
                if !isWorkingPlaidBackup {
                    pendingRestorePayload = nil
                    pendingRestoreURL = nil
                    restorePolicy = .safeMerge
                }
            }) {
                if let payload = pendingRestorePayload {
                    PlaidRestorePlanSheet(
                        payload: payload,
                        policy: $restorePolicy,
                        isWorking: $isWorkingPlaidBackup
                    ) {
                        try await applyRestorePayload()
                    }
                }
            }
            .fileImporter(
                isPresented: $showRestoreFilePicker,
                allowedContentTypes: Self.plaidBackupContentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    pendingRestoreURL = url
                    pendingRestorePayload = nil
                    restorePolicy = .safeMerge
                    showRestorePasswordSheet = true
                case .failure(let error):
                    statusIsError = true
                    statusMessage = error.localizedDescription
                }
            }
    }

    // MARK: - Two columns, laid out like the Settings app

    private var pages: [[SettingsPage]] {
        var groups: [[SettingsPage]] = []
        if !sampleData.isActive {
            groups.append([.banks] + (WalletSync.isAvailable ? [.appleCard] : []) + [.plaid])
            groups.append([.privacy, .backup, .ai])
            groups.append([.about] + (showsDeveloperTools ? [.developer] : []) + [.erase])
        } else {
            groups.append([.privacy, .ai])
            groups.append([.about])
        }
        return groups
    }

    private var twoColumnSettings: some View {
        NavigationSplitView {
            List(selection: $page) {
                if sampleData.isActive {
                    SampleDataBanner()
                }
                Section {
                    SettingsAppHeader()
                        .tag(SettingsPage.about)
                }
                ForEach(pages, id: \.self) { group in
                    Section {
                        ForEach(group) { item in
                            SettingsPageRow(page: item)
                                .tag(item)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .containerBackground(Color(.systemGroupedBackground), for: .navigation)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            NavigationStack {
                Form {
                    switch page ?? .banks {
                    case .banks:
                        banksSection
                        statusSection
                    case .appleCard:
                        appleCardSection
                        statusSection
                    case .plaid:
                        plaidSection
                        statusSection
                    case .privacy:
                        privacySection
                    case .backup:
                        backupSection
                        statusSection
                    case .ai:
                        aiSection
                    case .about:
                        aboutSection
                    case .developer:
                        developerSection
                    case .erase:
                        eraseSection
                    }
                }
                .navigationTitle((page ?? .banks).title)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Sections

    /// Hide amounts for screenshots.
    @ViewBuilder
    private var privacySection: some View {
                // MARK: Screenshot privacy
                Section {
                    Toggle(isOn: $screenshotPrivacy) {
                        Label("Hide for screenshots", systemImage: "eye.slash")
                    }
                } header: {
                    // Beside the sidebar the page title already says this.
                    if !twoColumns { Text("Privacy") }
                }
    }

    /// The user's own Plaid keys.
    @ViewBuilder
    private var plaidSection: some View {
                // MARK: Credentials
                Section {
                    LabeledContent("Client ID") {
                        TextField("client_id", text: $clientID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Secret")
                        Group {
                            if showSecret {
                                TextField("secret", text: $secret)
                            } else {
                                SecureField("secret", text: $secret)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)

                        Button {
                            showSecret.toggle()
                        } label: {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    Picker("Environment", selection: $environment) {
                        ForEach(PlaidEnvironment.allCases) { env in
                            Text(env.displayName).tag(env)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Redirect URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("OAuth redirect override", text: $redirectURI)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .keyboardType(.URL)
                            .textContentType(.URL)
                    }

                    Button("Save credentials") {
                        saveCredentials()
                    }

                    if didSave {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } header: {
                    // Beside the sidebar the page title already says this.
                    if !twoColumns { Text("Plaid account") }
                }
    }

    /// Linked banks, with relink and unlink.
    @ViewBuilder
    private var banksSection: some View {
                // MARK: Linked banks
                Section {
                    if linkedItems.isEmpty {
                        Text("No banks linked yet.")
                            .foregroundStyle(.secondary)
                        Button("Try with sample data") { sampleData.start() }
                    } else {
                        ForEach(linkedItems) { item in
                            HStack(spacing: 12) {
                                BankIconView(
                                    paymentMethod: item.institutionName,
                                    size: 36,
                                    displayName: item.institutionName,
                                    institutionName: item.institutionName
                                )
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.institutionName)
                                        .font(.body.weight(.semibold))
                                    if item.needsRelink {
                                        Text(item.errorMessage ?? "Login expired — Relink required")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                        Button("Relink") { startRelink(item) }
                                            .font(.caption.weight(.semibold))
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            .disabled(!PlaidCredentialsStore.isConfigured)
                                    } else if !accountNames(for: item).isEmpty {
                                        Text(accountNames(for: item).joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text("Linked \(item.linkedAt.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    startRelink(item)
                                } label: {
                                    Label("Relink…", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .disabled(!PlaidCredentialsStore.isConfigured)

                                Button(role: .destructive) {
                                    itemPendingDelete = item
                                } label: {
                                    Label("Unlink", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    startRelink(item)
                                } label: {
                                    Label("Relink", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .tint(.gray)
                                .disabled(!PlaidCredentialsStore.isConfigured)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    itemPendingDelete = item
                                } label: {
                                    Label("Unlink", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Button {
                        linkSheetRequest = LinkSheetRequest(mode: .new)
                    } label: {
                        Label("Link bank account", systemImage: "plus.circle.fill")
                    }
                    .disabled(!PlaidCredentialsStore.isConfigured)
                } header: {
                    // Beside the sidebar the page title already says this.
                    if !twoColumns { Text("Linked banks") }
                }
    }

    /// The result of the last link, save, or backup, near those controls.
    @ViewBuilder
    private var statusSection: some View {
                // Results of linking, saving keys and backups, kept near those controls.
                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusIsError ? .red : .secondary)
                    }
                }
    }

    /// Apple Card from Wallet, where FinanceKit runs.
    @ViewBuilder
    private var appleCardSection: some View {
                // MARK: Apple Card
                if WalletSync.isAvailable, !sampleData.isActive {
                    Section {
                        if appleCardConnected {
                            LabeledContent("Apple Card") {
                                Text("Connected").foregroundStyle(.green)
                            }
                            Button("Disconnect Apple Card", role: .destructive) {
                                WalletSync.disconnect(modelContext: modelContext)
                                appleCardConnected = false
                            }
                        } else {
                            Button {
                                Task {
                                    isConnectingAppleCard = true
                                    defer { isConnectingAppleCard = false }
                                    appleCardError = nil
                                    do {
                                        try await WalletSync.connect()
                                        appleCardConnected = true
                                        let report = try await WalletSync.sync(modelContext: modelContext)
                                        statusIsError = false
                                        statusMessage = (["Apple Card connected."] + report.lines).joined(separator: " ")
                                    } catch {
                                        appleCardError = error.localizedDescription
                                    }
                                }
                            } label: {
                                if isConnectingAppleCard {
                                    HStack {
                                        ProgressView()
                                        Text("Reading Apple Card…")
                                    }
                                } else {
                                    Label("Connect Apple Card", systemImage: "creditcard")
                                }
                            }
                            .disabled(isConnectingAppleCard)
                        }
                        if let appleCardError {
                            Text(appleCardError)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        // Beside the sidebar the page title already says this.
                        if !twoColumns { Text("Apple Card") }
                    } footer: {
                        Text("Reads your Apple Card balance and transactions from Wallet on this iPhone. Nothing is sent anywhere, and it updates each time you Sync.")
                    }
                }
    }

    /// Encrypted backup and restore.
    @ViewBuilder
    private var backupSection: some View {
                // MARK: Full backup
                Section {
                    Button {
                        showBackupPasswordSheet = true
                    } label: {
                        if isWorkingPlaidBackup {
                            HStack {
                                ProgressView()
                                Text("Working…")
                            }
                        } else {
                            Label("Back up everything", systemImage: "lock.shield")
                        }
                    }
                    .disabled(isWorkingPlaidBackup)

                    Button {
                        showRestoreConfirm = true
                    } label: {
                        Label("Restore from backup", systemImage: "arrow.counterclockwise.circle")
                    }
                    .disabled(isWorkingPlaidBackup)
                } header: {
                    // Beside the sidebar the page title already says this.
                    if !twoColumns { Text("Backup & restore") }
                }
    }

    /// Deletes everything after typing DELETE.
    @ViewBuilder
    private var eraseSection: some View {
                Section {
                    Button("Erase all data", role: .destructive) { showEraseAllData = true }
                } footer: {
                    Text("Deletes everything on this device, including your banks and keys.")
                }
    }

    /// Version, help, and privacy policy.
    @ViewBuilder
    private var aboutSection: some View {
                // MARK: About
                Section {
                    NavigationLink {
                        AboutBuildView()
                    } label: {
                        HStack {
                            Text("About")
                            Spacer()
                            Text(AppBuildInfo.versionBuildLabel)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Link(destination: URL(string: "https://budgetmagi.pages.dev/support.html")!) {
                        Label("Help & support", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://budgetmagi.pages.dev/privacy.html")!) {
                        Label("Privacy policy", systemImage: "hand.raised")
                    }
                }
    }

    /// Whether Apple Intelligence can run here.
    @ViewBuilder
    private var aiSection: some View {
                Section {
                    OnDeviceAIStatusView()
                } header: {
                    // Beside the sidebar the page title already says this.
                    if !twoColumns { Text("On-device AI") }
                }
    }

    /// Debug tools for testers.
    @ViewBuilder
    private var developerSection: some View {
                if showsDeveloperTools, !sampleData.isActive {
                    Section {
                        NavigationLink {
                            DebugMenuView()
                        } label: {
                            Label("Debug", systemImage: "ant")
                        }
                        Button {
                            showDebugExportConfirm = true
                        } label: {
                            if isExportingDebug {
                                HStack {
                                    ProgressView()
                                    Text("Preparing export…")
                                }
                            } else {
                                Label("Export database for debug", systemImage: "square.and.arrow.up")
                            }
                        }
                        .disabled(isExportingDebug)
                    } header: {
                        // Beside the sidebar the page title already says this.
                        if !twoColumns { Text("Developer") }
                    }
                }
    }

    /// UTTypes accepted by the restore file picker.
    private static var plaidBackupContentTypes: [UTType] {
        PlaidConnectionBackup.importContentTypes
    }

    /// Start restore when a `.fwbackup` was opened from Files / another app.
    private func consumeIncomingBackupIfNeeded() {
        if let error = AppBackupOpenBridge.pendingError {
            AppBackupOpenBridge.pendingError = nil
            statusIsError = true
            statusMessage = error
            return
        }
        guard let url = AppBackupOpenBridge.pendingURL else { return }
        AppBackupOpenBridge.pendingURL = nil
        pendingRestoreURL = url
        pendingRestorePayload = nil
        restorePolicy = .safeMerge
        showRestorePasswordSheet = true
        statusIsError = false
        statusMessage = "Opened \(url.lastPathComponent). Enter the backup password to continue."
    }

    @MainActor
    private func runDebugExport() async {
        isExportingDebug = true
        statusMessage = nil
        defer { isExportingDebug = false }
        do {
            let url = try DebugDataExporter.exportPackage(modelContext: modelContext)
            debugExportURL = url
            showDebugShare = true
            statusIsError = false
            statusMessage = "Debug export ready: \(url.lastPathComponent)"
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    /// Encrypt full app state and present the system share sheet.
    @MainActor
    private func runPlaidBackup(password: String) async throws {
        isWorkingPlaidBackup = true
        defer { isWorkingPlaidBackup = false }
        // Yield once so the sheet can paint the ProgressView before PBKDF2 runs.
        await Task.yield()
        let url = try PlaidConnectionBackup.exportEncryptedFile(
            password: password,
            modelContext: modelContext
        )
        plaidBackupShareURL = url
        showPlaidBackupShare = true
        statusIsError = false
        let banks = PlaidItemStore.loadItems().count
        statusMessage = "Encrypted full backup ready (\(banks) bank connection\(banks == 1 ? "" : "s") + local data). Save it somewhere safe."
        reload()
    }

    /// Decrypt only — shows the Safe merge plan before any writes.
    @MainActor
    private func decryptRestorePayload(password: String) async throws {
        guard let url = pendingRestoreURL else {
            throw PlaidConnectionBackup.BackupError.invalidFile
        }
        isWorkingPlaidBackup = true
        defer { isWorkingPlaidBackup = false }
        await Task.yield()
        let payload = try PlaidConnectionBackup.decryptPayload(from: url, password: password)
        pendingRestorePayload = payload
        restorePolicy = .safeMerge
        showRestorePlanSheet = true
    }

    /// Apply the decrypted payload with the chosen policy.
    @MainActor
    private func applyRestorePayload() async throws {
        guard let payload = pendingRestorePayload else {
            throw PlaidConnectionBackup.BackupError.invalidFile
        }
        isWorkingPlaidBackup = true
        defer { isWorkingPlaidBackup = false }
        await Task.yield()
        let summary = try PlaidConnectionBackup.apply(
            payload: payload,
            policy: restorePolicy,
            modelContext: modelContext
        )
        // Kept on failure: the review sheet needs the payload to show the error.
        pendingRestorePayload = nil
        pendingRestoreURL = nil
        reload()
        clientID = PlaidCredentialsStore.clientID
        secret = PlaidCredentialsStore.secret
        environment = PlaidCredentialsStore.environment
        redirectURI = PlaidCredentialsStore.redirectURI
        statusIsError = false
        statusMessage = restoreStatusMessage(summary)
    }

    private func restoreStatusMessage(_ summary: PlaidConnectionBackup.RestoreSummary) -> String {
        var parts: [String] = []
        if summary.itemsAdded > 0 {
            let names = summary.institutionNamesAdded.isEmpty
                ? "\(summary.itemsAdded) bank(s)"
                : summary.institutionNamesAdded.joined(separator: ", ")
            parts.append("added \(names)")
        }
        if summary.itemsPreserved > 0 {
            parts.append(summary.itemsPreserved == 1 ? "kept 1 bank already on this iPhone" : "kept \(summary.itemsPreserved) banks already on this iPhone")
        }
        if summary.itemsTokenReplaced > 0 {
            parts.append(summary.itemsTokenReplaced == 1 ? "reconnected 1 bank" : "reconnected \(summary.itemsTokenReplaced) banks")
        }
        if summary.credentialsWritten {
            parts.append("API keys written")
        } else if summary.credentialsSkipped {
            parts.append("API keys left unchanged")
        }
        if summary.transactionsUpserted > 0 {
            parts.append(summary.transactionsUpserted == 1 ? "1 transaction" : "\(summary.transactionsUpserted) transactions")
        }
        if summary.incomeUpserted > 0 {
            parts.append(summary.incomeUpserted == 1 ? "1 deposit" : "\(summary.incomeUpserted) deposits")
        }
        if summary.bankAccountsUpserted > 0 {
            parts.append(summary.bankAccountsUpserted == 1 ? "1 account" : "\(summary.bankAccountsUpserted) accounts")
        }
        if summary.payoffPlansUpserted > 0 {
            parts.append(summary.payoffPlansUpserted == 1 ? "1 payoff plan" : "\(summary.payoffPlansUpserted) payoff plans")
        }
        let detail = parts.isEmpty ? "nothing new to apply" : parts.joined(separator: " · ")
        let policyLabel: String = {
            switch summary.policy {
            case .safeMerge: return "safe merge"
            case .replaceConnections: return "replace"
            case .wipeThenRestore: return "wipe then restore"
            }
        }()
        return "Restored with \(policyLabel): \(detail). Sync brings your banks up to date."
    }

    /// Reloads credentials and linked banks from stores into local @State for the form.
    private func reload() {
        clientID = PlaidCredentialsStore.clientID
        secret = PlaidCredentialsStore.secret
        environment = PlaidCredentialsStore.environment
        // Drop legacy localhost OAuth redirect (not a valid Plaid allowlist target)
        PlaidCredentialsStore.clearLegacyLocalhostRedirectIfNeeded()
        redirectURI = PlaidCredentialsStore.redirectURI
        linkedItems = PlaidItemStore.loadItems()
        // One-shot cleanup of BankAccounts left behind by old Relink/Unlink bugs
        let removed = PlaidSyncEngine.cleanupStaleBankAccounts(modelContext: modelContext)
        if removed > 0 {
            try? modelContext.save()
        }
    }

    /// Writes the form fields into PlaidCredentialsStore (device-local storage).
    /// The bank's accounts by the names used everywhere else, nicknames included.
    private func accountNames(for item: PlaidLinkedItem) -> [String] {
        let names = bankAccounts.filter { $0.itemId == item.id }.map(\.displayName).sorted()
        return names.isEmpty ? item.accountNames : names
    }

    private func saveCredentials() {
        PlaidCredentialsStore.clientID = clientID
        PlaidCredentialsStore.secret = secret
        PlaidCredentialsStore.environment = environment
        let trimmedRedirect = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        // Plaid only allows https:// redirect URIs in the dashboard allowlist.
        if !trimmedRedirect.isEmpty, !trimmedRedirect.lowercased().hasPrefix("https://") {
            statusIsError = true
            statusMessage = "OAuth redirect must start with https:// (Plaid does not allow custom schemes there)."
            return
        }
        PlaidCredentialsStore.redirectURI = trimmedRedirect
        PlaidCredentialsStore.clearLegacyLocalhostRedirectIfNeeded()
        redirectURI = PlaidCredentialsStore.redirectURI
        didSave = true
        statusIsError = false
        statusMessage = "Credentials saved on this device."
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didSave = false
        }
    }

    /// Opens Plaid Link in update mode for an existing linked Item (relink / re-auth).
    private func startRelink(_ item: PlaidLinkedItem) {
        guard PlaidCredentialsStore.isConfigured else {
            statusIsError = true
            statusMessage = "Add Plaid credentials before relinking."
            return
        }
        linkSheetRequest = LinkSheetRequest(mode: .update(item))
    }

    /// Pull live accounts after update-mode Link and drop deselected ones from SwiftData.
    @MainActor
    private func reconcileAfterRelink(_ item: PlaidLinkedItem) async {
        PlaidItemStore.clearItemError(itemID: item.id)
        do {
            let n = try await PlaidSyncEngine.reconcileItemAccounts(
                item: item,
                modelContext: modelContext
            )
            try? modelContext.save()
            statusIsError = false
            statusMessage = "Relinked \(item.institutionName) · \(n) account(s). Tap Sync for transactions."
            reload()
        } catch {
            statusIsError = true
            statusMessage = "Relinked, but account refresh failed: \(error.localizedDescription). Tap Sync."
            reload()
        }
    }

    /// Removes a bank remotely (best-effort) and deletes local rows + Plaid Item metadata.
    private func unlink(_ item: PlaidLinkedItem) {
        Task {
            // Best-effort remote remove
            try? await PlaidAPIClient.removeItem(accessToken: item.accessToken)
            // Hop back to the main actor before touching UI state / SwiftData UI models.
            await MainActor.run {
                // Remove local bank rows for this Item so they don’t linger after unlink
                let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
                for account in all where account.itemId == item.id {
                    modelContext.delete(account)
                }
                try? modelContext.save()
                PlaidItemStore.remove(itemID: item.id)
                reload()
                statusIsError = false
                statusMessage = "Unlinked \(item.institutionName)."
            }
        }
    }
}

// MARK: - Settings pages (two columns)

/// One page in the Settings sidebar, with the icon tile the Settings app would give it.
enum SettingsPage: String, Hashable, Identifiable {
    case banks, appleCard, plaid, privacy, backup, ai, about, developer, erase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .banks: "Linked banks"
        case .appleCard: "Apple Card"
        case .plaid: "Plaid account"
        case .privacy: "Privacy"
        case .backup: "Backup & restore"
        case .ai: "On-device AI"
        case .about: "About"
        case .developer: "Developer"
        case .erase: "Erase all data"
        }
    }

    var systemImage: String {
        switch self {
        case .banks: "building.columns.fill"
        case .appleCard: "creditcard.fill"
        case .plaid: "key.fill"
        case .privacy: "hand.raised.fill"
        case .backup: "lock.shield.fill"
        case .ai: "apple.intelligence"
        case .about: "info"
        case .developer: "hammer.fill"
        case .erase: "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .banks: .blue
        case .appleCard: .black
        case .plaid: .gray
        case .privacy: .indigo
        case .backup: .green
        case .ai: .purple
        case .about: .gray
        case .developer: .orange
        case .erase: .red
        }
    }
}

/// A Settings-app row: a white symbol on a colored rounded square, then the title.
private struct SettingsPageRow: View {
    let page: SettingsPage

    var body: some View {
        Label {
            Text(page.title)
        } icon: {
            Image(systemName: page.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

/// The top of the sidebar, where the Settings app shows your account: the app and its version.
private struct SettingsAppHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 56 * 0.2237, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(AppBuildInfo.displayName)
                    .font(.title3.weight(.semibold))
                Text("Version \(AppBuildInfo.versionBuildLabel)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Link sheet request (stable mode capture)

/// Identifiable wrapper so `.sheet(item:)` can present Plaid Link with a fixed mode.
/// Capturing mode on a struct avoids racey re-reads of separate @State flags.
private struct LinkSheetRequest: Identifiable {
    let id = UUID()
    let mode: PlaidLinkMode
}

// MARK: - Plaid backup password sheet

/// Collects a password for encrypting or decrypting a full app backup.
private struct PlaidBackupPasswordSheet: View {
    enum Mode {
        case createBackup
        case restore
    }

    let mode: Mode
    @Binding var isWorking: Bool
    /// Async work that throws; sheet dismisses only on success.
    let onSubmit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var showPassword = false

    private var title: String {
        switch mode {
        case .createBackup: return "Back up everything"
        case .restore: return "Unlock backup"
        }
    }

    private var canSubmit: Bool {
        let min = PlaidConnectionBackup.minimumPasswordLength
        guard password.count >= min else { return false }
        if mode == .createBackup {
            return password == confirmPassword
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Group {
                        if showPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .textContentType(mode == .createBackup ? .newPassword : .password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    if mode == .createBackup {
                        Group {
                            if showPassword {
                                TextField("Confirm password", text: $confirmPassword)
                            } else {
                                SecureField("Confirm password", text: $confirmPassword)
                            }
                        }
                        .textContentType(.newPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }

                    Toggle("Show password", isOn: $showPassword)
                } header: {
                    Text("Password")
                }

                if mode == .createBackup, !confirmPassword.isEmpty, password != confirmPassword {
                    Section {
                        Text("Passwords do not match.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button(mode == .createBackup ? "Create" : "Continue") {
                            Task { await submit() }
                        }
                        .disabled(!canSubmit)
                    }
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func submit() async {
        errorMessage = nil
        guard canSubmit else { return }
        do {
            try await onSubmit(password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Restore plan (review before writes)

/// Shows a dry-run of restore impact and policy before any Keychain / data writes.
private struct PlaidRestorePlanSheet: View {
    let payload: PlaidConnectionBackup.Payload
    @Binding var policy: PlaidConnectionBackup.RestorePolicy
    @Binding var isWorking: Bool
    let onConfirm: () async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private var plan: PlaidConnectionBackup.RestorePlan {
        PlaidConnectionBackup.planRestore(payload: payload, policy: policy)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Policy", selection: $policy) {
                        ForEach(PlaidConnectionBackup.RestorePolicy.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.inline)
                    Text(policy.detail)
                        .font(.caption)
                        .foregroundStyle(policy.wipesLocalData ? .orange : .secondary)
                } header: {
                    Text("How to restore")
                }

                Section {
                    LabeledContent("API keys") {
                        Text(plan.credentialsAction)
                            .font(.caption)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    if !plan.itemsToAdd.isEmpty {
                        LabeledContent("Banks to add") {
                            Text(plan.itemsToAdd.joined(separator: ", "))
                                .font(.caption)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.green)
                        }
                    }
                    if !plan.itemsPreserved.isEmpty {
                        LabeledContent("Tokens kept (untouched)") {
                            Text(plan.itemsPreserved.joined(separator: ", "))
                                .font(.caption)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !plan.itemsTokenReplaced.isEmpty {
                        LabeledContent("Tokens to replace") {
                            Text(plan.itemsTokenReplaced.joined(separator: ", "))
                                .font(.caption)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.orange)
                        }
                    }
                    if plan.itemsToAdd.isEmpty && plan.itemsPreserved.isEmpty && plan.itemsTokenReplaced.isEmpty {
                        Text("No bank connections in this backup.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Connections")
                }

                Section {
                    LabeledContent("Transactions", value: "\(plan.transactionCount)")
                    LabeledContent("Income", value: "\(plan.incomeCount)")
                    LabeledContent("Accounts", value: "\(plan.bankAccountCount)")
                    LabeledContent("Card payments", value: "\(plan.paymentCount)")
                    LabeledContent("Budget plans", value: "\(plan.budgetPlanCount)")
                    LabeledContent("Payoff plans", value: "\(plan.payoffPlanCount)")
                    LabeledContent("Nicknames", value: "\(plan.cardLabelCount)")
                    LabeledContent("Vendor rules", value: "\(plan.vendorRuleCount)")
                } header: {
                    Text("In this backup")
                } footer: {
                    if policy == .safeMerge {
                        Text("Rows from banks already on this phone are skipped. Sync keeps those banks current.")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Review restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button(policy.wipesLocalData ? "Wipe & Restore" : "Restore") {
                            Task { await confirm() }
                        }
                        .foregroundStyle(policy.wipesLocalData ? .red : .accentColor)
                    }
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }

    @MainActor
    private func confirm() async {
        errorMessage = nil
        do {
            try await onConfirm()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Build info (from Info.plist / Xcode versions)

/// Reads marketing version, build number, and related values from the app’s Info.plist.
enum AppBuildInfo {
    /// CFBundleShortVersionString ← MARKETING_VERSION (e.g. 1.0)
    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// CFBundleVersion ← CURRENT_PROJECT_VERSION (e.g. 5)
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// Combined label like "1.0 (1)" for display in Settings.
    static var versionBuildLabel: String {
        "\(marketingVersion) (\(buildNumber))"
    }

    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Budget Magi"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "—"
    }

    static var minimumOS: String {
        Bundle.main.object(forInfoDictionaryKey: "MinimumOSVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String
            ?? "—"
    }
}

/// Detail screen showing app version, bundle id, and device runtime info.
struct AboutBuildView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("App") {
                    Text(AppBuildInfo.displayName)
                }
                LabeledContent("Version") {
                    Text(AppBuildInfo.marketingVersion)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Build") {
                    Text(AppBuildInfo.buildNumber)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text("Release")
            }

            Section("Identifiers") {
                LabeledContent("Bundle ID") {
                    Text(AppBuildInfo.bundleIdentifier)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Minimum iOS") {
                    Text(AppBuildInfo.minimumOS)
                        .font(.body.monospaced())
                }
            }

            Section("Runtime") {
                LabeledContent("iOS") {
                    Text(UIDevice.current.systemVersion)
                        .font(.body.monospaced())
                }
                LabeledContent("Device") {
                    Text(UIDevice.current.model)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    SettingsView()
}
