/**
 * GET  /api/purchasing/requests?org_id={id}[&status=draft]
 *      — قائمة طلبات الشراء مع بنودها
 * POST /api/purchasing/requests
 *      — إنشاء طلب شراء مع بنوده
 *      Body: { org_id, requester_name, department?, lines: [{description, quantity, estimated_price?, product_id?, unit_of_measure?}], notes? }
 * PATCH /api/purchasing/requests?id={uuid}&action=submit|approve|reject|cancel
 *      — تغيير حالة طلب الشراء
 * POST /api/purchasing/requests?action=to_po&id={uuid}
 *      — تحويل إلى أمر شراء (convert_pr_to_po)
 */
const { dbQuery, rpc } = require('../_lib/db');
const { requireAuth, sendError, sendOk, parseBody, requireFields, isUUID, isDate, validateLines } = require('../_lib/validate');

const STATUS_TRANSITIONS = {
  submit:  { from: ['draft'],              to: 'pending_approval' },
  approve: { from: ['pending_approval'],   to: 'approved'          }, // Owner only (enforced in DB)
  reject:  { from: ['pending_approval'],   to: 'rejected'          },
  cancel:  { from: ['draft','pending_approval'], to: 'cancelled'    },
};

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const jwt = requireAuth(req, res);
  if (!jwt) return;

  const { id, action, org_id } = req.query;

  // ── تحويل إلى أمر شراء ───────────────────────────────────
  if (req.method === 'POST' && action === 'to_po') {
    if (!isUUID(id)) return sendError(res, 'id طلب الشراء مطلوب');
    const body = parseBody(req) || {};
    if (!isUUID(body.vendor_id)) return sendError(res, 'vendor_id مطلوب لإنشاء أمر الشراء');

    const { data, error } = await rpc({
      jwt, fn: 'convert_pr_to_po',
      params: {
        p_pr_id: id,
        p_vendor_id: body.vendor_id,
        p_unit_costs: body.unit_costs || null,
      },
    });
    if (error) return sendError(res, error.message || 'خطأ في التحويل', 422);
    return sendOk(res, data, 'تم تحويل طلب الشراء إلى أمر شراء', 201);
  }

  // ── GET: قائمة طلبات الشراء ──────────────────────────────
  if (req.method === 'GET') {
    if (!org_id || !isUUID(org_id)) return sendError(res, 'org_id مطلوب');

    const filters = {
      org_id: `eq.${org_id}`,
      order: 'request_date.desc,created_at.desc',
      limit: req.query.limit || '50',
    };
    if (req.query.status) filters.status = `eq.${req.query.status}`;

    const { data, error } = await dbQuery({
      jwt, table: 'purchase_requests',
      select: '*,lines:purchase_request_lines(id,product_id,description,quantity,estimated_price,unit_of_measure,notes)',
      filters,
    });
    if (error) return sendError(res, error.message || 'خطأ في جلب طلبات الشراء', 500);
    return sendOk(res, data);
  }

  // ── POST: إنشاء طلب شراء ─────────────────────────────────
  if (req.method === 'POST') {
    const body = parseBody(req);
    if (!body) return sendError(res, 'جسم الطلب غير صالح');

    const err = requireFields(body, ['org_id', 'requester_name', 'lines']);
    if (err) return sendError(res, err);
    if (!isUUID(body.org_id)) return sendError(res, 'org_id غير صالح');
    if (!Array.isArray(body.lines) || body.lines.length === 0) {
      return sendError(res, 'أضف بنداً واحداً على الأقل');
    }
    for (let i = 0; i < body.lines.length; i++) {
      if (!body.lines[i].description?.trim()) {
        return sendError(res, `البند ${i+1}: الوصف مطلوب`);
      }
      if (parseFloat(body.lines[i].quantity) <= 0) {
        return sendError(res, `البند ${i+1}: الكمية يجب أن تكون أكبر من صفر`);
      }
    }

    // إنشاء طلب الشراء والبنود دفعة واحدة
    const { data: prData, error: prErr } = await dbQuery({
      jwt, table: 'purchase_requests', method: 'POST',
      body: {
        org_id: body.org_id,
        requester_name: body.requester_name.trim(),
        department: body.department || null,
        notes: body.notes || null,
        // رقم تسلسلي يُولَّد لاحقاً بـ trigger أو عبر query منفصل
      },
      prefer: 'return=representation',
    });
    if (prErr) return sendError(res, prErr.message || 'خطأ في إنشاء طلب الشراء', 422);

    const pr = Array.isArray(prData) ? prData[0] : prData;

    // إدراج البنود
    const linesPayload = body.lines.map((l, i) => ({
      purchase_request_id: pr.id,
      product_id: isUUID(l.product_id) ? l.product_id : null,
      description: l.description.trim(),
      quantity: parseFloat(l.quantity),
      estimated_price: l.estimated_price != null ? parseFloat(l.estimated_price) : null,
      unit_of_measure: l.unit_of_measure || 'قطعة',
      notes: l.notes || null,
      sort_order: i,
    }));

    const { error: lErr } = await dbQuery({
      jwt, table: 'purchase_request_lines', method: 'POST',
      body: linesPayload,
    });
    if (lErr) return sendError(res, lErr.message || 'خطأ في إضافة البنود', 422);

    return sendOk(res, pr, 'تم إنشاء طلب الشراء', 201);
  }

  // ── PATCH: تغيير الحالة ──────────────────────────────────
  if (req.method === 'PATCH') {
    if (!isUUID(id)) return sendError(res, 'id طلب الشراء مطلوب');
    const transition = STATUS_TRANSITIONS[action];
    if (!transition) {
      return sendError(res, `action غير معروف — المتاح: ${Object.keys(STATUS_TRANSITIONS).join(', ')}`);
    }

    // الموافقة عبر الدالة المخزّنة (تتحقق من صلاحية المالك)
    if (action === 'approve') {
      const { data, error } = await rpc({
        jwt, fn: 'approve_purchase_request',
        params: { p_pr_id: id },
      });
      if (error) return sendError(res, error.message || 'خطأ في الموافقة', 422);
      return sendOk(res, data, 'تمت الموافقة على طلب الشراء');
    }

    const { data: current } = await dbQuery({
      jwt, table: 'purchase_requests', select: 'id,status', filters: { id: `eq.${id}` },
    });
    if (!current?.[0]) return sendError(res, 'طلب الشراء غير موجود', 404);
    if (!transition.from.includes(current[0].status)) {
      return sendError(res, `لا يمكن "${action}" من حالة "${current[0].status}"`);
    }

    const { data, error } = await dbQuery({
      jwt, table: 'purchase_requests', method: 'PATCH',
      filters: { id: `eq.${id}` },
      body: { status: transition.to },
      prefer: 'return=representation',
    });
    if (error) return sendError(res, error.message || 'خطأ في التحديث', 422);
    return sendOk(res, Array.isArray(data) ? data[0] : data, `تم تحديث الحالة إلى "${transition.to}"`);
  }

  return sendError(res, 'Method not allowed', 405);
};
