# Cowry UX Design

> Status: draft · 2026-09-27
> Scope: purpose, UX principles, information architecture, core flows and presentation rules for the macOS app (phase 1). iOS gets notes in §10.
> Grounding: Apple Human Interface Guidelines — Design principles, and the pages on macOS, lists and tables, sidebars, split views, search fields, token fields, undo and redo, entering data, feedback, charting data, file management and windows. The system design is in [design.md](design.md).

The app ships in Korean and English. UI examples here are in English; the glossary (§2) gives both.

## 0. Purpose

### 0.1 Purpose statement

> **Keep an accurate record of your money, and get an instant answer to any question you ask of it. The record is entirely yours.**

"No network or performance constraints" is a means, not the purpose. People get the three things below; speed and offline operation are how we deliver them, and they work best when nobody notices them.

| Pillar | Meaning | Key features |
|---|---|---|
| **An accurate record** | Quick entry, a model that can't be wrong, and checking against real balances | Keyboard entry, autofill, reconciling |
| **Instant answers** | Nothing stands between a question and its answer | Search tokens, drill-down, back/forward |
| **Full ownership** | Data stays on your device, every change is kept, anything can be undone | Op log, undo, edit history, transparent network use |

People don't open a ledger to browse it. They open it to answer something: "How much did I spend on food last month?", "Is this card bill right?", "Am I spending more than last year?", "Where did this money go?". So exploration is designed around questions and answers.

### 0.2 What Cowry doesn't do

Following "Keep focused" under Purpose, Cowry doesn't do the following. It's a record and a lens, not a coach.

- Budgets, goals, spending scores, streaks, or other nudges
- Bank or card connections and automatic collection (imports take the output of external tools, in phase 3)
- Suggested categories or financial advice
- Ads, sign-up, or usage analytics

### 0.3 Audience

- **Primary:** anyone who wants an accurate record of their money. No knowledge of double-entry needed.
- **Also:** people fluent in double-entry and plain-text accounting. They turn on "Use accounting terms" in Settings (§2).

There's one model; only the vocabulary changes. The two groups never end up with different ledgers.

## 1. UX principles

Eight principles translate the HIG's eight into Cowry's context. When design decisions conflict, these decide.

### 1. Recording comes first
*Grounding: Purpose; Entering data*

The most frequent task is entry, not exploration. If entry is tedious, the record becomes inaccurate, and an inaccurate record isn't worth exploring.

- An entry takes a few seconds, keyboard only (§4.1).
- Don't ask for what can be known.
  - The date defaults to today.
  - Typing a payee fills category, account and amount from that payee's last entry.
  - The primary currency comes from the system locale.
- Offer choices over typing: categories and accounts come from autocomplete lists.
- Validate values as they're entered, next to the field. No error is discovered only after pressing Save.

### 2. Every number is a door
*Grounding: Agency ("Give people the freedom to explore"); Charting data*

Every total and balance on screen answers a question, and that answer is made of entries.

- Clicking a sidebar balance, a report cell or a chart bar opens the list of entries that make up that number.
- The list opens with the conditions applied as tokens, so people can keep asking by adding or removing them.
- There are no fixed flows or modes: anywhere leads anywhere.

### 3. Anything can be undone
*Grounding: Agency ("Help people recover from mistakes"); Undo and redo; Feedback*

People explore and edit freely only when they trust they can go back. The op log guarantees that structurally.

- Every change can be undone with ⌘Z.
  - There's no limit on how far back.
  - Menu items name what they undo, e.g. "Undo Add Starbucks Entry".
  - If the result of an undo is off screen, scroll to it and highlight it.
- Undo reaches beyond the session. Every entry and account has an edit history, and any earlier version can be restored.
- So deleting asks for no confirmation: deletion is the expected result, and it's always recoverable.
- Confirmations are reserved for truly irreversible actions, such as restoring from a backup.

### 4. No waiting
*Grounding: Craft ("durable, reliable, and high-performing"); Designing for macOS*

The whole ledger is on the device, so every answer should be immediate. Speed isn't a feature here; it's the quality of the app.

- No loading indicators on the main paths: lists, search, filters, drill-down and entry.
- Targets live in [design.md §8.2](design.md): smooth scrolling at 100,000 entries, filters and search within 100 ms, edits within one frame.
- Anything slower than 100 ms, such as verification or a full replay, never blocks the window; progress shows somewhere quiet.

### 5. A double-entry model, everyday words
*Grounding: Familiarity ("Use concepts that people know"); Simplicity ("Be concise")*

Every entry is stored as double-entry, but debits and credits don't appear in the default UI.

- Entries show where money went: `Visa → Dining`.
- Account views read like a bank statement: money in, money out, balance.
- Mechanisms like the conversion and opening balance accounts are hidden, surfacing only where needed as "exchange rate" and "starting balance".
- The glossary is in §2.

### 6. Your data is yours
*Grounding: Responsibility*

- No sign-up, no server we run, no usage analytics.
- The only network use is fetching prices, and Settings spells out what goes where (§9).
- Anything that would reveal holdings (security prices) works only once turned on.
- The ledger file's location is visible, and a backup can be exported at any time.

### 7. Calm
*Grounding: Delight ("Identify the emotion you want to inspire", "Don't mistake delight for decoration")*

Money easily stirs anxiety. The feeling Cowry aims for is **calm and in control**.

- Spending isn't painted red. Color carries meaning, not emotion (§5.3).
- No guilt-inducing copy, no streaks, no celebration animations.
- **Defining moments**
  - Typing a search and watching ten years of entries filter as you type
  - The ✓ lighting up when the statement balance matches the ledger
  - The reassurance that whatever you do can be undone

### 8. Mac-like
*Grounding: Familiarity ("Keep visuals and interactions consistent"); Flexibility; Designing for macOS*

- **Familiar layout.** Sidebar, list and inspector, like Mail; search at the trailing end of the toolbar.
- **Every command is in the menu bar,** with standard shortcuts respected (§8).
- **Multiple windows.** Open an account in its own window and reconcile side by side. Window size, position and navigation state are restored.
- **Input.** Move and change things with drag and drop, copy and paste. Copied entries become tab-separated text that pastes straight into Numbers.
- **Personalization.** A customizable toolbar; the sidebar and inspector can be hidden.

## 2. Vocabulary

Everyday terms are the default. Settings › General › "Use accounting terms" switches to accounting terms.

| Model | Everyday (default) | 일상어 (Korean) | Accounting | 회계 용어 (Korean) |
|---|---|---|---|---|
| Entry | Transaction | 거래 | Journal entry | 분개 |
| Posting | Line | 항목 | Posting | 분개 항목 |
| Account (asset) | Account: where money is (bank, cash, investments) | 계좌: 돈이 있는 곳 | Asset | 자산 |
| Account (liability) | Account: money owed (cards, loans) | 계좌: 갚을 돈 | Liability | 부채 |
| Account (income) | Income category | 수입 분류 | Revenue | 수익 |
| Account (expense) | Expense category | 지출 분류 | Expense | 비용 |
| Account (equity) | Not shown by default | 표시하지 않음 | Equity | 자본 |
| Opening balances | Starting balance | 시작 잔액 | Opening balance | 기초 잔액 |
| Conversion | Exchange rate / exchange | 환율 / 환전 | Trading account | 환전 계정 |
| Commodity | Currency · security | 통화 · 종목 | Commodity | 상품 |
| Primary commodity | Main currency | 기본 통화 | Reporting currency | 기준 통화 |
| Balance assertion | Balance check | 잔액 확인 | Balance assertion | 잔액 단언 |
| Void entry | Delete | 삭제 | Void | 분개 취소 |
| Journal | All Transactions | 모든 거래 | Journal | 분개장 |
| Register | Activity | 내역 | Ledger | 원장 |
| Diagnostics | Needs Attention | 확인 필요 | Warnings | 검증 경고 |
| Archive | Hide | 숨기기 | Archive | 보관 |
| Close | Stop using | 사용 종료 | Close | 해지 |

**Transaction kinds are derived from accounts, not stored.**
- An expense category makes it **spending**, an income category makes it **income**, and money moving between accounts is a **transfer**.
- The "Spending / Income / Transfer" choice in the entry form only shapes the form. The model has no kind field.

## 3. Information architecture

### 3.1 The library

- The ledger is a library managed by the app, like Photos. The app opens straight to it; there are no Open or Save dialogs.
- Nothing needs saving: every change is recorded as it's committed.
- The file lives in an App Group container ([design.md §5.6](design.md)). These commands make ownership visible:
  - File › Show Ledger in Finder
  - File › Export Backup… — a consistent point-in-time copy as a single file
  - File › Restore from Backup… — irreversible, so it asks for confirmation
- Phase 1 has one library. If multiple ledgers (personal, business, …) are needed, library switching like Photos comes later.

### 3.2 Window layout

```
┌─ ◀ ▶  All Transactions ───────────── [Period ▾] [+] [🔍 coffee · Account: Visa ✕] ┐
│ ▾ Browse                │ Date        Payee          Flow              Amount │ Apple Store      │
│     All Transactions    │ Sun, Sep 20 Apple Store    Visa → Shopping   $50.00 │ Sun, Sep 20 2026 │
│     Needs Attention  2  │                                             ₩68,650 │ Visa → Shopping  │
│ ▾ Saved Searches        │ Sat, Sep 19 Starbucks      Visa → Cafés      ₩4,500 │ $50.00           │
│     Cafés               │ …                                                   │  Charged ₩68,650 │
│ ▾ Accounts     ₩2.1M    │                                                     │  Rate ₩1,373/$   │
│   ▸ Bank       ₩3.0M    │                                                     │ Memo             │
│     Cash       ₩120K    │                                                     │ ▸ History 3      │
│     Visa      −₩1.0M    │                                                     │                  │
│ ▾ Spending · Sep ₩1.2M  │                                                     │                  │
│   ▾ Food       ₩480K    │                                                     │                  │
│       Cafés    ₩62K     │                                                     │                  │
│ ▸ Income · Sep ₩3.5M    │                                                     │                  │
│ ▸ Reports               │                                                     │                  │
└─────────────────────────┴─────────────────────────────────────────────────────┴──────────────────┘
```

- **Panes.** One `NSSplitViewController` with sidebar, list and inspector.
  - The sidebar and inspector can be hidden (View menu and toolbar buttons).
  - As the window narrows, the inspector collapses first.
- **Selection.** Each pane keeps its selection highlighted, so what you're viewing and what you've picked are always visible.
- **Toolbar,** leading to trailing: back/forward, title (current view), period pop-up, new transaction, search field.

### 3.3 Sidebar

Like Mail's mailboxes: sections with a hierarchy of **arbitrary depth**. People choose how many levels they want.

| Section | Contents | Number |
|---|---|---|
| Browse | All Transactions, Needs Attention, (phase 2) Changed by Sync | Needs Attention count |
| Saved Searches | Saved token combinations (Mail's Smart Mailboxes) | None |
| Accounts | Where money is and money owed; any depth | Balance at the end of the period |
| Spending · Income | Categories; any depth | Total over the period |
| Reports | Balance sheet, income and spending, net worth over time | None |

- **Hierarchy.** Each row has a disclosure triangle.
  - A parent's number is the sum of everything below it.
  - Selecting a parent lists the entries of its whole subtree.
- **Which period the numbers cover (proposal).**
  - Spending and income show totals for the period being viewed: the current view's period token, or this month if there's none.
  - Accounts show their balance at the end of that period.
  - Section titles name the period, e.g. "Spending · Sep".
  - So the sidebar's numbers always describe what you're looking at. To be validated in the prototype.
- **Order.** Set by dragging; alphabetical until then.
- **Drag to reorganize.**
  - Drag an account onto another to move it underneath.
  - Hold ⌥ while dragging to merge. Merging asks for no confirmation; undo reverts it.
  - Drag a transaction onto a category to recategorize it (like dragging a message onto a mailbox).
- **Icons.** SF Symbols in the system accent color; no fixed colors.
- **Bottom edge.** Nothing important goes at the very bottom of the sidebar.

### 3.4 List

- **All Transactions.** Columns: date, payee, flow, amount. A memo column can be turned on.
- **Account view (Activity).** Columns: date, payee, counterpart (category or account), money in, money out, balance — a bank statement.
- **Category view.** Columns: date, payee, account, amount; the period total appears above the list.
- **Sorting.** By date by default, opened scrolled to around today.
  - Clicking a column heading sorts by it; clicking again reverses.
  - The balance column only makes sense in date order, so other sorts hide it.
- **Columns** can be resized and chosen. Headings are short nouns.
- **Stripes.** Alternating row colors, since rows are read across several columns.
- **Repeated dates.** When consecutive rows share a date, the date is dimmed from the second row on. There are no date header rows, which keeps row heights fixed for the virtualized list.
- **Implementation** follows [design.md §8.3](design.md).

### 3.5 Inspector

Shows the selected entry and edits it in place. There's no separate edit mode.

- **Order:** payee, date, flow (lines), amount, exchange rate, memo, history.
- **With several entries selected** it shows their total and shared fields. Changing a shared field (category, date, …) applies it to all of them: one op per entry, undone as one.
- **With an account or category selected** it shows that account: name, parent, start date, stop-using date, memo, and past balance checks.

## 4. Core flows

### 4.1 Entering a transaction

**Starting.** ⌘N (or the toolbar +) opens a new draft in the inspector with focus on the amount. The draft appears right away as a dimmed row in the list.

**Fields.**

```
[ Spending | Income | Transfer ]
Amount     ₩ 4,500            (currency pop-up)
Date       Sun, Sep 27 2026   ← + / − / t
Payee      Starbucks          ← autocomplete
Category   Food:Cafés         ← autocomplete; paths can be typed
Paid with  Visa
Memo
```

**Keyboard.**
- Tab moves between fields.
- Return records the transaction and closes the draft.
- ⌘Return records it and opens the next draft right away — for working through a stack of receipts.
- Esc discards the draft.
- In the date field, `+` / `−` move a day and `t` jumps to today.

**Autofill.**
- Typing a payee fills category, payment account and amount from that payee's most recent entry. Filled fields are selected so they can be typed over.
- The payment account's currency defaults to the one it last used. This is derived from history, with no model change.

**Validation** happens as values are entered.
- Problems such as a stopped account or an unbalanced split appear next to the field, with the reason.
- While there's a problem, the record button is disabled.

**Duplicate.** ⌘D duplicates the selected entry as a draft dated today — the quick way to enter recurring items like rent.

**Editing an existing entry.** Select it and edit in the inspector.
- Selecting another entry or moving focus out of the inspector records the change. Editing one entry produces one op.
- Esc reverts to the state before recording.
- If another window changed the same entry first (a stale revision), the inspector reloads the new values and says "Changed elsewhere". The person's edits aren't thrown away; they're shown for comparison.

### 4.2 Splitting

- **How.** "Split" turns the category into several lines, e.g. a grocery receipt split into food and household.
- **Remaining amount.** While filling lines, "Remaining ₩2,000" stays visible below them; the entry can be recorded once it reaches zero.
- **Flow column** shows `Visa → Food + 1 more`.
- **Accounting mode** allows editing every line directly in debit and credit columns.

### 4.3 Foreign purchases and exchanges

- **Choosing a currency.** When the amount's currency differs from the payment account's, a **Charged** field appears — e.g. paid in dollars, charged in won.
- **Rate.** With both amounts entered, the implied rate shows, e.g. "₩1,373/$".
- **Recording.** Conversion lines are generated automatically and never shown ([design.md §4.2](design.md)).
- **Exchanging during a transfer** (e.g. KRW account to USD account) works the same: enter the amount sent and the amount received.
- **When the charged amount isn't known yet (proposal).**
  - Fill it with a value computed from the latest rate and mark it **Estimated**.
  - When the statement arrives, reconciling (§4.5) reveals the difference, and it gets corrected then.
  - Whether the model carries the estimated flag is an open question (§11).

### 4.4 Exploring

- **Drill-down.** Every number is clickable (principle 2).
  - Example: clicking "Food · March" in a report goes to All Transactions with `Category: Food` and `Period: March 2026` tokens.
  - Each move goes onto the back/forward stack (⌘[ ⌘]).
- **Search** sits at the trailing end of the toolbar and is the single place to search the app.
  - Results filter as you type.
  - The placeholder states the scope: "Search All Transactions", "Search Visa".
  - Token suggestions appear while typing: "vis" suggests `Account: Visa`, `Payee: vis`, and so on.
  - Token kinds: account, category, period, amount (`> 100,000`, `10,000–50,000`), currency, payee.
  - Tokens can be selected and deleted, and changed through a context menu.
  - Queries are NFC-normalized; two-syllable Korean words like "커피" work.
- **Period pop-up.** This month, last month, this year, last year, all, custom. Choosing one adds or replaces the period token. Tokens are the only way filters are expressed.
- **Saved searches.** Token combinations saved to the sidebar, e.g. `Category: Cafés` + `Period: This Year`.
- **Open in new window.** From an account's or category's context menu. Put two windows side by side to reconcile.

### 4.5 Reconciling

1. In an account view, choose "Check Balance…".
2. Enter the statement's date and balance.
3. The difference from the ledger shows immediately. Entries since the last check are highlighted, to tick off one by one.
4. When the difference reaches zero, the ✓ lights up and a balance check is recorded (`assert_balance`). This is one of Cowry's defining moments.

If a later edit to past entries breaks a checked balance, it appears under Needs Attention with the reason. Input is never blocked.

### 4.6 Fixing and undoing

- **Delete** with ⌫ or ⌘⌫. No confirmation; the row animates away to show the result.
- **Undo** with ⌘Z and ⇧⌘Z.
  - Menu items name the target, e.g. "Undo Delete Starbucks Entry".
  - Undo authors the inverse op, so undoing is kept in history too.
- **History.** Expanding "History N" in the inspector lists each version's time, device and changed fields, compared with the previous values. "Restore This Version" records a new edit.
- **Finding deleted entries.** View › Show Deleted Transactions; they can be brought back.

### 4.7 Managing accounts and categories

- **New.** ⇧⌘N, then pick a kind:
  - Where money is (bank, cash, investments)
  - Money owed (cards, loans)
  - Expense category
  - Income category
- **The rest:** name, parent, start date, starting balance. The starting balance is recorded as a "Starting balance" entry.
- **Rename and move.** Rename in place in the inspector or the sidebar (Return); move by dragging.
- **Stop using.** The account takes no entries after that date and stays in the sidebar, dimmed.
- **Hide.** The account leaves the sidebar; View › Show Hidden Accounts brings it back.
- **Merge** via "Merge into…" in the context menu or ⌥-drag. Entries aren't rewritten; only balances combine ([design.md §5.2](design.md)).
- **Delete** only works for accounts without entries. Otherwise: "This account has transactions. Stop using it, or merge it into another account" — the reason and what to do next.

### 4.8 Reports

- **Reports:**
  - Balance sheet: account balances on a date
  - Income and spending: a category tree over a period
  - Net worth over time: line chart
  - Monthly spending: bar chart
- **Every cell and bar is a way into drill-down** (principle 2).
- **Chart rules.**
  - Only familiar line and bar charts.
  - A one-line summary above each chart, e.g. "You spent 12% less in September than in August".
  - Charts of the same data keep consistent colors and marks.
  - Every chart has accessibility labels.
- **Conversion.** Values converted to the main currency show their rate date. Amounts without a rate appear separately as "No rate"; they're never converted to 0.

### 4.9 First launch

- **The first screen asks two things:**
  1. Main currency, prefilled from the system locale.
  2. How to start: **With suggested categories** (food, transport, housing, …; editable later) or **Empty**.
- **No tutorial.**
- **An empty ledger** shows "Add Your First Account" and "Record a Transaction ⌘N" where the list would be. Each sidebar section ends with a "+ Add" row.

## 5. Presentation

### 5.1 Numbers

- **Font.** The system font with monospaced digits (`monospacedDigit`).
- **Alignment.** Amounts are trailing-aligned, with decimal points aligned within a currency.
- **Format.** Currency symbol placement, grouping and decimal places follow the locale and the commodity's scale: no decimals for KRW, two for USD.
- **Foreign-currency entries.** The original amount is primary; the charged amount appears on the line below in a secondary color.
- **Abbreviation.** Narrow places like the sidebar use `₩2.1M`; tooltips and VoiceOver give the full value.

### 5.2 Signs

| What | Everyday mode | Accounting mode |
|---|---|---|
| Account balances | In the direction they add to net worth; money owed is negative (`−₩1.0M`) | Normal balance as positive, marked Dr/Cr |
| Income totals | Positive | Credit balance as positive |
| Spending totals | Positive | Debit balance as positive |
| List amounts | The entry's size as a positive number; direction comes from the flow arrow | Debit and credit columns |
| Account activity | Money in / money out columns | Debit / credit columns |

### 5.3 Color

- **Accent color.** Follows the system accent; when people change it, sidebar icons follow.
- **No color for the direction of money.** Income and spending, positive and negative, are never painted red or green (principle 7).
- **Color only when it means something.**
  - Red: errors — an unbalanced draft, a checked balance that no longer matches.
  - Green ✓: a balance check that matches. It means correctness, not a feeling about money.
  - Secondary label color: converted values, estimates, dimmed dates.
- **Color never works alone.** It always comes with a symbol or text. Verified in Dark Mode and with Increase Contrast.

### 5.4 Dates and writing

- **Dates.** Lists show "Sun, Sep 20", adding the year outside the current year. The inspector shows the full date. Formats follow the locale.
- **Writing.** Short and friendly (Korean uses 해요체). Error messages say what's wrong and what to do, e.g. "You stopped using Visa on Sep 1. Change the date or choose another payment account."

## 6. Feedback and status

- **Quiet by default.** Successful recording isn't announced; the row appearing in the list is the feedback.
- **Needs Attention.** Diagnostics ([design.md §6.4](design.md)) gather under Needs Attention in the sidebar, with a count. Each item gives the reason and a fix.
- **Alerts are used in exactly two cases:**
  - Irreversible data loss, such as restoring from a backup.
  - Ledger integrity problems, such as failed verification. Writing stops to protect the ledger, with the reason and how to export a backup.
- **Long operations** like a full replay or verification never block the window; a small progress indicator appears in the toolbar.
- **(Phase 2) Sync status** shows quietly under Browse in the sidebar. Only conflicts where an amount lost get a badge ([design.md §7.5](design.md)).

## 7. Accessibility and localization

- **VoiceOver.**
  - A row reads as one sentence, e.g. "September 20, Apple Store, from Visa to Shopping, 50 dollars, charged 68,650 won".
  - Amounts are read with sign and currency.
  - Charts provide Audio Graphs and summary labels.
- **Keyboard.** Everything works from the keyboard; focus order is checked with Full Keyboard Access.
- **Motion.** With Reduce Motion, row insert and delete animations become crossfades.
- **Size.** Follows the sidebar icon size setting (small, medium, large). List text size is adjustable from the View menu.
- **Localization.** Ships in Korean and English. Numbers, currencies and dates follow the locale. The layout is built to mirror for right-to-left languages.

## 8. Menus and shortcuts

Every command is in the menu bar. Standard shortcuts keep their standard meaning.

| Menu | Item | Shortcut |
|---|---|---|
| File | New Transaction | ⌘N |
| | New Account or Category | ⇧⌘N |
| | New Window | ⌥⌘N |
| | Show Ledger in Finder, Export Backup…, Restore from Backup… | |
| Edit | Undo *target* / Redo *target* | ⌘Z / ⇧⌘Z |
| | Cut, Copy, Paste (entries ↔ tab-separated text) | ⌘X ⌘C ⌘V |
| | Duplicate | ⌘D |
| | Delete | ⌫ / ⌘⌫ |
| | Find (focus the toolbar search field) | ⌘F |
| View | Show/Hide Sidebar | ⌃⌘S |
| | Show/Hide Inspector | ⌥⌘I |
| | Show Deleted Transactions, Show Hidden Accounts | |
| | Bigger / Smaller Text | ⌘+ / ⌘− |
| Go | Back / Forward | ⌘[ / ⌘] |
| | All Transactions / Needs Attention | ⌘1 / ⌘2 |
| | Selected Transaction's Account | ⌘↓ |
| Transaction | Check Balance… | ⌥⌘B |
| | Split, Show History | |

Combinations the system already uses, like ⌥⌘H (Hide Others), aren't taken. Shortcuts get added once something proves frequent.

## 9. Privacy and network use

Settings › Prices describes network use exactly as it is.

- **Exchange rates (on by default).**
  - All reference rates are fetched together from the European Central Bank (ECB).
  - Nothing personal is sent — not even which currencies you hold.
- **Security prices (off by default).**
  - When on, the codes of securities you hold are sent to the chosen provider. This is stated right next to the switch.
- **Nothing else goes out.** No analytics, no automatic crash reports, no ads.
- **(Phase 2) iCloud sync** can be turned on and off, with what's stored where and how it's encrypted explained the same way.

## 10. iOS notes (phase 2)

- **Same purpose and principles;** only the structure adapts to the screen.
- **Tabs:** All Transactions, Accounts, Reports and Search, with Search as a tab bar button for typing right away.
- **Entry** matters most on iPhone: a new-transaction sheet is one tap away from anywhere, with focus on the amount.
- **iPad** uses the same three-pane split view as the Mac.
- **Shared structure.** List virtualization and change events carry over to `UICollectionView`.

## 11. Open questions

1. **Entries with an estimated charged amount.** Put a flag in the model (`entry.estimated`), use a memo tag, or require the charged amount at entry (§4.3)? Same question as the one in [design.md §12](design.md).
2. **Which period sidebar numbers cover.** Does following the view's period token (§3.3) feel natural? Validate in the prototype.
3. **The suggested category set** offered on first launch (§4.9).
4. **Scope of accounting mode.** Just vocabulary, or also debit/credit editing in the entry form (§4.2)?
5. **Import by pasting.** Should phase 1 let people paste bank CSV or tab-separated text into the list and import it after a preview? It's a lighter on-ramp than external import tools (phase 3).
