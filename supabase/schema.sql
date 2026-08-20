-- ============================================================
-- حاسِب AI — مخطط قاعدة البيانات متعدد الشركات (multi-tenant)
--
-- شغّل هذا الملف مرة واحدة في: Supabase → SQL Editor → New query → Run
--
-- مبدأ التصميم: العزل مفروض في قاعدة البيانات نفسها عبر Row Level Security،
-- لا في واجهة المتصفح. حتى لو عبث أحدهم بالكود من DevTools، لن يرى صفاً
-- واحداً من دفاتر شركة لا ينتمي إليها — لأن Postgres هو من يمنعه لا الواجهة.
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- الأدوار ----------
do $$ begin
create type app_role as enum ('owner', 'accountant', 'viewer');
exception when duplicate_object then null; end $$;
-- owner : كل شيء + إدارة الأعضاء + إغلاق الشهر + الحذف
-- accountant : إضافة/تعديل/اعتماد الفواتير
-- viewer : اطّلاع فقط — لا يستهلك رصيد Claude ولا يعدّل شيئاً

-- ---------- الشركات ----------
create table if not exists organizations (
id uuid primary key default gen_random_uuid(),
name text not null,
vat_number text,
created_at timestamptz not null default now()
);

-- ---------- العضويات: من ينتمي لأي شركة وبأي دور ----------
create table if not exists memberships (
user_id uuid not null references auth.users(id) on delete cascade,
org_id uuid not null references organizations(id) on delete cascade,
role app_role not null default 'viewer',
created_at timestamptz not null default now(),
primary key (user_id, org_id)
);
create index if not exists memberships_org_idx on memberships(org_id);
create index if not exists memberships_user_idx on memberships(user_id);

-- ---------- الفواتير ----------
create table if not exists invoices (
id uuid primary key default gen_random_uuid(),
org_id uuid not null references organizations(id) on delete cascade,
created_by uuid references auth.users(id) on delete set null,
vendor_name text,
vendor_tax_number text,
invoice_number text,
invoice_date date,
subtotal numeric(14,2),
vat_amount numeric(14,2),
vat_rate numeric(5,2),
total_amount numeric(14,2),
currency text default 'SAR',
description text,
payment_method text,
account_type text,
debit_account text,
credit_account text,
zatca_compliant boolean,
confidence integer,
approved boolean not null default false,
needs_review boolean not null default false,
reconciled boolean not null default false,
-- نتيجة الوكلاء كاملة بما فيها audit_trail وسلسلة الـ hash
payload jsonb,
created_at timestamptz not null default now(),
updated_at timestamptz not null default now()
);
create index if not exists invoices_org_date_idx on invoices(org_id, invoice_date desc);
-- يمنع ازدواج نفس الفاتورة من نفس المورّد داخل الشركة الواحدة
create unique index if not exists invoices_org_unique_doc
on invoices(org_id, vendor_tax_number, invoice_number)
where vendor_tax_number is not null and invoice_number is not null;

-- منع تكرار رفع نفس ملف الفاتورة (نفس البايتات) لنفس الشركة
alter table invoices add column if not exists file_hash text;
create unique index if not exists invoices_org_unique_filehash
on invoices(org_id, file_hash)
where file_hash is not null;

-- ---------- الحركات البنكية (للمطابقة) ----------
create table if not exists bank_transactions (
id uuid primary key default gen_random_uuid(),
org_id uuid not null references organizations(id) on delete cascade,
txn_date date,
description text,
amount numeric(14,2),
matched_invoice_id uuid references invoices(id) on delete set null,
created_at timestamptz not null default now()
);
create index if not exists bank_txn_org_idx on bank_transactions(org_id, txn_date);

-- ---------- الفترات المقفلة ----------
create table if not exists closed_months (
org_id uuid not null references organizations(id) on delete cascade,
ym text not null, -- 'YYYY-MM'
closed_by uuid references auth.users(id) on delete set null,
closed_at timestamptz not null default now(),
primary key (org_id, ym)
);

-- ============================================================
-- دوال مساعدة للصلاحيات
-- security definer ضروري: تقرأ memberships متجاوزةً RLS الخاص بها،
-- وإلا وقعنا في تكرار لا نهائي عند تقييم السياسات.
-- ============================================================
create or replace function is_member(target_org uuid)
returns boolean language sql security definer stable set search_path = public as $$
select exists (
select 1 from memberships m
where m.org_id = target_org and m.user_id = auth.uid()
);
$$;

create or replace function has_role(target_org uuid, allowed app_role[])
returns boolean language sql security definer stable set search_path = public as $$
select exists (
select 1 from memberships m
where m.org_id = target_org and m.user_id = auth.uid() and m.role = any(allowed)
);
$$;

-- ============================================================
-- تفعيل RLS — لا شيء مقروء أو مكتوب بدون سياسة صريحة
-- ============================================================
alter table organizations enable row level security;
alter table memberships enable row level security;
alter table invoices enable row level security;
alter table bank_transactions enable row level security;
alter table closed_months enable row level security;

-- ---------- organizations ----------
drop policy if exists org_select on organizations;
create policy org_select on organizations for select
using (is_member(id));

drop policy if exists org_update on organizations;
create policy org_update on organizations for update
using (has_role(id, array['owner']::app_role[]));

-- أي مستخدم مسجّل يستطيع إنشاء شركة جديدة (ويصبح مالكها عبر التريجر أدناه)
drop policy if exists org_insert on organizations;
create policy org_insert on organizations for insert
with check (auth.uid() is not null);

-- ---------- memberships ----------
-- يرى العضو زملاءه في نفس الشركة فقط
drop policy if exists mem_select on memberships;
create policy mem_select on memberships for select
using (is_member(org_id));

-- إدارة الأعضاء حكر على المالك
drop policy if exists mem_write on memberships;
create policy mem_write on memberships for all
using (has_role(org_id, array['owner']::app_role[]))
with check (has_role(org_id, array['owner']::app_role[]));

-- ---------- invoices ----------
drop policy if exists inv_select on invoices;
create policy inv_select on invoices for select
using (is_member(org_id));

drop policy if exists inv_insert on invoices;
create policy inv_insert on invoices for insert
with check (has_role(org_id, array['owner','accountant']::app_role[]));

-- لا يجوز التعديل على فاتورة داخل شهر مقفل
drop policy if exists inv_update on invoices;
create policy inv_update on invoices for update
using (
has_role(org_id, array['owner','accountant']::app_role[])
and not exists (
select 1 from closed_months c
where c.org_id = invoices.org_id
and c.ym = to_char(invoices.invoice_date, 'YYYY-MM')
)
);

drop policy if exists inv_delete on invoices;
create policy inv_delete on invoices for delete
using (has_role(org_id, array['owner']::app_role[]));

-- ---------- bank_transactions ----------
drop policy if exists bank_select on bank_transactions;
create policy bank_select on bank_transactions for select
using (is_member(org_id));

drop policy if exists bank_write on bank_transactions;
create policy bank_write on bank_transactions for all
using (has_role(org_id, array['owner','accountant']::app_role[]))
with check (has_role(org_id, array['owner','accountant']::app_role[]));

-- ---------- closed_months ----------
drop policy if exists cm_select on closed_months;
create policy cm_select on closed_months for select
using (is_member(org_id));

-- إغلاق الشهر قرار محاسبي نهائي — للمالك وحده
drop policy if exists cm_insert on closed_months;
create policy cm_insert on closed_months for insert
with check (has_role(org_id, array['owner']::app_role[]));

drop policy if exists cm_delete on closed_months;
create policy cm_delete on closed_months for delete
using (has_role(org_id, array['owner']::app_role[]));

-- ============================================================
-- تريجرات
-- ============================================================
-- من ينشئ شركة يصبح مالكها تلقائياً، وإلا لأنشأ شركة لا يستطيع دخولها
create or replace function claim_new_org()
returns trigger language plpgsql security definer set search_path = public as $$
begin
insert into memberships (user_id, org_id, role)
values (auth.uid(), new.id, 'owner')
on conflict do nothing;
return new;
end; $$;

drop trigger if exists on_org_created on organizations;
create trigger on_org_created after insert on organizations
for each row execute function claim_new_org();

-- تحديث updated_at تلقائياً
create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end; $$;

drop trigger if exists on_invoice_update on invoices;
create trigger on_invoice_update before update on invoices
for each row execute function touch_updated_at();

-- ============================================================
-- تحقق سريع بعد التشغيل:
-- select tablename, rowsecurity from pg_tables
-- where schemaname='public' and tablename in
-- ('organizations','memberships','invoices','bank_transactions','closed_months');
-- يجب أن تكون rowsecurity = true في كل الصفوف.
-- ============================================================
