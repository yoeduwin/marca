-- Fecha de emisión capturable al registrar una revisión.
-- Requiere haber aplicado previamente supabase/folios_v2.sql.
--
-- El informe lleva su propia fecha, que no siempre es el día en que se genera
-- el PDF: se emite el 10, el cliente lo valida y se entrega el 25. La base
-- conserva las dos verdades por separado — fecha_emision es la del documento,
-- created_at el sello inmutable de cuándo se registró — y la bitácora guarda
-- ambas en el evento de emisión.

do $$
begin
  if to_regprocedure('private.registrar_revision(uuid,text,text,integer)') is null
     and to_regprocedure('private.registrar_revision(uuid,text,text,integer,date)') is null then
    raise exception
      'Ejecuta primero supabase/folios_v2.sql: no existe private.registrar_revision.'
      using errcode = 'P0001';
  end if;
end $$;

create or replace function private.registrar_revision(
  p_public_id uuid,
  p_folio text,
  p_sha256 text,
  p_num_paginas integer,
  p_fecha_emision date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_folio text := upper(btrim(coalesce(p_folio, '')));
  v_sha text := lower(btrim(coalesce(p_sha256, '')));
  -- La empresa opera en México: el día se decide en su huso, no en UTC, para
  -- que emitir por la noche no parezca una fecha futura.
  v_hoy date := (now() at time zone 'America/Mexico_City')::date;
  v_fecha date := coalesce(p_fecha_emision, v_hoy);
  v_anterior public.informes%rowtype;
  v_nueva public.informes%rowtype;
  v_revision integer;
begin
  if (select auth.uid()) is null or not (select private.es_operador()) then
    raise exception 'Usuario sin permisos de operador' using errcode = '42501';
  end if;
  if v_folio = '' then
    raise exception 'El folio es obligatorio' using errcode = '22023';
  end if;
  if v_sha !~ '^[0-9a-f]{64}$' then
    raise exception 'La huella SHA-256 no es válida' using errcode = '22023';
  end if;
  if p_public_id is null then
    raise exception 'El identificador público es obligatorio' using errcode = '22023';
  end if;
  if v_fecha > v_hoy then
    raise exception 'La fecha de emisión no puede ser posterior a hoy' using errcode = '22023';
  end if;
  if v_fecha < date '2000-01-01' then
    raise exception 'La fecha de emisión no es válida: revisa el año' using errcode = '22023';
  end if;

  select *
  into v_anterior
  from public.informes
  where upper(btrim(folio)) = v_folio
    and estado = 'activo'
  order by created_at desc, id desc
  limit 1
  for update;

  select coalesce(max(revision), -1) + 1
  into v_revision
  from public.informes
  where upper(btrim(folio)) = v_folio;

  if v_anterior.id is not null then
    update public.informes
    set estado = 'reemplazado',
        motivo_cambio = 'Sustituido por revisión R' || lpad(v_revision::text, 2, '0'),
        updated_at = now()
    where id = v_anterior.id;

    insert into public.folio_eventos (
      informe_id, folio, accion, detalle, actor_id
    ) values (
      v_anterior.id, v_folio, 'reemplazo',
      jsonb_build_object('revision_anterior', v_anterior.revision, 'revision_nueva', v_revision),
      (select auth.uid())
    );
  end if;

  insert into public.informes (
    public_id, folio, revision, sha256, num_paginas,
    estado, operador_id, reemplaza_id, fecha_emision
  ) values (
    p_public_id, v_folio, v_revision, v_sha, p_num_paginas,
    'activo', (select auth.uid()), v_anterior.id, v_fecha
  )
  returning * into v_nueva;

  -- La bitácora deja constancia de la fecha declarada y de si se capturó a
  -- mano; created_at del evento registra cuándo ocurrió en realidad.
  insert into public.folio_eventos (
    informe_id, folio, accion, detalle, actor_id
  ) values (
    v_nueva.id, v_folio, 'emision',
    jsonb_build_object(
      'revision', v_revision,
      'public_id', v_nueva.public_id,
      'fecha_emision', v_fecha,
      'fecha_capturada', p_fecha_emision is not null and p_fecha_emision <> v_hoy
    ),
    (select auth.uid())
  );

  return jsonb_build_object(
    'id', v_nueva.id,
    'public_id', v_nueva.public_id,
    'folio', v_nueva.folio,
    'revision', v_nueva.revision,
    'estado', v_nueva.estado,
    'fecha_emision', v_nueva.fecha_emision,
    'replaced', case when v_anterior.id is null then 0 else 1 end
  );
end;
$$;

revoke execute on function private.registrar_revision(uuid, text, text, integer, date)
  from public, anon;
grant execute on function private.registrar_revision(uuid, text, text, integer, date)
  to authenticated;

create or replace function public.registrar_revision(
  p_public_id uuid,
  p_folio text,
  p_sha256 text,
  p_num_paginas integer,
  p_fecha_emision date
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.registrar_revision(
    p_public_id, p_folio, p_sha256, p_num_paginas, p_fecha_emision
  );
$$;

-- La firma de cuatro argumentos se conserva a propósito: el frontend publicado
-- y la base se despliegan por separado, y sin ella no se podría emitir entre un
-- despliegue y el otro. Delega con la fecha en null, que equivale a hoy.
-- Ninguna de las dos lleva valor por omisión, para que PostgREST resuelva cada
-- llamada por el número de argumentos y nunca quede ambigua.
create or replace function public.registrar_revision(
  p_public_id uuid,
  p_folio text,
  p_sha256 text,
  p_num_paginas integer
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.registrar_revision(
    p_public_id, p_folio, p_sha256, p_num_paginas, null::date
  );
$$;

drop function if exists private.registrar_revision(uuid, text, text, integer);

revoke execute on function public.registrar_revision(uuid, text, text, integer, date)
  from public, anon;
revoke execute on function public.registrar_revision(uuid, text, text, integer)
  from public, anon;
grant execute on function public.registrar_revision(uuid, text, text, integer, date)
  to authenticated;
grant execute on function public.registrar_revision(uuid, text, text, integer)
  to authenticated;

notify pgrst, 'reload schema';
