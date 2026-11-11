-- =============================================================================
--  hanoutk — مخطط قاعدة بيانات Supabase (تعدد المحلات / Multi-Tenancy)
--  الإصدار: 1.0  |  التاريخ: 2026-11-11
--
--  طريقة التطبيق:
--    1) افتح مشروعك في Supabase → SQL Editor → الصق هذا الملف كاملًا → Run.
--    2) لا تغيّر شيئًا في سياسات RLS بعد التفعيل إلا بتقنية.
--
--  ملاحظة أمنية: كل الجداول تحت RLS، وكل الوصول يتم عبر `auth.uid()`
--  و`current_store_id()` — فلا يمكن لأي حساب أن يرى أو يعدّل بيانات محل آخر.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 0) الإعدادات الأساسية
-- -----------------------------------------------------------------------------
create extension if not exists pgcrypto;

-- Guard عام: يمنع تعديل السجلات عندما يكون المتصل بدور غير مصرّح به
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- =============================================================================
-- 1) جداول النظام
-- =============================================================================

-- المحلات: كل محل مستقل تمامًا (متجر/فرع/شركة)
create table if not exists public.stores (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(btrim(name)) between 2 and 120),
  phone       text,
  address     text,
  currency    text not null default 'DZD',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table public.stores is 'المحلات — كل صف = محل مستقل (Tenant)';

-- حسابات المستخدمين/العمال
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  store_id    uuid not null references public.stores(id) on delete cascade,
  role        text not null default 'staff' check (role in ('owner','staff')),
  full_name   text not null default '',
  phone       text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists profiles_store_idx on public.profiles(store_id);
create index if not exists profiles_role_idx  on public.profiles(store_id, role);

comment on table public.profiles is 'المستخدمون والعاملون — كل حساب مربوط بمحل واحد';

-- دعوات الانضمام: ينشئها المالك لعامل قبل أن يسجّل الدخول
create table if not exists public.staff_invitations (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references public.stores(id) on delete cascade,
  email       text not null,
  role        text not null default 'staff' check (role in ('owner','staff')),
  invited_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  accepted_at timestamptz
);

create unique index if not exists staff_invitations_store_email_idx
  on public.staff_invitations(store_id, lower(email));

-- =============================================================================
-- 2) جداول البيانات التشغيلية (كلها مرتبطة بـ store_id)
-- =============================================================================

create table if not exists public.categories (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references public.stores(id) on delete cascade,
  name        text not null check (length(btrim(name)) > 0),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create unique index if not exists categories_store_name_idx
  on public.categories(store_id, lower(name));

create table if not exists public.products (
  id             uuid primary key default gen_random_uuid(),
  store_id       uuid not null references public.stores(id) on delete cascade,
  name           text not null check (length(btrim(name)) > 0),
  barcode        text,
  category       text default 'عام',
  -- الأسعار العادية (لكل حبة)
  sell_price     numeric(12,2) not null default 0 check (sell_price >= 0),
  buy_price      numeric(12,2) not null default 0 check (buy_price  >= 0),
  -- البيع بالعلبة والحبة
  units_per_box  integer not null default 1 check (units_per_box >= 1),
  box_buy_price  numeric(12,2) not null default 0 check (box_buy_price  >= 0),
  box_sell_price numeric(12,2) not null default 0 check (box_sell_price >= 0),
  unit_sell_price numeric(12,2) not null default 0 check (unit_sell_price >= 0),
  -- المخزون يُحفظ بالحبات
  qty            numeric(12,2) not null default 0 check (qty >= 0),
  min_stock      integer not null default 5 check (min_stock >= 0),
  is_active      boolean not null default true,
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists products_store_idx   on public.products(store_id);
create index if not exists products_barcode_idx on public.products(store_id, barcode);
create index if not exists products_category_idx on public.products(store_id, category);

create table if not exists public.customers (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references public.stores(id) on delete cascade,
  name        text not null check (length(btrim(name)) > 0),
  phone       text,
  note        text,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists customers_store_idx on public.customers(store_id);
create index if not exists customers_phone_idx on public.customers(store_id, phone);

create table if not exists public.sales (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null references public.stores(id) on delete cascade,
  customer_id  uuid references public.customers(id) on delete set null,
  customer_name text not null default '',
  method       text not null default 'cash' check (method in ('cash','credit')),
  total        numeric(12,2) not null default 0,
  cost         numeric(12,2) not null default 0,
  paid         numeric(12,2) not null default 0,
  due          numeric(12,2) not null default 0,
  change       numeric(12,2) not null default 0,
  note         text,
  created_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists sales_store_idx    on public.sales(store_id, created_at desc);
create index if not exists sales_customer_idx on public.sales(customer_id);
create index if not exists sales_creator_idx  on public.sales(store_id, created_by);

create table if not exists public.sale_items (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references public.stores(id) on delete cascade,
  sale_id     uuid not null references public.sales(id) on delete cascade,
  product_id  uuid not null references public.products(id) on delete restrict,
  name        text not null default '',
  barcode     text not null default '',
  qty         numeric(12,2) not null default 0 check (qty > 0),
  unit        text not null default 'piece' check (unit in ('box','piece')),
  units       integer not null default 1 check (units >= 1),
  price       numeric(12,2) not null default 0 check (price >= 0),
  buy_price   numeric(12,2) not null default 0 check (buy_price >= 0),
  created_at  timestamptz not null default now()
);

create index if not exists sale_items_sale_idx    on public.sale_items(sale_id);
create index if not exists sale_items_product_idx on public.sale_items(product_id);
create index if not exists sale_items_store_idx   on public.sale_items(store_id);

create table if not exists public.expenses (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references public.stores(id) on delete cascade,
  amount      numeric(12,2) not null check (amount > 0),
  category    text not null default 'مصاريف أخرى',
  note        text,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists expenses_store_idx on public.expenses(store_id, created_at desc);

create table if not exists public.payments (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references public.stores(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  amount      numeric(12,2) not null check (amount > 0),
  note        text,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists payments_store_idx    on public.payments(store_id, created_at desc);
create index if not exists payments_customer_idx on public.payments(customer_id);

-- سجل نشاط العمال (المراقبة اللحظية)
create table if not exists public.activity (
  id             uuid primary key default gen_random_uuid(),
  store_id       uuid not null references public.stores(id) on delete cascade,
  employee_id    uuid references auth.users(id) on delete set null,
  employee_name  text not null default '',
  action         text not null default 'sale',
  text           text not null default '',
  amount         numeric(12,2) not null default 0,
  created_at     timestamptz not null default now()
);

create index if not exists activity_store_idx on public.activity(store_id, created_at desc);

-- =============================================================================
-- 3) دوال المساعدة — مصدر الحقيقة الوحيد للعزل
-- =============================================================================

-- المحل الذي ينتمي إليه المستخدم الحالي (من جدول profiles)
create or replace function public.current_store_id()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.store_id from public.profiles p where p.id = auth.uid() limit 1;
$$;

-- دور المستخدم داخل محله
create or replace function public.current_role()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.role from public.profiles p where p.id = auth.uid() limit 1;
$$;

create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$ select coalesce(public.current_role() = 'owner', false); $$;

create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$ select coalesce(public.current_role() = 'staff', false); $$;

-- هل السجل المطلوب ينتمي إلى محلي؟
create or replace function public.in_current_store(target_store uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$ select coalesce(target_store = public.current_store_id(), false); $$;

comment on function public.current_store_id() is 'معرّف محل المستخدم الحالي — يُستخدم في كل سياسات RLS';

-- =============================================================================
-- 4) الحمايات على مستوى قاعدة البيانات (Triggers)
-- =============================================================================

-- 4.1) عند تسجيل مستخدم جديد: يُنشأ له محل + حساب مالك، أو يُربط بدعوة قائمة
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_store_id uuid;
  v_invite   public.staff_invitations%rowtype;
  v_name     text;
begin
  v_name := coalesce(new.raw_user_meta_data ->> 'full_name', split_part(coalesce(new.email,''), '@', 1));

  -- هل هناك دعوةpended لهذا البريد؟
  select * into v_invite
  from public.staff_invitations i
  where lower(i.email) = lower(new.email) and i.accepted_at is null
  order by i.created_at desc
  limit 1;

  perform set_config('hanoutk.system_write', 'on', true);

  -- ملاحظة: لا نعتمد على FOUND هنا لأن PERFORM يكتب فوقه
  if v_invite.id is not null then
    insert into public.profiles (id, store_id, role, full_name)
    values (new.id, v_invite.store_id, v_invite.role, v_name)
    on conflict (id) do update set store_id = excluded.store_id, role = excluded.role, full_name = excluded.full_name;
    update public.staff_invitations set accepted_at = now() where id = v_invite.id;
  else
    -- مستخدم جديد = مالك محل جديد
    insert into public.stores (name) values (coalesce(new.raw_user_meta_data ->> 'store_name', 'محل جديد'))
    returning id into v_store_id;
    insert into public.profiles (id, store_id, role, full_name)
    values (new.id, v_store_id, 'owner', v_name);
  end if;

  perform set_config('hanoutk.system_write', 'off', true);
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 4.2) عند إنشاء محل: صاحب الإنشاء يصبح مالكه
create or replace function public.handle_new_store()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if auth.uid() is not null
     and not exists (select 1 from public.profiles p where p.id = auth.uid() and p.store_id = new.id) then
    perform set_config('hanoutk.system_write', 'on', true);
    insert into public.profiles (id, store_id, role, full_name)
    values (auth.uid(), new.id, 'owner', coalesce((select p.full_name from public.profiles p where p.id = auth.uid()), ''))
    on conflict (id) do update set store_id = excluded.store_id, role = 'owner';
    perform set_config('hanoutk.system_write', 'off', true);
  end if;
  return new;
end;
$$;

drop trigger if exists on_store_created on public.stores;
create trigger on_store_created
  after insert on public.stores
  for each row execute function public.handle_new_store();

-- 4.3) منع العامل من تغيير الصلاحيات أو المحل
create or replace function public.protect_profile_privileges()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- كتابة النظام (إنشاء الحساب تلقائيًا) مسموحة
  if coalesce(current_setting('hanoutk.system_write', true), 'off') = 'on' then
    return new;
  end if;
  if public.is_owner() and new.store_id = old.store_id then
    return new;
  end if;
  if new.store_id is distinct from old.store_id or new.role is distinct from old.role then
    raise exception 'غير مصرّح: تغيير المحل أو الصلاحية من المالك فقط';
  end if;
  return new;
end;
$$;

drop trigger if exists on_profile_protect on public.profiles;
create trigger on_profile_protect
  before update on public.profiles
  for each row execute function public.protect_profile_privileges();

-- 4.4) منع العامل من تعديل الكميات أو أسعار الشراء
create or replace function public.protect_product_sensitive_columns()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- الكتابة من النظام (خصم المخزون) مسموحة
  if coalesce(current_setting('hanoutk.system_write', true), 'off') = 'on' then
    return new;
  end if;

  if new.store_id is distinct from old.store_id then
    raise exception 'غير مصرّح: لا يمكن نقل منتج إلى محل آخر';
  end if;

  if not public.is_owner() then
    if new.qty is distinct from old.qty then
      raise exception 'غير مصرّح: تعديل الكمية من المالك فقط';
    end if;
    if new.buy_price is distinct from old.buy_price
       or new.box_buy_price is distinct from old.box_buy_price
       or new.units_per_box is distinct from old.units_per_box then
      raise exception 'غير مصرّح: أسعار الشراء للمالك فقط';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists on_product_protect on public.products;
create trigger on_product_protect
  before update on public.products
  for each row execute function public.protect_product_sensitive_columns();

-- 4.5) تثبيت store_id على السجلات الجديدة (لا يمكن الكتابة في محل آخر)
create or replace function public.force_current_store()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_store uuid;
begin
  v_store := public.current_store_id();
  if v_store is null then
    -- لا يوجد ملف بعد: يُسمح فقط عند إنشاء المتجر الأول (يعالجها trigger منفصل)
    if coalesce(current_setting('hanoutk.system_write', true), 'off') = 'on' then
      return new;
    end if;
    raise exception 'لا يوجد حساب مرتبط بمحل لهذا المستخدم';
  end if;
  if tg_table_name = 'sale_items' then
    -- العنصر يتبع الفاتورة
    if new.store_id is distinct from (select s.store_id from public.sales s where s.id = new.sale_id) then
      raise exception 'غير مصرّح: الفاتورة لا تنتمي إلى هذا المحل';
    end if;
    new.store_id := (select s.store_id from public.sales s where s.id = new.sale_id);
  else
    if new.store_id is distinct from v_store then
      raise exception 'غير مصرّح: لا يمكن الكتابة في بيانات محل آخر';
    end if;
    new.store_id := v_store;
  end if;
  return new;
end;
$$;

drop trigger if exists on_products_force_store on public.products;
create trigger on_products_force_store before insert on public.products for each row execute function public.force_current_store();
drop trigger if exists on_customers_force_store on public.customers;
create trigger on_customers_force_store before insert on public.customers for each row execute function public.force_current_store();
drop trigger if exists on_sales_force_store on public.sales;
create trigger on_sales_force_store before insert on public.sales for each row execute function public.force_current_store();
drop trigger if exists on_expenses_force_store on public.expenses;
create trigger on_expenses_force_store before insert on public.expenses for each row execute function public.force_current_store();
drop trigger if exists on_payments_force_store on public.payments;
create trigger on_payments_force_store before insert on public.payments for each row execute function public.force_current_store();
drop trigger if exists on_activity_force_store on public.activity;
create trigger on_activity_force_store before insert on public.activity for each row execute function public.force_current_store();
drop trigger if exists on_categories_force_store on public.categories;
create trigger on_categories_force_store before insert on public.categories for each row execute function public.force_current_store();
drop trigger if exists on_sale_items_force_store on public.sale_items;
create trigger on_sale_items_force_store before insert on public.sale_items for each row execute function public.force_current_store();

-- 4.6) عند إضافة عنصر لفاتورة: التكلفة من قاعدة البيانات + خصم المخزون + تحديث الفاتورة
--      (قبل الإدراج: نمنع تزوير التكلفة ونتحقق من المحل — بعد الإدراج: نخصم المخزون ونحدّث الفاتورة)

create or replace function public.on_sale_item_before()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_product public.products%rowtype;
  v_sale    public.sales%rowtype;
  v_cost    numeric(12,2);
begin
  select * into v_sale from public.sales where id = new.sale_id;
  if v_sale.id is null then raise exception 'الفاتورة غير موجودة'; end if;

  select * into v_product from public.products where id = new.product_id;
  if v_product.id is null then raise exception 'المنتج غير موجود'; end if;

  -- عزل المحلات: المنتج يجب أن يكون من نفس محل الفاتورة
  if v_product.store_id <> v_sale.store_id then
    raise exception 'غير مصرّح: المنتج من محل آخر';
  end if;

  -- التكلفة تُؤخذ من المنتج دائمًا (لا يمكن تزويرها من العميل)
  if new.unit = 'box' then
    v_cost := coalesce(v_product.box_buy_price, 0);
  elsif coalesce(v_product.units_per_box, 1) > 1 and coalesce(v_product.box_buy_price, 0) > 0 then
    v_cost := round(v_product.box_buy_price / v_product.units_per_box, 2);
  else
    v_cost := coalesce(v_product.buy_price, 0);
  end if;
  new.buy_price := v_cost;
  new.units    := greatest(1, coalesce(new.units, 1));
  new.name     := coalesce(nullif(new.name, ''), v_product.name);
  new.barcode  := coalesce(nullif(new.barcode, ''), coalesce(v_product.barcode, ''));
  return new;
end;
$$;

create or replace function public.on_sale_item_after()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- خصم المخزون (كتابة النظام)
  perform set_config('hanoutk.system_write', 'on', true);
  update public.products
     set qty = greatest(0, qty - (new.qty * greatest(1, coalesce(new.units, 1)))),
         updated_at = now()
   where id = new.product_id;
  perform set_config('hanoutk.system_write', 'off', true);

  -- تحديث إجمالي وتكلفة الفاتورة
  update public.sales s
     set total = t.total,
         cost  = t.cost,
         due   = greatest(0, t.total - coalesce(s.paid, 0)),
         change = greatest(0, coalesce(s.paid, 0) - t.total),
         updated_at = now()
    from (select coalesce(sum(qty * price), 0) as total,
                 coalesce(sum(qty * buy_price), 0) as cost
            from public.sale_items where sale_id = new.sale_id) t
   where s.id = new.sale_id;

  return new;
end;
$$;

drop trigger if exists on_sale_item_before on public.sale_items;
create trigger on_sale_item_before
  before insert on public.sale_items
  for each row execute function public.on_sale_item_before();

drop trigger if exists on_sale_item_created on public.sale_items;
create trigger on_sale_item_created
  after insert on public.sale_items
  for each row execute function public.on_sale_item_after();

-- 4.7) منع تعديل/حذف سطر فاتورة بعد الاعتماد (إلا للمالك ضمن نفس المحل)
create or replace function public.protect_sale_items()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_owner() then
    raise exception 'غير مصرّح: تعديل الفاتورة من المالك فقط';
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists on_sale_item_update on public.sale_items;
create trigger on_sale_item_update
  before update or delete on public.sale_items
  for each row execute function public.protect_sale_items();

-- 4.8) طوابع updated_at
do $$
declare
  t text;
begin
  foreach t in array array['stores','profiles','products','customers','sales','expenses','payments','categories']
  loop
    execute format('drop trigger if exists set_updated_at on public.%I', t);
    execute format('create trigger set_updated_at before update on public.%I for each row execute function public.set_updated_at()', t);
  end loop;
end;
$$;

-- =============================================================================
-- 5) تفعيل Row Level Security + السياسات
-- =============================================================================

alter table public.stores             enable row level security;
alter table public.profiles           enable row level security;
alter table public.staff_invitations  enable row level security;
alter table public.products           enable row level security;
alter table public.categories         enable row level security;
alter table public.customers          enable row level security;
alter table public.sales              enable row level security;
alter table public.sale_items         enable row level security;
alter table public.expenses           enable row level security;
alter table public.payments           enable row level security;
alter table public.activity           enable row level security;

-- ------------------------------ stores ------------------------------
drop policy if exists "members read own store" on public.stores;
create policy "members read own store" on public.stores
  for select to authenticated using (id = public.current_store_id());

drop policy if exists "owners update own store" on public.stores;
create policy "owners update own store" on public.stores
  for update to authenticated
  using (id = public.current_store_id() and public.is_owner())
  with check (id = public.current_store_id() and public.is_owner());

drop policy if exists "authenticated create store" on public.stores;
create policy "authenticated create store" on public.stores
  for insert to authenticated with check (true);

drop policy if exists "owners delete own store" on public.stores;
create policy "owners delete own store" on public.stores
  for delete to authenticated using (id = public.current_store_id() and public.is_owner());

-- ----------------------------- profiles -----------------------------
drop policy if exists "members read profiles of own store" on public.profiles;
create policy "members read profiles of own store" on public.profiles
  for select to authenticated using (store_id = public.current_store_id());

drop policy if exists "owners insert profiles" on public.profiles;
create policy "owners insert profiles" on public.profiles
  for insert to authenticated
  with check (store_id = public.current_store_id() and public.is_owner());

drop policy if exists "owners update profiles" on public.profiles;
create policy "owners update profiles" on public.profiles
  for update to authenticated
  using (store_id = public.current_store_id() and public.is_owner())
  with check (store_id = public.current_store_id() and public.is_owner());

drop policy if exists "users update own profile" on public.profiles;
create policy "users update own profile" on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and store_id = public.current_store_id());

drop policy if exists "owners delete profiles" on public.profiles;
create policy "owners delete profiles" on public.profiles
  for delete to authenticated using (store_id = public.current_store_id() and public.is_owner());

-- ------------------------ staff_invitations -------------------------
drop policy if exists "owners manage invitations" on public.staff_invitations;
create policy "owners manage invitations" on public.staff_invitations
  for all to authenticated
  using (store_id = public.current_store_id() and public.is_owner())
  with check (store_id = public.current_store_id() and public.is_owner());

-- ---------------------------- products ------------------------------
drop policy if exists "members read products" on public.products;
create policy "members read products" on public.products
  for select to authenticated using (store_id = public.current_store_id());

drop policy if exists "members insert products" on public.products;
create policy "members insert products" on public.products
  for insert to authenticated with check (store_id = public.current_store_id());

drop policy if exists "members update products" on public.products;
create policy "members update products" on public.products
  for update to authenticated
  using (store_id = public.current_store_id())
  with check (store_id = public.current_store_id());

drop policy if exists "owners delete products" on public.products;
create policy "owners delete products" on public.products
  for delete to authenticated using (store_id = public.current_store_id() and public.is_owner());

-- --------------------------- categories -----------------------------
drop policy if exists "members read categories" on public.categories;
create policy "members read categories" on public.categories
  for select to authenticated using (store_id = public.current_store_id());

drop policy if exists "members manage categories" on public.categories;
create policy "members manage categories" on public.categories
  for all to authenticated
  using (store_id = public.current_store_id())
  with check (store_id = public.current_store_id());

-- ---------------------------- customers -----------------------------
drop policy if exists "members read customers" on public.customers;
create policy "members read customers" on public.customers
  for select to authenticated using (store_id = public.current_store_id());

drop policy if exists "members insert customers" on public.customers;
create policy "members insert customers" on public.customers
  for insert to authenticated with check (store_id = public.current_store_id());

drop policy if exists "members update customers" on public.customers;
create policy "members update customers" on public.customers
  for update to authenticated
  using (store_id = public.current_store_id())
  with check (store_id = public.current_store_id());

drop policy if exists "members delete customers" on public.customers;
create policy "members delete customers" on public.customers
  for delete to authenticated using (store_id = public.current_store_id());

-- ------------------------------ sales -------------------------------
drop policy if exists "members read sales" on public.sales;
create policy "members read sales" on public.sales
  for select to authenticated using (store_id = public.current_store_id());

drop policy if exists "members insert sales" on public.sales;
create policy "members insert sales" on public.sales
  for insert to authenticated with check (store_id = public.current_store_id());

drop policy if exists "owners update sales" on public.sales;
create policy "owners update sales" on public.sales
  for update to authenticated
  using (store_id = public.current_store_id() and public.is_owner())
  with check (store_id = public.current_store_id() and public.is_owner());

drop policy if exists "owners or creator delete sales" on public.sales;
create policy "owners or creator delete sales" on public.sales
  for delete to authenticated
  using (store_id = public.current_store_id() and (public.is_owner() or created_by = auth.uid()));

-- ---------------------------- sale_items ----------------------------
drop policy if exists "members read sale items" on public.sale_items;
create policy "members read sale items" on public.sale_items
  for select to authenticated using (store_id = public.current_store_id());

drop policy if exists "members insert sale items" on public.sale_items;
create policy "members insert sale items" on public.sale_items
  for insert to authenticated with check (store_id = public.current_store_id());

drop policy if exists "owners delete sale items" on public.sale_items;
create policy "owners delete sale items" on public.sale_items
  for delete to authenticated using (store_id = public.current_store_id() and public.is_owner());

-- ---------------------------- expenses ------------------------------
-- المصاريف للمالك فقط (كما في hanoutk) — العامل لا يرى ولا يلمسها
drop policy if exists "owners read expenses" on public.expenses;
create policy "owners read expenses" on public.expenses
  for select to authenticated using (store_id = public.current_store_id() and public.is_owner());

drop policy if exists "owners insert expenses" on public.expenses;
create policy "owners insert expenses" on public.expenses
  for insert to authenticated
  with check (store_id = public.current_store_id() and public.is_owner());

drop policy if exists "owners update expenses" on public.expenses;
create policy "owners update expenses" on public.expenses
  for update to authenticated
  using (store_id = public.current_store_id() and public.is_owner())
  with check (store_id = public.current_store_id() and public.is_owner());

drop policy if exists "owners delete expenses" on public.expenses;
create policy "owners delete expenses" on public.expenses
  for delete to authenticated using (store_id = public.current_store_id() and public.is_owner());

-- ---------------------------- payments ------------------------------
drop policy if exists "members read payments" on public.payments;
create policy "members read payments" on public.payments
  for select to authenticated using (store_id = public.current_store_id());

drop policy if exists "members insert payments" on public.payments;
create policy "members insert payments" on public.payments
  for insert to authenticated with check (store_id = public.current_store_id());

drop policy if exists "members delete payments" on public.payments;
create policy "members delete payments" on public.payments
  for delete to authenticated using (store_id = public.current_store_id());

-- ---------------------------- activity ------------------------------
drop policy if exists "members read activity" on public.activity;
create policy "members read activity" on public.activity
  for select to authenticated using (store_id = public.current_store_id());

drop policy if exists "members insert activity" on public.activity;
create policy "members insert activity" on public.activity
  for insert to authenticated with check (store_id = public.current_store_id());

drop policy if exists "owners delete activity" on public.activity;
create policy "owners delete activity" on public.activity
  for delete to authenticated using (store_id = public.current_store_id() and public.is_owner());

-- =============================================================================
-- 6) الصلاحيات (Grants) + منع الوصول العام
-- =============================================================================

grant usage on schema public to authenticated, anon;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;

revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon;

alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges in schema public
  grant usage, select on sequences to authenticated;

-- =============================================================================
-- 7) عروض مساعدة (تعمل بنفس سياسات RLS thanks to security_invoker)
-- =============================================================================

create or replace view public.daily_sales_report
with (security_invoker = true)
as
select s.store_id,
       date_trunc('day', s.created_at) as day,
       count(*)                        as sales_count,
       coalesce(sum(s.total), 0)       as revenue,
       coalesce(sum(s.cost), 0)        as cost,
       coalesce(sum(s.total - s.cost), 0) as gross_profit,
       coalesce(sum(s.due), 0)         as credit_total
  from public.sales s
 group by s.store_id, date_trunc('day', s.created_at);

create or replace view public.product_stock_report
with (security_invoker = true)
as
select p.store_id,
       p.id,
       p.name,
       p.barcode,
       p.category,
       p.qty,
       case when p.units_per_box > 1
            then floor(p.qty / p.units_per_box) || ' علبة و' || (p.qty % p.units_per_box) || ' حبة'
            else p.qty::text || ' حبة' end as stock_label,
       p.min_stock,
       (p.qty <= p.min_stock) as is_low
  from public.products p;

commit;

-- =============================================================================
-- 8) ملاحظات التشغيل
-- =============================================================================
-- * كل استعلامات التطبيق يجب أن تمرّ عبر Supabase Auth (مفتاح anon) — لا يتمرّر
--   مفتاح service_role أبدًا (يمنح وصولًا كاملًا ويتجاوز RLS).
-- * الاتصال اللحظي: فعّل Realtime على الجداول sales / activity / products:
--     alter publication supabase_realtime add table public.sales, public.activity, public.products;
-- * للتجربة السريعة داخل SQL Editor:
--     select set_config('request.jwt.claim.sub', '<user-uuid>', false);
-- =============================================================================
