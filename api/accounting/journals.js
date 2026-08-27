/**
 * GET  /api/accounting/journals?org_id={id}[&source_type=sale][&limit=50][&offset=0]
 *      — قائمة القيود مع بنودها
 * POST /api/accounting/journals
 *      — قيد يدوي مباشر عبر post_journal_entry (يتحقق من التوازن)
 *      Body: { org_id, entry_date?, description, lines: [{account_code, debit, credit, memo?}] }
 */
const { extractToken, dbQuery, rpc } = require('../_lib/db');
const { requireAuth, sendError, sendOk, parseBody, requireFields, isUUID, isDate, validateLines } = require('../_lib/validate');

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const jwt = requireAuth(req, res);
  if (!jwt) return;

  // ── GET: قائمة القيود مع بنودها ──────────────────────────
  if (req.method === 'GET') {
    const { org_id, source_type, limit = '50', offset = '0' } = req.query;
    if (!org_id || !isUUID(org_id)) return sendError(res, 'org_id مطلوب');

    const filters = { org_id: `eq.${org_id}`, order: 'entry_date.desc,created_at.desc' };
    if (source_type) filters.source_type = `eq.${source_type}`;
    filters.limit  = limit;
    filters.offset = offset;

    const { data, error } = await dbQuery({
      jwt, table: 'journal_entries',
      select: '*,lines:journal_lines(account_code,debit,credit,memo)',
      filters,
    });
    if (error) return sendError(res, error.message || 'خطأ في جلب القيود', 500);
    return sendOk(res, data);
  }

  // ── POST: قيد يدوي ───────────────────────────────────────
  if (req.method === 'POST') {
    const body = parseBody(req);
    if (!body) return sendError(res, 'جسم الطلب غير صالح');

    const err = requireFields(body, ['org_id', 'description', 'lines']);
    if (err) return sendError(res, err);
    if (!isUUID(body.org_id)) return sendError(res, 'org_id غير صالح');

    // التحقق من البنود: كل بند له account_code + debit أو credit (ليس كليهما)
    const lines = body.lines;
    if (!Array.isArray(lines) || lines.length < 2) {
      return sendError(res, 'القيد يجب أن يحتوي على بندين على الأقل (مدين ودائن)');
    }
    for (let i = 0; i < lines.length; i++) {
      const l = lines[i];
      if (!l.account_code) return sendError(res, `البند ${i + 1}: account_code مطلوب`);
      const d = parseFloat(l.debit || 0);
      const c = parseFloat(l.credit || 0);
      if (d < 0 || c < 0) return sendError(res, `البند ${i + 1}: القيم لا تقبل أرقاماً سالبة`);
      if (d > 0 && c > 0) return sendError(res, `البند ${i + 1}: لا يمكن أن يكون البند مديناً ودائناً في آن واحد`);
    }

    const { data, error } = await rpc({
      jwt, fn: 'post_journal_entry',
      params: {
        p_org_id: body.org_id,
        p_entry_date: body.entry_date || null,
        p_source_type: 'manual',
        p_source_id: null,
        p_description: body.description,
        p_lines: lines,
      },
    });
    if (error) return sendError(res, error.message || 'خطأ في ترحيل القيد', 422);
    return sendOk(res, { journal_entry_id: data }, 'تم ترحيل القيد بنجاح', 201);
  }

  return sendError(res, 'Method not allowed', 405);
};
