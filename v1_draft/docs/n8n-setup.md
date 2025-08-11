## Personal Finance App with n8n (Email → Sheet → Postgres)

This guide sets up two n8n workflows using your schema in `schema.sql` and the email sample in `sample-data.json`:

- Email alerts → parse → append to a sheet (`TransactionsRaw`)
- Nightly at 11:00 PM → read today's rows → upsert into Postgres

### Prerequisites

- n8n running locally or in Docker
- Google account (for Google Sheets) or Microsoft 365 (if you prefer Excel)
- Postgres reachable from n8n
- Import your DB schema first:
  - Run `sql/enable_extensions.sql`
  - Run `schema.sql`

Recommended Google Sheet structure: use `data/transactions_sheet_template.csv` to create the sheet with headers (tab name `TransactionsRaw`).

Environment variables (configure in n8n or your OS):
- `PF_USER_NAME`: Your display name
- `PF_USER_EMAIL`: Your email to identify the user row in `users`

### Workflow 1: Email → Sheet

Nodes
1) Gmail Trigger (or IMAP Email if not using Gmail)
- Gmail search query example to restrict to Canara Bank alerts: `from:canarabank@canarabank.com subject:(Transaction Alert)`

2) Option A: Deterministic parser (recommended to start)
- Function: paste code from `parsers/parse-canara.js`

2) Option B: LLM parser (scales to multiple formats)
- Import `n8n/workflows/email_to_sheet_llm.json`
- Add OpenAI credentials (or your preferred LLM provider) in n8n
- Ensure model is set (e.g., `gpt-4o-mini`) and response format is JSON
- The workflow builds prompts based on `prompts/llm-system.txt` and `prompts/llm-user.txt` shape and then post-processes with `parsers/postprocess-llm.js`

3) Google Sheets: Append row
- Spreadsheet: your sheet
- Sheet: `TransactionsRaw`
- Map the following columns from Function output:
  - `timestamp`, `bank`, `account_name`, `account_mask`, `amount`, `currency`, `direction`, `type`, `txn_date`, `balance_after`, `source_email`, `subject`, `message_id`, `thread_id`, `raw_snippet`

Notes
- If you prefer Microsoft Excel, use the Microsoft Excel node instead of Google Sheets and map the same columns. You will need to set up Microsoft credentials in n8n.

### Workflow 2: Nightly Sheet → Postgres

Nodes
1) Cron
- Timezone: Asia/Kolkata
- Schedule: Daily at 23:00

2) Google Sheets: Read rows
- Spreadsheet: the same sheet
- Sheet: `TransactionsRaw`
- Read all rows

3) Function: Filter to today's rows and normalize types
- Filter rows where `txn_date` is today (Asia/Kolkata)
- Ensure `amount` is numeric and `txn_date` is `YYYY-MM-DD`

Example Function code:

```javascript
const tz = 'Asia/Kolkata';
const now = new Date(new Date().toLocaleString('en-US', { timeZone: tz }));
const yyyy = now.getFullYear();
const mm = String(now.getMonth() + 1).padStart(2, '0');
const dd = String(now.getDate()).padStart(2, '0');
const today = `${yyyy}-${mm}-${dd}`;

return $input.all().map(item => {
  const j = item.json;
  const amt = Number(String(j.amount).replace(/[,\s]/g, ''));
  const dateStr = String(j.txn_date || '').trim();
  // Accept YYYY-MM-DD or DD/MM/YYYY
  let isoDate = dateStr;
  const m = dateStr.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  if (m) isoDate = `${m[3]}-${m[2]}-${m[1]}`;
  return {
    json: {
      ...j,
      amount: isNaN(amt) ? null : amt,
      txn_date: isoDate,
      is_today: isoDate === today,
    }
  };
}).filter(i => i.json.is_today && i.json.amount !== null);
```

4) Postgres: Execute Query (Upsert per row)
- Connection: your Postgres credentials
- Query: paste contents of `sql/upsert_transactions.sql`
- It uses n8n expressions like `{{$json["amount"]}}` and `{{$env("PF_USER_EMAIL")}}`

### Postgres Upsert Logic

For each row:
- Ensure `users` has your user by email (insert or update name)
- Ensure `accounts` has a row matching the parsed account name and currency
- Ensure an `Uncategorized` category exists for the row's `type`
- Insert a `batches` row (source `gmail-canara`) and attach the transaction to this batch
- Insert transaction only if a potential duplicate does not already exist (same user, account, amount, type, date, subject)

The SQL handles idempotency by skipping inserts when a matching transaction exists.

### Parser coverage and customization

The provided parser focuses on the example Canara Bank alert format. For other banks/providers:
- Add `elseif` branches to extract data from different templates
- Keep the output fields consistent with the sheet columns

### Testing

1) Send or copy a sample Canara Bank alert email to the inbox watched by the workflow
2) Run Workflow 1 once manually; verify a new row appears in `TransactionsRaw`
3) Run Workflow 2 once manually; verify the row is inserted into Postgres and mapped to your schema
4) Confirm no duplicate is created when you rerun Workflow 2

### Troubleshooting
### Optional: Manual entry form

You can submit transactions manually via a simple form:

- Host `public/manual-entry.html` (or just open it locally in your browser)
- In n8n, import `n8n/workflows/manual_form_to_postgres.json`
- The webhook path defaults to `/webhook/manual-transaction` (set your Base URL in n8n)
- Enter your `user_email`, `account_name`, `amount`, `type`, and `txn_date`; optional `category_name`, `description`, `notes`
- The workflow validates input and upserts into Postgres using `sql/upsert_transactions_from_form.sql`


- Amount parsed as null: check locale commas and decimal points in the email; the parser strips commas
- Date mismatch: ensure the sheet’s `txn_date` is in `YYYY-MM-DD` or `DD/MM/YYYY`
- Duplicate inserts: compare fields used by the idempotency check (amount, type, date, subject, account)


