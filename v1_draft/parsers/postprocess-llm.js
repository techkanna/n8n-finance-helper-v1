// n8n Function node code: validate and coerce LLM JSON into the same shape as parse-canara.js

function toIsoDate(dateStr) {
  if (!dateStr) return null;
  const s = String(dateStr).trim();
  const ymd = s.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (ymd) return `${ymd[1]}-${ymd[2]}-${ymd[3]}`;
  const dmy = s.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  if (dmy) return `${dmy[3]}-${dmy[2]}-${dmy[1]}`;
  return null;
}

function toNumber(val) {
  if (val === null || val === undefined) return null;
  const n = Number(String(val).replace(/[,\s]/g, ''));
  return isNaN(n) ? null : n;
}

const tz = 'Asia/Kolkata';
const now = new Date(new Date().toLocaleString('en-US', { timeZone: tz }));
const isoTimestamp = now.toISOString();

return $input.all().map(item => {
  const j = item.json || {};
  // If the LLM returned JSON as string under j.ai_raw, parse it
  let parsed = j.ai_json || j.parsed || null;
  if (!parsed && typeof j.ai_raw === 'string') {
    try { parsed = JSON.parse(j.ai_raw); } catch (e) { parsed = null; }
  }
  if (!parsed && typeof j.response === 'string') {
    try { parsed = JSON.parse(j.response); } catch (e) { parsed = null; }
  }

  const bank = parsed?.bank ?? null;
  const amount = toNumber(parsed?.amount);
  const currency = (parsed?.currency || 'INR').toUpperCase();
  const direction = parsed?.direction ? String(parsed.direction).toUpperCase() : null;
  const type = parsed?.type ?? (direction === 'CREDITED' ? 'income' : (direction === 'DEBITED' ? 'expense' : null));
  const txn_date = toIsoDate(parsed?.txn_date);
  const account_mask = parsed?.account_mask ?? null;
  const account_name = parsed?.account_name || (bank && account_mask ? `${bank} - XXXX${account_mask}` : (bank || 'Bank Account'));
  const balance_after = toNumber(parsed?.balance_after);
  const description = parsed?.description ?? null;
  const confidence = typeof parsed?.confidence === 'number' ? Math.max(0, Math.min(1, parsed.confidence)) : 0.5;

  return {
    json: {
      timestamp: isoTimestamp,
      bank,
      account_name,
      account_mask,
      amount,
      currency,
      direction,
      type,
      txn_date,
      balance_after,
      source_email: j.From || j.from || null,
      subject: j.Subject || j.subject || null,
      message_id: j.id || j.messageId || null,
      thread_id: j.threadId || null,
      raw_snippet: j.snippet || j.body || '',
      ai_confidence: confidence
    }
  };
});


