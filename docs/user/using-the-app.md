---
layout: default
title: Using the app
---

# Using the app

Install and first Sync: [Getting started](getting-started.md).

## First launch

Splash (app icon) → **Welcome** → **Get Started** → tabs. Later launches skip Welcome.

## Home

A quick look at your money. The arrows step back or forward a month.

- **At a glance** — what you've spent this month (tap for the category chart), with what's left of your monthly budget if you set one; income so far, and whether it's ahead of or behind the paychecks you expect by now; and net.
- **Money** — cash available in checking and savings, what you owe on cards, and overall utilization. **See accounts** opens Accounts.
- **What's next** — the next card payment (tap to open the card) and the next bill. **See everything on Upcoming** opens Upcoming.
- **To do** — **Needs review** (items that still need a category or bill-pay check; swipe to fix) and **Monthly recap**.
- **Top categories** — where most of this month went.

**Sync** is here: Sync now, Force bank refresh, Full re-sync, and Link bank account. Pull down to Sync too. After a Sync, a short line says whether your banks are up to date, with the full counts under **Details**; dismiss it with the **×**.

## Accounts

Your accounts in detail.

- **All accounts** — every transaction from every account (below).
- **Credit** — total balance, limit, utilization, minimum payments, the next due date, and **Total paid** (card bill payments, not spend) for the period. The arrows step through months.
- **Credit cards**, **Checking & savings**, and **Other spend** (payment methods with spending that aren't a linked account).

Cards your bank names only "CREDIT CARD" show as the bank and last four (Chase ···4103) until you give them a name: open the card and set **Display name**. A name you set stays with the card if you relink the bank, since it's kept by bank and last four as well.

Open a card to see **all** activity by **statement period**. The card row and the card screen always show the same cycle: **This statement** while one is open, **Last statement** when nothing has posted since the close. A due date that has passed without the bank flagging the card overdue shows **Due date passed** until the next Sync. **Interest saving balance** (on the card) is other balances in full plus this statement's loan/installment payment — pay that to stay on the loan schedule without paying the loan off early.

Pull down to Sync; it refreshes Apple Card too, the same as **Sync** on Home.

### All accounts

Every charge and deposit for the selected period.

- **Total Spend** — purchases this week / month / all time (all cards). Tap for category charts (bars or pie).
- **Total Income** — money in for the same period (not part of spend).
- **Net** — income minus spend.

**Income** and **Expenses** are separate lists. **Total Income** is earnings (paychecks, direct deposits, interest). Merchant refunds, card credits, and loan proceeds stay in the expense list as **Refund** / **Loan** and do not inflate income. Toolbar:

| Control | What it does |
|---------|----------------|
| Search | Title, category, amount, last four, nickname. The field stays at the top of the list. |
| Calendar | This week / This month / All time |
| Sort | Date, amount, name |

The arrows at the top of the totals step back or forward a week or month at a time.

Tap a row for **Transaction** detail. You can change the **category** and how it was **paid with** (card or bank transfer). Pick **Custom…** to type a category of your own. **Save** turns on once something changed, and keeps it so later Syncs don’t overwrite it. **Technical details** holds the bank's raw fields, for reporting a problem. Turn on **learn** to apply the same category to future charges from that merchant. Rows show the day the bank posted the charge; the detail also shows the purchase day when it's different.

**Repeats** on that screen: **Auto-detect**, **Yearly**, **Monthly**, **Weekly**, or **Not recurring**. Use **Monthly** or **Yearly** for bills whose amount changes, like phone and electric — the Upcoming tab groups that merchant even when the dollar amount is different each time.

**Credit Card Payment** (shown as “Bill pay”) is a payment to a card, not a purchase. It stays in the list but is **not** in Total Spend, charts, or widgets. It also shows under Accounts → Total paid. Checking ACH and the card’s “Thank You” are the **same** payment — Total paid counts it once even if the bank posts them a day or two apart. Some banks post a card payment as just **PAYMENT** or **ACH PMT**. When one of your linked cards received that exact amount within a few days, Sync files the bank line as the card payment. To undo one, open it and set the category yourself.

A charge still **Pending** after ten days shows **may have dropped**: the bank usually posts or releases a hold within a few days, so it likely won't post.

**Loan** / **Installment** also stay in the list but are **not** Total Spend or Total Income. **Refund** rows aren’t income, and they reduce **Total Spend** in the month they post. Budget categories and charts show what you spent before refunds. Card statement credits (travel credit, merchant returns) and My Loan deposits to checking are not paychecks. Issuer **installment** billing (My Chase Plan, Amex Plan It) is the billing of a purchase already in the list — use **Pay over time…** if you want them on Upcoming.

### Loans, installments, and pay-off-by-date

On a **credit card**:

| | What it is |
|--|------------|
| **Loans & installments** | Open the **loan charge** or **installment** row. Enter remaining, remaining months, and the **statement payment**. **My Loan** also uses the **fixed APR** from the loan email (interest this statement = remaining × APR ÷ 12). **Pay Over Time** fee is payment minus remaining ÷ months. That payment is **already in the card minimum**. Chase: do not pay “Statement balance” or you pay the whole loan off at once; “Interest saving balance” includes the monthly loan payment. |
| **Pay off by date** | A plan to clear a promo (0% APR) or extra balance by a date you choose. Accounts → card → **Add a pay-off plan**. Extra principal you intend to send with the statement payment. |

**Record this month’s payment** reduces remaining in the app. **Mark paid off** and **Delete plan** each ask first. These show on **Upcoming** on the card’s due date.

Open a card from Accounts to see **all** activity grouped by **statement** (close day from the bank). The Accounts week/month filter does not apply on that screen.

## Ask

**Ask** is the field above the tab bar (beside it on wider screens). Tap it, type a question, and send, and the chat opens with the answer. **Done** closes the chat; an empty chat offers a few questions to start with. When you already have a chat, the button at the end of the field opens it without asking anything new. Ask is on-device chat (Apple Intelligence). The app works out the numbers itself: spending by merchant, category, or month, plus your budget, card due dates, balances, recurring charges, and individual charges. If an answer has an amount that doesn’t match your data, Ask tries again, then warns you. Card names match the nicknames you set in Accounts (not the bank’s “Credit Card” label). Replies stream in; you can tap a suggested follow-up. With a keyboard attached, Return sends.

Ask can also **make a budget** and **plan a card payoff**. Ask "help me make a budget", "what can I afford", "where can I cut back", or name an employer to budget on that paycheck alone. The budget sets your usual income against bills and card minimums, keeps needs like housing and groceries at their usual amount, and trims the rest to fit. Ask "how do I pay off my cards" or "which card should I pay first" for the payoff order: highest interest rate first, with what each card costs a month in interest, the minimums coming due, and any due date that has passed. The app works these plans out itself and writes them into the chat, so the same question always gets the same plan. A one-time deposit isn't counted as monthly income, and a bill that has skipped its usual date is listed apart instead of counted.

Ask can **change categories** too. Tell it what something is, like "Corner Cafe is dining, not shopping", "put Example Gym under health", or "the 177.09 payment is my phone bill". It finds the charges, says exactly what will change, and waits for **Apply**; nothing is written before that, and **Cancel** or a typed "no" drops it. Applying also files later charges from that merchant the same way. For a bank line that names nobody, like PAYMENT, it remembers only that exact amount, since the same line can be several different bills. When recent payments have no name and no real category, Ask offers **Help me label my unnamed payments**: it asks what each one was, you answer in your own words or say skip, and it files them one at a time. A category you name outright is the one it uses.

Ask can set up the **Budget** tab. After it builds a budget, tap **Use this budget** to turn it into category limits; each limit covers the budgeted spending plus the bills in that category, and it replaces the limits you had. Or set one limit at a time: "set my dining budget to 200", "cap shopping at $150". It also keeps **Upcoming** straight: "I cancelled Example Stream" moves it to Ended and takes it out of your bills and budget, "Example Power is a monthly bill" adds it even when the amount changes, and "Example Shop is not a subscription" removes it. Marking something cancelled only updates the app. Like category changes, each of these waits for **Apply**. The conversation is saved on this device. Simulator cannot run the model; use a real iPhone or **My Mac (Designed for iPhone)**.

**Why?** Open Total Spend for **Why this total?**, tap a category for why it changed, or open a charge for **Why this charge?** The app works out what changed itself, so these still work without Apple Intelligence, which only adds a short summary on top.

**Monthly recap** (on Home, under To do) shows a month's income, spending, category changes, price changes, new merchants, largest charges, and anything over budget. Tap one of the largest charges to open it. A month with nothing in it just says so.

**Search with AI** appears when you type a sentence into search, like "Amazon over $50 in August". You get the real matching rows, with the filters it used shown on top.

**Needs review** can suggest categories for merchants it's unsure about. Nothing changes until you tap Apply. Bank lines that name no merchant, like PAYMENT or ACH PMT, get no suggestion; set those yourself.

Cash back and rewards count as income, under **Rewards**. Check, cash, and ATM deposits count as income, under **Deposit**. To bring in older deposits, use **Sync → Full re-sync** once.

Transaction detail: **Suggest with Apple Intelligence** picks a category from the app’s list.

## Upcoming

What's coming due: card payments, plus detected subscriptions and repeating bills.

**Cards due** lists each card with a payment coming, soonest first, with its minimum (or the balance when the bank doesn't report a minimum). Tap one to open the card. A due date that passed without the bank marking the card overdue is left off until the next Sync brings the new date. **Summary** shows the card minimums due beside what extra bills cost a month.

Fixed-price subs need the same merchant and amount on a schedule. Phone, electric, and similar bills can **vary** — mark one charge **Monthly** or **Yearly** on Transaction detail, or the app may pick them up when the cadence is regular. A **month grid** marks card due dates in orange and bills in gray, a year ahead; tap a day to list what's due then, and **Clear** to go back. **Active** vs **Ended**. Shows next charge and estimated monthly total (`~` when the amount changes).

Tap a bill for its amount, schedule, and charges. **It's cancelled** moves it to **Ended**; **Not a recurring bill** takes it off this tab. Both ask first and apply to every charge from that merchant. An ended bill you marked cancelled has **Mark active again**.

Bills that missed their usual date are listed under **Hasn't charged lately** and aren't counted in Extra bills; if one has ended, open it and mark it cancelled. **Extra bills** is subscriptions and other charges besides the card payment. **On your cards** is loans and installments that are already in the card minimum — they do not add to Extra bills. Pay-off-extra plans are extra principal you mean to send with the statement.

## Budget

A **monthly cap**, **expected income**, and **per-category limits** compared to real spend. The monthly cap saves when you leave the field. With no categories yet, **Build a budget with Ask** asks Ask to make one. Remaining / over updates as new charges sync. **Add category limit** starts on a category without a limit, and warns before replacing one that has a limit. Income received is compared with the paychecks expected so far, so a payday later in the month isn't counted as missing. A card whose due date has gone by without the bank marking it overdue shows "Was due … · Sync to update", since the new date arrives with the next Sync.

## Settings

[Settings](settings.md) — Plaid keys, banks, privacy, backup.

## Not included

- Apple Cash and Apple Savings (Apple Card is covered: see [Settings](settings.md))
- Push alerts when you go over budget (the Budget tab still shows remaining / over)
- Automatic sync to another iPhone (use backup, or Sync from Plaid on that phone)
- A Budget Magi server that holds your Plaid secret (keys stay on the phone)

## Larger screens

With iPhone Duo unfolded and turned sideways (and on iPad or Mac), the app uses two columns:

- **Home** puts At a glance and Money on the left, What's next, To do and Top categories on the right.
- **Accounts** puts All accounts, Credit, Checking & savings and Other spend on the left, and your credit cards on the right.
- **All accounts** puts the totals and income on the left and expenses on the right; a card puts its summary on the left and its statements on the right; a transaction puts the charge on the left and what you can change on the right.
- **Budget** puts the month, expected income and the overall budget on the left, categories on the right.
- **Upcoming** puts the calendar and the day you pick on the left, and the summary, cards due, and bills on the right.
- **Settings** looks like the Settings app: a list of pages with colored icons on the left, the page on the right.

Unfolded and held upright, the app stays one column, with All accounts' totals side by side. Anything you open fills the screen, and both columns of a page start on the same line.
