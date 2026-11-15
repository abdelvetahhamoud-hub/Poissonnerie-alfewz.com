-- ============================================================
-- مسمكة الفوز — Supabase schema (شغّله كاملاً في SQL Editor)
-- ============================================================
create extension if not exists pgcrypto;

-- ---------- الجداول ----------
create table public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  name text check (name is null or char_length(name) between 2 and 40),
  phone text not null unique check (phone ~ '^[234][0-9]{7}$'),
  role text not null default 'customer' check (role in ('customer','owner')),
  stars int not null default 0 check (stars >= 0),
  created_at timestamptz not null default now()
);

create table public.products(
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  category text not null default 'سمك طازج' check (char_length(category) <= 30),
  price int not null check (price > 0 and price <= 10000000),
  unit text not null default 'كغ' check (char_length(unit) <= 12),
  image_path text check (image_path is null or char_length(image_path) <= 200),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.settings(
  id int primary key check (id = 1),
  whatsapp text check (whatsapp is null or whatsapp ~ '^[234][0-9]{7}$'),
  pay_number text check (pay_number is null or pay_number ~ '^[234][0-9]{7}$')
);
insert into public.settings(id, whatsapp) values (1, '44631654') on conflict do nothing;

create table public.orders(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  phone text not null,
  total int not null default 0 check (total >= 0),
  pay_method text not null check (pay_method in ('cash','bankily','masrvi','sedad')),
  tx_ref text check (tx_ref is null or tx_ref ~ '^[A-Za-z0-9]{4,30}$'),
  receipt_path text,
  status text not null default 'new' check (status in ('new','confirmed','cancelled')),
  created_at timestamptz not null default now()
);
-- رقم العملية لا يُستخدم مرتين (يمنع إعادة استخدام نفس الإشعار)
create unique index orders_tx_ref_uq on public.orders (lower(tx_ref)) where tx_ref is not null;
create index orders_user_idx on public.orders (user_id, created_at desc);

create table public.order_items(
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  name text not null,
  price int not null,
  qty int not null check (qty between 1 and 99)
);

create table public.audit_log(
  id bigint generated always as identity primary key,
  actor uuid,
  action text not null,
  detail text,
  created_at timestamptz not null default now()
);

-- ---------- دوال مساعدة ----------
create or replace function public.is_owner() returns boolean
language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'owner');
$$;
revoke all on function public.is_owner() from public;
grant execute on function public.is_owner() to anon, authenticated;

-- أرقام موريتانية فقط (+222) عند إنشاء الحساب
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.phone is null or new.phone !~ '^\+?222[234][0-9]{7}$' then
    raise exception 'Only Mauritanian numbers (+222) are allowed';
  end if;
  insert into public.profiles(id, phone) values (new.id, right(new.phone, 8));
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- سجل تلقائي لتغييرات المنتجات والإعدادات
create or replace function public.log_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log(actor, action, detail)
  values (auth.uid(), tg_table_name || ':' || lower(tg_op),
          case when tg_op = 'DELETE' then old.id::text else new.id::text end);
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
create trigger products_audit after insert or update or delete on public.products
  for each row execute function public.log_change();
create trigger settings_audit after insert or update or delete on public.settings
  for each row execute function public.log_change();

-- ---------- إنشاء الطلب (السعر يُحسب هنا من قاعدة البيانات لا من المتصفح) ----------
create or replace function public.create_order(p_items jsonb, p_pay text, p_ref text, p_receipt text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  prof public.profiles;
  prod public.products;
  oid uuid;
  tot int := 0;
  it jsonb;
  q int;
begin
  if uid is null then raise exception 'not_authenticated'; end if;
  select * into prof from public.profiles where id = uid;
  if not found or prof.name is null then raise exception 'profile_incomplete'; end if;
  if p_pay not in ('cash','bankily','masrvi','sedad') then raise exception 'bad_pay'; end if;
  if exists (select 1 from public.orders where user_id = uid and created_at > now() - interval '20 seconds') then
    raise exception 'too_fast';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or not (jsonb_array_length(p_items) between 1 and 30) then
    raise exception 'bad_items';
  end if;
  if p_pay <> 'cash' then
    if p_ref is null or p_ref !~ '^[A-Za-z0-9]{4,30}$' then raise exception 'bad_ref'; end if;
    if p_receipt is null or split_part(p_receipt, '/', 1) <> uid::text
       or not exists (select 1 from storage.objects where bucket_id = 'receipts' and name = p_receipt) then
      raise exception 'bad_receipt';
    end if;
  end if;

  begin
    insert into public.orders(user_id, name, phone, total, pay_method, tx_ref, receipt_path)
    values (uid, prof.name, prof.phone, 0, p_pay,
            case when p_pay = 'cash' then null else p_ref end,
            case when p_pay = 'cash' then null else p_receipt end)
    returning id into oid;
  exception when unique_violation then
    raise exception 'dup_ref';
  end;

  for it in select * from jsonb_array_elements(p_items) loop
    q := (it->>'qty')::int;
    if q is null or q < 1 or q > 99 then raise exception 'bad_qty'; end if;
    select * into prod from public.products where id = (it->>'product_id')::uuid and active;
    if not found then raise exception 'bad_product'; end if;
    insert into public.order_items(order_id, product_id, name, price, qty)
    values (oid, prod.id, prod.name, prod.price, q);
    tot := tot + prod.price * q;
  end loop;

  update public.orders set total = tot where id = oid;
  return oid;
end $$;

-- ---------- تأكيد الطلب وإضافة النجوم (المالك فقط) ----------
create or replace function public.confirm_order(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  if not public.is_owner() then raise exception 'forbidden'; end if;
  select * into o from public.orders where id = p_order for update;
  if not found or o.status <> 'new' then raise exception 'bad_state'; end if;
  update public.orders set status = 'confirmed' where id = p_order;
  update public.profiles set stars = stars + floor(o.total / 1000.0)::int where id = o.user_id;
  insert into public.audit_log(actor, action, detail) values (auth.uid(), 'confirm_order', p_order::text);
end $$;

-- ---------- تسليم هدية: يخصم 10 نجوم (المالك فقط) ----------
create or replace function public.redeem_gift(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_owner() then raise exception 'forbidden'; end if;
  update public.profiles set stars = stars - 10 where id = p_user and stars >= 10;
  if not found then raise exception 'not_enough_stars'; end if;
  insert into public.audit_log(actor, action, detail) values (auth.uid(), 'redeem_gift', p_user::text);
end $$;

revoke all on function public.create_order(jsonb, text, text, text) from public, anon;
revoke all on function public.confirm_order(uuid) from public, anon;
revoke all on function public.redeem_gift(uuid) from public, anon;
grant execute on function public.create_order(jsonb, text, text, text) to authenticated;
grant execute on function public.confirm_order(uuid) to authenticated;
grant execute on function public.redeem_gift(uuid) to authenticated;

-- ---------- الصلاحيات على مستوى الصفوف (RLS) ----------
alter table public.profiles    enable row level security;
alter table public.products    enable row level security;
alter table public.settings    enable row level security;
alter table public.orders      enable row level security;
alter table public.order_items enable row level security;
alter table public.audit_log   enable row level security;

-- لا كتابة مباشرة من المتصفح إلا ما يُسمح به أدناه
revoke insert, update, delete on public.orders, public.order_items, public.audit_log from anon, authenticated;
revoke insert, delete on public.profiles from anon, authenticated;
revoke update on public.profiles from anon, authenticated;
grant update (name) on public.profiles to authenticated;   -- الزبون يعدّل اسمه فقط، لا النجوم ولا الدور
revoke insert, update, delete on public.products, public.settings from anon;

create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_owner());
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy products_select on public.products for select to anon, authenticated
  using (active or public.is_owner());
create policy products_insert on public.products for insert to authenticated with check (public.is_owner());
create policy products_update on public.products for update to authenticated
  using (public.is_owner()) with check (public.is_owner());
create policy products_delete on public.products for delete to authenticated using (public.is_owner());

create policy settings_select on public.settings for select to anon, authenticated using (true);
create policy settings_insert on public.settings for insert to authenticated with check (public.is_owner());
create policy settings_update on public.settings for update to authenticated
  using (public.is_owner()) with check (public.is_owner());

create policy orders_select on public.orders for select to authenticated
  using (user_id = auth.uid() or public.is_owner());
create policy items_select on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and (o.user_id = auth.uid() or public.is_owner())));
create policy audit_select on public.audit_log for select to authenticated using (public.is_owner());

-- ---------- التخزين (الصور) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('product-images', 'product-images', true,  3145728, array['image/jpeg','image/png','image/webp']),
  ('receipts',       'receipts',       false, 2097152, array['image/jpeg'])
on conflict (id) do nothing;

create policy product_images_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'product-images' and public.is_owner());
create policy product_images_update on storage.objects for update to authenticated
  using (bucket_id = 'product-images' and public.is_owner());
create policy product_images_delete on storage.objects for delete to authenticated
  using (bucket_id = 'product-images' and public.is_owner());

create policy receipts_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and (storage.foldername(name))[1] = auth.uid()::text);
create policy receipts_select on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_owner()));

-- ---------- منتجات أولية (اختياري) ----------
insert into public.products (name, category, price, unit) values
 ('كربين','سمك طازج',4500,'كغ'),('أنكط','سمك طازج',2500,'كغ'),('كبار','سمك طازج',2000,'كغ'),
 ('ياي بوي','سمك طازج',1000,'كغ'),('تواجيت','سمك طازج',1200,'كغ'),('بنضه','سمك طازج',1000,'كغ'),
 ('بيرو','سمك طازج',2500,'كغ'),('خصو','سمك طازج',3000,'كغ'),('كلمار','أخطبوط وحبار',3500,'كغ'),
 ('كرفت','سمك طازج',4500,'كغ'),('بايلا','سمك طازج',1800,'كغ'),('يربله','سمك طازج',2800,'كغ'),
 ('لمليس','سمك طازج',2400,'كغ'),('ولص','سمك طازج',1300,'كغ');
