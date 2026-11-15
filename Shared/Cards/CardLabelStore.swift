//
//  CardLabelStore.swift
//  Finance Wizard
//
//  User-chosen display names for cards / payment methods.
//  Keys: "account:<plaid account_id>", "card:<bank>|<last four>", or "method:<raw payment method string>".
//

import Foundation

/// Read/write nicknames for linked cards so UI can show “Travel Visa” instead of raw Plaid text.
enum CardLabelStore {
    /// UserDefaults key for the whole [storageKey: nickname] dictionary.
    private static let labelsKey = "card.customLabels"

    // MARK: - Display name

    /// Preferred label for a Plaid bank account.
    static func label(
        accountId: String,
        fallback: String
    ) -> String {
        if let custom = getLabel(key: accountKey(accountId)), !custom.isEmpty {
            return custom
        }
        return fallback
    }

    /// Preferred label for a linked account. Relinking a bank gives every account a new id, so
    /// the bank and last four are a second key that carries the nickname over.
    static func label(
        accountId: String,
        institution: String,
        mask: String?,
        fallback: String
    ) -> String {
        if let custom = getLabel(key: accountKey(accountId)), !custom.isEmpty {
            return custom
        }
        if let key = cardKey(institution: institution, mask: mask),
           let custom = getLabel(key: key), !custom.isEmpty {
            return custom
        }
        return fallback
    }

    /// Preferred label for a transaction payment-method string.
    /// Tries account id first (stable), then raw method string, then fallback.
    static func label(
        paymentMethod: String,
        accountId: String? = nil,
        fallback: String? = nil
    ) -> String {
        if let accountId, let custom = getLabel(key: accountKey(accountId)), !custom.isEmpty {
            return custom
        }
        if let custom = getLabel(key: methodKey(paymentMethod)), !custom.isEmpty {
            return custom
        }
        return fallback ?? paymentMethod
    }

    // MARK: - Write names

    /// Save or clear a nickname for a Plaid account id.
    static func setLabel(_ name: String?, accountId: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            removeLabel(key: accountKey(accountId))
        } else {
            setLabelValue(trimmed, key: accountKey(accountId))
        }
    }

    /// Save or clear a nickname for a payment-method string key.
    static func setLabel(_ name: String?, paymentMethod: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            removeLabel(key: methodKey(paymentMethod))
        } else {
            setLabelValue(trimmed, key: methodKey(paymentMethod))
        }
    }

    /// Save nickname, preferring account id when available (stable across Sync renames).
    static func setLabel(_ name: String?, accountId: String?, paymentMethod: String) {
        if let accountId, !accountId.isEmpty {
            setLabel(name, accountId: accountId)
        } else {
            setLabel(name, paymentMethod: paymentMethod)
        }
    }

    /// Save or clear a nickname for an account, under its id and under its bank and last four.
    static func setLabel(_ name: String?, accountId: String, institution: String, mask: String?) {
        setLabel(name, accountId: accountId)
        guard let key = cardKey(institution: institution, mask: mask) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            removeLabel(key: key)
        } else {
            setLabelValue(trimmed, key: key)
        }
    }

    /// Copies nicknames saved before the bank-and-last-four key existed, so they also survive
    /// a relink. Never overwrites a name already stored under that key.
    static func backfillCardKeys(_ accounts: [(accountId: String, institution: String, mask: String?)]) {
        var map = labelMap()
        var changed = false
        for account in accounts {
            guard let key = cardKey(institution: account.institution, mask: account.mask),
                  map[key] == nil,
                  let name = map[accountKey(account.accountId)], !name.isEmpty else { continue }
            map[key] = name
            changed = true
        }
        if changed { persist(map) }
    }

    /// Restores a stored entry under its own key, whatever kind it is.
    static func setRawLabel(_ name: String, key: String) {
        guard key.hasPrefix("account:") || key.hasPrefix("method:") || key.hasPrefix("card:") else { return }
        setLabelValue(name, key: key)
    }

    // MARK: - Storage

    /// Prefix keys so account ids and method strings never collide in one map.
    private static func accountKey(_ id: String) -> String { "account:\(id)" }
    private static func methodKey(_ method: String) -> String { "method:\(method)" }

    /// Nil without a bank name or last four, since either alone matches several accounts.
    static func cardKey(institution: String, mask: String?) -> String? {
        let bank = institution.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !bank.isEmpty, let mask, !mask.isEmpty else { return nil }
        return "card:\(bank)|\(mask)"
    }

    /// In-memory copy of the nickname map.
    /// PERF: `labelMap()` used to hit `UserDefaults.dictionary(forKey:)` on every lookup, and
    /// lookups happen 1–3× per list row (BankAccount.displayName, subtitleDetail,
    /// TransactionRows). Measured over a 3,232-row list: 2.4 ms per pass uncached vs
    /// 0.047 ms cached — about 50×. Writes refresh the cache, so reads stay consistent.
    private static var cachedMap: [String: String]?
    private static let cacheLock = NSLock()

    private static func labelMap() -> [String: String] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedMap { return cachedMap }
        let loaded = UserDefaults.standard.dictionary(forKey: labelsKey) as? [String: String] ?? [:]
        cachedMap = loaded
        return loaded
    }

    /// Write the map to disk and keep the in-memory copy in step.
    private static func persist(_ map: [String: String]) {
        UserDefaults.standard.set(map, forKey: labelsKey)
        cacheLock.lock()
        cachedMap = map
        cacheLock.unlock()
    }

    /// Drop the cache after something replaces UserDefaults wholesale (restore, wipe).
    static func resetMemoryCache() {
        cacheLock.lock()
        cachedMap = nil
        cacheLock.unlock()
    }

    private static func getLabel(key: String) -> String? { labelMap()[key] }

    /// Insert/update one entry and write the whole map back to UserDefaults.
    private static func setLabelValue(_ value: String, key: String) {
        var map = labelMap()
        map[key] = value
        persist(map)
    }

    /// Delete one entry and persist the remaining map.
    private static func removeLabel(key: String) {
        var map = labelMap()
        map.removeValue(forKey: key)
        persist(map)
    }

    /// Drop every nickname (Debug menu).
    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: labelsKey)
        resetMemoryCache()
    }
}
