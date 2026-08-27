/**
 * GET /api/inventory/movements?org_id={id}[&product_id=uuid][&move_type=in|out|adjustment]
 *     [&limit=100][&offset=0]
 *     — سجل حركات المخزون (للقراءة فقط — الكتابة عبر record_purchase/record_sale)
 */
const { dbQuery } = require('../_lib/db');
const { requireAuth, sendError, sendOk, isUUID } = require('../_lib/validate');

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  const jwt = requireAuth(req, res);
  if (!jwt) return;

  if (req.method !== 'GET') return sendError(res, 'Method not allowed', 405);

  const { org_id, product_id, move_type, limit = '100', offset = '0' } = req.query;
  if (!org_id || !isUUID(org_id)) return sendError(res, 'org_id مطلوب');

  const filters = {
    org_id: `eq.${org_id}`,
    order: 'created_at.desc',
    limit, offset,
  };
  if (product_id && isUUID(product_id)) filters.product_id = `eq.${product_id}`;
  if (move_type && ['in','out','adjustment'].includes(move_type)) {
    filters.move_type = `eq.${move_type}`;
  }

  const { data, error } = await dbQuery({
    jwt, table: 'stock_moves',
    select: 'id,product_id,warehouse_id,move_type,quantity,unit_cost,ref_type,ref_id,note,created_at,product:products(name,sku)',
    filters,
  });
  if (error) return sendError(res, error.message || 'خطأ في جلب حركات المخزون', 500);
  return sendOk(res, data);
};
