// ============================================================
// حاسِب AI — وسيط Claude على الخادم (Vercel Serverless Function)
//
// الغرض: إبقاء مفتاح Anthropic API على الخادم فقط. المتصفح لم يعد
// يرى المفتاح ولا يُخزّنه، وإنما يرسل حمولة الرسائل إلى هذا المسار
// فيضيف الخادم الترويسة السرية ويمرّر الطلب.
//
// الإعداد المطلوب مرة واحدة في Vercel:
//   Project → Settings → Environment Variables
//   ANTHROPIC_API_KEY = sk-ant-...        (Production + Preview)
// ============================================================

const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';

// نماذج مسموح بها فقط — يمنع استخدام المسار لتشغيل نماذج غير مقصودة
const ALLOWED_MODELS = new Set([
  'claude-sonnet-4-6',
  'claude-opus-4-1',
  'claude-haiku-4-5'
]);

const MAX_TOKENS_CAP = 4000;
const MAX_BODY_BYTES = 12 * 1024 * 1024; // ~12MB: يكفي لفاتورة PDF/صورة base64

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: { message: 'Method not allowed' } });
  }

  // الطلب من المتصفح قد يرفق lang ('ar' أو 'en') لمطابقة لغة الواجهة الحالية
  // في رسائل الخطأ المرجعة من هذا الوسيط. لا علاقة له بمحتوى الفاتورة نفسه.
  let bodyForLang = req.body;
  try { if (typeof bodyForLang === 'string') bodyForLang = JSON.parse(bodyForLang); } catch (e) { bodyForLang = null; }
  const isAr = !bodyForLang || bodyForLang.lang !== 'en';
  const msg = (ar, en) => (isAr ? ar : en);

  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) {
    return res.status(500).json({
      error: {
        message: msg(
          'ANTHROPIC_API_KEY غير مضبوط على الخادم. أضِفه في Vercel: Settings → Environment Variables.',
          'ANTHROPIC_API_KEY is not configured on the server. Add it in Vercel: Settings → Environment Variables.'
        ),
        code: 'missing_server_key'
      }
    });
  }

  let body = req.body;
  try {
    if (typeof body === 'string') body = JSON.parse(body);
  } catch (e) {
    return res.status(400).json({ error: { message: msg('حمولة JSON غير صالحة', 'Invalid JSON payload') } });
  }
  if (!body || !Array.isArray(body.messages)) {
    return res.status(400).json({ error: { message: msg('الحقل messages مطلوب', 'The messages field is required') } });
  }

  const approxBytes = Buffer.byteLength(JSON.stringify(body), 'utf8');
  if (approxBytes > MAX_BODY_BYTES) {
    return res.status(413).json({ error: { message: msg('الملف كبير جداً — جرّب صورة أصغر أو PDF مضغوط', 'File too large — try a smaller image or a compressed PDF') } });
  }

  const model = ALLOWED_MODELS.has(body.model) ? body.model : 'claude-sonnet-4-6';
  const maxTokens = Math.min(Number(body.max_tokens) || 1600, MAX_TOKENS_CAP);

  try {
    const upstream = await fetch(ANTHROPIC_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': key,
        'anthropic-version': '2023-06-01'
      },
      body: JSON.stringify({ model: model, max_tokens: maxTokens, messages: body.messages })
    });

    const text = await upstream.text();
    res.status(upstream.status);
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    // لا نسمح بتخزين استجابات تحتوي بيانات فواتير
    res.setHeader('Cache-Control', 'no-store');
    return res.send(text);
  } catch (err) {
    return res.status(502).json({
      error: { message: msg('تعذّر الوصول إلى Claude API: ', 'Could not reach the Claude API: ') + (err && err.message ? err.message : msg('خطأ غير معروف', 'Unknown error')) }
    });
  }
};
