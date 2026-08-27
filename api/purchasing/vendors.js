/**
 * GET   /api/purchasing/vendors?org_id={id}[&q=search]  — قائمة الموردين
 * POST  /api/purchasing/vendors                          — إنشاء مورد
 * PATCH /api/purchasing/vendors?id={uuid}               — تعديل بيانات مورد
 */
const { dbQuery } = require('../_lib/db');
const { requireAuth, sendError, sendOk, parseBody, requireFields, isUUID } = require('../_lib/validate');

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const jwt = requireAuth(req, res);
  if (!jwt) return;

  if (req.method === 'GET') {
    const { org_id, q, limit = '100' } = req.query;
    if (!org_id || !isUUID(org_id)) return sendError(res, 'org_id مطلوب');

    const filters = { org_id: `eq.${org_id}`, order: 'name.asc', limit };
    if (q) filters['name'] = `ilike.*${q}*`;

    const { data, error } = await dbQuery({
      jwt, table: 'vendors',
      select: 'id,name,tax_number,phone,email,balance,created_at',
      filters,
    });
    if (error) return sendError(res, error.message || 'خطأ في جلب الموردين', 500);
    return sendOk(res, data);
  }

  if (req.method === 'POST') {
    const body = parseBody(req);
    if (!body) return sendError(res, 'جسم الطلب غير صالح');

    const err = requireFields(body, ['org_id', 'name']);
    if (err) return sendError(res, err);
    if (!isUUID(body.org_id)) return sendError(res, 'org_id غير صالح');

    const { data, error } = await dbQuery({
      jwt, table: 'vendors', method: 'POST',
      body: {
        org_id: body.org_id,
        name: body.name.trim(),
        tax_number: body.tax_number || null,
        phone: body.phone || null,
        email: body.email || null,
      },
      prefer: 'return=representation',
    });
    if (error) return sendError(res, error.message || 'خطأ في إنشاء المورد', 422);
    return sendOk(res, Array.isArray(data) ? data[0] : data, 'تم إنشاء المورد', 201);
  }

  if (req.method === 'PATCH') {
    const { id } = req.query;
    if (!isUUID(id)) return sendError(res, 'id المورد غير صالح');

    const body = parseBody(req);
    if (!body) return sendError(res, 'جسم الطلب غير صالح');

    const allowed = ['name','tax_number','phone','email'];
    const patch = {};
    for (const k of allowed) { if (body[k] !== undefined) patch[k] = body[k]; }
    if (Object.keys(patch).length === 0) return sendError(res, 'لا توجد حقول قابلة للتعديل');

    const { data, error } = await dbQuery({
      jwt, table: 'vendors', method: 'PATCH',
      filters: { id: `eq.${id}` }, body: patch, prefer: 'return=representation',
    });
    if (error) return sendError(res, error.message || 'خطأ في التعديل', 422);
    return sendOk(res, Array.isArray(data) ? data[0] : data, 'تم التعديل');
  }

  return sendError(res, 'Method not allowed', 405);
};
