-- Acceso controlado al informe digital desde el QR de MARCA.
-- Requiere haber aplicado previamente supabase/folios_v2.sql.
-- Diseño genérico; la activación por norma se decide desde el sistema de envíos.

-- Requisito previo: si Folios v2 no está aplicado, detener aquí con un mensaje
-- claro en lugar de encadenar errores en el editor SQL de Supabase.
do $$
begin
  if to_regclass('public.informes') is null
     or to_regnamespace('private') is null
     or to_regprocedure('private.es_operador()') is null
     or not exists (
       select 1 from information_schema.columns
       where table_schema = 'public'
         and table_name = 'informes'
         and column_name = 'public_id'
     ) then
    raise exception
      'Ejecuta primero supabase/folios_v2.sql: falta la base de Folios v2 (esquema private, función es_operador o columna public_id).'
      using errcode = 'P0001';
  end if;
end $$;

alter table public.informes
  add column if not exists norma text,
  add column if not exists drive_file_id text,
  add column if not exists drive_url text,
  add column if not exists acceso_informe_qr boolean not null default false,
  add column if not exists vinculado_at timestamptz;

create index if not exists informes_acceso_qr_idx
  on public.informes(public_id)
  where acceso_informe_qr = true and drive_url is not null;

-- El public_id funciona como credencial portadora del QR. Evitamos que pueda
-- obtenerse enumerando folios mediante SELECT anónimo sobre la tabla.
revoke select on table public.informes from anon;
revoke select (
  public_id, folio, revision, sha256, num_paginas,
  fecha_emision, estado, created_at, updated_at
) on public.informes from anon;

-- Con los privilegios revocados, la política de lectura pública de Folios v2
-- queda sin efecto: se retira para que la tabla no conserve una regla anon
-- que ya no describe cómo se consulta MARCA.
drop policy if exists informes_lectura_publica on public.informes;

-- Verificación pública de una revisión exacta. No devuelve public_id.
create or replace function public.verificar_documento(p_public_id uuid)
returns table (
  folio text,
  revision integer,
  sha256 text,
  num_paginas integer,
  fecha_emision date,
  estado text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select i.folio, i.revision, i.sha256, i.num_paginas,
         i.fecha_emision, i.estado, i.created_at
  from public.informes i
  where i.public_id = p_public_id
  limit 1;
$$;

-- Búsqueda pública por folio para conservar el buscador y QRs históricos.
-- Deliberadamente no expone public_id ni el enlace de Drive.
create or replace function public.buscar_folio(p_folio text)
returns table (
  folio text,
  revision integer,
  sha256 text,
  num_paginas integer,
  fecha_emision date,
  estado text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select i.folio, i.revision, i.sha256, i.num_paginas,
         i.fecha_emision, i.estado, i.created_at
  from public.informes i
  where upper(btrim(i.folio)) = upper(btrim(coalesce(p_folio, '')))
  order by i.created_at desc, i.id desc;
$$;

-- Verificación pública por huella. Tampoco devuelve public_id.
create or replace function public.verificar_archivo(p_sha256 text)
returns table (
  folio text,
  revision integer,
  sha256 text,
  num_paginas integer,
  fecha_emision date,
  estado text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select i.folio, i.revision, i.sha256, i.num_paginas,
         i.fecha_emision, i.estado, i.created_at
  from public.informes i
  where lower(btrim(i.sha256)) = lower(btrim(coalesce(p_sha256, '')))
  order by i.created_at desc, i.id desc
  limit 1;
$$;

revoke execute on function public.verificar_documento(uuid) from public;
revoke execute on function public.buscar_folio(text) from public;
revoke execute on function public.verificar_archivo(text) from public;
grant execute on function public.verificar_documento(uuid) to anon, authenticated;
grant execute on function public.buscar_folio(text) to anon, authenticated;
grant execute on function public.verificar_archivo(text) to anon, authenticated;

-- Vincula Drive con la revisión EXACTA indicada por el UUID que ya está dentro
-- del QR del PDF. Una revisión reemplazada/anulada se rechaza: nunca se redirige
-- un PDF antiguo al QR de una revisión nueva.
create or replace function private.vincular_entrega_por_public_id(
  p_public_id uuid,
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
  v_file_id text := btrim(coalesce(p_drive_file_id, ''));
  v_url text := btrim(coalesce(p_drive_url, ''));
  v_norma text := btrim(coalesce(p_norma, ''));
  v_informe public.informes%rowtype;
begin
  if (select auth.uid()) is null or not (select private.es_operador()) then
    raise exception 'Usuario sin permisos de operador' using errcode = '42501';
  end if;
  if p_public_id is null then
    raise exception 'El identificador público es obligatorio' using errcode = '22023';
  end if;
  if v_file_id = '' then
    raise exception 'El identificador de Drive es obligatorio' using errcode = '22023';
  end if;
  if v_url = '' or v_url !~ '^https://' then
    raise exception 'La URL del informe no es válida' using errcode = '22023';
  end if;
  -- El enlace se publica como «Ver informe» a nombre de Ejecutiva Ambiental:
  -- se limita a Drive para que no pueda llevar a un sitio ajeno. El ancla y el
  -- '/' final impiden formas como https://drive.google.com@otro-sitio o
  -- https://drive.google.com.otro-sitio.
  if v_url !~* '^https://(drive|docs)\.google\.com(/|$)' then
    raise exception 'El informe debe estar en Google Drive (drive.google.com o docs.google.com)'
      using errcode = '22023';
  end if;

  select *
    into v_informe
  from public.informes
  where public_id = p_public_id
  limit 1
  for update;

  if v_informe.id is null then
    raise exception 'No existe una revisión de MARCA con ese identificador'
      using errcode = 'P0002';
  end if;
  if v_informe.estado <> 'activo' then
    raise exception 'La revisión indicada ya no está vigente (estado: %)', v_informe.estado
      using errcode = 'P0001';
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
    v_informe.folio,
    'entrega_vinculada',
    jsonb_build_object(
      'revision', v_informe.revision,
      'public_id', v_informe.public_id,
      'norma', nullif(v_norma, ''),
      'drive_file_id', v_file_id,
      'acceso_informe_qr', coalesce(p_acceso_informe_qr, false)
    ),
    (select auth.uid())
  );

  return jsonb_build_object(
    'public_id', v_informe.public_id,
    'folio', v_informe.folio,
    'revision', v_informe.revision,
    'norma', nullif(v_norma, ''),
    'acceso_informe_qr', coalesce(p_acceso_informe_qr, false),
    'vinculado', true
  );
end;
$$;

revoke execute on function private.vincular_entrega_por_public_id(uuid, text, text, text, boolean)
  from public, anon;
grant execute on function private.vincular_entrega_por_public_id(uuid, text, text, text, boolean)
  to authenticated;

create or replace function public.vincular_entrega_por_public_id(
  p_public_id uuid,
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
  select private.vincular_entrega_por_public_id(
    p_public_id,
    p_drive_file_id,
    p_drive_url,
    p_norma,
    p_acceso_informe_qr
  );
$$;

revoke execute on function public.vincular_entrega_por_public_id(uuid, text, text, text, boolean)
  from public, anon;
grant execute on function public.vincular_entrega_por_public_id(uuid, text, text, text, boolean)
  to authenticated;

-- Compatibilidad defensiva: si una versión preliminar de esta migración llegó a
-- ejecutarse, la RPC por folio no debe quedar utilizable.
do $$
begin
  if to_regprocedure('public.vincular_entrega_por_folio(text,text,text,text,boolean)') is not null then
    execute 'revoke execute on function public.vincular_entrega_por_folio(text,text,text,text,boolean) from public, anon, authenticated';
  end if;
  if to_regprocedure('private.vincular_entrega_por_folio(text,text,text,text,boolean)') is not null then
    execute 'revoke execute on function private.vincular_entrega_por_folio(text,text,text,text,boolean) from public, anon, authenticated';
  end if;
end $$;

-- El enlace sólo se entrega al conocer el UUID exacto del QR, y únicamente si
-- esa revisión sigue vigente y fue habilitada para consulta.
create or replace function public.obtener_acceso_documento(p_public_id uuid)
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

-- Sin esta recarga, el frontend puede recibir "function not found" (PGRST202)
-- hasta que PostgREST vuelva a leer el esquema.
notify pgrst, 'reload schema';
