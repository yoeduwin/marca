# Acceso al informe desde el QR

Esta ampliación mantiene separadas dos funciones de MARCA:

1. **Autenticidad e integridad**: continúa usando `public_id`, revisión y SHA-256.
2. **Consulta del informe**: opcional. Un registro puede asociarse a un archivo externo (actualmente Google Drive) y decidir si ese archivo se muestra desde el QR.

## Base de datos

Después de `supabase/folios_v2.sql`, ejecutar:

```sql
supabase/acceso_documentos.sql
```

La migración agrega a `informes` los campos de vínculo (`norma`, `drive_file_id`, `drive_url`, `acceso_informe_qr`, `vinculado_at`) y dos RPC:

- `vincular_entrega_por_folio(...)`: sólo para usuarios autenticados que sean operadores activos de MARCA. La PC de envíos lo usa después de subir el PDF a Drive.
- `obtener_acceso_documento(public_id)`: consulta pública limitada al UUID exacto del QR. Sólo devuelve URL cuando la revisión está activa y `acceso_informe_qr = true`.

La URL de Drive no se agrega al `SELECT` público de la tabla `informes`.

## Flujo previsto

```text
MARCA -> registra revisión activa -> PDF final
                              |
                              v
PC de envíos -> lee folio de metadatos del PDF -> sube a Drive
                              |
                              v
                 vincular_entrega_por_folio
                              |
                              v
QR -> verificar.html -> obtener_acceso_documento(public_id) -> Ver informe
```

El PDF generado actualmente por MARCA ya incluye el folio en sus metadatos (`Title` / `Subject`), por lo que la PC de envíos no necesita transportar ni capturar manualmente el `public_id`.

## Activación por norma

La base y el frontend son genéricos. La aplicación que realiza el envío decide para qué normas habilitar `acceso_informe_qr`.

La primera implementación está pensada para habilitar únicamente:

- `NOM-081-SEMARNAT-1994`

Agregar otra norma en el futuro no requiere cambiar el formato del QR ni la estructura de la base; basta con habilitarla en la configuración del sistema de envíos.
