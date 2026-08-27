/**
 * GET  /api/sales/invoices?org_id={id}[&customer_id=uuid][&limit=50][&offset=0]
 *      — قائمة فواتير البيع
 * POST /api/sales/invoices
 *      — إنشاء فاتورة بيع مباشرة (record_sale: يخصم المخزون + يرحّل القيد)
 *      Body: { org_id, customer_name, invoice_number?, invoice_date?,
 *              items: [{product_id, quantity, unit_price}],
 *              vat_rate?: 0.15, payment_method: 'cash'|'bank'|'receivable',
 *              warehouse_id? }
 * POST /api/sales/invoices?action=payment&customer_id={uuid}&org_id={id}
 *      — تسجيل تحصيل (receive_customer_payment)
 */
const { dbQuery, rpc } = require('../_lib/db');
const { requireAuth, sendError, sendOk, parseBody, requireFields, isUUID, isDate } = require('../_lib/validate');

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const jwt = requireAuth(req, res);
  if (!jwt) return;

  const { action, org_id, customer_id } = req.query;

  // ── تسجيل تحصيل من عميل ──────────────────────────────────
  if (req.method === 'POST' && action === 'payment') {
    const body = parseBody(req);
    if (!body) return sendError(res, 'جسم الطلب غير صالح');

    const err = requireFields(body, ['org_id', 'customer_id', 'amount', 'method']);
    if (err) return sendError(res, err);
    if (parseFloat(body.amount) <= 0) return sendError(res, 'المبلغ يجب أن يكون أكبر من صفر');
    if (!['cash','bank'].includes(body.method)) return sendError(res, 'method يجب أن يكون cash أو bank');

    const { data, error } = await rpc({
      jwt, fn: 'receive_customer_payment',
      params: {
        p_org_id: body.org_id, p_customer_id: body.customer_id,
        p_amount: parseFloat(body.amount), p_method: body.method,
        p_date: body.date || null, p_note: body.note || null,
      },
    });
    if (error) return sendError(res, error.message || 'خطأ في تسجيل التحصيل', 422);
    return sendOk(res, data, 'تم تسجيل التحصيل وترحيل القيد', 201);
  }

  // ── GET: قائمة الفواتير ───────────────────────────────────
  if (req.method === 'GET') {
    if (!org_id || !isUUID(org_id)) return sendError(res, 'org_id مطلوب');

    const filters = {
      org_id: `eq.${org_id}`,
      order: 'invoice_date.desc,created_at.desc',
      limit: req.query.limit || '50',
      offset: req.query.offset || '0',
    };
    if (req.query.customer_id) filters.customer_id = `eq.${req.query.customer_id}`;

    const { data, error } = await dbQuery({
      jwt, table: 'sales_invoices',
      select: 'id,invoice_number,invoice_date,customer_name,subtotal,vat_amount,total_amount,cogs_amount,payment_method,journal_entry_id,created_at',
      filters,
    });
    if (error) return sendError(res, error.message || 'خطأ في جلب الفواتير', 500);
    return sendOk(res, data);
  }

  // ── POST: إنشاء فاتورة بيع مباشرة ───────────────────────
  if (req.method === 'POST') {
    const body = parseBody(req);
    if (!body) return sendError(res, 'جسم الطلب غير صالح');

    const err = requireFields(body, ['org_id', 'customer_name', 'items', 'payment_method']);
    if (err) return sendError(res, err);
    if (!isUUID(body.org_id)) return sendError(res, 'org_id غير صالح');
    if (!Array.isArray(body.items) || body.items.length === 0) {
      return sendError(res, 'items: أضف صنفاً واحداً على الأقل');
    }
    if (!['cash','bank','receivable'].includes(body.payment_method)) {
      return sendError(res, 'payment_method غير صالح (cash | bank | receivable)');
    }
    for (let i = 0; i < body.items.length; i++) {
      const it = body.items[i];
      if (!isUUID(it.product_id))       return sendError(res, `الصنف ${i+1}: product_id غير صالح`);
      if (parseFloat(it.quantity) <= 0)  return sendError(res, `الصنف ${i+1}: الكمية يجب أن تكون أكبر من صفر`);
      if (parseFloat(it.unit_price) < 0) return sendError(res, `الصنف ${i+1}: السعر لا يمكن أن يكون سالباً`);
    }
    if (body.invoice_date && !isDate(body.invoice_date)) {
      return sendError(res, 'invoice_date يجب أن يكون YYYY-MM-DD');
    }

    const { data, error } = await rpc({
      jwt, fn: 'record_sale',
      params: {
        p_org_id: body.org_id,
        p_customer_name: body.customer_name.trim(),
        p_invoice_number: body.invoice_number || null,
        p_invoice_date: body.invoice_date || null,
        p_items: body.items,
        p_vat_rate: body.vat_rate ?? 0.15,
        p_payment_method: body.payment_method,
        p_warehouse_id: body.warehouse_id || null,
      },
    });
    if (error) return sendError(res, error.message || 'خطأ في إنشاء الفاتورة', 422);
    return sendOk(res, data, 'تم إنشاء فاتورة البيع وتحديث المخزون والقيود', 201);
  }

  return sendError(res, 'Method not allowed', 405);
};
