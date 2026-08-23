-- ============================================================
-- حاسِب AI — migration 002: حدود الاستخدام + لوحة تحكم المؤسس + طلبات التجربة
--
-- شغّل هذا الملف مرة واحدة في: Supabase → SQL Editor → New query → Run
-- يبني على الجداول الموجودة فعلاً في الإنتاج: organizations, memberships,
-- invoices, bank_transactions, closed_months (وعلى الدالتين is_member/has_role).
-- ============================================================

-- ---------- الباقات ----------
create table if not exists plans (
  id text primary key,
  name_ar text not null,
  name_en text not null,
  price_sar numeric(10,2),        -- null = تسعير مخصص (باقة أعمال)
  max_invoices_per_month int,     -- null = غير محدود
  max_members int                 -- null = غير محدود
);

insert into plans (id, name_ar, name_en, price_sar, max_invoices_per_month, max_members) values
  ('starter', 'انطلاقة', 'Starter', 149, 50, 1),
  ('growth',  'نمو',     'Growth',  349, 300, 5),
  ('business','أعمال',   'Business', null, null, null)
on conflict (id) do update set
  name_ar = excluded.name_ar, name_en = excluded.name_en,
  price_sar = excluded.price_sar,
  max_invoices_per_month = excluded.max_invoices_per_month,
  max_members = excluded.max_members;

alter table organizations add column if not exists plan_id text not null default 'starter' references plans(id);

-- ---------- فحص حد الفواتير الشهري لشركة ----------
create or replace function invoice_quota_status(p_org_id uuid)
returns table(used int, cap int, allowed boolean)
language sql security definer stable set search_path = public as $$
  select
    (select count(*)::int from invoices i
       where i.org_id = p_org_id and i.created_at >= date_trunc('month', now())) as used,
    p.max_invoices_per_month as cap,
    (p.max_invoices_per_month is null or
     (select count(*)::int from invoices i
        where i.org_id = p_org_id and i.created_at >= date_trunc('month', now()))
     < p.max_invoices_per_month) as allowed
  from organizations o
  join plans p on p.id = o.plan_id
  where o.id = p_org_id and is_member(p_org_id);
$$;

-- ---------- فحص حد عدد الأعضاء لشركة ----------
create or replace function member_quota_status(p_org_id uuid)
returns table(used int, cap int, allowed boolean)
language sql security definer stable set search_path = public as $$
  select
    (select count(*)::int from memberships m where m.org_id = p_org_id) as used,
    p.max_members as cap,
    (p.max_members is null or
     (select count(*)::int from memberships m where m.org_id = p_org_id) < p.max_members) as allowed
  from organizations o
  join plans p on p.id = o.plan_id
  where o.id = p_org_id and is_member(p_org_id);
$$;

-- ---------- مؤسسو المنصة (صلاحية عبر كل الشركات — منفصلة تماماً عن أدوار memberships) ----------
create table if not exists platform_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table platform_admins enable row level security;
-- عمداً بلا select policy: لا يُقرأ الجدول مباشرة من العميل، فقط عبر is_platform_admin() أدناه

create or replace function is_platform_admin(uid uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from platform_admins where user_id = uid);
$$;

-- منح حساب المؤسس صلاحية المؤسس تلقائياً
insert into platform_admins (user_id)
select id from auth.users where email = 'abuayser333@gmail.com'
on conflict do nothing;

-- ---------- نظرة عامة على كل الشركات — للوحة تحكم المؤسس فقط ----------
create or replace function admin_org_overview()
returns table(
  org_id uuid, org_name text, plan_id text,
  member_count int, invoices_this_month int, created_at timestamptz
)
language sql security definer stable set search_path = public as $$
  select o.id, o.name, o.plan_id,
    (select count(*)::int from memberships m where m.org_id = o.id),
    (select count(*)::int from invoices i
       where i.org_id = o.id and i.created_at >= date_trunc('month', now())),
    o.created_at
  from organizations o
  where is_platform_admin(auth.uid())
  order by o.created_at desc;
$$;

-- ---------- طلبات تجربة من صفحة الهبوط العامة ----------
create table if not exists leads (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  company_name text,
  phone text,
  email text,
  message text,
  created_at timestamptz not null default now()
);
alter table leads enable row level security;

drop policy if exists leads_insert_public on leads;
create policy leads_insert_public on leads for insert
with check (true);   -- أي زائر غير مسجل يمكنه إرسال طلب تجربة

drop policy if exists leads_select_admin on leads;
create policy leads_select_admin on leads for select
using (is_platform_admin(auth.uid()));

-- ============================================================
-- تحقق سريع بعد التشغيل (اختياري — شغّله يدوياً):
-- select * from plans;
-- select is_platform_admin(auth.uid());  -- من داخل SQL Editor قد يرجع false لأنه بدون جلسة مستخدم؛
--   للتحقق الفعلي سجّل الدخول من admin.html بعد النشر.
-- ============================================================
