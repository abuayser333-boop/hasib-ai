/**
 * GET  /api/sales/quotes?org_id={id}[&status=draft][&customer_id=uuid]
 *      — قائمة عروض الأسعار مع بنودها
 * POST /api/sales/quotes
 *      — إنشاء عرض سعر (يولّد الترقيم تلقائياً)
 *      Body: { org_id, customer_name, lines: [{description, quantity, unit_price, discount?, product_id?}],
 *              expiry_date?, notes? }
 * PATCH /api/sales/quotes?id={uuid}&action=send|accept|reject|cancel
 *      — تغيير حالة عرض السعر
 * POST /api/sales/quotes?action=convert&id={uuid}
 *      — تحويل إلى أمر بيع (convert_quote_to_order)
 */
const { dbQuery, rpc } = require('../_lib/db');
const { requireAuth, sendError, sendOk, parseBody, requireFields, isUUID, isDate, validateLines } = require('../_lib/validate');

const STATUS_TRANSITIONS = {
  send:   { from: ['draft'],              to: 'sent'     },
  accept: { from: ['sent','draft'],       to: 'accepted' },
  reject: { from: ['sent','draft'],       to: 'rejected' },
  cancel: { from: ['draft','sent'],       to: 'cancelled' },
};

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const jwt = requireAuth(req, res);
  if (!jwt) return;

  const { id, action, org_id } = req.query;

  // ── تحويل عرض السعر إلى أمر بيع ─────────────────────────
  if (req.method === 'POST' && action === 'convert') {
    if (!isUUID(id)) return sendError(res, 'id عرض السعر مطلوب');
    const body = parseBody(req) || {};

    const { data, error } = await rpc({
      jwt, fn: 'convert_quote_to_order',
      params: {
        p_quote_id: id,
        p_payment_method: body.payment_method || 'receivable',
        p_requested_date: body.requested_date || null,
      },
    });
    if (error) return sendError(res, error.message || 'خطأ في التحويل', 422);
    return sendOk(res, data, 'تم تحويل عرض السعر إلى أمر بيع', 201);
  }

  // ── GET: قائمة عروض الأسعار ──────────────────────────────
  if (req.method === 'GET') {
    if (!org_id || !isUUID(org_id)) return sendError(res, 'org_id مطلوب');

    const filters = {
      org_id: `eq.${org_id}`,
      order: 'quote_date.desc,created_at.desc',
      limit: req.query.limit || '50',
    };
    if (req.query.status)      filters.status      = `eq.${req.query.status}`;
    if (req.query.customer_id) filters.customer_id = `eq.${req.query.customer_id}`;

    const { data, error } = await dbQuery({
      jwt, table: 'quotes',
      select: '*,lines:quote_lines(id,product_id,description,quantity,unit_price,discount,line_total,sort_order)',
      filters,
    });
    if (error) return sendError(res, error.message || 'خطأ في جلب عروض الأسعار', 500);
    return sendOk(res, data);
  }

  // ── POST: إنشاء عرض سعر ──────────────────────────────────
  if (req.method === 'POST') {
    const body = parseBody(req);
    if (!body) return sendError(res, 'جسم الطلب غير صالح');

    const err = requireFields(body, ['org_id', 'customer_name', 'lines']);
    if (err) return sendError(res, err);
    if (!isUUID(body.org_id)) return sendError(res, 'org_id غير صالح');

    const lineErr = validateLines(body.lines);
    if (lineErr) return sendError(res, lineErr);

    if (body.expiry_date && !isDate(body.expiry_date)) {
      return sendError(res, 'expiry_date يجب أن يكون YYYY-MM-DD');
    }

    const { data, error } = await rpc({
      jwt, fn: 'create_quote',
      params: {
        p_org_id: body.org_id,
        p_customer_name: body.customer_name.trim(),
        p_lines: body.lines,
        p_expiry_date: body.expiry_date || null,
        p_notes: body.notes || null,
      },
    });
    if (error) return sendError(res, error.message || 'خطأ في إنشاء عرض السعر', 422);
    return sendOk(res, data, 'تم إنشاء عرض السعر', 201);
  }

  // ── PATCH: تغيير حالة عرض السعر ─────────────────────────
  if (req.method === 'PATCH') {
    if (!isUUID(id)) return sendError(res, 'id عرض السعر مطلوب');
    if (!action || !STATUS_TRANSITIONS[action]) {
      return sendError(res, `action غير معروف — المتاح: ${Object.keys(STATUS_TRANSITIONS).join(', ')}`);
    }

    const transition = STATUS_TRANSITIONS[action];

    // جلب الحالة الحالية
    const { data: current, error: fetchErr } = await dbQuery({
      jwt, table: 'quotes', select: 'id,status,org_id', filters: { id: `eq.${id}` },
    });
    if (fetchErr || !current?.[0]) return sendError(res, 'عرض السعر غير موجود', 404);
    if (!transition.from.includes(current[0].status)) {
      return sendError(res, `لا يمكن "${action}" من حالة "${current[0].status}"`);
    }

    const { data, error } = await dbQuery({
      jwt, table: 'quotes', method: 'PATCH',
      filters: { id: `eq.${id}` },
      body: { status: transition.to },
      prefer: 'return=representation',
    });
    if (error) return sendError(res, error.message || 'خطأ في التحديث', 422);
    return sendOk(res, Array.isArray(data) ? data[0] : data, `تم تحديث الحالة إلى "${transition.to}"`);
  }

  return sendError(res, 'Method not allowed', 405);
};
