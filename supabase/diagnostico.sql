-- Diagnóstico de MARCA en Supabase (solo lectura, no modifica nada).
-- Pégalo completo en el editor SQL después de aplicar las migraciones.
-- Cada fila debe decir OK. Un REVISAR o FALTA indica qué volver a ejecutar.
-- Si responde 'relation "public.informes" does not exist', el proyecto todavía
-- no tiene ninguna migración aplicada: empieza por folios_v2.sql.

with verificaciones as (

  -- 1. Estructura -----------------------------------------------------------
  select 10 as orden,
         'Columnas de vínculo en public.informes' as verificacion,
         case when count(*) = 5 then 'OK' else 'FALTA' end as estado,
         count(*) || ' de 5 presentes' ||
           case when count(*) = 5 then '' else ' — falta ejecutar acceso_documentos.sql' end as detalle
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'informes'
    and column_name in ('norma', 'drive_file_id', 'drive_url', 'acceso_informe_qr', 'vinculado_at')

  union all
  select 20,
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
  select 30,
         'Índices de Folios v2 y de acceso QR',
         case when count(*) = 4 then 'OK' else 'FALTA' end,
         count(*) || ' de 4 presentes'
  from pg_indexes
  where schemaname = 'public'
    and indexname in ('informes_public_id_uq', 'informes_folio_revision_uq',
                      'informes_un_activo_por_folio_uq', 'informes_acceso_qr_idx')

  union all
  select 40,
         'RLS activo en las tres tablas',
         case when count(*) filter (where relrowsecurity) = 3 then 'OK' else 'REVISAR' end,
         count(*) filter (where relrowsecurity) || ' de 3 con row level security'
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname in ('informes', 'operadores', 'folio_eventos')

  -- 2. Frontera pública -----------------------------------------------------
  union all
  select 50,
         'anon SIN lectura directa de public.informes',
         case when has_table_privilege('anon', 'public.informes', 'select')
                or has_any_column_privilege('anon', 'public.informes', 'select')
              then 'REVISAR' else 'OK' end,
         case when has_table_privilege('anon', 'public.informes', 'select')
                or has_any_column_privilege('anon', 'public.informes', 'select')
              then 'anon puede enumerar public_id por folio — vuelve a ejecutar acceso_documentos.sql'
              else 'el public_id del QR no se puede enumerar' end

  union all
  select 55,
         'Política anon heredada retirada',
         case when count(*) = 0 then 'OK' else 'REVISAR' end,
         case when count(*) = 0 then 'sin políticas anon sobre informes'
              else 'queda ' || string_agg(policyname, ', ') || ' — vuelve a ejecutar acceso_documentos.sql' end
  from pg_policies
  where schemaname = 'public' and tablename = 'informes' and 'anon' = any(roles)

  union all
  select 60,
         'anon PUEDE verificar documentos',
         case when count(*) filter (where not permitido) = 0 then 'OK' else 'REVISAR' end,
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
  select 70,
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
  select 80,
         'Operadores con acceso completo',
         case when count(*) filter (where not permitido) = 0
               and has_table_privilege('authenticated', 'public.informes', 'select')
              then 'OK' else 'REVISAR' end,
         case when count(*) filter (where not permitido) > 0
              then 'sin permiso: ' || string_agg(sig, ', ') filter (where not permitido)
              when not has_table_privilege('authenticated', 'public.informes', 'select')
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

  -- 3. Datos ----------------------------------------------------------------
  union all
  select 90,
         'Un solo documento vigente por folio',
         case when count(*) = 0 then 'OK' else 'REVISAR' end,
         case when count(*) = 0 then 'sin folios con versiones activas duplicadas'
              else count(*) || ' folio(s) con más de una versión activa' end
  from (
    select upper(btrim(folio))
    from public.informes
    where estado = 'activo'
    group by 1
    having count(*) > 1
  ) d

  union all
  select 95,
         'Administradores activos',
         case when count(*) > 0 then 'OK' else 'REVISAR' end,
         count(*) || ' administrador(es) activo(s)'
  from public.operadores
  where rol = 'administrador' and activo

  union all
  select 100,
         'Informes con acceso desde el QR',
         'INFO',
         count(*) filter (where acceso_informe_qr and drive_url is not null and estado = 'activo')
           || ' revisión(es) vigente(s) con botón Ver informe · '
           || count(*) filter (where drive_url is not null) || ' vinculada(s) en total · '
           || count(*) || ' registro(s) en MARCA'
  from public.informes
)
select orden, verificacion, estado, detalle
from verificaciones
order by orden;
