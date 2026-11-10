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
  RETURN jsonb_build_object('conversation_id',v_conversation,'job_title',v_job.service_title);
END;
$function$

