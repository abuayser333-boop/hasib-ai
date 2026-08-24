-- ============================================================
-- حاسِب AI — migration 008: حقوق الملكية (Equity)
--
-- يبني فوق 003. حركات رأس المال — ضخ رأس مال، مسحوبات مالك،
-- توزيعات أرباح — كل حركة قيد مرحّل تلقائياً في دفتر الأستاذ العام.
--
-- ⚠ ملاحظة نطاق مهمة: قيد إقفال نهاية السنة (تصفير الإيرادات/
-- المصروفات إلى الأرباح المرحلة) غير مُضمَّن هنا عمداً — لأن فواتير
-- المصروفات المستخرجة بالذكاء الاصطناعي (جدول invoices الأصلي) لا
-- تزال تُرحَّل عرضاً فقط في الواجهة (JS) لا في journal_entries، فأي
-- "صافي دخل" يُحسب من journal_lines وحدها سيكون منقوصاً وغير دقيق.
-- يُنصح بإضافة قيد الإقفال بعد توحيد كل المصادر في دفتر الأستاذ.
-- ============================================================

insert into chart_of_accounts (code, name_ar, name_en, account_type, is_current) values
  ('3300','أرباح موزعة','Dividends Declared','equity',false)
on conflict (code) do update set name_ar = excluded.name_ar, name_en = excluded.name_en;

create table if not exists equity_transactions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  type text not null check (type in ('capital_injection','drawing','dividend')),
  amount numeric(14,2) not null check (amount > 0),
  method text not null check (method in ('cash','bank')),
  entry_date date not null default current_date,
  description text,
  journal_entry_id uuid references journal_entries(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists eq_org_idx on equity_transactions(org_id, entry_date desc);

alter table equity_transactions enable row level security;
drop policy if exists eq_select on equity_transactions;
create policy eq_select on equity_transactions for select using (is_member(org_id));
-- لا insert مباشر: حصراً عبر record_equity_transaction لضمان ترحيل القيد

create or replace function record_equity_transaction(
  p_org_id uuid, p_type text, p_amount numeric, p_method text, p_entry_date date, p_description text
) returns equity_transactions
language plpgsql security definer set search_path = public as $$
declare
  v_code text; -- حساب النقد/البنك
  v_equity_code text;
  v_lines jsonb;
  v_je uuid;
  v_row equity_transactions;
begin
  -- حركات حقوق الملكية قرار على مستوى المالك/الشركاء — للمالك وحده
  if not has_role(p_org_id, array['owner']::app_role[]) then
    raise exception 'حركات حقوق الملكية متاحة لمالك الشركة فقط';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'مبلغ غير صحيح'; end if;

  v_code := case when p_method = 'bank' then '1020' else '1010' end;

  if p_type = 'capital_injection' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_code',v_code,'debit',p_amount,'credit',0,'memo',coalesce(p_description,'ضخ رأس مال')),
      jsonb_build_object('account_code','3000','debit',0,'credit',p_amount,'memo','رأس المال')
    );
  elsif p_type = 'drawing' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_code','3200','debit',p_amount,'credit',0,'memo','مسحوبات المالك'),
      jsonb_build_object('account_code',v_code,'debit',0,'credit',p_amount,'memo',coalesce(p_description,'مسحوبات'))
    );
  elsif p_type = 'dividend' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_code','3300','debit',p_amount,'credit',0,'memo','أرباح موزعة'),
      jsonb_build_object('account_code',v_code,'debit',0,'credit',p_amount,'memo',coalesce(p_description,'توزيعات أرباح'))
    );
  else
    raise exception 'نوع حركة غير معروف: %', p_type;
  end if;

  v_je := post_journal_entry(p_org_id, coalesce(p_entry_date, current_date), 'equity', null,
    coalesce(p_description, p_type), v_lines);

  insert into equity_transactions (org_id, type, amount, method, entry_date, description, journal_entry_id, created_by)
  values (p_org_id, p_type, p_amount, p_method, coalesce(p_entry_date, current_date), p_description, v_je, auth.uid())
  returning * into v_row;

  update journal_entries set source_id = v_row.id where id = v_je;
  return v_row;
end; $$;
