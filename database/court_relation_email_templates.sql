alter table private.court_correction_email_templates_v1
  drop constraint court_correction_email_templates_v1_kind_check,
  add constraint court_correction_email_templates_v1_kind_check
    check (kind in ('duplicate', 'membership', 'combined', 'relation', 'relation_membership', 'relation_shared_phone'));

CREATE OR REPLACE FUNCTION public.court_correction_email_templates_v1(p_kind text DEFAULT NULL::text, p_template jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_subject text;
  v_body text;
begin
  if auth.uid() is null
     or coalesce(public.get_court_admin_identity_v1()->>'role', '') not in ('super_admin', 'staff') then
    raise exception '無權讀取或調整補件通知文字' using errcode = '42501';
  end if;

  if p_kind is null and p_template is null then
    return (
      select coalesce(jsonb_object_agg(t.kind, jsonb_build_object('subject', t.subject, 'body', t.body)), '{}'::jsonb)
      from private.court_correction_email_templates_v1 t
    );
  end if;

  v_subject := btrim(coalesce(p_template->>'subject', ''));
  v_body := btrim(coalesce(p_template->>'body', ''));
  if p_kind is null or p_kind not in ('duplicate', 'membership', 'combined', 'relation', 'relation_membership', 'relation_shared_phone')
     or jsonb_typeof(p_template->'subject') is distinct from 'string'
     or jsonb_typeof(p_template->'body') is distinct from 'string'
     or v_subject = '' or v_body = '' or v_subject ~ E'[\\r\\n]'
     or length(v_subject) + length(v_body) > 30000 then
    raise exception '請填寫有效的補件通知主旨及內文' using errcode = '22023';
  end if;

  if p_kind in ('relation', 'relation_membership', 'relation_shared_phone') and (
    (length(v_body) - length(replace(v_body, '{回覆期限}', ''))) <> length('{回覆期限}')
    or (length(v_body) - length(replace(v_body, '{關聯登記明細表}', ''))) <> length('{關聯登記明細表}')
  ) then
    raise exception '請在內文中各保留一個 {回覆期限} 和 {關聯登記明細表}' using errcode = '22023';
  end if;

  insert into private.court_correction_email_templates_v1(kind, subject, body)
  values (p_kind, v_subject, v_body)
  on conflict (kind) do update
    set subject = excluded.subject, body = excluded.body;

  return jsonb_build_object('subject', v_subject, 'body', v_body);
end;
$function$;
