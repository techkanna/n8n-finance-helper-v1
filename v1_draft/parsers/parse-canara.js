// n8n Function node code: parse Canara Bank alert emails into normalized fields
// Input: items from Gmail Trigger (each item.json contains fields like snippet, From, Subject, id, threadId)
// Output fields mapped to sheet headers expected by data/transactions_sheet_template.csv

function parseAmountAndDirection(text) {
  // Match: "An amount of INR 620.00 has been DEBITED" or "CREDITED"
  const amtDir = text.match(/amount\s+of\s+([A-Z]{3})?\s?([\d,]+(?:\.\d{1,2})?)\s+has\s+been\s+(DEBITED|CREDITED)/i);
  if (!amtDir) return { amount: null, currency: null, direction: null };
  const currency = (amtDir[1] || 'INR').toUpperCase();
  const amount = Number(amtDir[2].replace(/,/g, ''));
  const direction = amtDir[3].toUpperCase();
  return { amount, currency, direction };
}

function parseAccountMask(text) {
  // Example: "to your account XXX250" or "A/c no. XXXX1234"
  const m1 = text.match(/account\s+X+([\d]{2,})/i);
  if (m1) return m1[1];
  const m2 = text.match(/A\/?c\.?\s*(?:no\.?\s*)?X+([\d]{2,})/i);
  if (m2) return m2[1];
  return null;
}

function parseTxnDate(text) {
  // Example: "on 08/08/2025" or "on 2025-08-08"
  const m1 = text.match(/on\s+(\d{2})\/(\d{2})\/(\d{4})/i);
  if (m1) return `${m1[3]}-${m1[2]}-${m1[1]}`; // YYYY-MM-DD
  const m2 = text.match(/on\s+(\d{4})-(\d{2})-(\d{2})/i);
  if (m2) return `${m2[1]}-${m2[2]}-${m2[3]}`;
  return null;
}

function parseBalanceAfter(text) {
  // Example: "Total Avail.bal INR 2,82218.66" or "Avl Bal: INR 2,82,218.66"
  const m1 = text.match(/(?:Avail\.?\s*bal|Avl\.?\s*Bal|Available\s*Balance)[^\d]*([A-Z]{3})?\s?([\d,]+(?:\.\d{1,2})?)/i);
  if (!m1) return null;
  const bal = Number(m1[2].replace(/,/g, ''));
  return isNaN(bal) ? null : bal;
}

function normalizeWhitespace(text) {
  return String(text || '')
    .replace(/\r/g, ' ')
    .replace(/\n/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

const tz = 'Asia/Kolkata';
const now = new Date(new Date().toLocaleString('en-US', { timeZone: tz }));
const isoTimestamp = now.toISOString();

return $input.all().map(item => {
  const j = item.json || {};
  const snippet = normalizeWhitespace(j.snippet || j.body || j.text || '');
  const subject = normalizeWhitespace(j.Subject || j.subject || '');
  const from = normalizeWhitespace(j.From || j.from || '');
  const messageId = j.id || j.messageId || null;
  const threadId = j.threadId || null;

  const { amount, currency, direction } = parseAmountAndDirection(snippet + ' ' + subject);
  const accountMask = parseAccountMask(snippet + ' ' + subject);
  const txnDate = parseTxnDate(snippet + ' ' + subject);
  const balanceAfter = parseBalanceAfter(snippet + ' ' + subject);

  const type = direction === 'CREDITED' ? 'income' : (direction === 'DEBITED' ? 'expense' : null);
  const accountName = accountMask ? `Canara Bank - XXXX${accountMask}` : 'Canara Bank - Account';

  return {
    json: {
      timestamp: isoTimestamp,
      bank: 'Canara Bank',
      account_name: accountName,
      account_mask: accountMask,
      amount,
      currency: currency || 'INR',
      direction,
      type,
      txn_date: txnDate,
      balance_after: balanceAfter,
      source_email: from,
      subject,
      message_id: messageId,
      thread_id: threadId,
      raw_snippet: snippet
    }
  };
});


