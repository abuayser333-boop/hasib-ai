-- ============================================================
-- حاسِب AI — migration 006: حسابات بنكية + قيد يومية عام يدوي
--
-- يبني فوق 003. يضيف بطاقة "حسابات بنكية" حقيقية (لأغراض التسوية
-- والعرض التشغيلي) فوق حساب "البنك" 1020 الموحّد في دليل الحسابات
-- (لا نكسر منطق المطابقة البنكية الحالي في index.html)، ويضيف قيد
-- يومية عام يدوي — لأي حركة لا تمر عبر مبيعات/مشتريات/رواتب/أصول
-- (تحويل بين حسابات، رسوم بنكية، فوائد، تسويات افتتاحية...).
-- ============================================================

create table if not exists bank_accounts (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,           -- مثال: "الأهلي - جاري"
  bank_name text,
  iban text,
  account_number text,
  currency text not null default 'SAR',
  opening_balance numeric(14,2) not null default 0,
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists ba_org_idx on bank_accounts(org_id);

alter table bank_accounts enable row level security;
drop policy if exists ba_select on bank_accounts;
create policy ba_select on bank_accounts for select using (is_member(org_id));
drop policy if exists ba_write on bank_accounts;
create policy ba_write on bank_accounts for all
  using (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

-- ربط اختياري لحركات المطابقة البنكية الحالية بحساب بنكي محدد
-- (bank_transactions من schema.sql الأصلي — لم يُغيَّر أي عمود موجود)
alter table bank_transactions add column if not exists bank_account_id uuid references bank_accounts(id) on delete set null;
create index if not exists bank_txn_account_idx on bank_transactions(bank_account_id);

-- ------------------------------------------------------------
-- قيد يومية عام يدوي — لمالك الشركة فقط (قرار محاسبي حر يحتاج ضبطاً)
-- p_lines: [{account_code, debit, credit, memo}, ...] — يجب أن تتوازن
-- ------------------------------------------------------------
create or replace function record_manual_journal(
  p_org_id uuid, p_entry_date date, p_description text, p_lines jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_je uuid;
begin
  if not has_role(p_org_id, array['owner']::app_role[]) then
    raise exception 'القيد اليدوي متاح لمالك الشركة فقط';
  end if;
  if jsonb_array_length(p_lines) < 2 then
    raise exception 'القيد يحتاج سطرين على الأقل';
  end if;
  v_je := post_journal_entry(p_org_id, coalesce(p_entry_date, current_date), 'bank_manual', null,
    coalesce(p_description, 'قيد يومية عام يدوي'), p_lines);
  return v_je;
end; $$;

-- تحويل مباشر بين الصندوق والبنك (أو بين حسابين بنكيين تشغيلياً) — اختصار شائع
create or replace function transfer_cash_bank(
  p_org_id uuid, p_direction text, -- 'cash_to_bank' | 'bank_to_cash'
  p_amount numeric, p_entry_date date, p_note text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_je uuid; v_lines jsonb;
begin
  if not has_role(p_org_id, array['owner','accountant']::app_role[]) then
    raise exception 'ليست لديك صلاحية تسجيل تحويلات لهذه الشركة';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'مبلغ غير صحيح'; end if;

  if p_direction = 'cash_to_bank' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_code','1020','debit',p_amount,'credit',0,'memo',coalesce(p_note,'إيداع في البنك')),
      jsonb_build_object('account_code','1010','debit',0,'credit',p_amount,'memo',coalesce(p_note,'سحب من الصندوق'))
    );
  elsif p_direction = 'bank_to_cash' then
    v_lines := jsonb_build_array(
      jsonb_build_object('account_code','1010','debit',p_amount,'credit',0,'memo',coalesce(p_note,'سحب نقدي من البنك')),
      jsonb_build_object('account_code','1020','debit',0,'credit',p_amount,'memo',coalesce(p_note,'سحب من البنك'))
    );
  else
    raise exception 'اتجاه غير معروف: %', p_direction;
  end if;

  v_je := post_journal_entry(p_org_id, coalesce(p_entry_date, current_date), 'bank_manual', null,
    'تحويل بين الصندوق والبنك', v_lines);
  return v_je;
end; $$;
