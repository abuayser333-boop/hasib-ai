/**
 * Supabase HTTP client — يستخدم REST API مباشرة بدون حزمة خارجية.
 * كل طلب يمرر JWT الخاص بالمستخدم حتى تعمل سياسات RLS بشكل صحيح.
 */

const SUPABASE_URL     = process.env.SUPABASE_URL;
const SUPABASE_ANON    = process.env.SUPABASE_ANON_KEY;
const SUPABASE_SERVICE = process.env.SUPABASE_SERVICE_KEY; // اختياري للعمليات المميزة

/**
 * استخراج JWT من Authorization header.
 * @param {object} req - كائن الطلب
 * @returns {string|null}
 */
function extractToken(req) {
  const auth = req.headers['authorization'] || '';
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match ? match[1] : null;
}

/**
 * استدعاء REST API لجدول Supabase.
 *
 * @param {object} opts
 * @param {string}  opts.jwt        - JWT المستخدم
 * @param {string}  opts.table      - اسم الجدول
 * @param {string}  [opts.method]   - GET | POST | PATCH | DELETE (افتراضي: GET)
 * @param {string}  [opts.select]   - عمود Select (مثال: '*,customer:customers(*)')
 * @param {object}  [opts.filters]  - مرشحات {column: 'eq.value', ...}
 * @param {object}  [opts.body]     - جسم الطلب (POST/PATCH)
 * @param {string}  [opts.prefer]   - Prefer header (مثال: 'return=representation')
 * @returns {Promise<{data, error, status}>}
 */
async function dbQuery({ jwt, table, method = 'GET', select = '*', filters = {}, body, prefer }) {
  if (!SUPABASE_URL) throw new Error('SUPABASE_URL غير مضبوط');
  if (!SUPABASE_ANON) throw new Error('SUPABASE_ANON_KEY غير مضبوط');

  const url = new URL(`${SUPABASE_URL}/rest/v1/${table}`);
  if (select) url.searchParams.set('select', select);
  for (const [col, val] of Object.entries(filters)) {
    url.searchParams.set(col, val);
  }

  const headers = {
    'apikey': SUPABASE_ANON,
    'Authorization': `Bearer ${jwt || SUPABASE_ANON}`,
    'Content-Type': 'application/json',
  };
  if (prefer) headers['Prefer'] = prefer;

  const resp = await fetch(url.toString(), {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });

  const text = await resp.text();
  let data = null;
  try { data = JSON.parse(text); } catch { data = text; }

  if (!resp.ok) {
    return { data: null, error: data, status: resp.status };
  }
  return { data, error: null, status: resp.status };
}

/**
 * استدعاء Postgres RPC (دالة مخزّنة).
 *
 * @param {object} opts
 * @param {string} opts.jwt      - JWT المستخدم
 * @param {string} opts.fn       - اسم الدالة
 * @param {object} opts.params   - معاملات الدالة
 * @returns {Promise<{data, error, status}>}
 */
async function rpc({ jwt, fn, params = {} }) {
  if (!SUPABASE_URL) throw new Error('SUPABASE_URL غير مضبوط');

  const resp = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'apikey': SUPABASE_ANON,
      'Authorization': `Bearer ${jwt || SUPABASE_ANON}`,
      'Content-Type': 'application/json',
      'Prefer': 'return=representation',
    },
    body: JSON.stringify(params),
  });

  const text = await resp.text();
  let data = null;
  try { data = JSON.parse(text); } catch { data = text; }

  if (!resp.ok) return { data: null, error: data, status: resp.status };
  return { data, error: null, status: resp.status };
}

module.exports = { extractToken, dbQuery, rpc };
