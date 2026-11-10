-- Advertisers choose whether a dedicated job contact number is public.
ALTER TABLE public.job_posts
 ADD COLUMN contact_name text,
 ADD COLUMN contact_phone text,
 ADD COLUMN show_contact_phone boolean NOT NULL DEFAULT false,
 ADD COLUMN allow_whatsapp boolean NOT NULL DEFAULT false,
 ADD COLUMN salary_period text NOT NULL DEFAULT 'not_specified',
 ADD COLUMN working_hours text,
 ADD COLUMN experience_required text,
 ADD COLUMN benefits text,
 ADD CONSTRAINT job_ad_phone_valid CHECK (contact_phone IS NULL OR contact_phone ~ '^[0-9]{10}$'),
 ADD CONSTRAINT job_ad_public_phone_present CHECK (NOT show_contact_phone OR contact_phone IS NOT NULL),
 ADD CONSTRAINT job_ad_whatsapp_public CHECK (NOT allow_whatsapp OR show_contact_phone),
 ADD CONSTRAINT job_ad_salary_period_valid CHECK (salary_period IN ('not_specified','hour','day','month','job')),
 ADD CONSTRAINT job_ad_details_lengths CHECK (length(coalesce(contact_name,''))<=120 AND length(coalesce(working_hours,''))<=200 AND length(coalesce(experience_required,''))<=300 AND length(coalesce(benefits,''))<=1000);

CREATE OR REPLACE FUNCTION public.get_public_job_ads()
RETURNS TABLE(id uuid,service_title text,description text,district text,budget_lkr numeric,preferred_date date,created_at timestamptz,post_source text,contact_name text,contact_phone text,show_contact_phone boolean,allow_whatsapp boolean,salary_period text,working_hours text,experience_required text,benefits text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT j.id,j.service_title,j.description,j.district,j.budget_lkr,j.preferred_date,j.created_at,coalesce(j.post_source,'customer'),
 j.contact_name,CASE WHEN j.show_contact_phone THEN j.contact_phone ELSE NULL END,
 j.show_contact_phone,j.allow_whatsapp AND j.show_contact_phone,j.salary_period,j.working_hours,j.experience_required,j.benefits
 FROM public.job_posts j JOIN public.get_public_job_posts() p ON p.id=j.id
 ORDER BY j.created_at DESC LIMIT 100;
$$;
REVOKE ALL ON FUNCTION public.get_public_job_ads() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_job_ads() TO anon,authenticated;

CREATE TABLE public.job_chat_links (
 job_id uuid NOT NULL REFERENCES public.job_posts(id) ON DELETE CASCADE,
 conversation_id uuid NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(job_id,conversation_id)
);
CREATE INDEX job_chat_links_conversation_idx ON public.job_chat_links(conversation_id);
ALTER TABLE public.job_chat_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.job_chat_links FROM anon,authenticated;
GRANT SELECT ON public.job_chat_links TO authenticated;
CREATE POLICY "Participants view job chat links" ON public.job_chat_links FOR SELECT TO authenticated
 USING (EXISTS(SELECT 1 FROM public.conversations c WHERE c.id=conversation_id AND
 (c.customer_id=(SELECT auth.uid()) OR EXISTS(SELECT 1 FROM public.worker_profiles w WHERE w.id=c.worker_id AND w.user_id=(SELECT auth.uid())))));

-- Preserve official conversations already tied to recorded applications.
INSERT INTO public.job_chat_links(job_id,conversation_id)
 SELECT DISTINCT a.job_id,c.id FROM public.job_applications a JOIN public.job_posts j ON j.id=a.job_id
 JOIN public.conversations c ON c.customer_id=j.customer_id AND c.worker_id=a.worker_id
 WHERE j.post_source='clean_lanka' ON CONFLICT DO NOTHING;

-- Enquiries require an email-confirmed Worker account, not application approval.
-- No conversation is created merely by opening a job or chat window.
CREATE OR REPLACE FUNCTION public.worker_job_chat(p_job_id uuid,p_message text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_user uuid:=auth.uid(); v_worker public.worker_profiles%ROWTYPE; v_job public.job_posts%ROWTYPE; v_conversation uuid;
BEGIN
 IF v_user IS NULL OR NOT EXISTS(SELECT 1 FROM auth.users WHERE id=v_user AND email_confirmed_at IS NOT NULL) THEN RAISE EXCEPTION 'Please sign in with an email-confirmed Worker account.' USING ERRCODE='42501'; END IF;
 SELECT * INTO v_worker FROM public.worker_profiles WHERE user_id=v_user;
 IF v_worker.id IS NULL THEN RAISE EXCEPTION 'A registered Worker account is required to chat.'; END IF;
 SELECT j.* INTO v_job FROM public.job_posts j JOIN public.get_public_job_posts() p ON p.id=j.id WHERE j.id=p_job_id;
 IF v_job.id IS NULL THEN RAISE EXCEPTION 'This job is no longer available.'; END IF;
 IF v_job.customer_id=v_user THEN RAISE EXCEPTION 'You cannot contact yourself about your own job.'; END IF;
 SELECT id INTO v_conversation FROM public.conversations WHERE customer_id=v_job.customer_id AND worker_id=v_worker.id;
 IF p_message IS NOT NULL THEN
  IF length(trim(p_message)) NOT BETWEEN 1 AND 3500 THEN RAISE EXCEPTION 'Write a message of 1 to 3500 characters.'; END IF;
  INSERT INTO public.conversations(customer_id,worker_id) VALUES(v_job.customer_id,v_worker.id)
   ON CONFLICT(customer_id,worker_id) DO UPDATE SET customer_id=excluded.customer_id RETURNING id INTO v_conversation;
  INSERT INTO public.job_chat_links(job_id,conversation_id) VALUES(v_job.id,v_conversation) ON CONFLICT DO NOTHING;
  INSERT INTO public.messages(conversation_id,sender_id,message) VALUES(v_conversation,v_user,'Regarding job: '||left(v_job.service_title,200)||E'\n'||trim(p_message));
 END IF;
 RETURN jsonb_build_object('conversation_id',v_conversation,'job_title',v_job.service_title,'post_source',v_job.post_source,
 'contact_name',CASE WHEN v_job.post_source='clean_lanka' THEN coalesce(nullif(trim(v_job.contact_name),''),'Clean Lanka') ELSE coalesce(nullif(trim(v_job.contact_name),''),(SELECT nullif(trim(cp.full_name),'') FROM public.customer_profiles cp WHERE cp.user_id=v_job.customer_id LIMIT 1),'Job poster') END,
 'contact_district',v_job.district,'contact_public_id',CASE WHEN v_job.post_source='clean_lanka' THEN NULL ELSE (SELECT cp.customer_public_id FROM public.customer_profiles cp WHERE cp.user_id=v_job.customer_id LIMIT 1) END);
END $$;
REVOKE ALL ON FUNCTION public.worker_job_chat(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.worker_job_chat(uuid,text) TO authenticated;

-- Explicit applications retain the existing approval/availability/clearance rules.
CREATE OR REPLACE FUNCTION public.worker_apply_to_job(p_job_id uuid,p_message text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE w public.worker_profiles%ROWTYPE; a public.job_applications%ROWTYPE; result jsonb;
BEGIN
 SELECT * INTO w FROM public.worker_profiles WHERE user_id=auth.uid() FOR UPDATE;
 IF w.id IS NULL THEN RAISE EXCEPTION 'A registered Worker account is required.' USING ERRCODE='42501'; END IF;
 IF NOT (w.verification_status='approved' AND w.is_available IS TRUE AND (w.police_clearance_status='verified' OR w.gn_certificate_status='verified' OR w.temporary_booking_until>now())) IS TRUE THEN RAISE EXCEPTION 'Approval, availability and clearance eligibility are required to apply.'; END IF;
 IF p_message IS NULL OR length(trim(p_message)) NOT BETWEEN 1 AND 3500 THEN RAISE EXCEPTION 'Write an application message of 1 to 3500 characters.'; END IF;
 SELECT * INTO a FROM public.job_applications WHERE job_id=p_job_id AND worker_id=w.id LIMIT 1;
 IF a.status='rejected' THEN RAISE EXCEPTION 'This application has been rejected.'; END IF;
 -- Validation and chat use the same transaction: a failure cannot leave a partial application.
 result:=public.worker_job_chat(p_job_id,'Application: '||left(trim(p_message),3487));
 IF a.id IS NULL THEN INSERT INTO public.job_applications(job_id,worker_id,message,status) VALUES(p_job_id,w.id,trim(p_message),'pending'); END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.worker_apply_to_job(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.worker_apply_to_job(uuid,text) TO authenticated;

-- Only the posting, permitted Admin or an active Main Admin can operate the official inbox.
CREATE OR REPLACE FUNCTION cleanlanka_internal.can_reply_official_job_chat(p_conversation_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT auth.uid() IS NOT NULL AND EXISTS(
 SELECT 1 FROM public.conversations c JOIN public.job_chat_links l ON l.conversation_id=c.id
 JOIN public.job_posts j ON j.id=l.job_id JOIN public.admins a ON a.user_id=auth.uid()
 WHERE c.id=p_conversation_id AND j.post_source='clean_lanka' AND j.customer_id=c.customer_id AND a.is_active
 AND (a.role='main_admin' OR (c.customer_id=auth.uid() AND (a.role='admin' OR public.has_admin_permission('official_jobs_create')))));
$$;
REVOKE ALL ON FUNCTION cleanlanka_internal.can_reply_official_job_chat(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.get_official_job_chats()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.last_message_at DESC NULLS LAST),'[]'::jsonb) FROM (
 SELECT c.id AS conversation_id,w.user_id AS worker_user_id,w.full_name AS worker_name,w.district,w.worker_public_id,
 string_agg(DISTINCT j.service_title,' · ') AS job_titles,
 (SELECT m.message FROM public.messages m WHERE m.conversation_id=c.id ORDER BY m.created_at DESC LIMIT 1) AS last_message,
 (SELECT max(m.created_at) FROM public.messages m WHERE m.conversation_id=c.id) AS last_message_at
 FROM public.conversations c JOIN public.worker_profiles w ON w.id=c.worker_id
 JOIN public.job_chat_links l ON l.conversation_id=c.id JOIN public.job_posts j ON j.id=l.job_id
 WHERE j.post_source='clean_lanka' AND cleanlanka_internal.can_reply_official_job_chat(c.id)
 GROUP BY c.id,w.user_id,w.full_name,w.district,w.worker_public_id) t;
$$;
CREATE OR REPLACE FUNCTION public.read_official_job_chat(p_conversation_id uuid)
RETURNS TABLE(id uuid,sender_id uuid,message text,created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
BEGIN
 IF NOT cleanlanka_internal.can_reply_official_job_chat(p_conversation_id) THEN RAISE EXCEPTION 'Official job chat access denied.' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT m.id,m.sender_id,m.message,m.created_at FROM (SELECT x.* FROM public.messages x WHERE x.conversation_id=p_conversation_id ORDER BY x.created_at DESC LIMIT 100) m ORDER BY m.created_at;
END $$;
CREATE OR REPLACE FUNCTION public.send_official_job_message(p_conversation_id uuid,p_message text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE result uuid; owner_id uuid; worker_user uuid;
BEGIN
 IF NOT cleanlanka_internal.can_reply_official_job_chat(p_conversation_id) THEN RAISE EXCEPTION 'Official job chat access denied.' USING ERRCODE='42501'; END IF;
 IF p_message IS NULL OR length(trim(p_message)) NOT BETWEEN 1 AND 4000 THEN RAISE EXCEPTION 'Write a message of 1 to 4000 characters.'; END IF;
 INSERT INTO public.messages(conversation_id,sender_id,message) VALUES(p_conversation_id,auth.uid(),trim(p_message)) RETURNING id INTO result;
 SELECT c.customer_id,w.user_id INTO owner_id,worker_user FROM public.conversations c JOIN public.worker_profiles w ON w.id=c.worker_id WHERE c.id=p_conversation_id;
 IF auth.uid()<>owner_id THEN INSERT INTO public.notifications(user_id,title,message,notification_type,is_read,related_conversation_id) VALUES(worker_user,'New message','Clean Lanka replied to your job enquiry.','message',false,p_conversation_id); END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_official_job_chats(),public.read_official_job_chat(uuid),public.send_official_job_message(uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_official_job_chats(),public.read_official_job_chat(uuid),public.send_official_job_message(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.clean_lanka_chat_contact_names(p_conversation_ids uuid[])
RETURNS TABLE(conversation_id uuid,contact_name text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
 SELECT c.id,CASE WHEN c.customer_id=auth.uid() THEN coalesce(nullif(trim(w.full_name),''),'Worker')
 WHEN EXISTS(SELECT 1 FROM public.job_chat_links l JOIN public.job_posts j ON j.id=l.job_id WHERE l.conversation_id=c.id AND j.post_source='clean_lanka') THEN 'Clean Lanka'
 ELSE coalesce(nullif(trim(cp.full_name),''),'Job poster') END
 FROM public.conversations c JOIN public.worker_profiles w ON w.id=c.worker_id LEFT JOIN public.customer_profiles cp ON cp.user_id=c.customer_id
 WHERE auth.uid() IS NOT NULL AND c.id=ANY(p_conversation_ids) AND (c.customer_id=auth.uid() OR w.user_id=auth.uid());
$$;
REVOKE ALL ON FUNCTION public.clean_lanka_chat_contact_names(uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.clean_lanka_chat_contact_names(uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.guard_sub_admin_official_job_edits()
RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
DECLARE v_mutable_fields text[]:=ARRAY['service_title','description','district','address','budget_lkr','preferred_date','publish_on','expires_on','contact_name','contact_phone','show_contact_phone','allow_whatsapp','salary_period','working_hours','experience_required','benefits'];
BEGIN
 IF auth.uid() IS NULL OR public.is_admin() THEN RETURN NEW; END IF;
 IF OLD.post_source='clean_lanka' OR NEW.post_source='clean_lanka' THEN
  IF OLD.post_source IS DISTINCT FROM NEW.post_source OR NOT public.has_admin_permission('official_jobs_edit') THEN RAISE EXCEPTION 'Official job editing permission required'; END IF;
  IF OLD.status IS DISTINCT FROM 'open' OR NEW.status IS DISTINCT FROM 'open' OR (to_jsonb(OLD)-v_mutable_fields) IS DISTINCT FROM (to_jsonb(NEW)-v_mutable_fields) THEN RAISE EXCEPTION 'Sub Admin may edit official job details and dates only'; END IF;
 END IF;
 RETURN NEW;
END $$;
