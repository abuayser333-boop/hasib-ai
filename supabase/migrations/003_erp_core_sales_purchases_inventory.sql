-- ============================================================
-- حاسِب AI — migration 003: نواة ERP المترابطة
--   دفتر أستاذ عام (Journal) + مخازن حقيقية + عملاء/موردون + مبيعات/مشتريات
--   + دعوات الأعضاء (invites) + تحصيل/سداد
--
-- شغّل هذا الملف مرة واحدة في: Supabase → SQL Editor → New query → Run
-- يبني فوق 001 (schema.sql) و 002 (usage_limits_admin_leads) الموجودين
-- فعلاً في الإنتاج، ويكمل جداول كانت الواجهة (index.html) تستدعيها
-- (sb.from('products')‎, sb.rpc('record_purchase')‎ ...) دون أن تكون
-- موجودة في القاعدة — لذلك المشتريات/المبيعات/المخازن/الدعوات كانت
-- تفشل بصمت. هذا الملف يبنيها بنفس توقيع الاستدعاءات تماماً بدون أي
-- تعديل على الواجهة.
--
-- مبدأ الترابط التلقائي المطلوب:
--   تسجيل فاتورة بيع (record_sale) = عملية ذرية واحدة (transaction) تُنفّذ:
--     1) تتحقق من توفر الكمية في المخزون
--     2) تخصم الكمية من المخزون + تسجّل حركة مخزنية (stock_moves)
--     3) تحتسب تكلفة البضاعة المباعة (COGS) بمتوسط التكلفة المرجّح
--     4) تُنشئ/تُحدّث بطاقة العميل وتزيد رصيده إذا كانت آجلة
--     5) ترحّل قيداً محاسبياً موزوناً في دفتر الأستاذ العام (journal_entries)
--   وبالمثل تماماً لفاتورة الشراء (record_purchase) في الاتجاه المعاكس.
--   كل هذا يحدث داخل الخادم (Postgres function) لا في المتصفح، فلا يمكن
--   لأي طرف تخطي الترابط أو ترك القيود غير متوازنة.
-- ============================================================

-- ============================================================
-- 1) دفتر الأستاذ العام — مصدر الحقيقة الوحيد للقيود عبر كل الموديولات
-- ============================================================
create table if not exists chart_of_accounts (
  code text primary key,
  name_ar text not null,
  name_en text not null,
  account_type text not null check (account_type in ('asset','liability','equity','revenue','expense')),
  is_current boolean not null default true, -- تصنيف متداول/غير متداول لقائمة المركز المالي (IFRS: IAS 1)
  created_at timestamptz not null default now()
);

insert into chart_of_accounts (code, name_ar, name_en, account_type, is_current) values
  ('1010','الصندوق','Cash on hand','asset',true),
  ('1020','البنك','Bank','asset',true),
  ('1200','الذمم المدينة','Accounts Receivable','asset',true),
  ('1300','المخزون','Inventory','asset',true),
  ('1400','الأصول الثابتة','Fixed Assets','asset',false),
  ('1450','مجمّع الإهلاك','Accumulated Depreciation','asset',false),
  ('2100','الدائنون','Accounts Payable','liability',true),
  ('2130','ضريبة القيمة المضافة — المدخلات','VAT — Input','asset',true),
  ('2140','ضريبة القيمة المضافة — المخرجات','VAT — Output','liability',true),
  ('2200','رواتب مستحقة الدفع','Salaries Payable','liability',true),
  ('2210','التأمينات الاجتماعية (جوسي) مستحقة','GOSI Payable','liability',true),
  ('3000','رأس المال','Owner''s Capital','equity',false),
  ('3100','الأرباح المرحلة','Retained Earnings','equity',false),
  ('3200','مسحوبات المالك','Owner''s Drawings','equity',false),
  ('4000','إيرادات المبيعات','Sales Revenue','revenue',false),
  ('5050','تكلفة البضاعة المباعة','Cost of Goods Sold','expense',false),
  ('5100','مصروفات تشغيل','Operating Expenses','expense',false),
  ('5110','م صيانة','Maintenance','expense',false),
  ('5120','م ضيافة','Hospitality','expense',false),
  ('5130','م دعاية واعلان','Advertising & Marketing','expense',false),
  ('5140','م قطع غيار','Spare Parts','expense',false),
  ('5150','م وقود ومحروقات','Fuel','expense',false),
  ('5160','م ايجار','Rent','expense',false),
  ('5170','م اتصالات','Telecom','expense',false),
  ('5180','م حكومية','Government Fees','expense',false),
  ('5190','م تأمين','Insurance','expense',false),
  ('5200','مصروفات تسويقية','Marketing Expenses','expense',false),
  ('5300','مصروف الإهلاك','Depreciation Expense','expense',false),
  ('6000','مصروفات إدارية','Administrative Expenses','expense',false),
  ('6100','م اجور ورواتب','Salaries & Wages','expense',false),
  ('6110','مصروف التأمينات الاجتماعية (جوسي) — حصة الشركة','GOSI Expense (Employer)','expense',false)
on conflict (code) do update set
  name_ar = excluded.name_ar, name_en = excluded.name_en,
  account_type = excluded.account_type, is_current = excluded.is_current;

create table if not exists journal_entries (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  entry_date date not null default current_date,
  source_type text not null, -- 'invoice' | 'purchase' | 'sale' | 'asset_depreciation' | 'payroll' | 'equity' | 'bank_manual' | 'customer_payment' | 'vendor_payment'
  source_id uuid,
  description text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists je_org_date_idx on journal_entries(org_id, entry_date desc);
create index if not exists je_source_idx on journal_entries(org_id, source_type, source_id);

create table if not exists journal_lines (
  id uuid primary key default gen_random_uuid(),
  journal_entry_id uuid not null references journal_entries(id) on delete cascade,
  account_code text not null references chart_of_accounts(code),
  debit numeric(14,2) not null default 0,
  credit numeric(14,2) not null default 0,
  memo text,
  check (debit >= 0 and credit >= 0),
  check (not (debit > 0 and credit > 0))
);
create index if not exists jl_entry_idx on journal_lines(journal_entry_id);
create index if not exists jl_account_idx on journal_lines(account_code);

-- دالة مركزية: يستدعيها كل موديول لترحيل قيد. تتحقق من توازن القيد
-- (مجموع المدين = مجموع الدائن) وترفضه إن لم يكن متوازناً — لا قيد
-- غير متوازن يدخل الدفاتر مهما كان مصدره.
create or replace function post_journal_entry(
  p_org_id uuid, p_entry_date date, p_source_type text, p_source_id uuid,
  p_description text, p_lines jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_entry_id uuid;
  v_total_debit numeric(14,2) := 0;
  v_total_credit numeric(14,2) := 0;
  v_line jsonb;
begin
  select coalesce(sum((l->>'debit')::numeric),0), coalesce(sum((l->>'credit')::numeric),0)
    into v_total_debit, v_total_credit
    from jsonb_array_elements(p_lines) l;

  if round(v_total_debit,2) <> round(v_total_credit,2) then
    raise exception 'قيد غير متوازن: مدين %, دائن % (يجب أن يتساويا)', v_total_debit, v_total_credit;
  end if;

  insert into journal_entries (org_id, entry_date, source_type, source_id, description, created_by)
  values (p_org_id, coalesce(p_entry_date, current_date), p_source_type, p_source_id, p_description, auth.uid())
  returning id into v_entry_id;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    insert into journal_lines (journal_entry_id, account_code, debit, credit, memo)
    values (v_entry_id, v_line->>'account_code', coalesce((v_line->>'debit')::numeric,0),
            coalesce((v_line->>'credit')::numeric,0), v_line->>'memo');
  end loop;

  return v_entry_id;
end; $$;

-- ميزان مراجعة + دفتر أستاذ عام مباشرة من journal_lines — مصدر حقيقة
-- موحّد يغطي كل الموديولات (أصول ثابتة، رواتب، حقوق ملكية، بنوك...).
-- الواجهة الحالية لفواتير الشراء/البيع/المصروفات تستمر بحساب ميزانها
-- الخاص من مصدر المستندات مباشرة (كما هي اليوم) لتفادي أي تغيير سلوك؛
-- هذه الدالة تخدم كشاشة "دفتر الأستاذ العام" الجديدة وأي موديول لاحق
-- (أصول/رواتب/حقوق ملكية/بنوك) لا يوجد له عرض JS سابق أصلاً.
create or replace function general_ledger_balances(p_org_id uuid, p_upto date default null)
returns table(code text, name_ar text, name_en text, account_type text, debit numeric, credit numeric, balance numeric)
language sql security definer stable set search_path = public as $$
  select c.code, c.name_ar, c.name_en, c.account_type,
    coalesce(sum(jl.debit),0) as debit,
    coalesce(sum(jl.credit),0) as credit,
    coalesce(sum(jl.debit) - sum(jl.credit),0) as balance
  from chart_of_accounts c
  left join journal_lines jl on jl.account_code = c.code
  left join journal_entries je on je.id = jl.journal_entry_id
    and je.org_id = p_org_id
    and (p_upto is null or je.entry_date <= p_upto)
  where is_member(p_org_id)
  group by c.code, c.name_ar, c.name_en, c.account_type
  having coalesce(sum(jl.debit),0) <> 0 or coalesce(sum(jl.credit),0) <> 0
  order by c.code;
$$;

alter table chart_of_accounts enable row level security;
drop policy if exists coa_select on chart_of_accounts;
create policy coa_select on chart_of_accounts for select using (auth.uid() is not null);

alter table journal_entries enable row level security;
drop policy if exists je_select on journal_entries;
create policy je_select on journal_entries for select using (is_member(org_id));
-- لا سياسة insert/update/delete مباشرة: الترحيل حصراً عبر post_journal_entry
-- (security definer) من داخل RPCs الموديولات — لا يُسمح بقيد يدوي من العميل
-- خارج القنوات المحاسبية المعتمدة، حفاظاً على سلامة الأثر (Audit Trail).

alter table journal_lines enable row level security;
drop policy if exists jl_select on journal_lines;
create policy jl_select on journal_lines for select using (
  exists (select 1 from journal_entries je where je.id = journal_lines.journal_entry_id and is_member(je.org_id))
);

-- ============================================================
-- 2) المخازن (متعددة) + المنتجات + حركات المخزون
-- ============================================================
create table if not exists warehouses (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists wh_org_idx on warehouses(org_id);
create unique index if not exists wh_org_one_default on warehouses(org_id) where is_default;

create or replace function ensure_default_warehouse(p_org_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from warehouses where org_id = p_org_id and is_default limit 1;
  if v_id is null then
    insert into warehouses (org_id, name, is_default) values (p_org_id, 'المستودع الرئيسي', true)
    returning id into v_id;
  end if;
  return v_id;
end; $$;

-- كل شركة جديدة تحصل تلقائياً على مستودع افتراضي (يكمل on_org_created من schema.sql)
create or replace function create_default_warehouse_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform ensure_default_warehouse(new.id);
  return new;
end; $$;
drop trigger if exists on_org_created_warehouse on organizations;
create trigger on_org_created_warehouse after insert on organizations
for each row execute function create_default_warehouse_trg();

create table if not exists products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  warehouse_id uuid references warehouses(id) on delete set null,
  sku text,
  name text not null,
  quantity numeric(14,3) not null default 0,
  avg_cost numeric(14,4) not null default 0,
  selling_price numeric(14,2) not null default 0,
  reorder_level numeric(14,3) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists products_org_idx on products(org_id, name);
create unique index if not exists products_org_sku_unique on products(org_id, sku) where sku is not null and sku <> '';

drop trigger if exists on_product_update on products;
create trigger on_product_update before update on products
for each row execute function touch_updated_at();

create table if not exists stock_moves (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  product_id uuid not null references products(id) on delete cascade,
  warehouse_id uuid references warehouses(id) on delete set null,
  move_type text not null check (move_type in ('in','out','adjustment')),
  quantity numeric(14,3) not null,   -- دائماً موجب؛ الاتجاه من move_type
  unit_cost numeric(14,4),
  ref_type text,                     -- 'purchase' | 'sale' | 'adjustment'
  ref_id uuid,
  note text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists sm_org_product_idx on stock_moves(org_id, product_id, created_at desc);

alter table warehouses enable row level security;
drop policy if exists wh_select on warehouses;
create policy wh_select on warehouses for select using (is_member(org_id));
drop policy if exists wh_write on warehouses;
create policy wh_write on warehouses for all
  using (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

alter table products enable row level security;
drop policy if exists products_select on products;
create policy products_select on products for select using (is_member(org_id));
drop policy if exists products_write on products;
create policy products_write on products for all
  using (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

alter table stock_moves enable row level security;
drop policy if exists sm_select on stock_moves;
create policy sm_select on stock_moves for select using (is_member(org_id));
-- لا insert/update/delete مباشر: الحركات تُنشأ فقط عبر record_purchase/record_sale

-- ============================================================
-- 3) العملاء والموردون (بطاقة + رصيد جارٍ)
-- ============================================================
create table if not exists customers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  tax_number text,
  phone text,
  email text,
  credit_limit numeric(14,2),
  balance numeric(14,2) not null default 0, -- رصيد مدين مستحق (ذمم مدينة)
  created_at timestamptz not null default now()
);
create index if not exists customers_org_idx on customers(org_id, name);

create table if not exists vendors (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  tax_number text,
  phone text,
  email text,
  balance numeric(14,2) not null default 0, -- رصيد دائن مستحق (ذمم دائنة)
  created_at timestamptz not null default now()
);
create index if not exists vendors_org_idx on vendors(org_id, name);

alter table customers enable row level security;
drop policy if exists customers_select on customers;
create policy customers_select on customers for select using (is_member(org_id));
drop policy if exists customers_write on customers;
create policy customers_write on customers for all
  using (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

alter table vendors enable row level security;
drop policy if exists vendors_select on vendors;
create policy vendors_select on vendors for select using (is_member(org_id));
drop policy if exists vendors_write on vendors;
create policy vendors_write on vendors for all
  using (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

-- ============================================================
-- 4) فواتير الشراء والبيع + RPC الترحيل الذرّي المترابط
-- ============================================================
create table if not exists purchase_invoices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  vendor_id uuid references vendors(id) on delete set null,
  supplier_name text not null,
  invoice_number text,
  invoice_date date not null default current_date,
  items jsonb not null,
  subtotal numeric(14,2) not null,
  vat_amount numeric(14,2) not null,
  vat_rate numeric(5,4) not null default 0.15,
  total_amount numeric(14,2) not null,
  payment_method text not null check (payment_method in ('cash','bank','payable')),
  journal_entry_id uuid references journal_entries(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists pur_org_date_idx on purchase_invoices(org_id, invoice_date desc);

create table if not exists sales_invoices (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  customer_id uuid references customers(id) on delete set null,
  customer_name text not null,
  invoice_number text,
  invoice_date date not null default current_date,
  items jsonb not null,
  subtotal numeric(14,2) not null,
  vat_amount numeric(14,2) not null,
  vat_rate numeric(5,4) not null default 0.15,
  total_amount numeric(14,2) not null,
  cogs_amount numeric(14,2) not null default 0,
  payment_method text not null check (payment_method in ('cash','bank','receivable')),
  journal_entry_id uuid references journal_entries(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists sale_org_date_idx on sales_invoices(org_id, invoice_date desc);

alter table purchase_invoices enable row level security;
drop policy if exists pur_select on purchase_invoices;
create policy pur_select on purchase_invoices for select using (is_member(org_id));
-- لا insert مباشر: حصراً عبر record_purchase() لضمان ترابط المخزون والقيد

alter table sales_invoices enable row level security;
drop policy if exists sale_select on sales_invoices;
create policy sale_select on sales_invoices for select using (is_member(org_id));
-- لا insert مباشر: حصراً عبر record_sale()

-- ------------------------------------------------------------
-- record_purchase — نفس توقيع الاستدعاء الموجود فعلاً في index.html
-- ------------------------------------------------------------
create or replace function record_purchase(
  p_org_id uuid, p_supplier_name text, p_invoice_number text, p_invoice_date date,
  p_items jsonb, p_vat_rate numeric, p_payment_method text, p_warehouse_id uuid default null
) returns purchase_invoices
language plpgsql security definer set search_path = public as $$
declare
  v_wh uuid;
  v_vendor_id uuid;
  v_item jsonb;
  v_qty numeric; v_cost numeric; v_name text; v_sku text;
  v_subtotal numeric(14,2) := 0;
  v_vat numeric(14,2);
  v_total numeric(14,2);
  v_je uuid;
  v_lines jsonb := '[]'::jsonb;
  v_credit_code text; v_credit_memo text;
  v_prod_id uuid; v_prod_qty numeric; v_prod_cost numeric;
  v_row purchase_invoices;
begin
  if not has_role(p_org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية تسجيل فواتير شراء لهذه الشركة';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'أضف صنفاً واحداً على الأقل';
  end if;

  v_wh := coalesce(p_warehouse_id, ensure_default_warehouse(p_org_id));

  select id into v_vendor_id from vendors where org_id = p_org_id and lower(name) = lower(trim(p_supplier_name)) limit 1;
  if v_vendor_id is null then
    insert into vendors (org_id, name) values (p_org_id, trim(p_supplier_name)) returning id into v_vendor_id;
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'quantity')::numeric;
    v_cost := (v_item->>'unit_cost')::numeric;
    v_name := trim(v_item->>'product_name');
    v_sku := nullif(trim(coalesce(v_item->>'sku','')), '');
    if v_qty is null or v_qty <= 0 then raise exception 'كمية الصنف "%" غير صحيحة', v_name; end if;
    if v_cost is null or v_cost < 0 then raise exception 'تكلفة الصنف "%" غير صحيحة', v_name; end if;

    v_subtotal := v_subtotal + (v_qty * v_cost);

    -- إيجاد الصنف: بالكود إن وُجد، وإلا بالاسم داخل نفس الشركة
    select id, quantity, avg_cost into v_prod_id, v_prod_qty, v_prod_cost
      from products where org_id = p_org_id
      and ((v_sku is not null and sku = v_sku) or (v_sku is null and lower(name) = lower(v_name)))
      limit 1 for update;

    if v_prod_id is null then
      insert into products (org_id, warehouse_id, sku, name, quantity, avg_cost, selling_price)
      values (p_org_id, v_wh, v_sku, v_name, v_qty, v_cost, round(v_cost * 1.3, 2))
      returning id into v_prod_id;
    else
      update products set
        quantity = v_prod_qty + v_qty,
        avg_cost = case when (v_prod_qty + v_qty) > 0
                        then round(((v_prod_qty * v_prod_cost) + (v_qty * v_cost)) / (v_prod_qty + v_qty), 4)
                        else v_cost end
      where id = v_prod_id;
    end if;

    insert into stock_moves (org_id, product_id, warehouse_id, move_type, quantity, unit_cost, ref_type, note, created_by)
    values (p_org_id, v_prod_id, v_wh, 'in', v_qty, v_cost, 'purchase', 'شراء من ' || p_supplier_name, auth.uid());
  end loop;

  v_vat := round(v_subtotal * coalesce(p_vat_rate, 0.15), 2);
  v_total := v_subtotal + v_vat;

  if p_payment_method = 'cash' then v_credit_code := '1010'; v_credit_memo := 'الصندوق';
  elsif p_payment_method = 'bank' then v_credit_code := '1020'; v_credit_memo := 'البنك';
  elsif p_payment_method = 'payable' then
    v_credit_code := '2100'; v_credit_memo := 'الدائنون — ' || p_supplier_name;
    update vendors set balance = balance + v_total where id = v_vendor_id;
  else
    raise exception 'طريقة دفع غير معروفة: %', p_payment_method;
  end if;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_code','1300','debit',v_subtotal,'credit',0,'memo','مخزون — فاتورة شراء ' || coalesce(p_invoice_number,'')),
    jsonb_build_object('account_code','2130','debit',v_vat,'credit',0,'memo','ضريبة مدخلات'),
    jsonb_build_object('account_code',v_credit_code,'debit',0,'credit',v_total,'memo',v_credit_memo)
  );

  v_je := post_journal_entry(p_org_id, coalesce(p_invoice_date, current_date), 'purchase', null,
            'فاتورة شراء — ' || p_supplier_name, v_lines);

  insert into purchase_invoices (org_id, vendor_id, supplier_name, invoice_number, invoice_date, items,
    subtotal, vat_amount, vat_rate, total_amount, payment_method, journal_entry_id, created_by)
  values (p_org_id, v_vendor_id, trim(p_supplier_name), p_invoice_number, coalesce(p_invoice_date, current_date), p_items,
    v_subtotal, v_vat, coalesce(p_vat_rate,0.15), v_total, p_payment_method, v_je, auth.uid())
  returning * into v_row;

  update journal_entries set source_id = v_row.id where id = v_je;

  return v_row;
end; $$;

-- ------------------------------------------------------------
-- record_sale — نفس توقيع الاستدعاء الموجود فعلاً في index.html
-- ------------------------------------------------------------
create or replace function record_sale(
  p_org_id uuid, p_customer_name text, p_invoice_number text, p_invoice_date date,
  p_items jsonb, p_vat_rate numeric, p_payment_method text, p_warehouse_id uuid default null
) returns sales_invoices
language plpgsql security definer set search_path = public as $$
declare
  v_wh uuid;
  v_customer_id uuid;
  v_item jsonb;
  v_qty numeric; v_price numeric; v_pid uuid;
  v_prod_name text; v_prod_qty numeric; v_prod_cost numeric;
  v_subtotal numeric(14,2) := 0;
  v_vat numeric(14,2);
  v_total numeric(14,2);
  v_cogs numeric(14,2) := 0;
  v_je uuid;
  v_lines jsonb := '[]'::jsonb;
  v_debit_code text; v_debit_memo text;
  v_row sales_invoices;
begin
  if not has_role(p_org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية تسجيل فواتير بيع لهذه الشركة';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'أضف صنفاً واحداً على الأقل';
  end if;

  v_wh := coalesce(p_warehouse_id, ensure_default_warehouse(p_org_id));

  select id into v_customer_id from customers where org_id = p_org_id and lower(name) = lower(trim(p_customer_name)) limit 1;
  if v_customer_id is null then
    insert into customers (org_id, name) values (p_org_id, trim(p_customer_name)) returning id into v_customer_id;
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_pid := (v_item->>'product_id')::uuid;
    v_qty := (v_item->>'quantity')::numeric;
    v_price := (v_item->>'unit_price')::numeric;
    if v_pid is null then raise exception 'اختر صنفاً لكل بند'; end if;
    if v_qty is null or v_qty <= 0 then raise exception 'كمية غير صحيحة'; end if;
    if v_price is null or v_price < 0 then raise exception 'سعر غير صحيح'; end if;

    select name, quantity, avg_cost into v_prod_name, v_prod_qty, v_prod_cost
      from products where id = v_pid and org_id = p_org_id for update;
    if v_prod_name is null then raise exception 'الصنف غير موجود في هذه الشركة'; end if;
    if v_prod_qty < v_qty then
      raise exception 'الكمية المتوفرة من "%" غير كافية (المتوفر: %, المطلوب: %)', v_prod_name, v_prod_qty, v_qty;
    end if;

    v_subtotal := v_subtotal + (v_qty * v_price);
    v_cogs := v_cogs + (v_qty * v_prod_cost);

    update products set quantity = v_prod_qty - v_qty where id = v_pid;

    insert into stock_moves (org_id, product_id, warehouse_id, move_type, quantity, unit_cost, ref_type, note, created_by)
    values (p_org_id, v_pid, v_wh, 'out', v_qty, v_prod_cost, 'sale', 'بيع إلى ' || p_customer_name, auth.uid());
  end loop;

  v_vat := round(v_subtotal * coalesce(p_vat_rate, 0.15), 2);
  v_total := v_subtotal + v_vat;
  v_cogs := round(v_cogs, 2);

  if p_payment_method = 'cash' then v_debit_code := '1010'; v_debit_memo := 'الصندوق';
  elsif p_payment_method = 'bank' then v_debit_code := '1020'; v_debit_memo := 'البنك';
  elsif p_payment_method = 'receivable' then
    v_debit_code := '1200'; v_debit_memo := 'الذمم المدينة — ' || p_customer_name;
    update customers set balance = balance + v_total where id = v_customer_id;
  else
    raise exception 'طريقة دفع غير معروفة: %', p_payment_method;
  end if;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_code',v_debit_code,'debit',v_total,'credit',0,'memo',v_debit_memo),
    jsonb_build_object('account_code','4000','debit',0,'credit',v_subtotal,'memo','إيرادات مبيعات — ' || coalesce(p_invoice_number,'')),
    jsonb_build_object('account_code','2140','debit',0,'credit',v_vat,'memo','ضريبة مخرجات')
  );
  if v_cogs > 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_code','5050','debit',v_cogs,'credit',0,'memo','تكلفة البضاعة المباعة'),
      jsonb_build_object('account_code','1300','debit',0,'credit',v_cogs,'memo','تخفيض المخزون')
    );
  end if;

  v_je := post_journal_entry(p_org_id, coalesce(p_invoice_date, current_date), 'sale', null,
            'فاتورة بيع — ' || p_customer_name, v_lines);

  insert into sales_invoices (org_id, customer_id, customer_name, invoice_number, invoice_date, items,
    subtotal, vat_amount, vat_rate, total_amount, cogs_amount, payment_method, journal_entry_id, created_by)
  values (p_org_id, v_customer_id, trim(p_customer_name), p_invoice_number, coalesce(p_invoice_date, current_date), p_items,
    v_subtotal, v_vat, coalesce(p_vat_rate,0.15), v_total, v_cogs, p_payment_method, v_je, auth.uid())
  returning * into v_row;

  update journal_entries set source_id = v_row.id where id = v_je;

  return v_row;
end; $$;

-- ============================================================
-- 5) تحصيل من عميل / سداد لمورد — يقفل دورة الذمم مع البنك/الصندوق
-- ============================================================
create table if not exists customer_payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  customer_id uuid not null references customers(id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  method text not null check (method in ('cash','bank')),
  payment_date date not null default current_date,
  note text,
  journal_entry_id uuid references journal_entries(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists vendor_payments (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  vendor_id uuid not null references vendors(id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  method text not null check (method in ('cash','bank')),
  payment_date date not null default current_date,
  note text,
  journal_entry_id uuid references journal_entries(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table customer_payments enable row level security;
drop policy if exists cp_select on customer_payments;
create policy cp_select on customer_payments for select using (is_member(org_id));
alter table vendor_payments enable row level security;
drop policy if exists vp_select on vendor_payments;
create policy vp_select on vendor_payments for select using (is_member(org_id));

create or replace function receive_customer_payment(
  p_org_id uuid, p_customer_id uuid, p_amount numeric, p_method text, p_date date, p_note text
) returns customer_payments
language plpgsql security definer set search_path = public as $$
declare v_je uuid; v_code text; v_name text; v_row customer_payments;
begin
  if not has_role(p_org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية تسجيل تحصيلات لهذه الشركة';
  end if;
  select name into v_name from customers where id = p_customer_id and org_id = p_org_id;
  if v_name is null then raise exception 'العميل غير موجود'; end if;
  v_code := case when p_method = 'bank' then '1020' else '1010' end;

  update customers set balance = balance - p_amount where id = p_customer_id;

  v_je := post_journal_entry(p_org_id, coalesce(p_date, current_date), 'customer_payment', null,
    'تحصيل من العميل — ' || v_name,
    jsonb_build_array(
      jsonb_build_object('account_code',v_code,'debit',p_amount,'credit',0,'memo',coalesce(p_note,'تحصيل')),
      jsonb_build_object('account_code','1200','debit',0,'credit',p_amount,'memo','تخفيض ذمم — ' || v_name)
    ));

  insert into customer_payments (org_id, customer_id, amount, method, payment_date, note, journal_entry_id, created_by)
  values (p_org_id, p_customer_id, p_amount, p_method, coalesce(p_date, current_date), p_note, v_je, auth.uid())
  returning * into v_row;
  update journal_entries set source_id = v_row.id where id = v_je;
  return v_row;
end; $$;

create or replace function pay_vendor(
  p_org_id uuid, p_vendor_id uuid, p_amount numeric, p_method text, p_date date, p_note text
) returns vendor_payments
language plpgsql security definer set search_path = public as $$
declare v_je uuid; v_code text; v_name text; v_row vendor_payments;
begin
  if not has_role(p_org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية تسجيل مدفوعات لهذه الشركة';
  end if;
  select name into v_name from vendors where id = p_vendor_id and org_id = p_org_id;
  if v_name is null then raise exception 'المورد غير موجود'; end if;
  v_code := case when p_method = 'bank' then '1020' else '1010' end;

  update vendors set balance = balance - p_amount where id = p_vendor_id;

  v_je := post_journal_entry(p_org_id, coalesce(p_date, current_date), 'vendor_payment', null,
    'سداد للمورد — ' || v_name,
    jsonb_build_array(
      jsonb_build_object('account_code','2100','debit',p_amount,'credit',0,'memo','تخفيض دائنون — ' || v_name),
      jsonb_build_object('account_code',v_code,'debit',0,'credit',p_amount,'memo',coalesce(p_note,'سداد'))
    ));

  insert into vendor_payments (org_id, vendor_id, amount, method, payment_date, note, journal_entry_id, created_by)
  values (p_org_id, p_vendor_id, p_amount, p_method, coalesce(p_date, current_date), p_note, v_je, auth.uid())
  returning * into v_row;
  update journal_entries set source_id = v_row.id where id = v_je;
  return v_row;
end; $$;

-- ============================================================
-- 6) دعوات الأعضاء — نفس الجدول/التوقيع اللي تستدعيه الواجهة فعلاً
-- ============================================================
create table if not exists invites (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  email text not null,
  role app_role not null default 'accountant',
  invited_by uuid references auth.users(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','accepted','revoked')),
  created_at timestamptz not null default now()
);
create index if not exists invites_email_idx on invites(email, status);

alter table invites enable row level security;
drop policy if exists invites_select on invites;
-- يرى الدعوة: أعضاء الشركة الداعية، أو صاحب البريد المدعو نفسه (ليقبلها)
create policy invites_select on invites for select using (
  is_member(org_id) or lower(email) = lower(coalesce(auth.jwt() ->> 'email',''))
);
drop policy if exists invites_insert on invites;
create policy invites_insert on invites for insert with check (
  has_role(org_id, array['owner']::app_role[])
);
drop policy if exists invites_delete on invites;
create policy invites_delete on invites for delete using (
  has_role(org_id, array['owner']::app_role[])
);

-- الشخص المدعو ليس عضواً بعد، فسياسة org_select (is_member) وحدها لا تكفيه
-- ليرى اسم الشركة الداعية في شريط الدعوة قبل قبولها. سياسات SELECT من نفس
-- النوع تُجمع بـ OR في Postgres، فهذه إضافية ولا تُضعف org_select الأصلية.
drop policy if exists org_select_via_invite on organizations;
create policy org_select_via_invite on organizations for select using (
  exists (
    select 1 from invites i
    where i.org_id = organizations.id
      and i.status = 'pending'
      and lower(i.email) = lower(coalesce(auth.jwt() ->> 'email',''))
  )
);

create or replace function accept_invite(p_invite_id uuid)
returns memberships
language plpgsql security definer set search_path = public as $$
declare
  v_invite invites;
  v_row memberships;
  v_quota record;
begin
  select * into v_invite from invites where id = p_invite_id and status = 'pending';
  if v_invite.id is null then raise exception 'الدعوة غير موجودة أو تم استخدامها مسبقاً'; end if;
  if lower(v_invite.email) <> lower(coalesce(auth.jwt() ->> 'email','')) then
    raise exception 'هذه الدعوة موجهة لبريد إلكتروني آخر';
  end if;

  select * into v_quota from member_quota_status(v_invite.org_id) limit 1;
  if v_quota.allowed is false then
    raise exception 'وصلت الشركة للحد الأقصى لعدد الأعضاء في باقتها (%/%)', v_quota.used, v_quota.cap;
  end if;

  insert into memberships (user_id, org_id, role) values (auth.uid(), v_invite.org_id, v_invite.role)
  on conflict (user_id, org_id) do update set role = excluded.role
  returning * into v_row;

  update invites set status = 'accepted' where id = p_invite_id;
  return v_row;
end; $$;

-- ============================================================
-- تحقق سريع بعد التشغيل (اختياري):
-- select * from chart_of_accounts order by code;
-- select * from general_ledger_balances('<org-uuid>');
-- ============================================================
