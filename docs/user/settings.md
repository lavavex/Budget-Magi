---
layout: default
title: Settings
---

# Settings

Plaid keys and banks are required to pull transactions. See [Getting started](getting-started.md) if you haven’t linked yet.

On a narrow screen Settings is one list. With iPhone Duo unfolded sideways, iPad, or Mac, it looks like the Settings app: the app and its version at the top, then pages with colored icons (Linked banks, Apple Card, Plaid account, Backup & restore, On-device AI, About, Developer, and Erase all data on its own at the bottom), and the page you pick on the right.

## Plaid account

| Field | What to enter |
|-------|----------------|
| **client_id** | From [Plaid Dashboard → Keys](https://dashboard.plaid.com/developers/keys) |
| **secret** | The secret for the **same** environment you pick below |
| **Environment** | **Sandbox** (test banks) or **Production** (real banks; Plaid must enable Production on your account) |
| **Save credentials** | Stores keys on this iPhone (secret in the Keychain) |

## Linked banks

| Action | What happens |
|--------|----------------|
| **Link bank account** | Opens Plaid so you can sign in at your bank |
| **Relink** | Use when login expired. A bank that needs it shows a **Relink** button; otherwise swipe right on the bank |
| **Unlink** | Removes the bank from this iPhone |

## Backup & restore

**Back up everything** creates a password-encrypted `.fwbackup` file (keys, banks, transactions, budget, prefs). Keep the password somewhere safe.

**Restore** default is **Safe merge**. It adds banks that aren’t on this phone, with their data. Banks already here keep their tokens and transactions, and Sync keeps them current. **Replace connections from backup** lets the backup’s keys, tokens, and rows win. **Wipe device, then restore** deletes local data first, then restores the backup. If that restore fails, your previous data is put back. Restore only accepts a backup from this app version.

## Apple Card

**Settings → Connect Apple Card** shows progress while it reads the card, then what it brought in. It reads your Apple Card from Wallet on this iPhone: balance, credit limit, minimum payment, due date, and transactions. Wallet asks for permission once. Nothing is sent anywhere, and each **Sync** refreshes it. **Disconnect Apple Card** removes the card from Accounts and keeps the transactions already brought in.

## On-device AI

**Settings → On-device AI** shows whether Apple Intelligence can run on this iPhone (checks when you open Settings).

## About

Version and build of the TestFlight (or App Store) binary you have installed, plus links to **Help & support** and the **Privacy policy**.

## Developer

**Hide for screenshots** masks dollar amounts and card last-four so you can share a picture of the app without balances. It's there for everyone.

**Settings → Developer → Debug** (only on builds with developer tools) is for testers and contributors: replay Welcome, inspect counts, reset local pieces, or wipe local data. It does **not** change anything in the Plaid Dashboard. Implementation notes: [Developer Settings](../dev/settings.md).

## Erase all data

**Settings → Erase all data** deletes everything on this device, including banks and keys, after you type `DELETE`. It can't be undone. Backup files you saved elsewhere aren't touched, and your bank stays connected in your Plaid account until you remove it there.

It's the last thing in Settings, away from everything else.
