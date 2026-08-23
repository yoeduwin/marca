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

## Publicación de Folios v2

El orden es obligatorio:

1. Revisar y ejecutar `supabase/folios_v2.sql` en el proyecto `ejecutiva-verificacion`.
2. Confirmar que no existan errores de seguridad en Supabase Advisors.
3. Publicar `index.html` y `verificar.html`.
4. Generar un documento de prueba y escanear su QR.
5. Emitir una corrección con el mismo folio.
6. Confirmar que el QR anterior indique “Versión no vigente” y el nuevo indique “Documento auténtico”.

No publiques primero el frontend: depende de las columnas, políticas y funciones creadas por el SQL.

## Compatibilidad de documentos anteriores

Los QR históricos contienen solamente el folio, por lo que no permiten distinguir la revisión exacta. Seguirán consultando la versión vigente del folio. La huella del PDF sí permite identificar si el archivo histórico fue reemplazado.

Los documentos generados después de Folios v2 contienen un identificador único en el QR y sí muestran el estado exacto de su revisión.

## Seguridad

La llave incluida en el navegador es una llave publicable. Las operaciones privilegiadas se controlan mediante Supabase Auth, permisos explícitos, RLS y funciones transaccionales. No debe incluirse una llave `service_role` o secreta en estos archivos.
