/**
 * دوال التحقق من صحة المدخلات — مشتركة بين جميع موديولات API.
 * كل خطأ تحقق يُرجع استجابة JSON موحّدة بدون طرح استثناء.
 */

/**
 * التحقق من وجود الحقول المطلوبة.
 * @param {object} obj  - كائن المدخلات
 * @param {string[]} fields - قائمة الحقول المطلوبة
 * @returns {string|null} رسالة الخطأ أو null إذا كان كل شيء صحيحاً
 */
function requireFields(obj, fields) {
  for (const f of fields) {
    const val = obj[f];
    if (val === undefined || val === null || val === '') {
      return `الحقل "${f}" مطلوب`;
    }
  }
  return null;
}

/**
 * التحقق من صحة UUID.
 */
function isUUID(str) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(str);
}

/**
 * التحقق من صحة التاريخ (YYYY-MM-DD).
 */
function isDate(str) {
  return /^\d{4}-\d{2}-\d{2}$/.test(str) && !isNaN(Date.parse(str));
}

/**
 * التحقق من صحة رقم موجب.
 */
function isPositiveNumber(val) {
  return typeof val === 'number' ? val > 0 : !isNaN(val) && parseFloat(val) > 0;
}

/**
 * التحقق من صحة بنود الفاتورة/العرض.
 * كل بند يجب أن يحتوي على quantity وunit_price صحيحتين.
 * @param {Array} lines
 * @param {object} [opts]
 * @param {boolean} [opts.requireProductId] - هل product_id مطلوب؟
 * @returns {string|null}
 */
function validateLines(lines, opts = {}) {
  if (!Array.isArray(lines) || lines.length === 0) {
    return 'أضف بنداً واحداً على الأقل';
  }
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (opts.requireProductId && !isUUID(l.product_id)) {
      return `البند ${i + 1}: product_id مطلوب ويجب أن يكون UUID صحيحاً`;
    }
    if (!isPositiveNumber(l.quantity)) {
      return `البند ${i + 1}: الكمية يجب أن تكون أكبر من صفر`;
    }
    if (l.unit_price === undefined || parseFloat(l.unit_price) < 0) {
      return `البند ${i + 1}: السعر لا يمكن أن يكون سالباً`;
    }
    if (l.discount !== undefined) {
      const d = parseFloat(l.discount);
      if (isNaN(d) || d < 0 || d > 100) {
        return `البند ${i + 1}: الخصم يجب أن يكون بين 0 و 100`;
      }
    }
  }
  return null;
}

/**
 * إرجاع استجابة خطأ موحّدة.
 * @param {object} res - كائن الاستجابة
 * @param {string} message
 * @param {number} [status]
 */
function sendError(res, message, status = 400) {
  res.status(status).json({ error: { message, code: status } });
}

/**
 * إرجاع استجابة نجاح موحّدة.
 * @param {object} res
 * @param {*} data
 * @param {string} [message]
 * @param {number} [status]
 */
function sendOk(res, data, message, status = 200) {
  const body = { data };
  if (message) body.message = message;
  res.status(status).json(body);
}

/**
 * قراءة جسم الطلب JSON بأمان.
 */
function parseBody(req) {
  if (typeof req.body === 'string') {
    try { return JSON.parse(req.body); } catch { return null; }
  }
  return req.body || null;
}

/**
 * التحقق من المصادقة وإرجاع الـ JWT.
 * @param {object} req
 * @param {object} res
 * @returns {string|null} — null إذا أُرسلت استجابة خطأ بالفعل
 */
function requireAuth(req, res) {
  const { extractToken } = require('./db');
  const token = extractToken(req);
  if (!token) {
    sendError(res, 'مطلوب تسجيل الدخول — أرسل Authorization: Bearer {token}', 401);
    return null;
  }
  return token;
}

module.exports = {
  requireFields,
  isUUID,
  isDate,
  isPositiveNumber,
  validateLines,
  sendError,
  sendOk,
  parseBody,
  requireAuth,
};
