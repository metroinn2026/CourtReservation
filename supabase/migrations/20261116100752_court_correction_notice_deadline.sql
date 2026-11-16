create table if not exists private.court_correction_notice_settings_v1 (
  singleton boolean primary key default true check (singleton),
  due_at timestamptz not null check (isfinite(due_at)),
  updated_at timestamptz not null default now(),
  updated_by uuid not null
);

alter table private.court_correction_notice_settings_v1 enable row level security;
revoke all on table private.court_correction_notice_settings_v1 from public, anon, authenticated, service_role;

create or replace function public.court_correction_notice_deadline_v1(p_due_at timestamptz default null)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or coalesce(public.get_court_admin_identity_v1()->>'role','') not in ('super_admin','staff') then
    raise exception '無權讀取或調整補正回覆期限' using errcode='42501';
  end if;
  if p_due_at is not null then
    if not isfinite(p_due_at) then
      raise exception '請填寫有效的回覆期限';
    end if;
    insert into private.court_correction_notice_settings_v1(singleton,due_at,updated_by)
    values (true,p_due_at,auth.uid())
    on conflict (singleton) do update set
      due_at=excluded.due_at, updated_by=excluded.updated_by, updated_at=now();
    return p_due_at;
  end if;
  return (select due_at from private.court_correction_notice_settings_v1 where singleton);
end;
$function$;

revoke all on function public.court_correction_notice_deadline_v1(timestamptz) from public, anon, authenticated, service_role;
grant execute on function public.court_correction_notice_deadline_v1(timestamptz) to authenticated;
