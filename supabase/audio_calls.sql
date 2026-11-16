begin;
create schema if not exists cl_call_private;
revoke all on schema cl_call_private from public, anon;
grant usage on schema cl_call_private to authenticated;

create table public.cl_audio_calls (
 id uuid primary key default gen_random_uuid(),
 conversation_id uuid not null references public.conversations(id) on delete cascade,
 caller_id uuid not null references auth.users(id) on delete cascade,
 callee_id uuid not null references auth.users(id) on delete cascade,
 caller_name text not null,
 callee_name text not null,
 status text not null default 'ringing' check(status in ('ringing','accepted','ended','declined','missed','busy','cancelled','failed')),
 offer_sdp text,
 answer_sdp text,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default now()+interval '60 seconds',
 answered_at timestamptz,
 ended_at timestamptz,
 caller_seen_at timestamptz not null default now(),
 callee_seen_at timestamptz not null default now(),
 check(caller_id<>callee_id),
 check(length(offer_sdp)<=65536),
 check(length(answer_sdp)<=65536)
);
create index cl_audio_calls_caller_created on public.cl_audio_calls(caller_id,created_at desc);
create index cl_audio_calls_callee_created on public.cl_audio_calls(callee_id,created_at desc);
create index cl_audio_calls_conversation_created on public.cl_audio_calls(conversation_id,created_at desc);
alter table public.cl_audio_calls enable row level security;
revoke all on public.cl_audio_calls from public,anon,authenticated;
grant select on public.cl_audio_calls to authenticated;
create policy cl_audio_participants_read on public.cl_audio_calls for select to authenticated
 using((select auth.uid())=caller_id or (select auth.uid())=callee_id);

create table public.cl_audio_call_candidates (
 id bigint generated always as identity primary key,
 call_id uuid not null references public.cl_audio_calls(id) on delete cascade,
 sender_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
 candidate jsonb not null check(jsonb_typeof(candidate)='object' and octet_length(candidate::text)<=8192),
 created_at timestamptz not null default now()
);
create index cl_audio_candidates_call_id on public.cl_audio_call_candidates(call_id,id);
create index cl_audio_candidates_sender on public.cl_audio_call_candidates(sender_id);
alter table public.cl_audio_call_candidates enable row level security;
revoke all on public.cl_audio_call_candidates from public,anon,authenticated;
grant select on public.cl_audio_call_candidates to authenticated;
grant insert(call_id,candidate) on public.cl_audio_call_candidates to authenticated;
grant usage on sequence public.cl_audio_call_candidates_id_seq to authenticated;
create policy cl_audio_candidates_read on public.cl_audio_call_candidates for select to authenticated using(
 exists(select 1 from public.cl_audio_calls c where c.id=call_id and ((select auth.uid())=c.caller_id or (select auth.uid())=c.callee_id)));
create policy cl_audio_candidates_send on public.cl_audio_call_candidates for insert to authenticated with check(
 sender_id=(select auth.uid()) and exists(select 1 from public.cl_audio_calls c where c.id=call_id
 and ((select auth.uid())=c.caller_id or (select auth.uid())=c.callee_id)
 and (c.status='accepted' or (c.status='ringing' and c.expires_at>now()))));

create function cl_call_private.limit_candidates() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or new.sender_id<>auth.uid() then raise exception 'Sign in to signal a call.' using errcode='42501'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.call_id::text||new.sender_id::text,17));
 if (select count(*) from public.cl_audio_call_candidates where call_id=new.call_id and sender_id=new.sender_id)>=128 then
  raise exception 'Call signalling limit reached.';
 end if;
 return new;
end; $$;
revoke all on function cl_call_private.limit_candidates() from public,anon,authenticated;
create trigger cl_audio_limit_candidates before insert on public.cl_audio_call_candidates for each row execute function cl_call_private.limit_candidates();

create function cl_call_private.start_call(p_conversation_id uuid,p_offer text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 v_user uuid:=auth.uid(); v_customer uuid; v_worker uuid; v_customer_name text; v_worker_name text;
 v_other uuid; v_row public.cl_audio_calls; v_stale_ids uuid[];
begin
 if v_user is null or not exists(select 1 from auth.users where id=v_user and email_confirmed_at is not null) then
  raise exception 'Sign in with your confirmed account to call.' using errcode='42501';
 end if;
 if p_offer is null or length(p_offer)>65536 or position('m=audio' in p_offer)=0 or position('m=video' in p_offer)>0 then
  raise exception 'An audio-only call offer is required.';
 end if;
 select c.customer_id,w.user_id,coalesce(nullif(trim(cp.full_name),''),'Customer'),coalesce(nullif(trim(w.full_name),''),'Worker')
 into v_customer,v_worker,v_customer_name,v_worker_name
 from public.conversations c join public.worker_profiles w on w.id=c.worker_id
 left join lateral(select full_name from public.customer_profiles where user_id=c.customer_id or id=c.customer_id order by (id=c.customer_id) desc limit 1) cp on true
 where c.id=p_conversation_id and (c.customer_id=v_user or w.user_id=v_user);
 if v_customer is null or v_worker is null then raise exception 'This conversation is not available to your account.' using errcode='42501'; end if;
 v_other:=case when v_user=v_customer then v_worker else v_customer end;
 if v_other=v_user then raise exception 'You cannot call yourself.'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(least(v_user::text,v_other::text),19));
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(greatest(v_user::text,v_other::text),19));
 with stale as (
  update public.cl_audio_calls set status=case when status='ringing' then 'missed' else 'ended' end,
   ended_at=now(),offer_sdp=null,answer_sdp=null
  where (caller_id in(v_user,v_other) or callee_id in(v_user,v_other)) and
   ((status='ringing' and expires_at<=now()) or (status='accepted' and
    (least(caller_seen_at,callee_seen_at)<now()-interval '60 seconds' or answered_at<now()-interval '2 hours')))
  returning id
 ) select array_agg(id) into v_stale_ids from stale;
 delete from public.cl_audio_call_candidates where call_id=any(v_stale_ids);
 if exists(select 1 from public.cl_audio_calls where status in('ringing','accepted') and
  (caller_id in(v_user,v_other) or callee_id in(v_user,v_other))) then
  raise exception 'You or this person are already on another call. Please try again.' using errcode='P0001';
 end if;
 if (select count(*) from public.cl_audio_calls where caller_id=v_user and created_at>now()-interval '1 minute')>=3
  or (select count(*) from public.cl_audio_calls where caller_id=v_user and created_at>now()-interval '1 hour')>=60 then
  raise exception 'Please wait before making another call.';
 end if;
 insert into public.cl_audio_calls(conversation_id,caller_id,callee_id,caller_name,callee_name,offer_sdp)
 values(p_conversation_id,v_user,v_other,
  case when v_user=v_customer then v_customer_name else v_worker_name end,
  case when v_user=v_customer then v_worker_name else v_customer_name end,p_offer) returning * into v_row;
 return to_jsonb(v_row);
end; $$;

create function cl_call_private.act_on_call(p_call_id uuid,p_action text,p_answer text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_user uuid:=auth.uid(); v_row public.cl_audio_calls; v_status text;
begin
 if v_user is null then raise exception 'Please sign in.' using errcode='42501'; end if;
 select * into v_row from public.cl_audio_calls where id=p_call_id for update;
 if v_row.id is null or v_user not in(v_row.caller_id,v_row.callee_id) then
  raise exception 'This call is not available to your account.' using errcode='42501';
 end if;
 if p_action not in('accept','decline','cancel','end','fail','ping','timeout') or p_action is null then raise exception 'Unknown call action.'; end if;
 if v_row.status not in('ringing','accepted') then return to_jsonb(v_row); end if;
 if v_row.status='ringing' and v_row.expires_at<=now() then v_status:='missed';
 elsif v_row.status='accepted' and (v_row.answered_at<now()-interval '2 hours' or
   (case when v_user=v_row.caller_id then v_row.callee_seen_at else v_row.caller_seen_at end)<now()-interval '60 seconds') then v_status:='ended';
 elsif p_action='ping' then
  update public.cl_audio_calls set caller_seen_at=case when v_user=caller_id then now() else caller_seen_at end,
   callee_seen_at=case when v_user=callee_id then now() else callee_seen_at end where id=p_call_id returning * into v_row;
  return to_jsonb(v_row);
 elsif p_action='timeout' then return to_jsonb(v_row);
 elsif p_action='accept' then
  if v_user<>v_row.callee_id then raise exception 'Only the called person can answer.' using errcode='42501'; end if;
  if v_row.status='accepted' then return to_jsonb(v_row); end if;
  if p_answer is null or length(p_answer)>65536 or position('m=audio' in p_answer)=0 or position('m=video' in p_answer)>0 then
   raise exception 'An audio-only answer is required.';
  end if;
  update public.cl_audio_calls set status='accepted',answer_sdp=p_answer,answered_at=now(),callee_seen_at=now()
   where id=p_call_id returning * into v_row;
  return to_jsonb(v_row);
 elsif p_action='decline' then
  if v_user<>v_row.callee_id or v_row.status<>'ringing' then raise exception 'Only an incoming ringing call can be declined.' using errcode='42501'; end if;
  v_status:='declined';
 elsif p_action='cancel' then
  if v_user<>v_row.caller_id or v_row.status<>'ringing' then raise exception 'Only your outgoing ringing call can be cancelled.' using errcode='42501'; end if;
  v_status:='cancelled';
 elsif p_action='end' then v_status:=case when v_row.status='accepted' then 'ended' when v_user=v_row.caller_id then 'cancelled' else 'declined' end;
 elsif p_action='fail' then v_status:='failed';
 end if;
 update public.cl_audio_calls set status=v_status,ended_at=now(),offer_sdp=null,answer_sdp=null where id=p_call_id returning * into v_row;
 delete from public.cl_audio_call_candidates where call_id=p_call_id;
 return to_jsonb(v_row);
end; $$;
revoke all on function cl_call_private.start_call(uuid,text),cl_call_private.act_on_call(uuid,text,text) from public,anon;
grant execute on function cl_call_private.start_call(uuid,text),cl_call_private.act_on_call(uuid,text,text) to authenticated;

create function public.cl_start_audio_call(p_conversation_id uuid,p_offer text) returns jsonb language sql security invoker set search_path=''
 as $$select cl_call_private.start_call(p_conversation_id,p_offer);$$;
create function public.cl_audio_call_action(p_call_id uuid,p_action text,p_answer text default null) returns jsonb language sql security invoker set search_path=''
 as $$select cl_call_private.act_on_call(p_call_id,p_action,p_answer);$$;
revoke all on function public.cl_start_audio_call(uuid,text),public.cl_audio_call_action(uuid,text,text) from public,anon;
grant execute on function public.cl_start_audio_call(uuid,text),public.cl_audio_call_action(uuid,text,text) to authenticated;

-- Operations can supply a TURN relay here without putting credentials in HTML.
create table cl_call_private.rtc_config (
 id boolean primary key default true check(id),
 ice_servers jsonb not null check(jsonb_typeof(ice_servers)='array')
);
alter table cl_call_private.rtc_config enable row level security;
revoke all on cl_call_private.rtc_config from public,anon,authenticated;
create policy cl_rtc_config_no_client_access on cl_call_private.rtc_config for all to authenticated using(false) with check(false);
insert into cl_call_private.rtc_config(id,ice_servers) values(true,
 '[{"urls":"stun:stun.cloudflare.com:3478"},{"urls":"stun:stun.l.google.com:19302"}]'::jsonb);
create function cl_call_private.ice_config() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Please sign in.' using errcode='42501'; end if;
 return (select ice_servers from cl_call_private.rtc_config where id);
end; $$;
revoke all on function cl_call_private.ice_config() from public,anon;
grant execute on function cl_call_private.ice_config() to authenticated;
create function public.cl_audio_ice_config() returns jsonb language sql stable security invoker set search_path=''
 as $$select cl_call_private.ice_config();$$;
revoke all on function public.cl_audio_ice_config() from public,anon;
grant execute on function public.cl_audio_ice_config() to authenticated;

do $$begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='cl_audio_calls') then
  alter publication supabase_realtime add table public.cl_audio_calls;
 end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='cl_audio_call_candidates') then
  alter publication supabase_realtime add table public.cl_audio_call_candidates;
 end if;
end; $$;
commit;
