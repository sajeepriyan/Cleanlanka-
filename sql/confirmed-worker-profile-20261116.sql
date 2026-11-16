
create schema if not exists cl_registration_private;
revoke all on schema cl_registration_private from public, anon, authenticated;

create unique index worker_profiles_one_per_auth_user on public.worker_profiles(user_id) where user_id is not null;

create function cl_registration_private.ensure_confirmed_worker(u auth.users) returns void
language plpgsql security definer set search_path='' as $$
declare m jsonb := u.raw_user_meta_data; v_skills text[];
begin
 if u.email_confirmed_at is null or m->>'account_type' is distinct from 'worker' then return; end if;
 if not exists(select 1 from public.worker_legal_acceptances l where l.user_id=u.id) then return; end if;
 if nullif(btrim(m->>'full_name'),'') is null
    or nullif(btrim(m->>'district'),'') is null
    or nullif(btrim(m->>'address'),'') is null
    or coalesce(m->>'Phone','') !~ '^[0-9]{10}$' then return; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(u.id::text,2816));
 if exists(select 1 from public.worker_profiles w where w.user_id=u.id) then return; end if;
 if jsonb_typeof(m->'skills')='array' then
   select coalesce(array_agg(btrim(s)) filter(where btrim(s)<>''),'{}'::text[]) into v_skills
   from jsonb_array_elements_text(m->'skills') as a(s);
 else
   select coalesce(array_agg(btrim(s)) filter(where btrim(s)<>''),'{}'::text[]) into v_skills
   from unnest(string_to_array(coalesce(m->>'skills',''),',')) as a(s);
 end if;
 insert into public.worker_profiles
 (user_id,full_name,email,district,address,skills,experience_years,service_price_lkr,availability,"Phone",gender,
  verification_status,is_available,show_phone_publicly,police_clearance_status,gn_certificate_status)
 values
 (u.id,btrim(m->>'full_name'),u.email,btrim(m->>'district'),btrim(m->>'address'),v_skills,
  case when coalesce(m->>'experience_years','') ~ '^[0-9]{1,9}$' then (m->>'experience_years')::integer else 0 end,
  case when coalesce(m->>'service_price_lkr','') ~ '^[0-9]{1,12}([.][0-9]{1,2})?$' then (m->>'service_price_lkr')::numeric else 0 end,
  'Available',m->>'Phone',case when m->>'gender' in ('male','female','prefer_not_to_say') then m->>'gender' else null end,
  'pending',false,false,'pending','pending')
 on conflict (user_id) where user_id is not null do nothing;
end;
$$;
revoke all on function cl_registration_private.ensure_confirmed_worker(auth.users) from public,anon,authenticated;

create function cl_registration_private.on_worker_email_confirmed() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 perform cl_registration_private.ensure_confirmed_worker(new);
 return new;
end;
$$;
revoke all on function cl_registration_private.on_worker_email_confirmed() from public,anon,authenticated;

create trigger zz_create_confirmed_worker_on_insert after insert on auth.users
for each row when (new.email_confirmed_at is not null)
execute function cl_registration_private.on_worker_email_confirmed();

create trigger zz_create_worker_on_email_confirmation after update of email_confirmed_at on auth.users
for each row when (old.email_confirmed_at is null and new.email_confirmed_at is not null)
execute function cl_registration_private.on_worker_email_confirmed();

select cl_registration_private.ensure_confirmed_worker(u)
from auth.users u
where u.email_confirmed_at is not null and u.raw_user_meta_data->>'account_type'='worker'
and not exists(select 1 from public.worker_profiles w where w.user_id=u.id);
