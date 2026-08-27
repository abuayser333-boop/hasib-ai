/**
 * GET  /api/sales/orders?org_id={id}[&status=confirmed][&customer_id=uuid]
 *      — قائمة أوامر البيع مع بنودها
 * PATCH /api/sales/orders?id={uuid}&action=ship|deliver|cancel
 *      — تغيير حالة أمر البيع
 * POST /api/sales/orders?action=invoice&id={uuid}
 *      — تحويل أمر بيع إلى فاتورة (invoice_sales_order → record_sale)
 *        يُخصم المخزون ويُرحّل القيد المحاسبي تلقائياً
 */
const { dbQuery, rpc } = require('../_lib/db');
const { requireAuth, sendError, sendOk, parseBody, isUUID, isDate } = require('../_lib/validate');

const STATUS_TRANSITIONS = {
  ship:    { from: ['confirmed','in_progress'], to: 'shipped'     },
  deliver: { from: ['shipped'],                 to: 'delivered'   },
  cancel:  { from: ['confirmed','in_progress'], to: 'cancelled'   },
};

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const jwt = requireAuth(req, res);
  if (!jwt) return;

  const { id, action, org_id } = req.query;

  // ── تحويل إلى فاتورة (يُشغّل record_sale) ───────────────
  if (req.method === 'POST' && action === 'invoice') {
    if (!isUUID(id)) return sendError(res, 'id أمر البيع مطلوب');
    const body = parseBody(req) || {};

    const { data, error } = await rpc({
      jwt, fn: 'invoice_sales_order',
      params: {
        p_order_id: id,
        p_invoice_date: body.invoice_date || null,
      },
    });
    if (error) return sendError(res, error.message || 'خطأ في إصدار الفاتورة', 422);
    return sendOk(res, data, 'تم إصدار فاتورة البيع وتحديث المخزون والقيود', 201);
  }

  // ── GET: قائمة أوامر البيع ───────────────────────────────
  if (req.method === 'GET') {
    if (!org_id || !isUUID(org_id)) return sendError(res, 'org_id مطلوب');

    const filters = {
      org_id: `eq.${org_id}`,
      order: 'order_date.desc,created_at.desc',
      limit: req.query.limit || '50',
    };
    if (req.query.status)      filters.status      = `eq.${req.query.status}`;
    if (req.query.customer_id) filters.customer_id = `eq.${req.query.customer_id}`;

    const { data, error } = await dbQuery({
      jwt, table: 'sales_orders',
      select: '*,lines:sales_order_lines(id,product_id,description,quantity,unit_price,discount,line_total)',
      filters,
    });
    if (error) return sendError(res, error.message || 'خطأ في جلب أوامر البيع', 500);
    return sendOk(res, data);
  }

  // ── PATCH: تغيير الحالة ──────────────────────────────────
  if (req.method === 'PATCH') {
    if (!isUUID(id)) return sendError(res, 'id أمر البيع مطلوب');
    const transition = STATUS_TRANSITIONS[action];
    if (!transition) {
      return sendError(res, `action غير معروف — المتاح: ${Object.keys(STATUS_TRANSITIONS).join(', ')}`);
    }

    const { data: current } = await dbQuery({
      jwt, table: 'sales_orders', select: 'id,status', filters: { id: `eq.${id}` },
    });
    if (!current?.[0]) return sendError(res, 'أمر البيع غير موجود', 404);
    if (!transition.from.includes(current[0].status)) {
      return sendError(res, `لا يمكن "${action}" من حالة "${current[0].status}"`);
    }

    const { data, error } = await dbQuery({
      jwt, table: 'sales_orders', method: 'PATCH',
      filters: { id: `eq.${id}` },
      body: { status: transition.to },
      prefer: 'return=representation',
    });
    if (error) return sendError(res, error.message || 'خطأ في التحديث', 422);
    return sendOk(res, Array.isArray(data) ? data[0] : data, `تم تحديث الحالة إلى "${transition.to}"`);
  }

  return sendError(res, 'Method not allowed', 405);
};
