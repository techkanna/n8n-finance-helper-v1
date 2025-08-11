-- n8n Postgres Node: Execute Query for form submissions
-- Expects per-item fields in JSON: user_email, user_name?, account_name, currency, amount, type, txn_date,
-- optional: category_name, description, notes

WITH me AS (
  INSERT INTO users (name, username, email)
  VALUES (
    COALESCE({{$json["user_name"]}}, SPLIT_PART({{$json["user_email"]}}, '@', 1)),
    SPLIT_PART({{$json["user_email"]}}, '@', 1),
    {{$json["user_email"]}}
  )
  ON CONFLICT (email)
  DO UPDATE SET name = EXCLUDED.name
  RETURNING id
), u AS (
  SELECT id FROM me
  UNION ALL
  SELECT id FROM users WHERE email = {{$json["user_email"]}} AND NOT EXISTS (SELECT 1 FROM me)
), acct AS (
  INSERT INTO accounts (user_id, name, type, currency)
  SELECT (SELECT id FROM u),
         COALESCE({{$json["account_name"]}}, 'Manual Account'),
         'bank',
         COALESCE({{$json["currency"]}}, 'INR')
  WHERE NOT EXISTS (
    SELECT 1 FROM accounts a
    WHERE a.user_id = (SELECT id FROM u)
      AND a.name = COALESCE({{$json["account_name"]}}, 'Manual Account')
  )
  RETURNING id
), a AS (
  SELECT id FROM acct
  UNION ALL
  SELECT id FROM accounts
  WHERE name = COALESCE({{$json["account_name"]}}, 'Manual Account')
    AND user_id = (SELECT id FROM u)
  LIMIT 1
), cat AS (
  INSERT INTO categories (user_id, name, type)
  SELECT (SELECT id FROM u), COALESCE({{$json["category_name"]}}, 'Uncategorized'), {{$json["type"]}}
  WHERE NOT EXISTS (
    SELECT 1 FROM categories c
    WHERE c.user_id = (SELECT id FROM u)
      AND c.name = COALESCE({{$json["category_name"]}}, 'Uncategorized')
      AND c.type = {{$json["type"]}}
  )
  RETURNING id
), c AS (
  SELECT id FROM cat
  UNION ALL
  SELECT id FROM categories
  WHERE user_id = (SELECT id FROM u)
    AND name = COALESCE({{$json["category_name"]}}, 'Uncategorized')
    AND type = {{$json["type"]}}
  LIMIT 1
), b AS (
  INSERT INTO batches (user_id, source, notes)
  SELECT (SELECT id FROM u), 'manual-form', 'Submitted via n8n Webhook form'
  RETURNING id
), possible_duplicate AS (
  SELECT t.id
  FROM transactions t
  WHERE t.user_id = (SELECT id FROM u)
    AND t.account_id = (SELECT id FROM a)
    AND t.amount = {{$json["amount"]}}
    AND t.type = {{$json["type"]}}
    AND t.txn_date = {{$json["txn_date"]}}
    AND t.description = {{$json["description"]}}
  LIMIT 1
), ins AS (
  INSERT INTO transactions (
    user_id, account_id, amount, type, category_id, description, notes,
    is_recurring, status, txn_date, batch_id
  )
  SELECT (SELECT id FROM u), (SELECT id FROM a), {{$json["amount"]}}, {{$json["type"]}},
         (SELECT id FROM c), {{$json["description"]}}, {{$json["notes"]}},
         FALSE, 'posted', {{$json["txn_date"]}}, (SELECT id FROM b)
  WHERE NOT EXISTS (SELECT 1 FROM possible_duplicate)
  RETURNING id
)
SELECT COALESCE((SELECT id FROM ins), (SELECT id FROM possible_duplicate)) AS txn_id;


