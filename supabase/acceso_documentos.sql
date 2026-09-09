-- Acceso controlado al informe original desde el QR de MARCA.
-- Requiere haber aplicado previamente supabase/folios_v2.sql.
-- Diseño genérico; la activación por norma se decide desde el sistema de envíos.

alter table public.informes
  add column if not exists norma text,
  add column if not exists drive_file_id text,
  add column if not exists drive_url text,
  add column if not exists acceso_informe_qr boolean not null default false,
  add column if not exists vinculado_at timestamptz;

create index if not exists informes_acceso_qr_idx
  on public.informes(public_id)
  where acceso_informe_qr = true and drive_url is not null;

-- Vincula la entrega de Drive con la revisión ACTIVA de un folio.
-- Se ejecuta desde la PC fija con una cuenta autenticada y activa de MARCA.
create or replace function private.vincular_entrega_por_folio(
  p_folio text,
  p_drive_file_id text,
  p_drive_url text,
  p_norma text,
  p_acceso_informe_qr boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_folio text := upper(btrim(coalesce(p_folio, '')));
  v_file_id text := btrim(coalesce(p_drive_file_id, ''));
  v_url text := btrim(coalesce(p_drive_url, ''));
  v_norma text := btrim(coalesce(p_norma, ''));
  v_informe public.informes%rowtype;
begin
  if (select auth.uid()) is null or not (select private.es_operador()) then
    raise exception 'Usuario sin permisos de operador' using errcode = '42501';
  end if;
  if v_folio = '' then
    raise exception 'El folio es obligatorio' using errcode = '22023';
  end if;
  if v_file_id = '' then
    raise exception 'El identificador de Drive es obligatorio' using errcode = '22023';
  end if;
  if v_url = '' or v_url !~ '^https://' then
    raise exception 'La URL del informe no es válida' using errcode = '22023';
  end if;

  select *
    into v_informe
  from public.informes
  where upper(btrim(folio)) = v_folio
    and estado = 'activo'
  order by created_at desc, id desc
  limit 1
  for update;

  if v_informe.id is null then
    raise exception 'No existe una revisión activa de MARCA para el folio %', v_folio
      using errcode = 'P0002';
  end if;

  update public.informes
  set norma = nullif(v_norma, ''),
      drive_file_id = v_file_id,
      drive_url = v_url,
      acceso_informe_qr = coalesce(p_acceso_informe_qr, false),
      vinculado_at = now(),
      updated_at = now()
  where id = v_informe.id;

  insert into public.folio_eventos (
    informe_id, folio, accion, detalle, actor_id
  ) values (
    v_informe.id,
    v_folio,
    'entrega_vinculada',
    jsonb_build_object(
      'revision', v_informe.revision,
      'norma', nullif(v_norma, ''),
      'drive_file_id', v_file_id,
      'acceso_informe_qr', coalesce(p_acceso_informe_qr, false)
    ),
    (select auth.uid())
  );

  return jsonb_build_object(
    'public_id', v_informe.public_id,
    'folio', v_folio,
    'revision', v_informe.revision,
    'norma', nullif(v_norma, ''),
    'acceso_informe_qr', coalesce(p_acceso_informe_qr, false),
    'vinculado', true
  );
end;
$$;

create or replace function public.vincular_entrega_por_folio(
  p_folio text,
  p_drive_file_id text,
  p_drive_url text,
  p_norma text,
  p_acceso_informe_qr boolean default false
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.vincular_entrega_por_folio(
    p_folio,
    p_drive_file_id,
    p_drive_url,
    p_norma,
    p_acceso_informe_qr
  );
$$;

revoke execute on function public.vincular_entrega_por_folio(text, text, text, text, boolean)
  from public, anon;
grant execute on function public.vincular_entrega_por_folio(text, text, text, text, boolean)
  to authenticated;

-- Consulta pública deliberadamente estrecha: el enlace NO se expone mediante
-- SELECT directo. Solo se devuelve al conocer el public_id UUID exacto del QR,
-- cuando la revisión sigue activa y el acceso fue habilitado.
create or replace function public.obtener_acceso_documento(
  p_public_id uuid
)
returns table (
  folio text,
  revision integer,
  norma text,
  url text
)
language sql
stable
security definer
set search_path = ''
as $$
  select i.folio, i.revision, i.norma, i.drive_url
  from public.informes i
  where i.public_id = p_public_id
    and i.estado = 'activo'
    and i.acceso_informe_qr = true
    and i.drive_url is not null
  limit 1;
$$;

revoke execute on function public.obtener_acceso_documento(uuid) from public;
grant execute on function public.obtener_acceso_documento(uuid) to anon, authenticated;
