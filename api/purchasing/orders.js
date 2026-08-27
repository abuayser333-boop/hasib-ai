/**
 * GET  /api/purchasing/orders?org_id={id}[&status=draft][&vendor_id=uuid]
 *      — قائمة أوامر الشراء مع بنودها
 * PATCH /api/purchasing/orders?id={uuid}&action=send|confirm|cancel
 *      — تغيير حالة أمر الشراء
 * POST /api/purchasing/orders?action=receive&id={uuid}
 *      — استلام أمر الشراء (receive_purchase_order → record_purchase)
 *        يزيد المخزون ويرحّل القيد المحاسبي تلقائياً
 */
const { dbQuery, rpc } = require('../_lib/db');
const { requireAuth, sendError, sendOk, parseBody, isUUID, isDate } = require('../_lib/validate');

const STATUS_TRANSITIONS = {
  send:    { from: ['draft'],              to: 'sent'      },
  confirm: { from: ['sent','draft'],       to: 'confirmed' },
  cancel:  { from: ['draft','sent','confirmed'], to: 'cancelled' },
};

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const jwt = requireAuth(req, res);
  if (!jwt) return;

  const { id, action, org_id } = req.query;

  // ── استلام أمر الشراء (يُشغّل record_purchase) ───────────
  if (req.method === 'POST' && action === 'receive') {
    if (!isUUID(id)) return sendError(res, 'id أمر الشراء مطلوب');
    const body = parseBody(req) || {};

    const { data, error } = await rpc({
      jwt, fn: 'receive_purchase_order',
      params: {
        p_po_id: id,
        p_invoice_number: body.invoice_number || null,
        p_invoice_date:   body.invoice_date   || null,
      },
    });
    if (error) return sendError(res, error.message || 'خطأ في استلام أمر الشراء', 422);
    return sendOk(res, data, 'تم استلام الشحنة وتحديث المخزون وترحيل القيد', 201);
  }

  // ── GET: قائمة أوامر الشراء ──────────────────────────────
  if (req.method === 'GET') {
    if (!org_id || !isUUID(org_id)) return sendError(res, 'org_id مطلوب');

    const filters = {
      org_id: `eq.${org_id}`,
      order: 'order_date.desc,created_at.desc',
      limit: req.query.limit || '50',
    };
    if (req.query.status)    filters.status    = `eq.${req.query.status}`;
    if (req.query.vendor_id) filters.vendor_id = `eq.${req.query.vendor_id}`;

    const { data, error } = await dbQuery({
      jwt, table: 'purchase_orders',
      select: '*,lines:purchase_order_lines(id,product_id,product_name,sku,quantity,quantity_received,unit_cost,line_total)',
      filters,
    });
    if (error) return sendError(res, error.message || 'خطأ في جلب أوامر الشراء', 500);
    return sendOk(res, data);
  }

  // ── PATCH: تغيير الحالة ──────────────────────────────────
  if (req.method === 'PATCH') {
    if (!isUUID(id)) return sendError(res, 'id أمر الشراء مطلوب');
    const transition = STATUS_TRANSITIONS[action];
    if (!transition) {
      return sendError(res, `action غير معروف — المتاح: ${Object.keys(STATUS_TRANSITIONS).join(', ')}`);
    }

    const { data: current } = await dbQuery({
      jwt, table: 'purchase_orders', select: 'id,status', filters: { id: `eq.${id}` },
    });
    if (!current?.[0]) return sendError(res, 'أمر الشراء غير موجود', 404);
    if (!transition.from.includes(current[0].status)) {
      return sendError(res, `لا يمكن "${action}" من حالة "${current[0].status}"`);
    }

    const { data, error } = await dbQuery({
      jwt, table: 'purchase_orders', method: 'PATCH',
      filters: { id: `eq.${id}` },
      body: { status: transition.to },
      prefer: 'return=representation',
    });
    if (error) return sendError(res, error.message || 'خطأ في التحديث', 422);
    return sendOk(res, Array.isArray(data) ? data[0] : data, `تم تحديث الحالة إلى "${transition.to}"`);
  }

  return sendError(res, 'Method not allowed', 405);
};
