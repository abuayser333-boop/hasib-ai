-- ============================================================
-- حاسِب AI — migration 005: الموارد البشرية والرواتب (HR & Payroll)
--
-- يبني فوق 003. تشغيل رواتب شهر = عملية ذرية واحدة: تحتسب لكل موظف
-- نشط الراتب الإجمالي + التأمينات الاجتماعية (جوسي) حسب فئته، ترحّل
-- قيد استحقاق واحد مجمّع، ثم قيد سداد منفصل عند الدفع الفعلي — تماماً
-- كما تُدار الرواتب محاسبياً (Accrual ثم Payment).
--
-- ⚠ نسب جوسي أدناه قابلة للتغيير من مُشغّل الدالة (معاملات اختيارية)
-- لأن الأنظمة تتغيّر — تحقق من النسب الحالية في نظام التأمينات
-- الاجتماعية الموحد قبل الاعتماد على القيم الافتراضية.
-- ============================================================

create table if not exists employees (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name text not null,
  national_id text,
  gosi_category text not null default 'saudi' check (gosi_category in ('saudi','non_saudi')),
  job_title text,
  department text,
  basic_salary numeric(14,2) not null default 0,
  housing_allowance numeric(14,2) not null default 0,
  other_allowances numeric(14,2) not null default 0,
  hire_date date,
  status text not null default 'active' check (status in ('active','terminated')),
  termination_date date,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists emp_org_idx on employees(org_id, status);

drop trigger if exists on_employee_update on employees;
create trigger on_employee_update before update on employees
for each row execute function touch_updated_at();

alter table employees enable row level security;
drop policy if exists emp_select on employees;
create policy emp_select on employees for select using (is_member(org_id));
drop policy if exists emp_write on employees;
create policy emp_write on employees for all
  using (has_role(org_id, array['owner','accountant']::app_role[]))
  with check (has_role(org_id, array['owner','accountant']::app_role[]));

create table if not exists payroll_runs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  ym text not null,
  status text not null default 'posted' check (status in ('posted','paid')),
  total_gross numeric(14,2) not null default 0,
  total_gosi_employee numeric(14,2) not null default 0,
  total_gosi_employer numeric(14,2) not null default 0,
  total_net numeric(14,2) not null default 0,
  accrual_journal_entry_id uuid references journal_entries(id) on delete set null,
  payment_journal_entry_id uuid references journal_entries(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (org_id, ym)
);
create table if not exists payroll_lines (
  id uuid primary key default gen_random_uuid(),
  payroll_run_id uuid not null references payroll_runs(id) on delete cascade,
  employee_id uuid not null references employees(id) on delete restrict,
  basic numeric(14,2) not null default 0,
  housing_allowance numeric(14,2) not null default 0,
  other_allowances numeric(14,2) not null default 0,
  gross numeric(14,2) not null default 0,
  gosi_employee numeric(14,2) not null default 0,
  gosi_employer numeric(14,2) not null default 0,
  net_pay numeric(14,2) not null default 0
);

alter table payroll_runs enable row level security;
drop policy if exists pr_select on payroll_runs;
create policy pr_select on payroll_runs for select using (is_member(org_id));
alter table payroll_lines enable row level security;
drop policy if exists pl_select on payroll_lines;
create policy pl_select on payroll_lines for select using (
  exists (select 1 from payroll_runs r where r.id = payroll_lines.payroll_run_id and is_member(r.org_id))
);

create or replace function run_payroll(
  p_org_id uuid, p_ym text,
  p_gosi_employee_rate numeric default 0.0975,
  p_gosi_employer_rate_saudi numeric default 0.1175,
  p_gosi_employer_rate_nonsaudi numeric default 0.02
) returns payroll_runs
language plpgsql security definer set search_path = public as $$
declare
  v_emp record;
  v_gross numeric(14,2); v_gosi_base numeric(14,2);
  v_gosi_emp numeric(14,2); v_gosi_er numeric(14,2); v_net numeric(14,2);
  v_run_id uuid;
  v_total_gross numeric(14,2) := 0; v_total_gosi_emp numeric(14,2) := 0;
  v_total_gosi_er numeric(14,2) := 0; v_total_net numeric(14,2) := 0;
  v_je uuid;
  v_row payroll_runs;
begin
  if not has_role(p_org_id, array['owner']::app_role[]) then
    raise exception 'تشغيل الرواتب متاح لمالك الشركة فقط';
  end if;
  if exists (select 1 from payroll_runs where org_id = p_org_id and ym = p_ym) then
    raise exception 'تم ترحيل رواتب شهر % مسبقاً لهذه الشركة', p_ym;
  end if;

  insert into payroll_runs (org_id, ym, created_by) values (p_org_id, p_ym, auth.uid()) returning id into v_run_id;

  for v_emp in select * from employees where org_id = p_org_id and status = 'active' loop
    v_gross := v_emp.basic_salary + v_emp.housing_allowance + v_emp.other_allowances;
    v_gosi_base := v_emp.basic_salary + v_emp.housing_allowance; -- الوعاء النظامي: الأساسي + السكن
    if v_emp.gosi_category = 'saudi' then
      v_gosi_emp := round(v_gosi_base * p_gosi_employee_rate, 2);
      v_gosi_er  := round(v_gosi_base * p_gosi_employer_rate_saudi, 2);
    else
      v_gosi_emp := 0; -- غير السعودي: لا اقتطاع من الموظف، فقط اشتراك الأخطار المهنية على الشركة
      v_gosi_er  := round(v_gosi_base * p_gosi_employer_rate_nonsaudi, 2);
    end if;
    v_net := v_gross - v_gosi_emp;

    insert into payroll_lines (payroll_run_id, employee_id, basic, housing_allowance, other_allowances,
      gross, gosi_employee, gosi_employer, net_pay)
    values (v_run_id, v_emp.id, v_emp.basic_salary, v_emp.housing_allowance, v_emp.other_allowances,
      v_gross, v_gosi_emp, v_gosi_er, v_net);

    v_total_gross := v_total_gross + v_gross;
    v_total_gosi_emp := v_total_gosi_emp + v_gosi_emp;
    v_total_gosi_er := v_total_gosi_er + v_gosi_er;
    v_total_net := v_total_net + v_net;
  end loop;

  if v_total_gross = 0 then
    raise exception 'لا يوجد موظفون نشطون لتشغيل رواتب شهر %', p_ym;
  end if;

  v_je := post_journal_entry(p_org_id, (to_date(p_ym||'-01','YYYY-MM-DD') + interval '1 month' - interval '1 day')::date,
    'payroll', v_run_id, 'استحقاق رواتب — ' || p_ym,
    jsonb_build_array(
      jsonb_build_object('account_code','6100','debit',v_total_gross,'credit',0,'memo','إجمالي رواتب ' || p_ym),
      jsonb_build_object('account_code','6110','debit',v_total_gosi_er,'credit',0,'memo','حصة الشركة في جوسي'),
      jsonb_build_object('account_code','2200','debit',0,'credit',v_total_net,'memo','صافي رواتب مستحقة'),
      jsonb_build_object('account_code','2210','debit',0,'credit',v_total_gosi_emp + v_total_gosi_er,'memo','جوسي مستحقة (حصة الموظف + الشركة)')
    ));

  update payroll_runs set total_gross = v_total_gross, total_gosi_employee = v_total_gosi_emp,
    total_gosi_employer = v_total_gosi_er, total_net = v_total_net, accrual_journal_entry_id = v_je
  where id = v_run_id returning * into v_row;

  return v_row;
end; $$;

-- صرف صافي الرواتب فعلياً (بعد الاستحقاق) — Dr رواتب مستحقة، Cr نقد/بنك
create or replace function pay_payroll_run(p_org_id uuid, p_run_id uuid, p_payment_method text)
returns payroll_runs
language plpgsql security definer set search_path = public as $$
declare v_run payroll_runs; v_code text; v_je uuid;
begin
  if not has_role(p_org_id, array['owner']::app_role[]) then
    raise exception 'صرف الرواتب متاح لمالك الشركة فقط';
  end if;
  select * into v_run from payroll_runs where id = p_run_id and org_id = p_org_id for update;
  if v_run.id is null then raise exception 'تشغيلة الرواتب غير موجودة'; end if;
  if v_run.status = 'paid' then raise exception 'تم صرف هذه الرواتب مسبقاً'; end if;

  v_code := case when p_payment_method = 'bank' then '1020' else '1010' end;
  v_je := post_journal_entry(p_org_id, current_date, 'payroll_payment', p_run_id,
    'صرف رواتب — ' || v_run.ym,
    jsonb_build_array(
      jsonb_build_object('account_code','2200','debit',v_run.total_net,'credit',0,'memo','تسوية رواتب مستحقة'),
      jsonb_build_object('account_code',v_code,'debit',0,'credit',v_run.total_net,'memo','صرف رواتب ' || v_run.ym)
    ));

  update payroll_runs set status = 'paid', payment_journal_entry_id = v_je where id = p_run_id
  returning * into v_run;
  return v_run;
end; $$;

-- سداد جوسي الشهري (حصة الموظف + الشركة) للجهة المختصة
create or replace function pay_gosi(p_org_id uuid, p_run_id uuid, p_payment_method text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_run payroll_runs; v_code text; v_je uuid; v_amount numeric(14,2);
begin
  if not has_role(p_org_id, array['owner']::app_role[]) then
    raise exception 'سداد جوسي متاح لمالك الشركة فقط';
  end if;
  select * into v_run from payroll_runs where id = p_run_id and org_id = p_org_id;
  if v_run.id is null then raise exception 'تشغيلة الرواتب غير موجودة'; end if;
  v_amount := v_run.total_gosi_employee + v_run.total_gosi_employer;
  if v_amount <= 0 then raise exception 'لا يوجد مبلغ جوسي مستحق لهذه التشغيلة'; end if;

  v_code := case when p_payment_method = 'bank' then '1020' else '1010' end;
  v_je := post_journal_entry(p_org_id, current_date, 'gosi_payment', p_run_id,
    'سداد التأمينات الاجتماعية — ' || v_run.ym,
    jsonb_build_array(
      jsonb_build_object('account_code','2210','debit',v_amount,'credit',0,'memo','تسوية جوسي مستحقة'),
      jsonb_build_object('account_code',v_code,'debit',0,'credit',v_amount,'memo','سداد جوسي ' || v_run.ym)
    ));
  return v_je;
end; $$;
