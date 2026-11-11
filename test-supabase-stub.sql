-- أدوار Supabase
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
end;
$$;

grant usage on schema public to authenticated, anon;

-- محاكاة بيئة Supabase للاختبار: مخطط auth + auth.uid()
create schema if not exists auth;

do $$
begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace where t.typname = 'auth_user' and n.nspname = 'auth') then
    create type auth.auth_user as (
      id uuid,
      email text,
      raw_user_meta_data jsonb
    );
  end if;
  if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where c.relname = 'users' and n.nspname = 'auth') then
    create table auth.users (
      id uuid primary key,
      email text,
      raw_user_meta_data jsonb default '{}'::jsonb
    );
  end if;
end;
$$;

-- auth.uid() في Supabase يقرأ من طلب JWT؛ هنا نقرأ من GUC للاختبار
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;
