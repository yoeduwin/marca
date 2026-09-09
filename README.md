# MARCA — Protección y verificación documental

Aplicación web de Ejecutiva Ambiental para proteger PDF, emitir certificados y verificar su autenticidad mediante folio, QR y huella SHA-256.

## Folios y revisiones

El folio se captura manualmente porque proviene del sistema operativo de la empresa. Cada emisión recibe además:

- un identificador público único para su QR;
- una revisión automática `R00`, `R01`, etc.;
- un estado: `activo`, `reemplazado` o `anulado`;
- la huella SHA-256 del PDF final;
- el operador responsable y una bitácora de cambios.

Cuando se registra una corrección, Supabase reemplaza la versión vigente e inserta la nueva dentro de una sola transacción. Solo puede existir una versión activa por folio.

## Roles

- **Operador:** genera y registra documentos, consulta folios e historial.
- **Administrador:** además puede anular folios, activar operadores y cambiar roles.

Las cuentas se crean en Supabase Authentication. Un trigger crea automáticamente su perfil como operador. El primer usuario existente se conserva como administrador inicial.

## Acceso al informe desde el QR

Una revisión puede quedar vinculada a su informe en Drive. Cuando el QR se
escanea y esa revisión sigue vigente, el verificador muestra el botón **Ver
informe**. Buscar el folio a mano nunca muestra ese botón. El detalle del flujo
está en [`INTEGRACION_ACCESO_QR.md`](INTEGRACION_ACCESO_QR.md).

## Actualización de Supabase

El orden es obligatorio. Los scripts se ejecutan en el editor SQL del proyecto
`ejecutiva-verificacion` y pueden repetirse sin dañar los datos:

1. `supabase/folios_v2.sql` — revisiones, roles y auditoría.
2. `supabase/acceso_documentos.sql` — acceso al informe desde el QR y cierre de
   la lectura pública directa de `informes`.
3. `supabase/diagnostico.sql` — no modifica nada; cada fila debe decir `OK`.
4. Confirmar que no existan errores de seguridad en Supabase Advisors.
5. Publicar `index.html` y `verificar.html`.

`acceso_documentos.sql` siempre va después: `folios_v2.sql` abre la lectura
anónima de `informes` y `acceso_documentos.sql` la cierra. Si en el futuro
vuelves a ejecutar `folios_v2.sql` por cualquier motivo, ejecuta enseguida
`acceso_documentos.sql`; el diagnóstico marca esa regresión en la fila
«anon SIN lectura directa».

No publiques primero el frontend: depende de las columnas, políticas y funciones
creadas por el SQL.

### Prueba después de actualizar

1. Generar un documento de prueba y escanear su QR.
2. Emitir una corrección con el mismo folio.
3. Confirmar que el QR anterior indique “Versión no vigente” y el nuevo
   “Documento auténtico”.
4. En un documento con informe vinculado y habilitado, confirmar que el QR
   muestre **Ver informe** y que la búsqueda manual del mismo folio no lo muestre.

## Compatibilidad de documentos anteriores

Los QR históricos contienen solamente el folio, por lo que no permiten distinguir la revisión exacta. Seguirán consultando la versión vigente del folio. La huella del PDF sí permite identificar si el archivo histórico fue reemplazado.

Los documentos generados después de Folios v2 contienen un identificador único en el QR y sí muestran el estado exacto de su revisión.

## Seguridad

La llave incluida en el navegador es una llave publicable. Las operaciones privilegiadas se controlan mediante Supabase Auth, permisos explícitos, RLS y funciones transaccionales. No debe incluirse una llave `service_role` o secreta en estos archivos.

El público no lee la tabla `informes`: consulta funciones que devuelven sólo los
datos del certificado. El identificador único del QR se comporta como una
credencial y por eso no puede obtenerse buscando el folio.
