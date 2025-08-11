# Personal Finance n8n Workflows Setup Checklist

A step-by-step, checkbox-driven guide to implement the Gmail → Sheets → Postgres pipeline with OpenAI extraction and nightly import. It aligns with the tables in `schema.sql` and your rough plan.

## 0) Quick overview
- [ ] You will manage master data (users, accounts, categories) in Google Sheets, then sync to Postgres on demand or weekly
- [ ] Emails are parsed to a staging sheet using OpenAI with a regex fallback
- [ ] A nightly job imports staged rows into Postgres, idempotent via Gmail message ID

---

## 1) Prerequisites
- [x] n8n is running on Proxmox and reachable
- [x] n8n credentials created: Gmail, Google Sheets, Postgres, OpenAI
- [x] Postgres has tables from `schema.sql` already created

Optional but recommended:
- [x] A dedicated Google Spreadsheet for this project (keep the URL handy)

`https://docs.google.com/spreadsheets/d/1TH36ljdTe_dvJFE8VL6XFWY_TH3mV-bm0qoIPCHa01o/edit?usp=sharing`

---

## 2) Database changes (run once)
Run the following in your Postgres (same DB you connected in n8n):

```sql
-- Ensure UUID helper exists
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Accounts: add a hint field to map masked numbers to accounts
ALTER TABLE accounts
  ADD COLUMN IF NOT EXISTS bank_hint TEXT; -- e.g., XXX250 or last 4 digits

-- Unique indexes for stable upserts
CREATE UNIQUE INDEX IF NOT EXISTS accounts_user_name_unique
  ON accounts (user_id, name);

-- Optional but useful for mapping by hint
CREATE UNIQUE INDEX IF NOT EXISTS accounts_user_bank_hint_unique
  ON accounts (user_id, bank_hint) WHERE bank_hint IS NOT NULL;

-- Categories: unique by (user, name, type)
CREATE UNIQUE INDEX IF NOT EXISTS categories_user_name_type_unique
  ON categories (user_id, name, type);

-- Transactions: idempotency + helpful index
ALTER TABLE transactions
  ADD COLUMN IF NOT EXISTS external_id TEXT UNIQUE; -- store gmail_message_id

CREATE INDEX IF NOT EXISTS transactions_user_date_idx
  ON transactions (user_id, txn_date);
```

- [x] Executed the SQL above successfully

---

## 3) Google Sheets setup
Create a Google Spreadsheet with four sheets and these headers in row 1.

- [x] Users
```
email,username,name
```
- [x] Accounts
```
user_email,account_name,type,currency,bank_hint,is_active
```
- [x] Categories
```
user_email,category_name,type,parent_category_name
```
- [ ] Transactions_Staging
```
status,user_email,account_hint,amount,currency,type,txn_date,description,merchant,channel,raw_from,subject,gmail_message_id,extraction_confidence,notes,inserted_txn_id
```

- [ ] Note down the Spreadsheet ID (from the URL)

---

## 4) Workflow A — Master Data Sync (Sheets → Postgres)
Trigger: Manual or Cron (weekly) to upsert users, accounts, categories into Postgres.

- [ ] Create a new workflow in n8n named: Master Data Sync
- [ ] Add Trigger: Cron (weekly) OR keep Manual Trigger for on-demand sync

Users upsert:
- [ ] Node: Google Sheets (Operation: Read, Sheet: Users)
- [ ] Node: Postgres (Execute Query) to upsert by email

```sql
WITH incoming AS (
  SELECT
    {{ $json.email }}::text AS email,
    {{ $json.username }}::text AS username,
    {{ $json.name }}::text AS name
)
INSERT INTO users (email, username, name)
SELECT email, username, name FROM incoming
ON CONFLICT (email)
DO UPDATE SET
  username = EXCLUDED.username,
  name = EXCLUDED.name,
  updated_at = now()
RETURNING id;
```

Accounts upsert:
- [ ] Node: Google Sheets (Read, Sheet: Accounts)
- [ ] Node: Postgres (Execute Query) to upsert `(user_id, name)` and set `bank_hint`

```sql
WITH u AS (
  SELECT id AS user_id FROM users WHERE email = {{ $json.user_email }} LIMIT 1
), incoming AS (
  SELECT
    (SELECT user_id FROM u) AS user_id,
    {{ $json.account_name }}::text AS name,
    {{ $json.type }}::text AS type,
    COALESCE({{ $json.currency }}::text, 'INR') AS currency,
    COALESCE({{ $json.bank_hint }}::text, NULL) AS bank_hint,
    COALESCE({{ $json.is_active }}::boolean, true) AS is_active
)
INSERT INTO accounts (user_id, name, type, currency, bank_hint, is_active)
SELECT user_id, name, type, currency, bank_hint, is_active FROM incoming
ON CONFLICT (user_id, name)
DO UPDATE SET
  type = EXCLUDED.type,
  currency = EXCLUDED.currency,
  bank_hint = COALESCE(EXCLUDED.bank_hint, accounts.bank_hint),
  is_active = EXCLUDED.is_active
RETURNING id;
```

Categories upsert:
- [ ] Node: Google Sheets (Read, Sheet: Categories)
- [ ] Node: Postgres (Execute Query) to resolve parent and upsert `(user_id, name, type)`

```sql
WITH u AS (
  SELECT id AS user_id FROM users WHERE email = {{ $json.user_email }} LIMIT 1
), parent AS (
  SELECT id AS parent_id
  FROM categories
  WHERE user_id = (SELECT user_id FROM u)
    AND name = {{ $json.parent_category_name }}
    AND type = {{ $json.type }}
  LIMIT 1
), incoming AS (
  SELECT
    (SELECT user_id FROM u) AS user_id,
    {{ $json.category_name }}::text AS name,
    {{ $json.type }}::text AS type,
    (SELECT parent_id FROM parent) AS parent_id
)
INSERT INTO categories (user_id, name, type, parent_id)
SELECT user_id, name, type, parent_id FROM incoming
ON CONFLICT (user_id, name, type)
DO UPDATE SET parent_id = EXCLUDED.parent_id
RETURNING id;
```

- [ ] Test run Workflow A and confirm rows are upserted

---

## 5) Workflow B — Email to Staging (near real-time)
Trigger: Gmail polling, extract via OpenAI, fallback to regex, write to `Transactions_Staging`.

- [ ] Create a new workflow: Email to Staging
- [ ] Node: Gmail (Operation: Read Messages)
  - Query example: `from:(canarabank.com OR icicibank.com OR hdfcbank.net) (transaction OR alert) newer_than:2d`

Prepare payload:
- [ ] Node: Function (convert Gmail message to text fields)

```javascript
// Input: Gmail item in item.json
const msg = item.json;
const rawBody = msg.payload?.body?.data
  ? Buffer.from(msg.payload.body.data, 'base64').toString('utf8')
  : '';
const raw_text = [msg.snippet || '', rawBody].join('\n');

return [{
  raw_text,
  raw_from: msg.From || '',
  subject: msg.Subject || '',
  gmail_message_id: msg.id,
  user_email: '' // set a default or map if multi-user
}];
```

OpenAI extraction:
- [ ] Node: OpenAI (Chat) — model `gpt-4o-mini`, temperature `0.2`, response format JSON
  - System:

```text
You extract bank transaction info from Indian bank emails. Output single JSON only.
Fields: currency, amount (number), type (income|expense|transfer), txn_date (YYYY-MM-DD),
account_hint, merchant, channel, description, confidence (0-1).
If unknown, set null. Infer type from words like DEBITED/CREDITED. Infer channel from keywords.
```

  - User: `{{ $json.raw_text }}`

Fallback parser when confidence is low:
- [ ] Node: IF — condition `{{ $json.confidence >= 0.7 }}`
  - False branch → Node: Function (regex fallback)

```javascript
const t = $json.raw_text || '';
const amountMatch = t.match(/INR\s*([\d,]+\.\d{2}|\d[\d,]*)/i);
const amount = amountMatch ? parseFloat(amountMatch[1].replace(/,/g, '')) : null;
const type = /DEBITED/i.test(t) ? 'expense' : (/CREDITED/i.test(t) ? 'income' : null);
const dateMatch = t.match(/\b(\d{2}[\/-]\d{2}[\/-]\d{4})\b/);
const [d, m, y] = dateMatch ? dateMatch[1].split(/[\/-]/) : [];
const iso = (d && m && y) ? `${y}-${m}-${d}` : null;
const hintMatch = t.match(/account\s*(?:X+|\*+)?(\d{3,4})/i);
const account_hint = hintMatch ? `XXX${hintMatch[1]}` : null;
const channel = /UPI/i.test(t) ? 'UPI' : (/ATM/i.test(t) ? 'ATM' : (/IMPS/i.test(t) ? 'IMPS' : null));

return [{
  currency: 'INR',
  amount,
  type,
  txn_date: iso,
  account_hint,
  merchant: null,
  channel,
  description: (type ? `${type} detected` : 'bank txn'),
  confidence: 0.5,
}];
```

Normalize and append to sheet:
- [ ] Node: Function (normalize for sheet)

```javascript
return [{
  status: 'pending',
  user_email: $json.user_email || '',
  account_hint: $json.account_hint,
  amount: $json.amount,
  currency: $json.currency || 'INR',
  type: $json.type,
  txn_date: $json.txn_date,
  description: $json.description,
  merchant: $json.merchant,
  channel: $json.channel,
  raw_from: $json.raw_from,
  subject: $json.subject,
  gmail_message_id: $json.gmail_message_id,
  extraction_confidence: $json.confidence,
  notes: ''
}];
```

- [ ] Node: Google Sheets (Append Row → `Transactions_Staging`)
- [ ] Optional dedupe: before append, check if `gmail_message_id` already exists (Lookup or handle during nightly import)
- [ ] Test: run the workflow; verify a new row appears in `Transactions_Staging`

---

## 6) Workflow C — Nightly Import (Staging → Postgres at 23:00)
Imports today’s pending rows, resolves IDs, optional categorization, idempotent insert, writeback to sheet.

- [ ] Create a new workflow: Nightly Import
- [ ] Node: Cron — daily at 23:00
- [ ] Node: Google Sheets (Read → `Transactions_Staging`)
- [ ] Node: Function (filter pending + today)

```javascript
const today = new Date().toISOString().slice(0,10);
return items.filter(i => i.json.status === 'pending' && i.json.txn_date === today);
```

Resolve IDs and optional auto-categorize:
- [ ] Node: Postgres (Execute Query) — get `user_id`

```sql
SELECT id FROM users WHERE email = {{ $json.user_email }} LIMIT 1;
```

- [ ] Node: Postgres (Execute Query) — get `account_id` by `bank_hint`

```sql
SELECT a.id
FROM accounts a
WHERE a.user_id = {{ $json.user_id }}::uuid
  AND a.bank_hint = {{ $json.account_hint }}
LIMIT 1;
```

- [ ] Optional Node: OpenAI (Chat) — categorize into existing categories
  - System:

```text
You classify transactions into one of these exact categories.
Output JSON: { "category_name": string|null, "confidence": number }.
```

  - User:

```text
Categories: {{ $json.categories_csv }}
Transaction: {{ $json.description }} | {{ $json.merchant }} | {{ $json.channel }} | {{ $json.amount }}
```

- [ ] Node: Postgres (Execute Query) — resolve `category_id` by `category_name` (when present)

```sql
SELECT id FROM categories
WHERE user_id = {{ $json.user_id }}::uuid
  AND name = {{ $json.category_name }}
LIMIT 1;
```

Idempotent insert and writeback:
- [ ] Node: Postgres (Execute Query) — insert if not exists (using `external_id`)

```sql
WITH found AS (
  SELECT id FROM transactions WHERE external_id = {{ $json.gmail_message_id }} LIMIT 1
), ins AS (
  INSERT INTO transactions (
    user_id, account_id, amount, type, category_id, description,
    notes, tags, txn_date, status, external_id
  )
  SELECT
    {{ $json.user_id }}::uuid,
    {{ $json.account_id }}::uuid,
    {{ $json.amount }}::numeric,
    {{ $json.type }}::text,
    {{ $json.category_id }}::uuid,
    {{ $json.description }}::text,
    {{ $json.notes }}::text,
    ARRAY[{{ 'gmail_id:' + $json.gmail_message_id }}::text],
    {{ $json.txn_date }}::date,
    'posted',
    {{ $json.gmail_message_id }}::text
  WHERE NOT EXISTS (SELECT 1 FROM found)
  RETURNING id
)
SELECT COALESCE((SELECT id FROM ins), (SELECT id FROM found)) AS id;
```

- [ ] Node: Google Sheets (Update row) — set `status = imported`, `inserted_txn_id = {{$json.id}}`
- [ ] Test: run Nightly Import manually; confirm records in `transactions`

---

## 7) Error handling and observability
- [ ] Add an Error Trigger node to each workflow
- [ ] Connect to Slack/Telegram (send workflow name, error, item preview)
- [ ] Add a success summary message (counts of processed/staged/imported/failed)

---

## 8) OpenAI configuration in n8n
- [ ] Create OpenAI credentials with your API key
- [ ] Default model: `gpt-4o-mini`
- [ ] Temperature: `0.2`
- [ ] Response format: JSON (strict)
- [ ] Test a sample extraction call in the OpenAI node

---

## 9) Testing checklist
- [ ] Populate Users/Accounts/Categories in Sheets (fill `bank_hint` where possible)
- [ ] Run Workflow A (Master Data Sync) and verify Postgres rows
- [ ] Send or fetch a bank email; run Workflow B and verify a row in `Transactions_Staging`
- [ ] Run Workflow C manually; verify a transaction in Postgres with `external_id = gmail_message_id`
- [ ] Check writeback: `status = imported`, `inserted_txn_id` filled

---

## 10) Maintenance tips
- [ ] Add new banks by expanding the Gmail query and fallback regex
- [ ] Keep Accounts `bank_hint` updated for reliable mapping
- [ ] Consider adding SMS/PDF (OCR) ingestion later
- [ ] Periodically back up n8n workflows and credential configs

---

If you want, you can paste your Google Spreadsheet ID and I will tailor node configs (ranges, IDs) for copy-paste.
