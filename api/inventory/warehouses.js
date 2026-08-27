/**
 * GET   /api/inventory/warehouses?org_id={id}  — قائمة المستودعات
 * POST  /api/inventory/warehouses              — إنشاء مستودع
 * PATCH /api/inventory/warehouses?id={uuid}   — تعديل مستودع
 */
const { dbQuery } = require('../_lib/db');
const { requireAuth, sendError, sendOk, parseBody, requireFields, isUUID } = require('../_lib/validate');

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const jwt = requireAuth(req, res);
  if (!jwt) return;

  if (req.method === 'GET') {
    const { org_id } = req.query;
    if (!org_id || !isUUID(org_id)) return sendError(res, 'org_id مطلوب');

    const { data, error } = await dbQuery({
      jwt, table: 'warehouses',
      select: 'id,name,is_default,created_at',
      filters: { org_id: `eq.${org_id}`, order: 'is_default.desc,name.asc' },
    });
    if (error) return sendError(res, error.message || 'خطأ في جلب المستودعات', 500);
    return sendOk(res, data);
  }

  if (req.method === 'POST') {
    const body = parseBody(req);
    if (!body) return sendError(res, 'جسم الطلب غير صالح');

    const err = requireFields(body, ['org_id', 'name']);
    if (err) return sendError(res, err);
    if (!isUUID(body.org_id)) return sendError(res, 'org_id غير صالح');

    const { data, error } = await dbQuery({
      jwt, table: 'warehouses', method: 'POST',
      body: { org_id: body.org_id, name: body.name.trim(), is_default: body.is_default || false },
      prefer: 'return=representation',
    });
    if (error) return sendError(res, error.message || 'خطأ في إنشاء المستودع', 422);
    return sendOk(res, Array.isArray(data) ? data[0] : data, 'تم إنشاء المستودع', 201);
  }

  if (req.method === 'PATCH') {
    const { id } = req.query;
    if (!isUUID(id)) return sendError(res, 'id المستودع غير صالح');

    const body = parseBody(req);
    if (!body) return sendError(res, 'جسم الطلب غير صالح');

    const patch = {};
    if (body.name !== undefined) patch.name = body.name;
    if (Object.keys(patch).length === 0) return sendError(res, 'لا توجد حقول قابلة للتعديل');

    const { data, error } = await dbQuery({
      jwt, table: 'warehouses', method: 'PATCH',
      filters: { id: `eq.${id}` }, body: patch, prefer: 'return=representation',
    });
    if (error) return sendError(res, error.message || 'خطأ في التعديل', 422);
    return sendOk(res, Array.isArray(data) ? data[0] : data, 'تم التعديل');
  }

  return sendError(res, 'Method not allowed', 405);
};
