# Acceso al informe desde el QR

Esta ampliación mantiene separadas dos funciones de MARCA:

1. **Autenticidad e integridad**: continúa usando `public_id`, revisión y SHA-256.
2. **Consulta del informe**: opcional. Un registro puede asociarse a un archivo externo (actualmente Google Drive) y decidir si ese archivo se muestra desde el QR.

## Base de datos

Después de `supabase/folios_v2.sql`, ejecutar:

```sql
supabase/acceso_documentos.sql
```

La migración agrega a `informes` los campos de vínculo (`norma`, `drive_file_id`, `drive_url`, `acceso_informe_qr`, `vinculado_at`) y las RPC públicas controladas necesarias para verificar y vincular documentos. También cierra la lectura anónima directa de `informes` que abría `folios_v2.sql`, por lo que siempre debe ejecutarse después de él.

Para confirmar que quedó aplicada, ejecutar `supabase/diagnostico.sql`: es de sólo lectura y todas sus filas deben decir `OK`.

### Quién vincula

Hay dos caminos hacia la misma función, y ambos exigen sesión de operador:

- **El panel de folios de MARCA.** Cada revisión vigente tiene el botón
  **Vincular informe**: se pega el enlace de Drive, se elige la norma y se
  decide si el QR muestra el informe. Es el camino disponible hoy.
- **La PC fija**, cuando exista, para hacerlo automáticamente al momento de la
  entrega.

No se puede vincular desde el editor SQL de Supabase: ahí no hay usuario
autenticado y la función rechaza la llamada.

### Punto de unión entre MARCA y la PC fija

No se usa el folio ni el SHA-256 como llave operativa. El `public_id` exacto de cada revisión ya está codificado dentro del QR que MARCA inserta en el PDF:

```text
.../verificar.html?documento=<UUID>
```

La PC fija lee ese QR del propio PDF, extrae el UUID y, después de subir el archivo a Drive, llama a:

- `vincular_entrega_por_public_id(...)`

La función sólo acepta una revisión cuyo `public_id` coincida exactamente y cuyo estado siga siendo `activo`. Si se intenta procesar tarde una R00 después de existir R01, la vinculación de R00 se rechaza y nunca puede terminar apuntando al QR de R01.

## Protección del acceso

El rol `anon` deja de tener `SELECT` directo sobre `informes`. El verificador público usa funciones específicas que no devuelven `public_id` al buscar por folio o por SHA-256:

- `verificar_documento(public_id)` — valida una revisión exacta conocida por QR.
- `buscar_folio(folio)` — conserva la búsqueda manual y los QR históricos sin revelar UUIDs.
- `verificar_archivo(sha256)` — conserva la comprobación de integridad sin revelar UUIDs.
- `obtener_acceso_documento(public_id)` — devuelve el enlace sólo si se conoce el UUID exacto, la revisión está activa y `acceso_informe_qr = true`.

Esa frontera es lo que sostiene el modelo: si `anon` recuperara el `SELECT` sobre `informes`, cualquiera podría obtener el `public_id` buscando el folio y, con él, el enlace de todo informe habilitado. El diagnóstico vigila esa condición.

Además, `verificar.html` sólo solicita `obtener_acceso_documento(...)` cuando la navegación llegó mediante `?documento=<UUID>`. Buscar manualmente un folio no muestra el botón **Ver informe**.

## Flujo previsto

```text
MARCA -> registra revisión -> genera PDF con QR(public_id)
                                   |
              +--------------------+--------------------+
              |                                         |
              v                                         v
  Panel de folios de MARCA                PC fija -> lee QR del PDF
  (operador pega el enlace)               -> extrae public_id -> sube a Drive
              |                                         |
              +--------------------+--------------------+
                                   v
                    vincular_entrega_por_public_id
                                   |
                                   v
QR -> verificar.html -> obtener_acceso_documento(public_id) -> Ver informe
```

## Activación por norma

La base es genérica: guarda cualquier norma. Quien vincula decide cuáles habilitan `acceso_informe_qr`.

En el panel de MARCA esa decisión vive en `NORMAS_CON_ACCESO_QR`, junto a `VERIFY_BASE_URL` en `index.html`. Hoy contiene únicamente:

- `NOM-081-SEMARNAT-1994`

Con cualquier otra norma el panel guarda el vínculo pero deja bloqueada la casilla de acceso público. Agregar una norma es añadirla a esa lista: no cambia el QR ni la estructura de la base.
