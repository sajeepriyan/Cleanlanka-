CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
      SELECT 1
          FROM public.admins
              WHERE user_id = auth.uid()
                    AND is_active = true
                          AND role IN ('main_admin', 'admin')
                            );
                            $function$


CREATE OR REPLACE FUNCTION public.worker_job_chat(p_job_id uuid, p_message text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user uuid := auth.uid();
  v_worker public.worker_profiles%ROWTYPE;
  v_job public.job_posts%ROWTYPE;
  v_conversation uuid;
  v_application public.job_applications%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'Please sign in as a Worker.'; END IF;
  SELECT * INTO v_worker FROM public.worker_profiles WHERE user_id=v_user;
  IF v_worker.id IS NULL THEN RAISE EXCEPTION 'A registered Worker account is required to apply.'; END IF;
  SELECT j.* INTO v_job FROM public.job_posts j JOIN public.get_public_job_posts() p ON p.id=j.id WHERE j.id=p_job_id;
  IF v_job.id IS NULL THEN RAISE EXCEPTION 'This job is no longer available.'; END IF;
  IF v_job.customer_id=v_user THEN RAISE EXCEPTION 'You cannot apply to your own job.'; END IF;
  SELECT id INTO v_conversation FROM public.conversations WHERE customer_id=v_job.customer_id AND worker_id=v_worker.id;
  IF p_message IS NOT NULL THEN
    IF length(trim(p_message)) NOT BETWEEN 1 AND 3500 THEN RAISE EXCEPTION 'Write a message of 1 to 3500 characters.'; END IF;
    IF NOT (v_worker.verification_status='approved' AND v_worker.is_available IS TRUE AND
      (v_worker.police_clearance_status='verified' OR v_worker.gn_certificate_status='verified' OR v_worker.temporary_booking_until>now())) IS TRUE
    THEN RAISE EXCEPTION 'Your Worker profile must be approved, available and clearance eligible before applying.'; END IF;
    -- Lock the worker to serialize repeat sends without duplicate applications.
    PERFORM 1 FROM public.worker_profiles WHERE id=v_worker.id FOR UPDATE;
    SELECT * INTO v_application FROM public.job_applications WHERE job_id=p_job_id AND worker_id=v_worker.id LIMIT 1;
    IF v_application.status='rejected' THEN RAISE EXCEPTION 'This application has been rejected.'; END IF;
    IF v_application.id IS NULL THEN
      INSERT INTO public.job_applications(job_id,worker_id,message,status) VALUES(p_job_id,v_worker.id,trim(p_message),'pending');
    END IF;
    INSERT INTO public.conversations(customer_id,worker_id) VALUES(v_job.customer_id,v_worker.id)
      ON CONFLICT(customer_id,worker_id) DO UPDATE SET customer_id=excluded.customer_id RETURNING id INTO v_conversation;
    INSERT INTO public.messages(conversation_id,sender_id,message)
      VALUES(v_conversation,v_user,'Regarding job: '||left(v_job.service_title,200)||E'\n'||trim(p_message));
  END IF;
  RETURN jsonb_build_object(
    'conversation_id',v_conversation,
    'job_title',v_job.service_title,
    'contact_name',CASE WHEN v_job.post_source='clean_lanka' THEN 'Clean Lanka'
      ELSE COALESCE((SELECT NULLIF(trim(cp.full_name),'') FROM public.customer_profiles cp WHERE cp.user_id=v_job.customer_id LIMIT 1),'Customer') END,
    'contact_district',v_job.district,
    'contact_public_id',CASE WHEN v_job.post_source='clean_lanka' THEN NULL
      ELSE (SELECT cp.customer_public_id FROM public.customer_profiles cp WHERE cp.user_id=v_job.customer_id LIMIT 1) END
  );
END;
$function$


CREATE OR REPLACE FUNCTION public.admin_chat_directory()
 RETURNS TABLE(conversation_id uuid, customer_user_id uuid, customer_name text, customer_email text, worker_user_id uuid, worker_name text, worker_email text, last_message_at timestamp with time zone, message_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
 if auth.uid() is null or not exists (select 1 from public.admins a where a.user_id=auth.uid() and a.role='main_admin' and a.is_active=true) then
  raise exception 'Main Admin access required' using errcode='42501';
 end if;
 insert into public.admin_action_audit(actor_id,actor_role,action,target_table,changed_fields)
 values(auth.uid(),'main_admin','view_chat_directory','conversations',array['read']);
 return query
 select c.id,c.customer_id,coalesce(cp.full_name,'Customer'),coalesce(cp.email,au.email),w.user_id,coalesce(w.full_name,'Worker'),coalesce(w.email,wu.email),max(m.created_at),count(m.id)
 from public.conversations c
 left join public.customer_profiles cp on cp.user_id=c.customer_id
 left join auth.users au on au.id=c.customer_id
 left join public.worker_profiles w on w.id=c.worker_id
 left join auth.users wu on wu.id=w.user_id
 left join public.messages m on m.conversation_id=c.id
 group by c.id,c.customer_id,cp.full_name,cp.email,au.email,w.user_id,w.full_name,w.email,wu.email
 order by max(m.created_at) desc nulls last;
end $function$


CREATE OR REPLACE FUNCTION public.get_public_job_posts()
 RETURNS TABLE(id uuid, service_title text, description text, district text, budget_lkr numeric, preferred_date date, created_at timestamp with time zone, post_source text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    j.id,j.service_title,j.description,j.district,j.budget_lkr,
    j.preferred_date,j.created_at,COALESCE(j.post_source,'customer')
  FROM public.job_posts AS j
  WHERE j.status='open'
    AND (
      j.post_source <> 'clean_lanka'
      OR (
        j.publish_on <= (now() AT TIME ZONE 'Asia/Colombo')::date
        AND j.expires_on >= (now() AT TIME ZONE 'Asia/Colombo')::date
      )
    )
  ORDER BY j.created_at DESC
  LIMIT 100;
$function$


CREATE OR REPLACE FUNCTION public.has_admin_permission(p_permission text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
          SELECT EXISTS (
                  SELECT 1
                          FROM public.admins a
                                  WHERE a.user_id = auth.uid()
                                            AND a.is_active = true
                                                      AND (
                                                                    (
                                                                                      a.role = 'main_admin'
                                                                                                        AND a.permissions @> '{"all":true}'::jsonb
                                                                                                                      )
                                                                                                                                    OR
                                                                                                                                                  (
                                                                                                                                                                    a.role = 'sub_admin'
                                                                                                                                                                                      AND a.permissions ->> p_permission = 'true'
                                                                                                                                                                                                        AND a.parent_admin_id IS NOT NULL
                                                                                                                                                                                                                          AND EXISTS (
                                                                                                                                                                                                                                                SELECT 1
                                                                                                                                                                                                                                                                      FROM public.admins parent
                                                                                                                                                                                                                                                                                            WHERE parent.user_id = a.parent_admin_id
                                                                                                                                                                                                                                                                                                                    AND parent.role = 'main_admin'
                                                                                                                                                                                                                                                                                                                                            AND parent.is_active = true
                                                                                                                                                                                                                                                                                                                                                              )
                                                                                                                                                                                                                                                                                                                                                                            )
                                                                                                                                                                                                                                                                                                                                                                                      )
                                                                                                                                                                                                                                                                                                                                                                                          );
                                                                                                                                                                                                                                                                                                                                                                                          $function$


CREATE OR REPLACE FUNCTION public.search_public_job_posts(p_search_query text DEFAULT NULL::text)
 RETURNS TABLE(id uuid, service_title text, description text, district text, budget_lkr numeric, preferred_date date, created_at timestamp with time zone, post_source text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT
    j.id,j.service_title,j.description,j.district,j.budget_lkr,
    j.preferred_date,j.created_at,COALESCE(j.post_source,'customer')
  FROM public.job_posts AS j
  WHERE j.status='open'
    AND (
      j.post_source <> 'clean_lanka'
      OR (
        j.publish_on <= (now() AT TIME ZONE 'Asia/Colombo')::date
        AND j.expires_on >= (now() AT TIME ZONE 'Asia/Colombo')::date
      )
    )
    AND (
      NULLIF(trim(p_search_query),'') IS NULL
      OR j.service_title ILIKE '%' || trim(p_search_query) || '%'
      OR j.description ILIKE '%' || trim(p_search_query) || '%'
      OR j.district ILIKE '%' || trim(p_search_query) || '%'
      OR EXISTS (
        SELECT 1 FROM public.job_post_search_terms AS t
        WHERE t.job_id=j.id AND t.search_term ILIKE '%' || trim(p_search_query) || '%'
      )
    )
  ORDER BY j.created_at DESC
  LIMIT 100;
$function$

