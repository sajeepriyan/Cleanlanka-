
begin;
create temp table audit_context(k text primary key,v uuid);
create temp table audit_results(check_name text,passed boolean);
grant select on audit_context to authenticated;
grant select,insert on audit_results to authenticated;
insert into audit_context values('worker',gen_random_uuid()),('customer',gen_random_uuid()),('outsider',gen_random_uuid()),('admin',(select user_id from public.admins where role='main_admin' and is_active=true limit 1));
insert into auth.users(id,email,raw_user_meta_data)
select v,v::text||'@audit.invalid',
case when k='worker' then '{"account_type":"worker","full_name":"Audit Worker","Phone":"0000000000","district":"Colombo","address":"Audit only","skills":"Cleaning","experience_years":1,"service_price_lkr":1000,"worker_legal_accepted":true,"worker_terms_version":"1.0","worker_privacy_version":"1.0"}'::jsonb
else '{"account_type":"customer","full_name":"Audit Customer","phone":"0000000000","district":"Colombo","address":"Audit only"}'::jsonb end
from audit_context where k in ('worker','customer','outsider');
insert into audit_results select 'unconfirmed_has_no_profile',not exists(select 1 from public.worker_profiles where user_id=(select v from audit_context where k='worker'));
update auth.users set email_confirmed_at=now() where id in(select v from audit_context where k in('worker','customer','outsider'));
insert into audit_context select 'worker_profile',id from public.worker_profiles where user_id=(select v from audit_context where k='worker');
insert into audit_results select 'confirmed_worker_pending',exists(select 1 from public.worker_profiles where user_id=(select v from audit_context where k='worker') and verification_status='pending' and not is_available);
insert into audit_results select 'confirmed_customer_profile',exists(select 1 from public.customer_profiles where user_id=(select v from audit_context where k='customer'));
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='worker'),'role','authenticated')::text,true);
set local role authenticated;
insert into audit_results select 'worker_reads_own_profile',count(*)=1 from public.worker_profiles where user_id=(select v from audit_context where k='worker');
do $$begin
 begin update public.worker_profiles set is_available=true where user_id=(select v from audit_context where k='worker');
 insert into audit_results values('pending_availability_blocked',false);
 exception when others then insert into audit_results values('pending_availability_blocked',true); end;
 begin update public.worker_profiles set verification_status='approved' where user_id=(select v from audit_context where k='worker');
 insert into audit_results values('worker_self_approval_blocked',false);
 exception when others then insert into audit_results values('worker_self_approval_blocked',true); end;
end$$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='admin'),'role','authenticated')::text,true);
set local role authenticated;
select public.admin_decide_worker((select v from audit_context where k='worker_profile'),'approve');
insert into audit_results select 'admin_approval_14_day_window',verification_status='approved' and temporary_booking_until>now() from public.worker_profiles where id=(select v from audit_context where k='worker_profile');
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='worker'),'role','authenticated')::text,true);
set local role authenticated;
update public.worker_profiles set is_available=true where user_id=(select v from audit_context where k='worker');
insert into audit_results select 'approved_worker_availability',is_available from public.worker_profiles where id=(select v from audit_context where k='worker_profile');
update public.worker_profiles set full_name='Audit Worker Edited' where user_id=(select v from audit_context where k='worker');
insert into audit_results select 'worker_profile_edit',full_name='Audit Worker Edited' from public.worker_profiles where id=(select v from audit_context where k='worker_profile');
reset role;
insert into audit_context values('job',gen_random_uuid()),('conversation',gen_random_uuid()),('application',gen_random_uuid());
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='customer'),'role','authenticated')::text,true);
set local role authenticated;
insert into public.job_posts(id,customer_id,service_title,description,district,address,budget_lkr,status,post_source)
select (select v from audit_context where k='job'),(select v from audit_context where k='customer'),'Audit Cleaning','Audit only','Colombo','Audit only',1000,'open','customer';
insert into public.conversations(id,customer_id,worker_id) select (select v from audit_context where k='conversation'),(select v from audit_context where k='customer'),(select v from audit_context where k='worker_profile');
insert into public.messages(conversation_id,sender_id,message) select (select v from audit_context where k='conversation'),(select v from audit_context where k='customer'),'Audit customer message';
insert into audit_results values('customer_job_and_conversation_create',true);
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='worker'),'role','authenticated')::text,true);
set local role authenticated;
insert into public.messages(conversation_id,sender_id,message) select (select v from audit_context where k='conversation'),(select v from audit_context where k='worker'),'Audit worker reply';
insert into audit_results select 'worker_reads_both_messages',count(*)=2 from public.messages where conversation_id=(select v from audit_context where k='conversation');
insert into public.job_applications(id,job_id,worker_id,message,status) select (select v from audit_context where k='application'),(select v from audit_context where k='job'),(select v from audit_context where k='worker_profile'),'Audit application','pending';
insert into audit_results values('eligible_worker_application',true);
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='outsider'),'role','authenticated')::text,true);
set local role authenticated;
insert into audit_results select 'outsider_cannot_read_chat',count(*)=0 from public.messages where conversation_id=(select v from audit_context where k='conversation');
do $$begin
 begin insert into public.messages(conversation_id,sender_id,message) select (select v from audit_context where k='conversation'),(select v from audit_context where k='outsider'),'Unauthorized test';
 insert into audit_results values('outsider_send_blocked',false);
 exception when insufficient_privilege then insert into audit_results values('outsider_send_blocked',true); end;
 begin perform public.accept_job_application((select v from audit_context where k='application'));
 insert into audit_results values('outsider_accept_blocked',false);
 exception when others then insert into audit_results values('outsider_accept_blocked',true); end;
end$$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='customer'),'role','authenticated')::text,true);
set local role authenticated;
insert into audit_results select 'customer_reads_worker_reply',count(*)=2 from public.messages where conversation_id=(select v from audit_context where k='conversation');
select public.accept_job_application((select v from audit_context where k='application'));
insert into audit_results select 'job_accept_assigns_job',status='assigned' from public.job_posts where id=(select v from audit_context where k='job');
reset role;

-- The same transaction checks notifications, calls and document/profile permissions.
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='customer'),'role','authenticated')::text,true);
set local role authenticated;
insert into audit_results select 'customer_message_notification',exists(select 1 from public.notifications where user_id=(select v from audit_context where k='customer') and related_conversation_id=(select v from audit_context where k='conversation'));
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='worker'),'role','authenticated')::text,true);
set local role authenticated;
insert into audit_results select 'worker_message_notification',exists(select 1 from public.notifications where user_id=(select v from audit_context where k='worker') and related_conversation_id=(select v from audit_context where k='conversation'));
do $$begin
 begin update public.worker_profiles set "Phone"='123' where user_id=(select v from audit_context where k='worker');
 insert into audit_results values('short_phone_rejected',false);
 exception when others then insert into audit_results values('short_phone_rejected',true); end;
end$$;
update public.worker_profiles set selfie_storage_path=(select v::text||'/selfie-1794845000000.jpg' from audit_context where k='worker') where user_id=(select v from audit_context where k='worker');
insert into audit_results select 'worker_selfie_path_save',selfie_storage_path is not null from public.worker_profiles where user_id=(select v from audit_context where k='worker');
update public.worker_profiles set police_clearance_path=(select v::text||'/police-clearance-1794845000000.pdf' from audit_context where k='worker') where user_id=(select v from audit_context where k='worker');
insert into audit_results select 'worker_document_path_save',police_clearance_path is not null and police_clearance_status='pending' from public.worker_profiles where user_id=(select v from audit_context where k='worker');
insert into audit_results select 'public_phone_privacy',phone is null from public.get_public_worker_profiles() where worker_id=(select v from audit_context where k='worker_profile');
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='customer'),'role','authenticated')::text,true);
set local role authenticated;
-- Only signalling is tested; no microphones, emails or external calls.
reset role;
insert into audit_context(k,v) select 'call',(public.cl_start_audio_call((select v from audit_context where k='conversation'),'v=0'||chr(13)||chr(10)||'m=audio 9 UDP/TLS/RTP/SAVPF 111'||chr(13)||chr(10))->>'id')::uuid;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='outsider'),'role','authenticated')::text,true);
set local role authenticated;
insert into audit_results select 'outsider_cannot_read_notifications',count(*)=0 from public.notifications where related_conversation_id=(select v from audit_context where k='conversation');
insert into audit_results select 'outsider_cannot_read_calls',count(*)=0 from public.cl_audio_calls where id=(select v from audit_context where k='call');
do $$begin
 begin perform public.cl_audio_call_action((select v from audit_context where k='call'),'accept','m=audio 9 UDP/TLS/RTP/SAVPF 111');
 insert into audit_results values('outsider_cannot_answer_call',false);
 exception when others then insert into audit_results values('outsider_cannot_answer_call',true); end;
end$$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='worker'),'role','authenticated')::text,true);
set local role authenticated;
select public.cl_audio_call_action((select v from audit_context where k='call'),'accept','v=0'||chr(13)||chr(10)||'m=audio 9 UDP/TLS/RTP/SAVPF 111'||chr(13)||chr(10));
insert into audit_results select 'worker_can_answer_call',status='accepted' from public.cl_audio_calls where id=(select v from audit_context where k='call');
select public.cl_audio_call_action((select v from audit_context where k='call'),'end',null);
insert into audit_results select 'call_end_clears_signalling',status='ended' and offer_sdp is null and answer_sdp is null from public.cl_audio_calls where id=(select v from audit_context where k='call');
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select v from audit_context where k='admin'),'role','authenticated')::text,true);
set local role authenticated;
select public.admin_decide_worker((select v from audit_context where k='worker_profile'),'more_info');
insert into audit_results select 'admin_more_info_hides_worker',not exists(select 1 from public.get_public_worker_profiles() where worker_id=(select v from audit_context where k='worker_profile'));
select public.admin_decide_worker((select v from audit_context where k='worker_profile'),'approve');
select public.admin_decide_worker((select v from audit_context where k='worker_profile'),'reject');
insert into audit_results select 'admin_rejection_disables_availability',verification_status='rejected' and not is_available from public.worker_profiles where id=(select v from audit_context where k='worker_profile');
select public.admin_decide_worker((select v from audit_context where k='worker_profile'),'approve');
insert into audit_results select 'admin_can_reverse_decision',verification_status='approved' from public.worker_profiles where id=(select v from audit_context where k='worker_profile');
reset role;
insert into audit_results select 'job_creation_timestamp_default',created_at is not null from public.job_posts where id=(select v from audit_context where k='job');
insert into audit_results select 'application_creation_timestamp_default',created_at is not null from public.job_applications where id=(select v from audit_context where k='application');
do $$begin if exists(select 1 from audit_results where passed is distinct from true) then raise exception 'Regression test failed'; end if; end$$;
select jsonb_agg(jsonb_build_object('check',check_name,'passed',passed)) as results from audit_results;
rollback;
