-- n8n Postgres Node: Execute Query (single row mode)
-- Assumes items contain the fields from parsers/parse-canara.js and sheet columns
-- Uses n8n expressions ({{$json[...]}} / {{$env(...)}})

WITH me AS (
  INSERT INTO users (name, username, email)
  VALUES (
    COALESCE({{$env("PF_USER_NAME")}}, 'User'),
    SPLIT_PART({{$env("PF_USER_EMAIL")}}, '@', 1),
    {{$env("PF_USER_EMAIL")}}
  )
  ON CONFLICT (email)
  DO UPDATE SET name = EXCLUDED.name
  RETURNING id
), u AS (
  SELECT id FROM me
  UNION ALL
  SELECT id FROM users WHERE email = {{$env("PF_USER_EMAIL")}} AND NOT EXISTS (SELECT 1 FROM me)
), acct AS (
  INSERT INTO accounts (user_id, name, type, currency, balance)
  SELECT (SELECT id FROM u),
         COALESCE({{$json["account_name"]}}, 'Default Account'),
         CASE WHEN {{$json["type"]}} = 'income' THEN 'bank' ELSE 'bank' END,
         COALESCE({{$json["currency"]}}, 'INR'),
         COALESCE({{$json["balance_after"]}}, 0)
  WHERE NOT EXISTS (
    SELECT 1 FROM accounts a
    WHERE a.user_id = (SELECT id FROM u)
      AND a.name = COALESCE({{$json["account_name"]}}, 'Default Account')
  )
  RETURNING id
), a AS (
  SELECT id FROM acct
  UNION ALL
  SELECT id FROM accounts
  WHERE name = COALESCE({{$json["account_name"]}}, 'Default Account')
    AND user_id = (SELECT id FROM u)
  LIMIT 1
), cat AS (
  INSERT INTO categories (user_id, name, type)
  SELECT (SELECT id FROM u), 'Uncategorized', {{$json["type"]}}
  WHERE NOT EXISTS (
    SELECT 1 FROM categories c
    WHERE c.user_id = (SELECT id FROM u)
      AND c.name = 'Uncategorized'
      AND c.type = {{$json["type"]}}
  )
  RETURNING id
), c AS (
  SELECT id FROM cat
  UNION ALL
  SELECT id FROM categories
  WHERE user_id = (SELECT id FROM u)
    AND name = 'Uncategorized'
    AND type = {{$json["type"]}}
  LIMIT 1
), b AS (
  INSERT INTO batches (user_id, source, notes)
  SELECT (SELECT id FROM u), 'gmail-canara', 'Automated import from n8n'
  RETURNING id
), possible_duplicate AS (
  SELECT t.id
  FROM transactions t
  WHERE t.user_id = (SELECT id FROM u)
    AND t.account_id = (SELECT id FROM a)
    AND t.amount = {{$json["amount"]}}
    AND t.type = {{$json["type"]}}
    AND t.txn_date = {{$json["txn_date"]}}
    AND t.description = {{$json["subject"]}}
  LIMIT 1
), ins AS (
  INSERT INTO transactions (
    user_id, account_id, amount, type, category_id, description, notes, tags,
    is_recurring, status, txn_date, attachment_url, batch_id
  )
  SELECT (SELECT id FROM u), (SELECT id FROM a), {{$json["amount"]}}, {{$json["type"]}},
         (SELECT id FROM c), {{$json["subject"]}}, {{$json["raw_snippet"]}}, NULL,
         FALSE, 'posted', {{$json["txn_date"]}}, NULL, (SELECT id FROM b)
  WHERE NOT EXISTS (SELECT 1 FROM possible_duplicate)
  RETURNING id
)
SELECT COALESCE((SELECT id FROM ins), (SELECT id FROM possible_duplicate)) AS txn_id;


