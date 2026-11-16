begin;
create temporary table cl_audio_fixture as
 select c.id conversation_id,c.customer_id,w.user_id worker_user_id
 from public.conversations c join public.worker_profiles w on w.id=c.worker_id
 join auth.users a on a.id=c.customer_id join auth.users b on b.id=w.user_id
 where a.email_confirmed_at is not null and b.email_confirmed_at is not null and c.customer_id<>w.user_id limit 1;
grant select on cl_audio_fixture to authenticated;
set local role authenticated;
do $$
declare f record; v_call_id uuid; payload jsonb; blocked boolean; n integer;
begin
 select * into f from cl_audio_fixture;
 if f.conversation_id is null then raise exception 'No confirmed conversation fixture available'; end if;
 perform set_config('request.jwt.claim.sub',f.customer_id::text,true);
 payload:=public.cl_start_audio_call(f.conversation_id,E'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n');
 v_call_id:=(payload->>'id')::uuid;
 if payload->>'status'<>'ringing' or (payload->>'caller_id')::uuid<>f.customer_id or (payload->>'callee_id')::uuid<>f.worker_user_id
 or length(payload->>'caller_name')=0 or length(payload->>'callee_name')=0 then raise exception 'Call participant/name validation failed'; end if;
 insert into public.cl_audio_call_candidates(call_id,candidate) values(v_call_id,'{"candidate":"candidate:test","sdpMid":"0"}'::jsonb);
 blocked:=false;
 begin perform public.cl_audio_call_action(v_call_id,'accept','m=audio'); exception when insufficient_privilege then blocked:=true; end;
 if not blocked then raise exception 'Caller was allowed to accept their own outgoing call'; end if;
 blocked:=false;
 begin perform public.cl_start_audio_call(f.conversation_id,'m=audio'); exception when raise_exception then blocked:=true; end;
 if not blocked then raise exception 'Concurrent call was allowed'; end if;
 perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 select count(*) into n from public.cl_audio_calls where id=v_call_id;
 if n<>0 then raise exception 'Unrelated account could read call'; end if;
 select count(*) into n from public.cl_audio_call_candidates c where c.call_id=v_call_id;
 if n<>0 then raise exception 'Unrelated account could read network candidates'; end if;
 blocked:=false;
 begin perform public.cl_audio_call_action(v_call_id,'end'); exception when insufficient_privilege then blocked:=true; end;
 if not blocked then raise exception 'Unrelated account could end call'; end if;
 blocked:=false;
 begin insert into public.cl_audio_call_candidates(call_id,candidate) values(v_call_id,'{}'); exception when insufficient_privilege then blocked:=true; end;
 if not blocked then raise exception 'Unrelated account could signal call'; end if;
 perform set_config('request.jwt.claim.sub',f.worker_user_id::text,true);
 payload:=public.cl_audio_call_action(v_call_id,'accept',E'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n');
 if payload->>'status'<>'accepted' or payload->>'answer_sdp' is null then raise exception 'Callee could not accept'; end if;
 perform set_config('request.jwt.claim.sub',f.customer_id::text,true);
 payload:=public.cl_audio_call_action(v_call_id,'end');
 if payload->>'status'<>'ended' or payload->>'offer_sdp' is not null or payload->>'answer_sdp' is not null then raise exception 'Call did not end/clear network metadata'; end if;
 select count(*) into n from public.cl_audio_call_candidates c where c.call_id=v_call_id;
 if n<>0 then raise exception 'Ended call candidates were not deleted'; end if;
 payload:=public.cl_start_audio_call(f.conversation_id,'m=audio');v_call_id:=(payload->>'id')::uuid;
 perform set_config('request.jwt.claim.sub',f.worker_user_id::text,true);
 payload:=public.cl_audio_call_action(v_call_id,'decline');
 if payload->>'status'<>'declined' then raise exception 'Decline failed'; end if;
 payload:=public.cl_start_audio_call(f.conversation_id,'m=audio');v_call_id:=(payload->>'id')::uuid;
 if (payload->>'caller_id')::uuid<>f.worker_user_id then raise exception 'Worker could not initiate a call'; end if;
 payload:=public.cl_audio_call_action(v_call_id,'cancel');
 if payload->>'status'<>'cancelled' then raise exception 'Cancel failed'; end if;
end; $$;
reset role;
rollback;
select 'Passed: named calls in both directions, accept/decline/cancel/end, busy protection, unrelated-user RLS denial, candidate cleanup. All fixture changes rolled back; no real calls sent.' as verification;
