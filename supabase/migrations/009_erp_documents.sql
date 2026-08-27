-- ============================================================
-- حاسِب AI — migration 009: موديولات المستندات التجارية
--
-- يُضاف فوق migration 003 (القيود، المخزون، العملاء، الموردون).
-- يبني دورة المستندات الكاملة لكل موديول:
--   مبيعات  : عروض أسعار → أوامر بيع → فواتير بيع (record_sale)
--   مشتريات : طلبات شراء → أوامر شراء → فواتير شراء (record_purchase)
--
-- كل تحويل بين مراحل يحدث داخل دالة SECURITY DEFINER ذرّية
-- لا يمكن تجاوزها من العميل.
-- ============================================================

-- ============================================================
-- 0) تصنيفات المنتجات
-- ============================================================
create table if not exists product_categories (
  id   uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  parent_id uuid references product_categories(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists pc_org_idx on product_categories(org_id);

alter table product_categories enable row level security;
drop policy if exists pc_select on product_categories;
create policy pc_select on product_categories for select using (is_member(org_id));
drop policy if exists pc_write on product_categories;
create policy pc_write on product_categories for all
  using  (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

-- ربط المنتجات بالتصنيف (عمود إضافي آمن)
alter table products add column if not exists category_id uuid references product_categories(id) on delete set null;
alter table products add column if not exists unit_of_measure text not null default 'قطعة';
alter table products add column if not exists is_active boolean not null default true;

-- ============================================================
-- 1) موديول المبيعات — عروض الأسعار (Quotes)
-- ============================================================
create table if not exists quotes (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references organizations(id) on delete cascade,
  customer_id     uuid references customers(id) on delete set null,
  customer_name   text not null,
  quote_number    text,
  quote_date      date not null default current_date,
  expiry_date     date,
  -- draft → sent → accepted → rejected → converted → cancelled
  status          text not null default 'draft'
                  check (status in ('draft','sent','accepted','rejected','converted','cancelled')),
  subtotal        numeric(14,2) not null default 0,
  vat_amount      numeric(14,2) not null default 0,
  vat_rate        numeric(5,4) not null default 0.15,
  total_amount    numeric(14,2) not null default 0,
  notes           text,
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists quotes_org_date_idx on quotes(org_id, quote_date desc);
create unique index if not exists quotes_org_number on quotes(org_id, quote_number) where quote_number is not null;
drop trigger if exists on_quote_update on quotes;
create trigger on_quote_update before update on quotes
  for each row execute function touch_updated_at();

create table if not exists quote_lines (
  id          uuid primary key default gen_random_uuid(),
  quote_id    uuid not null references quotes(id) on delete cascade,
  product_id  uuid references products(id) on delete set null,
  description text not null,
  quantity    numeric(14,3) not null check (quantity > 0),
  unit_price  numeric(14,2) not null check (unit_price >= 0),
  discount    numeric(5,2) not null default 0 check (discount between 0 and 100),
  line_total  numeric(14,2) generated always as
              (round(quantity * unit_price * (1 - discount/100), 2)) stored,
  sort_order  integer not null default 0
);
create index if not exists ql_quote_idx on quote_lines(quote_id, sort_order);

alter table quotes enable row level security;
drop policy if exists q_select on quotes;
create policy q_select on quotes for select using (is_member(org_id));
drop policy if exists q_write on quotes;
create policy q_write on quotes for all
  using  (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

alter table quote_lines enable row level security;
drop policy if exists ql_select on quote_lines;
create policy ql_select on quote_lines for select using (
  exists (select 1 from quotes q where q.id = quote_lines.quote_id and is_member(q.org_id))
);
drop policy if exists ql_write on quote_lines;
create policy ql_write on quote_lines for all using (
  exists (select 1 from quotes q where q.id = quote_lines.quote_id
          and has_role(q.org_id, array['owner','accountant']::app_role[]))
) with check (
  exists (select 1 from quotes q where q.id = quote_lines.quote_id
          and has_role(q.org_id, array['owner','accountant']::app_role[]))
);

-- ============================================================
-- 2) موديول المبيعات — أوامر البيع (Sales Orders)
-- ============================================================
create table if not exists sales_orders (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references organizations(id) on delete cascade,
  quote_id        uuid references quotes(id) on delete set null,
  customer_id     uuid references customers(id) on delete set null,
  customer_name   text not null,
  order_number    text,
  order_date      date not null default current_date,
  requested_date  date,
  -- confirmed → in_progress → shipped → delivered → cancelled
  status          text not null default 'confirmed'
                  check (status in ('confirmed','in_progress','shipped','delivered','invoiced','cancelled')),
  payment_method  text not null default 'receivable'
                  check (payment_method in ('cash','bank','receivable')),
  subtotal        numeric(14,2) not null default 0,
  vat_amount      numeric(14,2) not null default 0,
  vat_rate        numeric(5,4) not null default 0.15,
  total_amount    numeric(14,2) not null default 0,
  invoice_id      uuid references sales_invoices(id) on delete set null,
  notes           text,
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists so_org_date_idx on sales_orders(org_id, order_date desc);
create unique index if not exists so_org_number on sales_orders(org_id, order_number) where order_number is not null;
drop trigger if exists on_so_update on sales_orders;
create trigger on_so_update before update on sales_orders
  for each row execute function touch_updated_at();

create table if not exists sales_order_lines (
  id              uuid primary key default gen_random_uuid(),
  sales_order_id  uuid not null references sales_orders(id) on delete cascade,
  product_id      uuid not null references products(id) on delete restrict,
  description     text not null,
  quantity        numeric(14,3) not null check (quantity > 0),
  unit_price      numeric(14,2) not null check (unit_price >= 0),
  discount        numeric(5,2) not null default 0 check (discount between 0 and 100),
  line_total      numeric(14,2) generated always as
                  (round(quantity * unit_price * (1 - discount/100), 2)) stored,
  sort_order      integer not null default 0
);
create index if not exists sol_order_idx on sales_order_lines(sales_order_id, sort_order);

alter table sales_orders enable row level security;
drop policy if exists so_select on sales_orders;
create policy so_select on sales_orders for select using (is_member(org_id));
drop policy if exists so_write on sales_orders;
create policy so_write on sales_orders for all
  using  (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

alter table sales_order_lines enable row level security;
drop policy if exists sol_select on sales_order_lines;
create policy sol_select on sales_order_lines for select using (
  exists (select 1 from sales_orders so where so.id = sales_order_lines.sales_order_id and is_member(so.org_id))
);
drop policy if exists sol_write on sales_order_lines;
create policy sol_write on sales_order_lines for all using (
  exists (select 1 from sales_orders so where so.id = sales_order_lines.sales_order_id
          and has_role(so.org_id, array['owner','accountant']::app_role[]))
) with check (
  exists (select 1 from sales_orders so where so.id = sales_order_lines.sales_order_id
          and has_role(so.org_id, array['owner','accountant']::app_role[]))
);

-- ============================================================
-- 3) موديول المشتريات — طلبات الشراء (Purchase Requests)
-- ============================================================
create table if not exists purchase_requests (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references organizations(id) on delete cascade,
  request_number  text,
  request_date    date not null default current_date,
  requester_name  text not null,
  department      text,
  -- draft → pending_approval → approved → rejected → converted → cancelled
  status          text not null default 'draft'
                  check (status in ('draft','pending_approval','approved','rejected','converted','cancelled')),
  approved_by     uuid references auth.users(id) on delete set null,
  approved_at     timestamptz,
  notes           text,
  created_by      uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists pr_org_date_idx on purchase_requests(org_id, request_date desc);
create unique index if not exists pr_org_number on purchase_requests(org_id, request_number) where request_number is not null;
drop trigger if exists on_pr_update on purchase_requests;
create trigger on_pr_update before update on purchase_requests
  for each row execute function touch_updated_at();

create table if not exists purchase_request_lines (
  id                  uuid primary key default gen_random_uuid(),
  purchase_request_id uuid not null references purchase_requests(id) on delete cascade,
  product_id          uuid references products(id) on delete set null,
  description         text not null,
  quantity            numeric(14,3) not null check (quantity > 0),
  estimated_price     numeric(14,2) check (estimated_price >= 0),
  unit_of_measure     text not null default 'قطعة',
  notes               text,
  sort_order          integer not null default 0
);
create index if not exists prl_pr_idx on purchase_request_lines(purchase_request_id, sort_order);

alter table purchase_requests enable row level security;
drop policy if exists preq_select on purchase_requests;
create policy preq_select on purchase_requests for select using (is_member(org_id));
drop policy if exists preq_write on purchase_requests;
create policy preq_write on purchase_requests for all
  using  (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

alter table purchase_request_lines enable row level security;
drop policy if exists prl_select on purchase_request_lines;
create policy prl_select on purchase_request_lines for select using (
  exists (select 1 from purchase_requests pr where pr.id = purchase_request_lines.purchase_request_id and is_member(pr.org_id))
);
drop policy if exists prl_write on purchase_request_lines;
create policy prl_write on purchase_request_lines for all using (
  exists (select 1 from purchase_requests pr where pr.id = purchase_request_lines.purchase_request_id
          and has_role(pr.org_id, array['owner','accountant']::app_role[]))
) with check (
  exists (select 1 from purchase_requests pr where pr.id = purchase_request_lines.purchase_request_id
          and has_role(pr.org_id, array['owner','accountant']::app_role[]))
);

-- ============================================================
-- 4) موديول المشتريات — أوامر الشراء (Purchase Orders)
-- ============================================================
create table if not exists purchase_orders (
  id                  uuid primary key default gen_random_uuid(),
  org_id              uuid not null references organizations(id) on delete cascade,
  purchase_request_id uuid references purchase_requests(id) on delete set null,
  vendor_id           uuid references vendors(id) on delete set null,
  supplier_name       text not null,
  order_number        text,
  order_date          date not null default current_date,
  expected_date       date,
  payment_method      text not null default 'payable'
                      check (payment_method in ('cash','bank','payable')),
  -- draft → sent → confirmed → partially_received → received → cancelled
  status              text not null default 'draft'
                      check (status in ('draft','sent','confirmed','partially_received','received','cancelled')),
  subtotal            numeric(14,2) not null default 0,
  vat_amount          numeric(14,2) not null default 0,
  vat_rate            numeric(5,4) not null default 0.15,
  total_amount        numeric(14,2) not null default 0,
  invoice_id          uuid references purchase_invoices(id) on delete set null,
  notes               text,
  warehouse_id        uuid references warehouses(id) on delete set null,
  created_by          uuid references auth.users(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists po_org_date_idx on purchase_orders(org_id, order_date desc);
create unique index if not exists po_org_number on purchase_orders(org_id, order_number) where order_number is not null;
drop trigger if exists on_po_update on purchase_orders;
create trigger on_po_update before update on purchase_orders
  for each row execute function touch_updated_at();

create table if not exists purchase_order_lines (
  id                uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references purchase_orders(id) on delete cascade,
  product_id        uuid references products(id) on delete set null,
  product_name      text not null,
  sku               text,
  quantity          numeric(14,3) not null check (quantity > 0),
  quantity_received numeric(14,3) not null default 0,
  unit_cost         numeric(14,2) not null check (unit_cost >= 0),
  line_total        numeric(14,2) generated always as (round(quantity * unit_cost, 2)) stored,
  sort_order        integer not null default 0
);
create index if not exists pol_po_idx on purchase_order_lines(purchase_order_id, sort_order);

alter table purchase_orders enable row level security;
drop policy if exists po_select on purchase_orders;
create policy po_select on purchase_orders for select using (is_member(org_id));
drop policy if exists po_write on purchase_orders;
create policy po_write on purchase_orders for all
  using  (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

alter table purchase_order_lines enable row level security;
drop policy if exists pol_select on purchase_order_lines;
create policy pol_select on purchase_order_lines for select using (
  exists (select 1 from purchase_orders po where po.id = purchase_order_lines.purchase_order_id and is_member(po.org_id))
);
drop policy if exists pol_write on purchase_order_lines;
create policy pol_write on purchase_order_lines for all using (
  exists (select 1 from purchase_orders po where po.id = purchase_order_lines.purchase_order_id
          and has_role(po.org_id, array['owner','accountant']::app_role[]))
) with check (
  exists (select 1 from purchase_orders po where po.id = purchase_order_lines.purchase_order_id
          and has_role(po.org_id, array['owner','accountant']::app_role[]))
);

-- ============================================================
-- 5) دوال تحويل المستندات (Business Logic — Atomic Transitions)
-- ============================================================

-- ── 5.1 إنشاء عرض سعر مع بنوده دفعة واحدة ──────────────────
create or replace function create_quote(
  p_org_id       uuid,
  p_customer_name text,
  p_lines        jsonb,   -- [{product_id?, description, quantity, unit_price, discount?}]
  p_expiry_date  date     default null,
  p_notes        text     default null
) returns quotes
language plpgsql security definer set search_path = public as $$
declare
  v_customer_id uuid;
  v_sub  numeric(14,2) := 0;
  v_vat  numeric(14,2);
  v_num  text;
  v_line jsonb;
  v_sort integer := 0;
  v_row  quotes;
begin
  if not has_role(p_org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية إنشاء عروض أسعار';
  end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'أضف بنداً واحداً على الأقل';
  end if;

  -- إيجاد أو إنشاء العميل
  select id into v_customer_id from customers
    where org_id = p_org_id and lower(name) = lower(trim(p_customer_name)) limit 1;
  if v_customer_id is null then
    insert into customers (org_id, name) values (p_org_id, trim(p_customer_name))
    returning id into v_customer_id;
  end if;

  -- توليد رقم عرض سعر تسلسلي
  select 'QT-' || lpad((coalesce(max(substring(quote_number from 4)::integer),0) + 1)::text, 5, '0')
    into v_num from quotes where org_id = p_org_id and quote_number like 'QT-%';
  if v_num is null then v_num := 'QT-00001'; end if;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    if (v_line->>'quantity')::numeric <= 0 then raise exception 'الكمية يجب أن تكون أكبر من صفر'; end if;
    if (v_line->>'unit_price')::numeric < 0  then raise exception 'السعر لا يمكن أن يكون سالباً'; end if;
    v_sub := v_sub + round((v_line->>'quantity')::numeric * (v_line->>'unit_price')::numeric
                    * (1 - coalesce((v_line->>'discount')::numeric, 0)/100), 2);
  end loop;
  v_vat := round(v_sub * 0.15, 2);

  insert into quotes (org_id, customer_id, customer_name, quote_number, expiry_date, notes,
                      subtotal, vat_amount, total_amount, created_by)
  values (p_org_id, v_customer_id, trim(p_customer_name), v_num, p_expiry_date, p_notes,
          v_sub, v_vat, v_sub + v_vat, auth.uid())
  returning * into v_row;

  for v_line in select * from jsonb_array_elements(p_lines) loop
    insert into quote_lines (quote_id, product_id, description, quantity, unit_price, discount, sort_order)
    values (v_row.id, nullif((v_line->>'product_id'),'')::uuid,
            v_line->>'description',
            (v_line->>'quantity')::numeric,
            (v_line->>'unit_price')::numeric,
            coalesce((v_line->>'discount')::numeric, 0),
            v_sort);
    v_sort := v_sort + 1;
  end loop;

  return v_row;
end; $$;

-- ── 5.2 تحويل عرض السعر إلى أمر بيع ──────────────────────────
create or replace function convert_quote_to_order(
  p_quote_id      uuid,
  p_payment_method text default 'receivable',
  p_requested_date date default null
) returns sales_orders
language plpgsql security definer set search_path = public as $$
declare
  v_quote   quotes;
  v_line    quote_lines;
  v_num     text;
  v_row     sales_orders;
begin
  select * into v_quote from quotes where id = p_quote_id;
  if v_quote.id is null then raise exception 'عرض السعر غير موجود'; end if;
  if not has_role(v_quote.org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية'; end if;
  if v_quote.status not in ('draft','sent','accepted') then
    raise exception 'لا يمكن تحويل عرض سعر بحالة "%"', v_quote.status; end if;

  -- رقم أمر بيع تسلسلي
  select 'SO-' || lpad((coalesce(max(substring(order_number from 4)::integer),0)+1)::text,5,'0')
    into v_num from sales_orders where org_id = v_quote.org_id and order_number like 'SO-%';
  if v_num is null then v_num := 'SO-00001'; end if;

  insert into sales_orders (org_id, quote_id, customer_id, customer_name, order_number,
                            requested_date, payment_method, subtotal, vat_amount, vat_rate, total_amount, created_by)
  values (v_quote.org_id, v_quote.id, v_quote.customer_id, v_quote.customer_name, v_num,
          p_requested_date, p_payment_method, v_quote.subtotal, v_quote.vat_amount, v_quote.vat_rate,
          v_quote.total_amount, auth.uid())
  returning * into v_row;

  for v_line in select * from quote_lines where quote_id = p_quote_id loop
    if v_line.product_id is null then
      raise exception 'بند "%" لا يحتوي على صنف — تأكد من ربط كل بنود عرض السعر بصنف قبل التحويل', v_line.description;
    end if;
    insert into sales_order_lines (sales_order_id, product_id, description, quantity, unit_price, discount, sort_order)
    values (v_row.id, v_line.product_id, v_line.description, v_line.quantity,
            v_line.unit_price, v_line.discount, v_line.sort_order);
  end loop;

  update quotes set status = 'converted' where id = p_quote_id;
  return v_row;
end; $$;

-- ── 5.3 تحويل أمر البيع إلى فاتورة بيع (يشغّل record_sale) ──
create or replace function invoice_sales_order(
  p_order_id     uuid,
  p_invoice_date date default null
) returns sales_invoices
language plpgsql security definer set search_path = public as $$
declare
  v_order   sales_orders;
  v_line    sales_order_lines;
  v_items   jsonb := '[]'::jsonb;
  v_inv     sales_invoices;
  v_inv_num text;
begin
  select * into v_order from sales_orders where id = p_order_id;
  if v_order.id is null then raise exception 'أمر البيع غير موجود'; end if;
  if not has_role(v_order.org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية'; end if;
  if v_order.status in ('invoiced','cancelled') then
    raise exception 'أمر البيع بحالة "%" ولا يمكن إصدار فاتورة له', v_order.status; end if;

  -- رقم فاتورة بيع تسلسلي
  select 'INV-' || lpad((coalesce(max(substring(invoice_number from 5)::integer),0)+1)::text,5,'0')
    into v_inv_num from sales_invoices where org_id = v_order.org_id and invoice_number like 'INV-%';
  if v_inv_num is null then v_inv_num := 'INV-00001'; end if;

  for v_line in select * from sales_order_lines where sales_order_id = p_order_id loop
    v_items := v_items || jsonb_build_array(
      jsonb_build_object(
        'product_id', v_line.product_id,
        'quantity', v_line.quantity * (1 - v_line.discount/100.0),
        'unit_price', v_line.unit_price
      )
    );
  end loop;

  -- استدعاء الدالة الذرية الموجودة (تخصم المخزون + ترحّل القيد)
  select * into v_inv from record_sale(
    v_order.org_id, v_order.customer_name, v_inv_num,
    coalesce(p_invoice_date, current_date), v_items,
    v_order.vat_rate, v_order.payment_method
  );

  update sales_orders set status = 'invoiced', invoice_id = v_inv.id where id = p_order_id;
  return v_inv;
end; $$;

-- ── 5.4 الموافقة على طلب الشراء ──────────────────────────────
create or replace function approve_purchase_request(p_pr_id uuid)
returns purchase_requests
language plpgsql security definer set search_path = public as $$
declare v_pr purchase_requests;
begin
  select * into v_pr from purchase_requests where id = p_pr_id;
  if v_pr.id is null then raise exception 'طلب الشراء غير موجود'; end if;
  if not has_role(v_pr.org_id, array['owner']::app_role[]) then
    raise exception 'الموافقة على طلبات الشراء متاحة للمالك فقط'; end if;
  if v_pr.status <> 'pending_approval' then
    raise exception 'طلب الشراء ليس في حالة "في انتظار الموافقة"'; end if;

  update purchase_requests
    set status = 'approved', approved_by = auth.uid(), approved_at = now()
  where id = p_pr_id
  returning * into v_pr;
  return v_pr;
end; $$;

-- ── 5.5 تحويل طلب الشراء إلى أمر شراء ───────────────────────
create or replace function convert_pr_to_po(
  p_pr_id       uuid,
  p_vendor_id   uuid,
  p_unit_costs  jsonb default null  -- [{line_index, unit_cost}] لتحديث التكاليف
) returns purchase_orders
language plpgsql security definer set search_path = public as $$
declare
  v_pr    purchase_requests;
  v_line  purchase_request_lines;
  v_cost  numeric(14,2);
  v_sub   numeric(14,2) := 0;
  v_vat   numeric(14,2);
  v_num   text;
  v_vname text;
  v_row   purchase_orders;
  v_sort  integer := 0;
begin
  select * into v_pr from purchase_requests where id = p_pr_id;
  if v_pr.id is null then raise exception 'طلب الشراء غير موجود'; end if;
  if not has_role(v_pr.org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية'; end if;
  if v_pr.status <> 'approved' then
    raise exception 'يجب أن يكون طلب الشراء معتمداً قبل التحويل إلى أمر شراء'; end if;

  select name into v_vname from vendors where id = p_vendor_id and org_id = v_pr.org_id;
  if v_vname is null then raise exception 'المورد غير موجود في هذه الشركة'; end if;

  select 'PO-' || lpad((coalesce(max(substring(order_number from 4)::integer),0)+1)::text,5,'0')
    into v_num from purchase_orders where org_id = v_pr.org_id and order_number like 'PO-%';
  if v_num is null then v_num := 'PO-00001'; end if;

  insert into purchase_orders (org_id, purchase_request_id, vendor_id, supplier_name, order_number,
                               subtotal, vat_amount, total_amount, created_by)
  values (v_pr.org_id, p_pr_id, p_vendor_id, v_vname, v_num, 0, 0, 0, auth.uid())
  returning * into v_row;

  for v_line in select * from purchase_request_lines where purchase_request_id = p_pr_id order by sort_order loop
    -- استخدام التكلفة المُرسلة أو السعر التقديري
    v_cost := coalesce(
      (select (elem->>'unit_cost')::numeric from jsonb_array_elements(coalesce(p_unit_costs,'[]'::jsonb)) elem
       where (elem->>'line_index')::integer = v_sort limit 1),
      v_line.estimated_price, 0
    );
    insert into purchase_order_lines (purchase_order_id, product_id, product_name, sku,
                                      quantity, unit_cost, sort_order)
    values (v_row.id, v_line.product_id, v_line.description, null,
            v_line.quantity, v_cost, v_sort);
    v_sub := v_sub + (v_line.quantity * v_cost);
    v_sort := v_sort + 1;
  end loop;

  v_vat := round(v_sub * 0.15, 2);
  update purchase_orders set subtotal = v_sub, vat_amount = v_vat, total_amount = v_sub + v_vat
    where id = v_row.id
  returning * into v_row;

  update purchase_requests set status = 'converted' where id = p_pr_id;
  return v_row;
end; $$;

-- ── 5.6 استلام أمر الشراء (يشغّل record_purchase ذرياً) ──────
create or replace function receive_purchase_order(
  p_po_id        uuid,
  p_invoice_number text  default null,
  p_invoice_date   date  default null
) returns purchase_invoices
language plpgsql security definer set search_path = public as $$
declare
  v_po    purchase_orders;
  v_line  purchase_order_lines;
  v_items jsonb := '[]'::jsonb;
  v_inv   purchase_invoices;
begin
  select * into v_po from purchase_orders where id = p_po_id;
  if v_po.id is null then raise exception 'أمر الشراء غير موجود'; end if;
  if not has_role(v_po.org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية'; end if;
  if v_po.status in ('received','cancelled') then
    raise exception 'أمر الشراء بحالة "%" ولا يمكن استلامه مجدداً', v_po.status; end if;

  for v_line in select * from purchase_order_lines where purchase_order_id = p_po_id loop
    v_items := v_items || jsonb_build_array(
      jsonb_build_object(
        'product_name', v_line.product_name,
        'sku', v_line.sku,
        'quantity', v_line.quantity,
        'unit_cost', v_line.unit_cost
      )
    );
  end loop;

  -- record_purchase: يزيد المخزون + يرحّل القيد المحاسبي تلقائياً
  select * into v_inv from record_purchase(
    v_po.org_id, v_po.supplier_name,
    coalesce(p_invoice_number, v_po.order_number),
    coalesce(p_invoice_date, current_date),
    v_items, 0.15, v_po.payment_method, v_po.warehouse_id
  );

  update purchase_orders set status = 'received', invoice_id = v_inv.id where id = p_po_id;
  update purchase_order_lines set quantity_received = quantity where purchase_order_id = p_po_id;
  return v_inv;
end; $$;

-- ============================================================
-- 6) دالة مساعدة: ترقيم تلقائي (touch_updated_at موجودة بالفعل)
-- ============================================================

-- ============================================================
-- تحقق سريع (اختياري بعد التشغيل):
-- select count(*) from quotes;
-- select count(*) from sales_orders;
-- select count(*) from purchase_requests;
-- select count(*) from purchase_orders;
-- ============================================================
