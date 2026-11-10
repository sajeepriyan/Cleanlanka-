-- All test adverts, messages, notifications, applications and temporary profile changes roll back.
BEGIN;
DO $$
DECLARE
 customer_user uuid; worker_user uuid; worker_profile uuid; admin_user uuid;
 private_job uuid; official_job uuid; enquiry jsonb; official jsonb; applications_before bigint; last_message uuid; result jsonb;
BEGIN
 SELECT cp.user_id INTO customer_user FROM public.customer_profiles cp JOIN auth.users u ON u.id=cp.user_id WHERE u.email_confirmed_at IS NOT NULL LIMIT 1;
 SELECT w.user_id,w.id INTO worker_user,worker_profile FROM public.worker_profiles w JOIN auth.users u ON u.id=w.user_id WHERE u.email_confirmed_at IS NOT NULL AND w.user_id<>customer_user LIMIT 1;
 SELECT a.user_id INTO admin_user FROM public.admins a JOIN auth.users u ON u.id=a.user_id WHERE a.role='main_admin' AND a.is_active AND u.email_confirmed_at IS NOT NULL AND a.user_id<>worker_user LIMIT 1;
 ASSERT customer_user IS NOT NULL AND worker_user IS NOT NULL AND admin_user IS NOT NULL,'Required existing test identities unavailable';
 INSERT INTO public.job_posts(customer_id,service_title,description,district,address,budget_lkr,status,post_source,contact_phone,show_contact_phone,allow_whatsapp,salary_period,working_hours,benefits)
 VALUES(customer_user,'QA private-contact advert','Rollback-only contact test','Colombo','Colombo',2000,'open','customer','0770000000',false,false,'day','8 hours','Meals') RETURNING id INTO private_job;
 ASSERT (SELECT contact_phone IS NULL FROM public.get_public_job_ads() WHERE id=private_job),'Private number leaked through public RPC';
 UPDATE public.job_posts SET show_contact_phone=true,allow_whatsapp=true WHERE id=private_job;
 ASSERT (SELECT contact_phone='0770000000' AND allow_whatsapp FROM public.get_public_job_ads() WHERE id=private_job),'Opted-in contact missing';
 UPDATE public.job_posts SET show_contact_phone=false,allow_whatsapp=false WHERE id=private_job;
 BEGIN UPDATE public.job_posts SET allow_whatsapp=true WHERE id=private_job; RAISE EXCEPTION 'WhatsApp privacy constraint missing'; EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN UPDATE public.job_posts SET contact_phone='123' WHERE id=private_job; RAISE EXCEPTION 'Phone validation constraint missing'; EXCEPTION WHEN check_violation THEN NULL; END;
 ASSERT NOT has_function_privilege('anon','public.worker_job_chat(uuid,text)','EXECUTE'),'Anonymous chat access';
 ASSERT has_function_privilege('anon','public.get_public_job_ads()','EXECUTE'),'Anonymous ad browsing unavailable';
 ASSERT NOT has_table_privilege('authenticated','public.job_chat_links','INSERT'),'Direct job chat link insertion allowed';
 INSERT INTO public.job_posts(customer_id,service_title,description,district,address,status,post_source,publish_on,expires_on)
 VALUES(admin_user,'QA official-contact advert','Rollback-only official test','Colombo','Colombo','open','clean_lanka',(now() AT TIME ZONE 'Asia/Colombo')::date,(now() AT TIME ZONE 'Asia/Colombo')::date+1) RETURNING id INTO official_job;
 PERFORM set_config('request.jwt.claim.sub',admin_user::text,true);
 UPDATE public.worker_profiles SET verification_status='pending' WHERE id=worker_profile;
 PERFORM set_config('request.jwt.claim.sub',worker_user::text,true);
 SELECT count(*) INTO applications_before FROM public.job_applications;
 enquiry:=public.worker_job_chat(private_job,NULL);
 ASSERT enquiry->>'conversation_id' IS NULL OR EXISTS(SELECT 1 FROM public.conversations WHERE id=(enquiry->>'conversation_id')::uuid),'Invalid existing conversation';
 enquiry:=public.worker_job_chat(private_job,'What are the working hours?');
 ASSERT enquiry->>'conversation_id' IS NOT NULL,'Pending Worker cannot enquire';
 ASSERT (SELECT count(*) FROM public.job_applications)=applications_before,'Enquiry incorrectly created an application';
 BEGIN PERFORM public.worker_apply_to_job(private_job,'I want to apply'); RAISE EXCEPTION 'Pending Worker application unexpectedly permitted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT LIKE 'Approval, availability%' THEN RAISE; END IF; END;
 official:=public.worker_job_chat(official_job,'Can you explain the official job?');
 ASSERT EXISTS(SELECT 1 FROM public.job_chat_links WHERE job_id=official_job AND conversation_id=(official->>'conversation_id')::uuid),'Official conversation not linked';
 BEGIN PERFORM public.read_official_job_chat((official->>'conversation_id')::uuid); RAISE EXCEPTION 'Worker accessed Admin inbox RPC'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 PERFORM set_config('request.jwt.claim.sub',customer_user::text,true);
 ASSERT public.get_official_job_chats()='[]'::jsonb,'Customer accessed official inbox';
 BEGIN PERFORM public.send_official_job_message((official->>'conversation_id')::uuid,'Unauthorized reply'); RAISE EXCEPTION 'Customer impersonated official Admin'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 PERFORM set_config('request.jwt.claim.sub',admin_user::text,true);
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(public.get_official_job_chats()) row WHERE row->>'conversation_id'=official->>'conversation_id'),'Official Admin inbox missing enquiry';
 ASSERT (SELECT count(*) FROM public.read_official_job_chat((official->>'conversation_id')::uuid))>=1,'Admin cannot read enquiry';
 BEGIN PERFORM public.read_official_job_chat((enquiry->>'conversation_id')::uuid); RAISE EXCEPTION 'Official inbox leaked customer chat'; EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 last_message:=public.send_official_job_message((official->>'conversation_id')::uuid,'Clean Lanka reply');
 ASSERT EXISTS(SELECT 1 FROM public.messages WHERE id=last_message AND sender_id=admin_user),'Admin reply not recorded with actual sender';
 ASSERT EXISTS(SELECT 1 FROM public.notifications WHERE user_id=worker_user AND related_conversation_id=(official->>'conversation_id')::uuid),'Worker reply notification missing';
 UPDATE public.worker_profiles SET verification_status='approved',is_available=true,police_clearance_status='verified' WHERE id=worker_profile;
 PERFORM set_config('request.jwt.claim.sub',worker_user::text,true);
 result:=public.worker_apply_to_job(private_job,'My formal application');
 ASSERT (SELECT count(*) FROM public.job_applications WHERE job_id=private_job AND worker_id=worker_profile)=1,'Explicit application missing';
 PERFORM public.worker_apply_to_job(private_job,'Follow-up application');
 ASSERT (SELECT count(*) FROM public.job_applications WHERE job_id=private_job AND worker_id=worker_profile)=1,'Duplicate application created';
END $$;
ROLLBACK;
