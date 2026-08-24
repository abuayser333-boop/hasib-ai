-- ============================================================
-- حاسِب AI — migration 007: إدارة علاقات العملاء (CRM)
--
-- يبني فوق 003 (customers). قمع مبيعات بسيط (Pipeline): فرصة جديدة
-- ← تواصل ← مؤهلة ← عرض سعر ← فوز/خسارة. عند "الفوز" تتحول الفرصة
-- تلقائياً إلى بطاقة عميل حقيقية في جدول customers نفسه الذي تستخدمه
-- فواتير البيع — فلا يُعاد إدخال بيانات العميل يدوياً مرتين.
-- ============================================================

create table if not exists crm_opportunities (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  title text not null,
  contact_name text,
  contact_phone text,
  contact_email text,
  company_name text,
  stage text not null default 'new' check (stage in ('new','contacted','qualified','proposal','won','lost')),
  value numeric(14,2) not null default 0,
  expected_close_date date,
  customer_id uuid references customers(id) on delete set null, -- يُملأ تلقائياً عند الفوز
  lost_reason text,
  owner_id uuid references auth.users(id) on delete set null,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists crm_org_stage_idx on crm_opportunities(org_id, stage);

drop trigger if exists on_crm_update on crm_opportunities;
create trigger on_crm_update before update on crm_opportunities
for each row execute function touch_updated_at();

create table if not exists crm_activities (
  id uuid primary key default gen_random_uuid(),
  opportunity_id uuid not null references crm_opportunities(id) on delete cascade,
  activity_type text not null default 'note' check (activity_type in ('note','call','meeting','email','stage_change')),
  body text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table crm_opportunities enable row level security;
drop policy if exists crm_select on crm_opportunities;
create policy crm_select on crm_opportunities for select using (is_member(org_id));
drop policy if exists crm_write on crm_opportunities;
create policy crm_write on crm_opportunities for all
  using (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

alter table crm_activities enable row level security;
drop policy if exists crm_act_select on crm_activities;
create policy crm_act_select on crm_activities for select using (
  exists (select 1 from crm_opportunities o where o.id = crm_activities.opportunity_id and is_member(o.org_id))
);
drop policy if exists crm_act_write on crm_activities;
create policy crm_act_write on crm_activities for insert with check (
  exists (select 1 from crm_opportunities o where o.id = crm_activities.opportunity_id
          and has_role(o.org_id, array['owner','accountant']::app_role[]))
);

-- تحديث المرحلة + تسجيل الحركة في السجل الزمني بخطوة واحدة
create or replace function set_opportunity_stage(p_opportunity_id uuid, p_stage text, p_note text default null)
returns crm_opportunities
language plpgsql security definer set search_path = public as $$
declare v_row crm_opportunities; v_org uuid;
begin
  select org_id into v_org from crm_opportunities where id = p_opportunity_id;
  if v_org is null then raise exception 'الفرصة غير موجودة'; end if;
  if not has_role(v_org, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية تعديل هذه الفرصة';
  end if;

  update crm_opportunities set stage = p_stage where id = p_opportunity_id returning * into v_row;
  insert into crm_activities (opportunity_id, activity_type, body, created_by)
  values (p_opportunity_id, 'stage_change', coalesce(p_note, 'تغيير المرحلة إلى ' || p_stage), auth.uid());
  return v_row;
end; $$;

-- فوز بالفرصة → إنشاء/ربط بطاقة عميل فعلية جاهزة للفوترة في موديول المبيعات
create or replace function win_opportunity(p_opportunity_id uuid)
returns customers
language plpgsql security definer set search_path = public as $$
declare
  v_opp crm_opportunities;
  v_customer_id uuid;
  v_customer customers;
begin
  select * into v_opp from crm_opportunities where id = p_opportunity_id;
  if v_opp.id is null then raise exception 'الفرصة غير موجودة'; end if;
  if not has_role(v_opp.org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية تحديث هذه الفرصة';
  end if;

  select id into v_customer_id from customers
    where org_id = v_opp.org_id and lower(name) = lower(coalesce(v_opp.company_name, v_opp.contact_name, v_opp.title))
    limit 1;

  if v_customer_id is null then
    insert into customers (org_id, name, phone, email)
    values (v_opp.org_id, coalesce(v_opp.company_name, v_opp.contact_name, v_opp.title), v_opp.contact_phone, v_opp.contact_email)
    returning id into v_customer_id;
  end if;

  update crm_opportunities set stage = 'won', customer_id = v_customer_id where id = p_opportunity_id;
  insert into crm_activities (opportunity_id, activity_type, body, created_by)
  values (p_opportunity_id, 'stage_change', 'فوز — تم إنشاء/ربط بطاقة عميل', auth.uid());

  select * into v_customer from customers where id = v_customer_id;
  return v_customer;
end; $$;
