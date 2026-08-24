-- ============================================================
-- حاسِب AI — migration 004: الأصول الثابتة (Fixed Assets) — IAS 16
--
-- يبني فوق 003 (journal_entries/journal_lines/post_journal_entry/
-- chart_of_accounts). تسجيل أصل ← جدولة إهلاك بالقسط الثابت شهرياً ←
-- ترحيل تلقائي لقيد الإهلاك المجمّع ← تحديث مجمّع الإهلاك على كل أصل ←
-- استبعاد الأصل عند البيع/الإحلال بقيد واحد يحسب الربح/الخسارة تلقائياً.
-- ============================================================

insert into chart_of_accounts (code, name_ar, name_en, account_type, is_current) values
  ('4900','أرباح استبعاد أصول ثابتة','Gain on Disposal of Fixed Assets','revenue',false),
  ('5400','خسائر استبعاد أصول ثابتة','Loss on Disposal of Fixed Assets','expense',false)
on conflict (code) do update set name_ar = excluded.name_ar, name_en = excluded.name_en;

create table if not exists fixed_assets (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  category text, -- مثال: أثاث، سيارات، معدات، أجهزة
  purchase_date date not null,
  cost numeric(14,2) not null check (cost > 0),
  salvage_value numeric(14,2) not null default 0,
  useful_life_months int not null check (useful_life_months > 0),
  method text not null default 'straight_line' check (method in ('straight_line')), -- طريقة القسط الثابت فقط حالياً
  accumulated_depreciation numeric(14,2) not null default 0,
  status text not null default 'active' check (status in ('active','disposed')),
  disposal_date date,
  disposal_proceeds numeric(14,2),
  journal_entry_id uuid references journal_entries(id) on delete set null, -- قيد الشراء إن سُجّل هنا
  disposal_journal_entry_id uuid references journal_entries(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists fa_org_idx on fixed_assets(org_id, status);

drop trigger if exists on_asset_update on fixed_assets;
create trigger on_asset_update before update on fixed_assets
for each row execute function touch_updated_at();

alter table fixed_assets enable row level security;
drop policy if exists fa_select on fixed_assets;
create policy fa_select on fixed_assets for select using (is_member(org_id));
drop policy if exists fa_write on fixed_assets;
create policy fa_write on fixed_assets for all
  using (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

-- ------------------------------------------------------------
-- تسجيل أصل جديد + قيد الحصول عليه (Dr أصول ثابتة، Cr نقد/بنك/دائنون)
-- ------------------------------------------------------------
create or replace function record_fixed_asset(
  p_org_id uuid, p_name text, p_category text, p_purchase_date date,
  p_cost numeric, p_salvage_value numeric, p_useful_life_months int, p_payment_method text
) returns fixed_assets
language plpgsql security definer set search_path = public as $$
declare
  v_row fixed_assets;
  v_je uuid;
  v_code text; v_memo text;
begin
  if not has_role(p_org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية تسجيل أصول ثابتة لهذه الشركة';
  end if;
  if p_payment_method = 'cash' then v_code := '1010'; v_memo := 'الصندوق';
  elsif p_payment_method = 'bank' then v_code := '1020'; v_memo := 'البنك';
  elsif p_payment_method = 'payable' then v_code := '2100'; v_memo := 'الدائنون';
  else raise exception 'طريقة دفع غير معروفة: %', p_payment_method; end if;

  v_je := post_journal_entry(p_org_id, coalesce(p_purchase_date, current_date), 'asset_purchase', null,
    'شراء أصل ثابت — ' || p_name,
    jsonb_build_array(
      jsonb_build_object('account_code','1400','debit',p_cost,'credit',0,'memo',p_name),
      jsonb_build_object('account_code',v_code,'debit',0,'credit',p_cost,'memo',v_memo)
    ));

  insert into fixed_assets (org_id, name, category, purchase_date, cost, salvage_value,
    useful_life_months, journal_entry_id, created_by)
  values (p_org_id, p_name, p_category, p_purchase_date, p_cost, coalesce(p_salvage_value,0),
    p_useful_life_months, v_je, auth.uid())
  returning * into v_row;

  update journal_entries set source_id = v_row.id where id = v_je;
  return v_row;
end; $$;

-- ------------------------------------------------------------
-- تشغيل إهلاك شهر معيّن لكل الأصول النشطة — قيد واحد مجمّع، ويمنع التكرار لنفس الشهر
-- ------------------------------------------------------------
create table if not exists depreciation_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  ym text not null, -- 'YYYY-MM'
  total_amount numeric(14,2) not null default 0,
  asset_count int not null default 0,
  journal_entry_id uuid references journal_entries(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, ym)
);
create table if not exists depreciation_lines (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references depreciation_runs(id) on delete cascade,
  asset_id uuid not null references fixed_assets(id) on delete cascade,
  amount numeric(14,2) not null
);

alter table depreciation_runs enable row level security;
drop policy if exists dr_select on depreciation_runs;
create policy dr_select on depreciation_runs for select using (is_member(org_id));
alter table depreciation_lines enable row level security;
drop policy if exists dl_select on depreciation_lines;
create policy dl_select on depreciation_lines for select using (
  exists (select 1 from depreciation_runs r where r.id = depreciation_lines.run_id and is_member(r.org_id))
);

create or replace function run_asset_depreciation(p_org_id uuid, p_ym text)
returns depreciation_runs
language plpgsql security definer set search_path = public as $$
declare
  v_asset record;
  v_monthly numeric(14,2);
  v_remaining numeric(14,2);
  v_total numeric(14,2) := 0;
  v_count int := 0;
  v_run_id uuid;
  v_je uuid;
  v_lines jsonb := '[]'::jsonb;
  v_row depreciation_runs;
  v_period_end date;
begin
  if not has_role(p_org_id, array['owner']::app_role[]) then
    raise exception 'ترحيل الإهلاك الشهري متاح لمالك الشركة فقط';
  end if;
  if exists (select 1 from depreciation_runs where org_id = p_org_id and ym = p_ym) then
    raise exception 'تم ترحيل إهلاك شهر % مسبقاً لهذه الشركة', p_ym;
  end if;

  v_period_end := (to_date(p_ym || '-01', 'YYYY-MM-DD') + interval '1 month' - interval '1 day')::date;
  insert into depreciation_runs (org_id, ym, created_by) values (p_org_id, p_ym, auth.uid()) returning id into v_run_id;

  for v_asset in
    select * from fixed_assets
    where org_id = p_org_id and status = 'active' and purchase_date <= v_period_end
    order by purchase_date
  loop
    v_monthly := round((v_asset.cost - v_asset.salvage_value) / v_asset.useful_life_months, 2);
    v_remaining := round(v_asset.cost - v_asset.salvage_value - v_asset.accumulated_depreciation, 2);
    if v_remaining <= 0 then continue; end if;
    if v_monthly > v_remaining then v_monthly := v_remaining; end if;
    if v_monthly <= 0 then continue; end if;

    insert into depreciation_lines (run_id, asset_id, amount) values (v_run_id, v_asset.id, v_monthly);
    update fixed_assets set accumulated_depreciation = accumulated_depreciation + v_monthly where id = v_asset.id;

    v_total := v_total + v_monthly;
    v_count := v_count + 1;
  end loop;

  if v_total > 0 then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_code','5300','debit',v_total,'credit',0,'memo','مصروف إهلاك شهر ' || p_ym),
      jsonb_build_object('account_code','1450','debit',0,'credit',v_total,'memo','مجمّع الإهلاك — ' || p_ym)
    );
    v_je := post_journal_entry(p_org_id, v_period_end, 'asset_depreciation', v_run_id,
      'إهلاك شهري (' || v_count || ' أصل) — ' || p_ym, v_lines);
  end if;

  update depreciation_runs set total_amount = v_total, asset_count = v_count, journal_entry_id = v_je
  where id = v_run_id returning * into v_row;

  return v_row;
end; $$;

-- ------------------------------------------------------------
-- استبعاد/بيع أصل — يحسب الربح أو الخسارة تلقائياً ويستبعد الأصل من الدفاتر
-- ------------------------------------------------------------
create or replace function dispose_fixed_asset(
  p_org_id uuid, p_asset_id uuid, p_disposal_date date, p_proceeds numeric, p_payment_method text
) returns fixed_assets
language plpgsql security definer set search_path = public as $$
declare
  v_asset fixed_assets;
  v_nbv numeric(14,2);
  v_gain_loss numeric(14,2);
  v_lines jsonb;
  v_je uuid;
  v_code text;
begin
  if not has_role(p_org_id, array['owner']::app_role[]) then
    raise exception 'استبعاد الأصول متاح لمالك الشركة فقط';
  end if;
  select * into v_asset from fixed_assets where id = p_asset_id and org_id = p_org_id for update;
  if v_asset.id is null then raise exception 'الأصل غير موجود'; end if;
  if v_asset.status = 'disposed' then raise exception 'هذا الأصل مستبعد مسبقاً'; end if;

  v_nbv := v_asset.cost - v_asset.accumulated_depreciation;
  v_gain_loss := round(coalesce(p_proceeds,0) - v_nbv, 2); -- موجب = ربح، سالب = خسارة

  if p_payment_method = 'cash' then v_code := '1010';
  elsif p_payment_method = 'bank' then v_code := '1020';
  else v_code := null; end if;

  v_lines := jsonb_build_array(
    jsonb_build_object('account_code','1450','debit',v_asset.accumulated_depreciation,'credit',0,'memo','إلغاء مجمّع الإهلاك — ' || v_asset.name)
  );
  if coalesce(p_proceeds,0) > 0 and v_code is not null then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_code',v_code,'debit',p_proceeds,'credit',0,'memo','متحصلات استبعاد — ' || v_asset.name)
    );
  end if;
  if v_gain_loss > 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_code','4900','debit',0,'credit',v_gain_loss,'memo','ربح استبعاد — ' || v_asset.name)
    );
  elsif v_gain_loss < 0 then
    v_lines := v_lines || jsonb_build_array(
      jsonb_build_object('account_code','5400','debit',-v_gain_loss,'credit',0,'memo','خسارة استبعاد — ' || v_asset.name)
    );
  end if;
  v_lines := v_lines || jsonb_build_array(
    jsonb_build_object('account_code','1400','debit',0,'credit',v_asset.cost,'memo','استبعاد الأصل — ' || v_asset.name)
  );

  v_je := post_journal_entry(p_org_id, coalesce(p_disposal_date, current_date), 'asset_disposal', p_asset_id,
    'استبعاد أصل — ' || v_asset.name, v_lines);

  update fixed_assets set status = 'disposed', disposal_date = coalesce(p_disposal_date, current_date),
    disposal_proceeds = coalesce(p_proceeds,0), disposal_journal_entry_id = v_je
  where id = p_asset_id
  returning * into v_asset;

  return v_asset;
end; $$;
