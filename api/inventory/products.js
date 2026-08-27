/**
 * GET   /api/inventory/products?org_id={id}[&q=search][&low_stock=1][&category_id=uuid]
 *       — قائمة المنتجات (مع تصفية المخزون المنخفض)
 * POST  /api/inventory/products
 *       — إنشاء منتج جديد
 *       Body: { org_id, name, sku?, selling_price, avg_cost?, reorder_level?,
 *               warehouse_id?, category_id?, unit_of_measure? }
 * PATCH /api/inventory/products?id={uuid}
 *       — تعديل بيانات منتج (السعر، مستوى إعادة الطلب، إلخ)
 */
const { dbQuery } = require('../_lib/db');
const { requireAuth, sendError, sendOk, parseBody, requireFields, isUUID } = require('../_lib/validate');

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const jwt = requireAuth(req, res);
  if (!jwt) return;

  if (req.method === 'GET') {
    const { org_id, q, low_stock, category_id, limit = '200', offset = '0' } = req.query;
    if (!org_id || !isUUID(org_id)) return sendError(res, 'org_id مطلوب');

    const filters = {
      org_id: `eq.${org_id}`,
      is_active: 'eq.true',
      order: 'name.asc',
      limit, offset,
    };
    if (q)           filters['name']         = `ilike.*${q}*`;
    if (low_stock)   filters['quantity']     = 'lte.reorder_level'; // يحتاج تعديل في Supabase PostgREST
    if (category_id) filters['category_id'] = `eq.${category_id}`;

    const { data, error } = await dbQuery({
      jwt, table: 'products',
      select: 'id,sku,name,quantity,avg_cost,selling_price,reorder_level,unit_of_measure,category_id,warehouse_id,updated_at',
      filters,
    });
    if (error) return sendError(res, error.message || 'خطأ في جلب المنتجات', 500);

    // حساب المنتجات ذات المخزون المنخفض من جانب الخادم
    const result = data || [];
    if (low_stock === '1') {
      return sendOk(res, result.filter(p => parseFloat(p.quantity) <= parseFloat(p.reorder_level || 0)));
    }
    return sendOk(res, result);
  }

  if (req.method === 'POST') {
    const body = parseBody(req);
    if (!body) return sendError(res, 'جسم الطلب غير صالح');

    const err = requireFields(body, ['org_id', 'name', 'selling_price']);
    if (err) return sendError(res, err);
    if (!isUUID(body.org_id)) return sendError(res, 'org_id غير صالح');
    if (parseFloat(body.selling_price) < 0) return sendError(res, 'سعر البيع لا يمكن أن يكون سالباً');

    const { data, error } = await dbQuery({
      jwt, table: 'products', method: 'POST',
      body: {
        org_id: body.org_id,
        name: body.name.trim(),
        sku: body.sku || null,
        selling_price: parseFloat(body.selling_price),
        avg_cost: body.avg_cost != null ? parseFloat(body.avg_cost) : 0,
        reorder_level: body.reorder_level != null ? parseFloat(body.reorder_level) : 0,
        warehouse_id: isUUID(body.warehouse_id) ? body.warehouse_id : null,
        category_id: isUUID(body.category_id) ? body.category_id : null,
        unit_of_measure: body.unit_of_measure || 'قطعة',
      },
      prefer: 'return=representation',
    });
    if (error) return sendError(res, error.message || 'خطأ في إنشاء المنتج', 422);
    return sendOk(res, Array.isArray(data) ? data[0] : data, 'تم إنشاء المنتج', 201);
  }

  if (req.method === 'PATCH') {
    const { id } = req.query;
    if (!isUUID(id)) return sendError(res, 'id المنتج غير صالح');

    const body = parseBody(req);
    if (!body) return sendError(res, 'جسم الطلب غير صالح');

    const allowed = ['name','sku','selling_price','reorder_level','category_id','unit_of_measure','is_active'];
    const patch = {};
    for (const k of allowed) { if (body[k] !== undefined) patch[k] = body[k]; }
    if (Object.keys(patch).length === 0) return sendError(res, 'لا توجد حقول قابلة للتعديل');
    if (patch.selling_price !== undefined && parseFloat(patch.selling_price) < 0) {
      return sendError(res, 'سعر البيع لا يمكن أن يكون سالباً');
    }

    const { data, error } = await dbQuery({
      jwt, table: 'products', method: 'PATCH',
      filters: { id: `eq.${id}` }, body: patch, prefer: 'return=representation',
    });
    if (error) return sendError(res, error.message || 'خطأ في التعديل', 422);
    return sendOk(res, Array.isArray(data) ? data[0] : data, 'تم تعديل المنتج');
  }

  return sendError(res, 'Method not allowed', 405);
};
