-- =============================================================================
--  اختبار فعلي لعزل المحلات (Multi-Tenancy) على مخطط hanoutk
--  محلي: PostgreSQL 15 مع محاكاة auth.uid()
-- =============================================================================
\set ON_ERROR_STOP on

-- ---------- تهيئة: محلان + مستخدمان (مالكان) + عاملان ----------
insert into auth.users (id, email, raw_user_meta_data)
values
  ('11111111-1111-1111-1111-111111111111', 'owner-a@shop.dz', '{"full_name":"مالك أ","store_name":"محل ألف"}'),
  ('22222222-2222-2222-2222-222222222222', 'owner-b@shop.dz', '{"full_name":"مالك ب","store_name":"محل باء"}');

-- Trigger handle_new_user ينشئ المتجر + ملف المالك تلقائيًا
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);

-- نتحقق من إنشاء المتجر والملف
do $$
declare
  v_stores int;
  v_profiles int;
begin
  select count(*) into v_stores from public.stores;
  select count(*) into v_profiles from public.profiles;
  if v_stores <> 2 then raise exception 'FAIL: المتوقع محلين، الموجود %', v_stores; end if;
  if v_profiles <> 2 then raise exception 'FAIL: Expected 2 profiles, got %', v_profiles; end if;
  raise notice 'OK: إنشاء المتجر والملف تلقائيًا (stores=%, profiles=%)', v_stores, v_profiles;
end $$;

-- نضيف عاملين: صاحب المحل يُنشئ الدعوة أولًا، ثم يسجّل العامل دخوله
insert into public.staff_invitations (store_id, email, role)
select s.id, 'staff-a@shop.dz', 'staff'
  from public.stores s where s.name = 'محل ألف';

insert into public.staff_invitations (store_id, email, role)
select s.id, 'staff-b@shop.dz', 'staff'
  from public.stores s where s.name = 'محل باء';

insert into auth.users (id, email, raw_user_meta_data)
values
  ('33333333-3333-3333-3333-333333333333', 'staff-a@shop.dz', '{"full_name":"عامل ألف"}'),
  ('44444444-4444-4444-4444-444444444444', 'staff-b@shop.dz', '{"full_name":"عامل باء"}');

-- التحقق: العامل وُضع في محل的正确 + الدعوة قُبلت
do $$
declare
  v_store text; v_role text; v_inv int;
begin
  select s.name, p.role into v_store, v_role
    from public.profiles p join public.stores s on s.id = p.store_id
   where p.id = '33333333-3333-3333-3333-333333333333';
  if v_store <> 'محل ألف' then raise exception 'FAIL: العامل في %', v_store; end if;
  if v_role <> 'staff' then raise exception 'FAIL: دور العامل %', v_role; end if;
  select count(*) into v_inv from public.staff_invitations where accepted_at is not null;
  if v_inv <> 2 then raise exception 'FAIL: الدعوات المقبولة %', v_inv; end if;
  raise notice 'OK: العامل انضمّ إلى % بدعوة (دور %)', v_store, v_role;
end $$;

-- =============================================================================
--  الاختبار 1: عزل القراءة بين المحلات
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

-- مالك ألف يضيف منتجًا وزبونًا
insert into public.products (store_id, name, barcode, sell_price, buy_price, qty, min_stock)
select id, 'منتج محل ألف', '1110000000001', 250, 120, 40, 5 from public.stores where name = 'محل ألف';

insert into public.customers (store_id, name, phone)
select id, 'زبون محل ألف', '0555000001' from public.stores where name = 'محل ألف';

insert into public.expenses (store_id, amount, note)
select id, 5000, 'مصروف خاص بمحل ألف' from public.stores where name = 'محل ألف';

-- مالك باء يضيف منتجه
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);
insert into public.products (store_id, name, barcode, sell_price, buy_price, qty, min_stock)
select id, 'منتج محل باء', '2220000000002', 300, 150, 10, 5 from public.stores where name = 'محل باء';

-- نعود لمالك ألف ونتحقق
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);

do $$
declare
  v_products int;
  v_customers int;
  v_expenses int;
  v_other text;
begin
  select count(*) into v_products from public.products;
  select count(*) into v_customers from public.customers;
  select count(*) into v_expenses from public.expenses;
  if v_products <> 1 then raise exception 'FAIL: مالك ألف يرى % منتج (المتوقع 1)', v_products; end if;
  if v_customers <> 1 then raise exception 'FAIL: مالك ألف يرى % زبون', v_customers; end if;
  if v_expenses <> 1 then raise exception 'FAIL: مالك ألف يرى % مصروف', v_expenses; end if;
  select name into v_other from public.products;
  if v_other <> 'منتج محل ألف' then raise exception 'FAIL: رأى منتج محل آخر: %', v_other; end if;
  raise notice 'OK: عزل القراءة — مالك ألف يرى % منتج و% زبون و% مصروف فقط', v_products, v_customers, v_expenses;
end $$;

-- =============================================================================
--  الاختبار 2: منع الكتابة في محل آخر
-- =============================================================================
do $$
declare
  v_store_b uuid;
begin
  select id into v_store_b from public.stores where name = 'محل باء';

  begin
    insert into public.products (store_id, name, sell_price, buy_price, qty)
    values (v_store_b, 'تسرّب من محل ألف', 100, 50, 5);
    raise exception 'FAIL: سمح بالكتابة في محل آخر';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise notice 'OK: رُفضت الكتابة في محل آخر (%)', sqlerrm;
  end;

  -- تحديث منتج محل آخر (يجب ألا يؤثّر)
  update public.products set sell_price = 1
   where id = (select id from public.products where store_id = v_store_b limit 1);
  if found then raise exception 'FAIL: حدّث منتجًا في محل آخر'; end if;
  raise notice 'OK: التحديث على بيانات محل آخر لا يؤثر';
end $$;

-- =============================================================================
--  الاختبار 3: صلاحيات العامل
-- =============================================================================
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', false);

do $$
declare
  v_expenses int;
  v_product uuid;
begin
  -- العامل لا يرى المصاريف
  select count(*) into v_expenses from public.expenses;
  if v_expenses <> 0 then raise exception 'FAIL: العامل يرى % مصروف', v_expenses; end if;
  raise notice 'OK: العامل لا يرى مصاريف المحل';

  -- العامل لا يغيّر الكمية
  select id into v_product from public.products limit 1;
  begin
    update public.products set qty = 999 where id = v_product;
    raise exception 'FAIL: العامل عدّل الكمية';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise notice 'OK: رُفض تعديل الكمية من العامل';
  end;

  -- العامل لا يغيّر سعر الشراء
  begin
    update public.products set buy_price = 1 where id = v_product;
    raise exception 'FAIL: العامل عدّل سعر الشراء';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise notice 'OK: رُفض تعديل سعر الشراء من العامل';
  end;

  -- العامل لا يغيّر دوره إلى مالك
  begin
    update public.profiles set role = 'owner' where id = auth.uid();
    raise exception 'FAIL: العامل رُفع إلى مالك';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    raise notice 'OK: رُفض ترقية العامل إلى مالك';
  end;
end $$;

-- =============================================================================
--  الاختبار 4: بيع كامل (تكلفة من القاعدة + خصم المخزون + حساب الإجمالي)
-- =============================================================================
do $$
declare
  v_product public.products%rowtype;
  v_sale uuid;
  v_item uuid;
  v_qty numeric;
  v_cost numeric;
  v_total numeric;
  v_due numeric;
begin
  select * into v_product from public.products where name = 'منتج محل ألف';

  insert into public.sales (store_id, paid, method)
  select id, 1000, 'cash' from public.stores where name = 'محل ألف'
  returning id into v_sale;

  insert into public.sale_items (store_id, sale_id, product_id, name, qty, unit, units, price, buy_price)
  values ((select store_id from public.sales where id = v_sale), v_sale, v_product.id, v_product.name,
          2, 'piece', 1, 250, 999)  -- 999 = محاولة تزوير التكلفة
  returning id into v_item;

  select qty into v_qty from public.products where id = v_product.id;
  select cost, total, due into v_cost, v_total, v_due from public.sales where id = v_sale;

  if v_qty <> 38 then raise exception 'FAIL: المخزون % (المتوقع 38)', v_qty; end if;
  if v_cost <> 240 then raise exception 'FAIL: التكلفة % (المتوقع 240 من سعر الشراء)', v_cost; end if;
  if v_total <> 500 then raise exception 'FAIL: الإجمالي % (المتوقع 500)', v_total; end if;
  if v_due <> 0 then raise exception 'FAIL: الباقي % (المتوقع 0)', v_due; end if;
  raise notice 'OK: البيع محسوب من القاعدة — مخزون=%, تكلفة=%, إجمالي=%, باقي=%', v_qty, v_cost, v_total, v_due;
end $$;

-- =============================================================================
--  الاختبار 5: العامل لا يحذف منتجًا / لا يرى مصاريف محله
-- =============================================================================
do $$
declare
  v_before int;
  v_after int;
begin
  select count(*) into v_before from public.products;
  delete from public.products where name = 'منتج محل ألف';
  select count(*) into v_after from public.products;
  if v_after <> v_before then
    raise exception 'FAIL: العامل حذف منتجًا (% → %)', v_before, v_after;
  end if;
  raise notice 'OK: رُفض حذف المنتج من العامل (العدد بقي %) ', v_after;
end $$;

reset role;

-- =============================================================================
--  الاختبار 6: المالك B يرى بيانات محله فقط (وليس ألف)
-- =============================================================================
set role authenticated;
select set_config('request.jwt.claim.sub', '22222222-2222-2222-2222-222222222222', false);

do $$
declare
  v_products int;
  v_sales int;
  v_name text;
begin
  select count(*) into v_products from public.products;
  select count(*) into v_sales from public.sales;
  if v_products <> 1 then raise exception 'FAIL: مالك باء يرى % منتج', v_products; end if;
  if v_sales <> 0 then raise exception 'FAIL: مالك باء يرى % فاتورة من محل آخر', v_sales; end if;
  select name into v_name from public.products;
  if v_name <> 'منتج محل باء' then raise exception 'FAIL: رأى %', v_name; end if;
  raise notice 'OK: مالك باء يرى % منتج و% فاتورة فقط', v_products, v_sales;
end $$;

reset role;

\echo ''
\echo '=========================================================='
\echo '  نجح: كل اختبارات عزل المحلات والمزامنة'
\echo '=========================================================='
