alter table public.job_posts alter column created_at set default now();
alter table public.job_applications alter column created_at set default now();
