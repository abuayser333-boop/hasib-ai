/**
 * GET  /api/accounting/accounts        — قائمة شجرة الحسابات
 * POST /api/accounting/accounts        — إضافة حساب مخصص (للمالك فقط)
 * GET  /api/accounting/accounts?ledger=1&org_id={id} — ميزان المراجعة
 */
const { extractToken, dbQuery, rpc } = require('../_lib/db');
const { requireAuth, sendError, sendOk, parseBody, requireFields, isUUID } = require('../_lib/validate');

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const jwt = requireAuth(req, res);
  if (!jwt) return;

  // ── GET: شجرة الحسابات أو ميزان المراجعة ─────────────────
  if (req.method === 'GET') {
    const { ledger, org_id, upto } = req.query;

    if (ledger === '1') {
      if (!org_id || !isUUID(org_id)) return sendError(res, 'org_id مطلوب');
      const { data, error } = await rpc({
        jwt, fn: 'general_ledger_balances',
        params: { p_org_id: org_id, p_upto: upto || null }
      });
      if (error) return sendError(res, error.message || 'خطأ في جلب ميزان المراجعة', 500);
      return sendOk(res, data);
    }

    // قائمة شجرة الحسابات
    const { data, error } = await dbQuery({
      jwt, table: 'chart_of_accounts',
      select: 'code,name_ar,name_en,account_type,is_current',
      filters: {},
    });
    if (error) return sendError(res, error.message || 'خطأ في جلب شجرة الحسابات', 500);
    return sendOk(res, data);
  }

  return sendError(res, 'Method not allowed', 405);
};
