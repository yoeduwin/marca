-- Diagnóstico de MARCA en Supabase (solo lectura, no modifica nada).
-- Pégalo completo en el editor SQL del proyecto y ejecútalo.
-- Funciona en cualquier estado: la primera fila dice qué hay que hacer.
--
--   OK      la parte está bien
--   FALTA   todavía no se ha ejecutado el script que la crea
--   REVISAR está aplicada pero quedó en un estado que hay que corregir
--   INFO    dato informativo, no es un problema

with

-- Métricas de datos. Se leen con query_to_xml para que el diagnóstico no
-- falle cuando la tabla o las columnas todavía no existen: la consulta de
-- adentro sólo se ejecuta si el CASE llega a evaluarla.
m_informes as (
  select case
    when to_regclass('public.informes') is null then null
    else query_to_xml(
      $q$ select count(*)::text as total,
                 count(*) filter (where estado = 'activo')::text as activos,
                 (select count(*)::text from (
                    select 1 from public.informes
                    where estado = 'activo'
                    group by upper(btrim(folio))
                    having count(*) > 1
                  ) d) as duplicados
          from public.informes $q$, false, true, '')
  end as x
),
m_acceso as (
  select case
    when (select count(*) from information_schema.columns
          where table_schema = 'public' and table_name = 'informes'
            and column_name in ('acceso_informe_qr', 'drive_url')) < 2 then null
    else query_to_xml(
      $q$ select count(*) filter (
                   where acceso_informe_qr and drive_url is not null and estado = 'activo'
                 )::text as con_acceso,
                 count(*) filter (where drive_url is not null)::text as vinculados
          from public.informes $q$, false, true, '')
  end as x
),
m_operadores as (
  select case
    when to_regclass('public.operadores') is null then null
    else query_to_xml(
      $q$ select count(*) filter (where rol = 'administrador' and activo)::text as admins,
                 count(*) filter (where activo)::text as activos
          from public.operadores $q$, false, true, '')
  end as x
),

-- Estado de cada migración, para poder decir qué sigue.
estado_migraciones as (
  select
    to_regclass('public.informes') is not null as hay_tabla,
    (select count(*) from information_schema.columns
     where table_schema = 'public' and table_name = 'informes'
       and column_name = 'public_id') = 1 as hay_folios_v2,
    (select count(*) from information_schema.columns
     where table_schema = 'public' and table_name = 'informes'
       and column_name in ('norma', 'drive_file_id', 'drive_url',
                           'acceso_informe_qr', 'vinculado_at')) = 5
      and to_regprocedure('public.obtener_acceso_documento(uuid)') is not null as hay_acceso,
    case
      when to_regclass('public.informes') is null then false
      else has_table_privilege('anon', 'public.informes', 'select')
        or has_any_column_privilege('anon', 'public.informes', 'select')
    end as anon_lee_tabla,
    exists (
      select 1 from pg_policies
      where schemaname = 'public' and tablename = 'informes' and 'anon' = any(roles)
    ) as politica_anon_restante,
    coalesce(
      to_regprocedure('private.vincular_entrega_por_public_id(uuid,text,text,text,boolean)') is not null
      and pg_get_functiondef(
            to_regprocedure('private.vincular_entrega_por_public_id(uuid,text,text,text,boolean)')::oid
          ) like '%(drive|docs)%',
      false) as enlace_restringido,
    to_regprocedure('public.registrar_revision(uuid,text,text,integer,date)') is not null
      as hay_fecha_emision
),

verificaciones as (

  -- 0. Qué hacer -----------------------------------------------------------
  select 1 as orden,
         '¿Qué sigue?' as verificacion,
         case when hay_tabla and hay_folios_v2 and hay_acceso
                   and not anon_lee_tabla and not politica_anon_restante
                   and enlace_restringido and hay_fecha_emision
              then 'LISTO' else 'ACCIÓN' end as estado,
         case
           when not hay_tabla
             then 'No existe la tabla informes: confirma que estás en el proyecto de MARCA (ejecutiva-verificacion).'
           when not hay_folios_v2
             then 'Ejecuta supabase/folios_v2.sql y enseguida supabase/acceso_documentos.sql.'
           when not hay_acceso
             then 'Ejecuta supabase/acceso_documentos.sql.'
           when anon_lee_tabla
             then 'Vuelve a ejecutar supabase/acceso_documentos.sql para cerrar la lectura pública de informes.'
           when politica_anon_restante
             then 'Vuelve a ejecutar supabase/acceso_documentos.sql: queda la política anon heredada de Folios v2 (ver fila 65).'
           when not enlace_restringido
             then 'Vuelve a ejecutar supabase/acceso_documentos.sql: la vinculación todavía acepta enlaces fuera de Drive (ver fila 25).'
           when not hay_fecha_emision
             then 'Ejecuta supabase/fecha_emision.sql para poder capturar la fecha del informe (ver fila 27).'
           else 'Nada pendiente en la base. Revisa que index.html y verificar.html estén publicados.'
         end as detalle
  from estado_migraciones

  -- 1. Estructura ----------------------------------------------------------
  union all
  select 10,
         'Base de Folios v2',
         case when hay_folios_v2 then 'OK' else 'FALTA' end,
         case when hay_folios_v2 then 'revisiones, roles y auditoría aplicados'
              else 'falta ejecutar folios_v2.sql' end
  from estado_migraciones

  union all
  select 20,
         'Columnas de vínculo en public.informes',
         case when count(*) = 5 then 'OK' else 'FALTA' end,
         count(*) || ' de 5 presentes' ||
           case when count(*) = 5 then '' else ' — falta ejecutar acceso_documentos.sql' end
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'informes'
    and column_name in ('norma', 'drive_file_id', 'drive_url', 'acceso_informe_qr', 'vinculado_at')

  union all
  select 25,
         'Enlace del informe restringido a Drive',
         case when enlace_restringido then 'OK' else 'REVISAR' end,
         case when enlace_restringido
              then 'la vinculación sólo acepta drive.google.com y docs.google.com'
              else 'la vinculación acepta cualquier https — vuelve a ejecutar acceso_documentos.sql' end
  from estado_migraciones

  union all
  select 27,
         'Fecha de emisión capturable',
         case when hay_fecha_emision then 'OK' else 'FALTA' end,
         case when hay_fecha_emision
              then 'el informe puede registrarse con su propia fecha'
              else 'la fecha siempre será la del día del registro — falta fecha_emision.sql' end
  from estado_migraciones

  union all
  select 30,
         'Funciones RPC publicadas',
         case when count(*) filter (where to_regprocedure(sig) is null) = 0 then 'OK' else 'FALTA' end,
         coalesce(
           'no existen: ' || string_agg(sig, ', ') filter (where to_regprocedure(sig) is null),
           'las 8 funciones existen'
         )
  from (values
    ('public.registrar_revision(uuid,text,text,integer)'),
    ('public.anular_folio(text,text)'),
    ('public.actualizar_operador(uuid,text,boolean)'),
    ('public.verificar_documento(uuid)'),
    ('public.buscar_folio(text)'),
    ('public.verificar_archivo(text)'),
    ('public.obtener_acceso_documento(uuid)'),
    ('public.vincular_entrega_por_public_id(uuid,text,text,text,boolean)')
  ) as f(sig)

  union all
  select 40,
         'Índices de Folios v2 y de acceso QR',
         case when count(*) = 4 then 'OK' else 'FALTA' end,
         count(*) || ' de 4 presentes'
  from pg_indexes
  where schemaname = 'public'
    and indexname in ('informes_public_id_uq', 'informes_folio_revision_uq',
                      'informes_un_activo_por_folio_uq', 'informes_acceso_qr_idx')

  union all
  select 50,
         'RLS activo en las tres tablas',
         case when count(*) filter (where relrowsecurity) = 3 then 'OK' else 'FALTA' end,
         count(*) filter (where relrowsecurity) || ' de 3 con row level security'
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in ('informes', 'operadores', 'folio_eventos')

  -- 2. Frontera pública ----------------------------------------------------
  union all
  select 60,
         'anon SIN lectura directa de public.informes',
         case when not hay_tabla then 'FALTA'
              when anon_lee_tabla then 'REVISAR' else 'OK' end,
         case when not hay_tabla then 'la tabla informes no existe'
              when anon_lee_tabla
                then 'anon puede enumerar public_id por folio — vuelve a ejecutar acceso_documentos.sql'
              else 'el public_id del QR no se puede enumerar' end
  from estado_migraciones

  union all
  select 65,
         'Política anon heredada retirada',
         case when count(*) = 0 then 'OK' else 'REVISAR' end,
         case when count(*) = 0 then 'sin políticas anon sobre informes'
              else 'queda ' || string_agg(policyname, ', ') || ' — vuelve a ejecutar acceso_documentos.sql' end
  from pg_policies
  where schemaname = 'public' and tablename = 'informes' and 'anon' = any(roles)

  union all
  select 70,
         'anon PUEDE verificar documentos',
         case when count(*) filter (where not permitido) = 0 then 'OK' else 'FALTA' end,
         case when count(*) filter (where not permitido) = 0
              then 'las 4 funciones de verificación responden al público'
              else 'sin permiso: ' || string_agg(sig, ', ') filter (where not permitido) end
  from (
    select sig,
           to_regprocedure(sig) is not null
             and has_function_privilege('anon', to_regprocedure(sig)::oid, 'execute') as permitido
    from (values
      ('public.verificar_documento(uuid)'),
      ('public.buscar_folio(text)'),
      ('public.verificar_archivo(text)'),
      ('public.obtener_acceso_documento(uuid)')
    ) as f(sig)
  ) x

  union all
  select 80,
         'anon NO PUEDE escribir ni vincular',
         case when count(*) filter (where permitido) = 0 then 'OK' else 'REVISAR' end,
         case when count(*) filter (where permitido) = 0
              then 'las funciones de operador están cerradas al público'
              else 'expuestas a anon: ' || string_agg(sig, ', ') filter (where permitido) end
  from (
    select sig,
           to_regprocedure(sig) is not null
             and has_function_privilege('anon', to_regprocedure(sig)::oid, 'execute') as permitido
    from (values
      ('public.registrar_revision(uuid,text,text,integer)'),
      ('public.anular_folio(text,text)'),
      ('public.actualizar_operador(uuid,text,boolean)'),
      ('public.vincular_entrega_por_public_id(uuid,text,text,text,boolean)'),
      ('public.vincular_entrega_por_folio(text,text,text,text,boolean)'),
      ('private.vincular_entrega_por_public_id(uuid,text,text,text,boolean)')
    ) as f(sig)
  ) y

  union all
  select 90,
         'Operadores con acceso completo',
         case when count(*) filter (where not permitido) = 0
               and (select hay_tabla and has_table_privilege('authenticated', 'public.informes', 'select')
                    from estado_migraciones)
              then 'OK' else 'FALTA' end,
         case when count(*) filter (where not permitido) > 0
              then 'sin permiso: ' || string_agg(sig, ', ') filter (where not permitido)
              when not (select hay_tabla and has_table_privilege('authenticated', 'public.informes', 'select')
                        from estado_migraciones)
              then 'authenticated no puede listar folios en el panel'
              else 'emisión, anulación, alta de operadores y vinculación disponibles' end
  from (
    select sig,
           to_regprocedure(sig) is not null
             and has_function_privilege('authenticated', to_regprocedure(sig)::oid, 'execute') as permitido
    from (values
      ('public.registrar_revision(uuid,text,text,integer)'),
      ('public.anular_folio(text,text)'),
      ('public.actualizar_operador(uuid,text,boolean)'),
      ('public.vincular_entrega_por_public_id(uuid,text,text,text,boolean)')
    ) as f(sig)
  ) z

  -- 3. Datos ---------------------------------------------------------------
  union all
  select 100,
         'Un solo documento vigente por folio',
         case when x is null then 'FALTA'
              when (xpath('/row/duplicados/text()', x))[1]::text::bigint = 0 then 'OK'
              else 'REVISAR' end,
         case when x is null then 'la tabla informes no existe'
              when (xpath('/row/duplicados/text()', x))[1]::text::bigint = 0
                then 'sin folios con versiones activas duplicadas'
              else (xpath('/row/duplicados/text()', x))[1]::text
                   || ' folio(s) con más de una versión activa' end
  from m_informes

  union all
  select 110,
         'Administradores activos',
         case when x is null then 'FALTA'
              when (xpath('/row/admins/text()', x))[1]::text::bigint > 0 then 'OK'
              else 'REVISAR' end,
         case when x is null then 'la tabla operadores no existe — falta folios_v2.sql'
              else (xpath('/row/admins/text()', x))[1]::text || ' administrador(es) y '
                   || (xpath('/row/activos/text()', x))[1]::text || ' cuenta(s) activa(s)' end
  from m_operadores

  union all
  select 120,
         'Documentos registrados en MARCA',
         'INFO',
         case when x is null then 'la tabla informes no existe'
              else (xpath('/row/total/text()', x))[1]::text || ' registro(s), '
                   || (xpath('/row/activos/text()', x))[1]::text || ' vigente(s)' end
  from m_informes

  union all
  select 130,
         'Informes con acceso desde el QR',
         'INFO',
         case when x is null then 'todavía sin acceso al informe — falta acceso_documentos.sql'
              else (xpath('/row/con_acceso/text()', x))[1]::text
                   || ' revisión(es) vigente(s) con botón Ver informe · '
                   || (xpath('/row/vinculados/text()', x))[1]::text || ' vinculada(s) en total' end
  from m_acceso
)
select orden, verificacion, estado, detalle
from verificaciones
order by orden;
