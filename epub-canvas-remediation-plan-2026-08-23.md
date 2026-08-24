# Plan de remediación del lienzo EPUB — 2026-08-23

Estado: implementado y verificado el 2026-08-24; este documento conserva el plan de ejecución

Rama base: `codex/kindle-scribe-stylus`

Commit revisado: `7f37516498e22217659f358c701c6671e344ee15`

Stack: KOReader v2026.07, LuaJIT/Lua 5.1, `lua-ljsqlite3`, framebuffer e-ink

Feature: lienzos acotados y anclados por xpointer para EPUB

## 1. Resultado que debe producir esta remediación

Al terminar, un trazo debe conservar una identidad válida desde que se levanta
el lápiz hasta que se borra, incluso si entre ambas operaciones hubo un flush,
un cierre del libro o un reinicio de KOReader. Ningún fallo de SQLite debe
convertirse en una hoja vacía ni permitir que se cierre silenciosamente una
hoja con operaciones pendientes. Abrir y rasterizar libros con muchas notas
debe tener trabajo y memoria acotados por tick y por chunk, no por la longitud
del trazo completo.

La arquitectura del lienzo, el anclaje por xpointer y la separación respecto de
la tinta directa sobre PDF se conservan. No hace falta rediseñar el producto;
sí hace falta reforzar los límites entre sesión, caché, cola y repositorio.

## 2. Alcance y no objetivos

### En alcance

- Corregir identidad, secuencia, borrado y undo de trazos pendientes y
  persistidos.
- Hacer que los fallos de lectura y escritura se propaguen hasta la UI sin
  descartar estado recuperable.
- Hacer streaming real de chunks al leer, rasterizar y escribir.
- Validar metadatos, orden, seams y recuentos del codec antes de declarar una
  hoja lista para editar.
- Hacer correcta la goma para segmentos y grosores, con lecturas SQLite
  acotadas y reutilizadas dentro de un contacto.
- Completar el modo de lectura para esquemas futuros.
- Hacer transaccional la creación del esquema v1 y verificar el resultado de
  un checkpoint WAL antes de copiar una base durante una migración.
- Corregir la propiedad de la barra al rotar una hoja abierta.
- Añadir pruebas unitarias, conformance con SQLite real, fault injection,
  pruebas de escala y gates de emulador/dispositivo.

### Fuera de alcance

- **No reordenar, dividir, combinar, rebasar ni reescribir los commits Git ya
  existentes.** La atomicidad histórica de los commits no forma parte de esta
  remediación.
- No cambiar la representación del anclaje ni volver a introducir detección de
  reflow para los puntos del lienzo.
- No cambiar la tinta directa sobre PDF ni el almacenamiento heredado de esa
  ruta.
- No añadir presión, inclinación, hover ni una API Wacom de nivel inferior.
- No implementar lista global de lienzos, cuaderno multihoja ni exportación.
- No implementar coalescing de refresh de 8–16 ms sin medir primero en el
  Scribe. Se conserva el refresh por segmento ya probado.
- No resolver el agujero preexistente de `hold` de la ruta de dedo descrito por
  ADR-2.
- No cambiar `Repository.SCHEMA_VERSION`: las correcciones propuestas no
  alteran el formato lógico v1.

> La transacción de creación del **esquema SQLite** sí está en alcance. Es un
> problema de integridad de datos distinto de la atomicidad de los commits Git.

## 3. Fuentes de verdad y línea base

Orden de autoridad para implementar:

1. El comportamiento y las pruebas del repositorio actual.
2. KOReader v2026.07 y el `koreader-base` que utiliza ese build.
3. La documentación oficial de SQLite.
4. `epub-canvas-design-2026-08-23.md`, sólo donde no contradiga el runtime ni
   este plan.

Antes de editar, registrar en la descripción del trabajo:

```sh
git status --short --branch
git rev-parse HEAD
luajit test.lua
lua test.lua
```

La ejecución informada antes de esta remediación fue de 1044 comprobaciones y
42 claims de conformance. Esos números son una referencia, no un sustituto de
volver a ejecutar las suites. El runner debe mostrar que ejecutó
`fingerink.koplugin/tests/run.lua`; un `SKIP` no es verde.

## 4. Invariantes que mandan sobre el diseño

### I-1. Identidad única y resoluble

Todo metadata de trazo en la caché tiene exactamente uno de estos estados:

```text
pending:   id local negativo + puntos en memoria + row_id nil
persisted: id SQLite positivo + puntos opcionales nil + row_id == id
```

Nunca se consulta SQLite con un id negativo. Después de confirmar el `COMMIT`,
la caché cambia de forma atómica su clave local por el id SQLite. Antes de ese
momento conserva los puntos en memoria.

### I-2. Secuencia monotónica dentro de la sesión

`seq` no se calcula a partir del último elemento visible después de cada undo.
Al abrir una hoja se inicializa una única vez a `max(seq) + 1`; cada inserción
la incrementa y undo no la decrementa. Así un DELETE todavía pendiente nunca
compite con un INSERT nuevo por `UNIQUE(canvas_id, seq)`.

### I-3. Un fallo conserva la posibilidad de reintento

Si falla un flush interactivo, `Queue.ops`, los puntos pendientes, la caché, la
hoja y su barra siguen vivos. Se bloquea nueva edición, se muestra el error una
vez y quedan accesibles `Retry saving` y `Close sheet`.

### I-4. Una lectura incompleta no equivale a tinta vacía

Un error de `listCanvases`, `listStrokes`, cursor, decode o validación deja el
estado en `load_failed`. No se llama `on_ready`, no se habilita edición y no se
reescribe ni elimina la base.

### I-5. Trabajo acotado durante carga

La rasterización retiene como máximo el raster BB8, metadata O(trazos+chunks),
un chunk decodificado activo y el LRU explícitamente acotado. Cada tick consume
un presupuesto de puntos, no un número de trazos de longitud arbitraria.

### I-6. La UI principal coordina los cambios visibles

Sólo `FingerInk` modifica conjuntamente `canvas_open`, `drawing`, `bar`, el
router y la ventana activa. `Session` devuelve éxito/error y administra datos y
recursos, pero no deja al plugin principal creyendo que una hoja cerrada o
eliminada sigue abierta.

### I-7. Read-only significa ausencia de SQL mutante

Una base con `user_version` futuro puede consultarse, pero no ejecuta
`bookId`, `touchCanvas`, creación, borrado, flush, cambio de journal ni ninguna
otra escritura.

## 5. Mapa de archivos

| Archivo | Responsabilidad tras la remediación |
|---|---|
| `fingerink.koplugin/ink_canvas_queue.lua` | operaciones pendientes, asignación local→SQLite, flush/retry/close |
| `fingerink.koplugin/ink_canvas_cache.lua` | raster, claves activas, metadata de chunks, carga por presupuesto, hit-test y repair |
| `fingerink.koplugin/ink_canvas_codec.lua` | encoder incremental y validador/decoder incremental |
| `fingerink.koplugin/ink_canvas_repository.lua` | cursores de chunks, consultas puntuales, transacciones, esquema, WAL y read-only |
| `fingerink.koplugin/ink_canvas_session.lua` | estado de carga/guardado, `next_seq`, aperturas/cierres/borrados recuperables |
| `fingerink.koplugin/ink_anchor_index.lua` | propagar fallo de listado; nunca convertirlo en índice vacío |
| `fingerink.koplugin/ink_spatial_grid.lua` | seguir indexando cajas; la caché le entrega cajas expandidas por grosor |
| `fingerink.koplugin/ink_canvas_overlay.lua` | mostrar `loading`, `load_failed` y `read_only`; bloquear edición sin ocultar Hide/Retry |
| `fingerink.koplugin/main.lua` | coordinación UI, ciclos de la goma y propiedad de la barra |
| `fingerink.koplugin/tests/support.lua` | dobles con cursores, fallos por etapa, contadores y límites de memoria lógica |
| `fingerink.koplugin/tests/*_spec.lua` | contratos unitarios e integración entre capas |
| `fingerink.koplugin/tests/conformance.lua` | semántica SQLite real, blobs, DDL, WAL y EPUB real |
| `README.md`, `epub-canvas-design-2026-08-23.md` | estado real, límites y gate físico; no promesas adelantadas |

No modificar `ink_capture.lua`, `ink_contact_router.lua`, `ink_store.lua` ni la
ruta PDF salvo que una prueba de regresión demuestre una integración necesaria.

## 6. Orden de implementación

No ejecutar fases posteriores mientras el criterio de salida de la fase actual
esté rojo. No hace falta reorganizar la historia Git para seguir este orden.

### Fase 0 — Fijar los fallos con pruebas de integración rojas

Archivos:

- `fingerink.koplugin/tests/canvas_queue_spec.lua`
- `fingerink.koplugin/tests/canvas_cache_spec.lua`
- `fingerink.koplugin/tests/canvas_session_spec.lua`
- `fingerink.koplugin/tests/main_canvas_spec.lua`
- `fingerink.koplugin/tests/canvas_repository_spec.lua`
- `fingerink.koplugin/tests/canvas_scale_spec.lua`
- `fingerink.koplugin/tests/support.lua`

Trabajo:

1. Añadir un helper que encadene la ruta real
   `Session:addStroke → Queue:flush → Cache:hitTest/removeStroke` en vez de
   probar cada objeto aislado.
2. Añadir fault injection nominal por operación: `listCanvases`, `listStrokes`,
   preparar/avanzar/cerrar cursor, decode, BEGIN, INSERT, DELETE, COMMIT,
   `touchCanvas`, checkpoint y delete de canvas.
3. Hacer que el store falso distinga ids negativos de ids SQLite y cuente cada
   lectura de chunk.
4. Añadir aserciones de estado visible: ventana en stack, `canvas_open`, barra,
   `drawing`, cola, caché, pending ops y notificaciones.

Casos rojos obligatorios antes de tocar producción:

- dibujar → flush → borrar → flush → reabrir: el trazo no vuelve;
- cargar un trazo persistido → undo → flush → reabrir: no vuelve;
- undo de persistido → dibujar antes del flush: no hay colisión de `seq`;
- fallo de COMMIT → Hide: hoja y cola siguen accesibles;
- fallo de lectura: no se presenta como hoja vacía;
- borrar la hoja activa: se limpian todos los flags del plugin sólo si el
  DELETE fue exitoso;
- rotar con hoja abierta: la barra visible sigue siendo `overlay.bar`.

Criterio de salida: las pruebas nuevas fallan por las razones esperadas, y las
pruebas PDF/stylus heredadas continúan verdes.

### Fase 1 — Unificar identidad y secuencia de trazos

Archivos principales:

- `ink_canvas_queue.lua`
- `ink_canvas_cache.lua`
- `ink_canvas_session.lua`
- sus tres specs

#### 1.1 Contrato de Queue

1. Añadir a `Queue.new` un callback `on_persisted(local_id, row_id)`.
2. Mantener `real[local_id] = row_id` como tabla defensiva y para reconciliar
   un flush que ocurra antes de que Session termine de registrar la metadata.
3. Después de un `COMMIT` exitoso, publicar todas las asignaciones mediante
   `on_persisted`. No publicar nada antes del COMMIT ni si éste falla.
4. Cambiar el contrato de `removeStroke(canvas, id)`:

   - `id < 0` y existe INSERT pendiente: retirar ese INSERT;
   - `id < 0` y `real[id]` existe: encolar DELETE del `row_id` resuelto;
   - `id > 0`: encolar DELETE directamente por ese `row_id`;
   - id desconocido: devolver `nil, "unknown_stroke"`, no éxito ficticio.

5. Una operación DELETE almacena `row_id`; `flush` no vuelve a resolverla desde
   `real`.
6. Mantener las asignaciones `real` hasta que la caché confirme el rekey o se
   cierre la sesión. No son la identidad pública del trazo.

#### 1.2 Contrato de Cache

1. La metadata recién dibujada conserva `points` y `n` mientras su id sea
   negativo.
2. Implementar `markPersisted(local_id, row_id)`:

   - verificar que `row_id > 0` y que no colisiona con `by_id`;
   - quitar `local_id` del grid y de `by_id`;
   - cambiar `meta.id` a `row_id` sin alterar su posición ni `seq`;
   - reinsertar la caja expandida bajo `row_id`;
   - registrar `row_id` y liberar `meta.points/meta.n` sólo después de la
     confirmación durable.

3. Si el callback llega antes de `Cache:addStroke`, Session debe consultar
   `Queue:realId(local_id)` inmediatamente después del add y ejecutar el mismo
   rekey. Esa comprobación hace seguro el flush síncrono por umbral existente.
4. Centralizar la obtención de puntos:

   - pending: usar `meta.points`, nunca Repository;
   - persisted: usar las APIs de chunks del repositorio;
   - error: propagarlo; no tratarlo como miss.
5. En erase/undo, Session pide primero a Queue que acepte el DELETE o retire el
   INSERT pendiente. Sólo después quita la metadata de Cache. Si Queue está
   failed/closed o desconoce el id, la caché y el raster no cambian.

#### 1.3 Secuencia

1. Al completar `Cache:open`, Session inicializa `next_seq` a uno más que el
   mayor `seq` listado.
2. `Session:addStroke` toma el valor actual y lo incrementa inmediatamente
   después de aceptar la inserción.
3. `undo`, erase y DELETE no reducen `next_seq`.
4. `next_seq` se descarta al cerrar la hoja.

Pruebas mínimas:

- pending erase/undo no consulta SQLite;
- flush por timer y flush por umbral rekeyean el grid y `by_id`;
- el callback temprano se reconcilia después de `Cache:addStroke`;
- un persistido cargado se elimina usando su id positivo aunque `Queue.real`
  esté vacío;
- draw → flush → erase y reopen → erase sobreviven al reinicio;
- undo persistido → add genera `max_seq + 1`, no reutiliza `seq`;
- repair de una región que contiene pending usa sus puntos en memoria;
- mutaciones que restauren el early return actual o consulten un id negativo
  deben romper al menos una prueba.

Criterio de salida: ninguna ruta de edición consulta SQLite con id negativo y
el ciclo draw/flush/erase/reopen queda verde con store falso y SQLite real.

### Fase 2 — Cierre, cambio y borrado recuperables

Archivos principales:

- `ink_canvas_queue.lua`
- `ink_canvas_session.lua`
- `main.lua`
- `ink_canvas_overlay.lua`
- specs de queue/session/main/overlay

#### 2.1 Flush y cierre

1. `Queue:close()` sólo pone `closed = true` después de un flush exitoso. Ante
   error conserva `ops`, `failed`, `error`, puntos y temporizador cancelado.
2. `Session:closeCanvas()` devuelve `true` o `nil, err`. Si el flush falla, no
   cierra overlay/caché, no pone sus referencias a nil y no cambia `canvas`.
3. Tocar `updated_at` después de guardar la tinta. Un fallo de `touchCanvas`
   se registra, pero no convierte tinta ya durable en pendiente ni impide
   liberar la hoja.
4. `Session:openCanvas(next)` aborta si no puede cerrar la actual. No asigna el
   nuevo canvas ni libera el raster actual.
5. `FingerInk:closeCanvas()` no cambia `canvas_open` ni pierde `bar` hasta que
   Session confirme el cierre. Puede dejar `drawing = false` tras un fallo para
   impedir nueva tinta mientras `Retry saving` está activo.
6. `Session:close({ force = true })` distingue el teardown obligatorio del
   cierre interactivo. Debe intentar flush y notificar; si el proceso/documento
   se está cerrando puede liberar recursos después del fallo, pero nunca debe
   registrar que los datos fueron guardados.
7. `FingerInk:onSaveSettings()` conserva el gate actual y comprueba el retorno
   para emitir la misma notificación deduplicada.

#### 2.2 Borrar una hoja

1. Añadir un coordinador `FingerInk:deleteCanvas(canvas)`; el callback del
   diálogo no llama a Session directamente.
2. Para hoja activa, `Session:deleteCanvas` ejecuta primero el DELETE durable.
   Si falla, overlay, queue, caché e índice permanecen intactos.
3. Sólo después del DELETE exitoso descarta las operaciones pendientes de esa
   hoja, cierra sus recursos y la quita del índice.
4. Tras éxito, FingerInk aborta cualquier trazo en curso sin guardarlo,
   restablece `drawing`, `canvas_open`, `bar`, router y barra independiente, y
   solicita refresh completo.
5. Para hoja inactiva no se toca la hoja abierta ni su cola.

Pruebas mínimas:

- COMMIT falla en Hide, switch y cierre interactivo: no se libera nada;
- Retry exitoso permite cerrar después sin duplicar INSERT/DELETE;
- teardown forzado informa fallo y no afirma durabilidad;
- DELETE activo exitoso deja una sola barra válida y ningún capture de lienzo;
- DELETE activo fallido no descarta pending ni modifica el índice;
- DELETE inactivo no cierra el activo;
- dos callbacks consecutivos de cierre/borrado son idempotentes.

Criterio de salida: no existe camino interactivo que haga nil la cola después
de un flush fallido, y main/session coinciden sobre qué hoja está abierta.

### Fase 3 — Lecturas fail-closed y estados explícitos

Archivos principales:

- `ink_anchor_index.lua`
- `ink_canvas_cache.lua`
- `ink_canvas_session.lua`
- `ink_canvas_overlay.lua`
- `main.lua`

Trabajo:

1. `Index:open()` devuelve `true` o `nil, err`. Un fallo de `listCanvases` no
   llama `_rebuild` con `{}`.
2. `Session:open()` marca `available = true` sólo después de que `book_id` e
   índice se hayan abierto. En fallo cierra el repositorio que posea y expone
   una razón estable.
3. `Cache` adopta estados `loading`, `ready`, `load_failed`, `closed`, con
   `loadError()` y `retryOpen()`.
4. `Cache:open()` devuelve error si falla `listStrokes`; Session no muestra una
   hoja editable en ese caso.
5. Un error asíncrono de cursor/decode/validación:

   - cierra el cursor activo;
   - invalida la generación y cancela batches viejos;
   - conserva metadata y base intactas;
   - cambia a `load_failed`;
   - no llama `on_ready`;
   - notifica una vez.

6. Overlay mantiene visibles Hide y `Retry loading`, pinta un mensaje corto y
   no acepta tinta/undo/erase durante `loading` o `load_failed`.
7. `hitTest` y `repair` devuelven `(resultado, error)`; Session distingue miss
   normal de fallo de lectura y bloquea edición en el segundo caso.

Mensajes mínimos, traducibles:

- `Could not read this sheet's ink. The database was left unchanged.`
- `Retry loading sheet`
- `Could not list this book's sheets.`

Pruebas mínimas:

- error en cada frontera de lectura no crea un índice/canvas vacío;
- decode de un stroke intermedio no deja `ready = true`;
- callbacks de batches anteriores no reviven una caché fallida;
- Retry reconstruye desde cero, con nuevo generation y un único raster;
- ninguna operación de escritura se ejecuta mientras la carga está fallida.

Criterio de salida: toda pérdida de información de lectura es visible y
recuperable; nunca se confunde con “el usuario no tiene notas”.

### Fase 4 — Streaming real, validación estricta y memoria acotada

Archivos principales:

- `ink_canvas_codec.lua`
- `ink_canvas_repository.lua`
- `ink_canvas_cache.lua`
- `ink_canvas_session.lua`
- specs de codec/repository/cache/scale y conformance

#### 4.1 Decoder incremental

Añadir un objeto/estado de decoder con este contrato equivalente:

```text
decoder = Codec.newDecoder(logical_w, logical_h, meta)
points, n, from = decoder:push(chunk_no, sql_point_count, blob)
ok, err = decoder:finish()
```

`push` valida, antes de entregar puntos:

- `meta.codec == Codec.VERSION`;
- `chunk_no` contiguo empezando en 0;
- versión y longitud del header;
- `sql_point_count == header point_count`;
- seam idéntico entre chunks;
- ningún total parcial supera `meta.point_count`.

`finish` exige al menos un chunk y que el total único —sin contar seams
repetidos— sea exactamente `meta.point_count`. Las razones deben ser estables:
`unsupported_codec`, `chunk_order`, `chunk_count`, `chunk_length`, `chunk_joint`
y `stroke_point_count`.

#### 4.2 Cursor del repositorio

1. Reemplazar el uso de `_select` para blobs por
   `Repository:openStrokeCursor(stroke_id)` con `next()` y `close()`.
2. `next()` devuelve una sola fila normalizada
   `{ chunk_no, point_count, points }`. Toda salida numérica pasa por `num` y
   los puntos conservan el `CAST(points AS TEXT)` ya probado.
3. Cerrar el statement en EOF, error, rebuild, rotación y `Cache:close`.
4. Añadir `readStrokeChunk(stroke_id, chunk_no)` para goma/repair local. No
   materializar todos los chunks para esa consulta.
5. Mantener `readStroke` sólo como adaptador de compatibilidad para tests o
   conformance; la caché de producción no lo llama.

#### 4.3 Raster por presupuesto

1. Sustituir `DEFAULT_BATCH = 32 strokes` por
   `DEFAULT_POINT_BUDGET_PER_TICK`, inicialmente 8192 puntos.
2. Mantener un único trabajo activo `{ meta, cursor, decoder }` y consumir
   chunks hasta agotar el presupuesto. Procesar al menos un chunk para evitar
   starvation.
3. Pintar y soltar cada tabla decodificada antes de pedir la siguiente.
4. Construir durante esa pasada metadata en memoria por chunk:
   `{ chunk_no, min_x, min_y, max_x, max_y, point_count }`. Es O(chunks), no
   O(puntos), y permitirá que goma y repair lean sólo chunks relevantes.
5. No permitir edición hasta que todos los strokes hayan terminado y sus
   validadores hayan pasado `finish`.
6. `Cache:addStroke` calcula las mismas cajas de chunk desde los puntos vivos,
   usando exactamente los límites/seams de `Codec`. Debe hacerlo antes de que
   `markPersisted` pueda liberar esos puntos; no crea blobs ni retiene tablas de
   puntos por chunk.

Mantener un cursor SQLite abierto entre ticks es aceptable sólo mientras la
hoja está `loading`: la edición permanece bloqueada y el mismo connection no
intenta escribir. El cursor se debe cerrar antes de pasar a `ready`.

#### 4.4 Encoder incremental

1. Añadir `Codec.eachEncodedChunk(points, n, logical_w, logical_h, callback)`.
2. Validar todos los puntos antes de emitir el primer chunk, para que un
   `bad_point` tardío no deje trabajo parcial dentro de la transacción.
3. `Repository:addStroke` inserta cada blob inmediatamente dentro de su
   transacción y deja que la cadena y su buffer se liberen antes del siguiente.
4. Conservar `Codec.encode` como wrapper para compatibilidad de pruebas, pero no
   usarlo en el write path de producción.

Pruebas mínimas:

- stroke de 100 000 puntos necesita múltiples ticks aunque sea uno solo;
- ningún tick decodifica más que budget + un chunk;
- máximo un cursor activo y cierre probado en EOF/error/rotación/close;
- no se retiene un array de blobs ni el stroke decodificado completo;
- encoder emite en orden y un fallo en el chunk N revierte metadata y chunks;
- faltan chunk 0, intermedio o final; orden cambiado; seam roto; codec futuro;
  recuento SQL/header/meta distinto: todos fallan cerrados;
- blob con NUL conserva el round-trip real;
- los metadatos por chunk cubren todos los segmentos, incluido el seam.

Criterio de salida: las operaciones de carga y escritura tienen pico de memoria
proporcional a un chunk, salvo el raster fijo, metadata y buffers acotados
declarados.

### Fase 5 — Goma correcta y coste controlado

Archivos principales:

- `ink_canvas_cache.lua`
- `ink_spatial_grid.lua` sólo si hace falta una API auxiliar
- `ink_canvas_session.lua`
- `main.lua`
- specs de cache/session/main/scale

Trabajo:

1. Centralizar `Cache:_indexStroke(meta)`. Insertar en el grid la caja de la
   línea central expandida por `meta.width / 2`; no cambiar los valores
   persistidos de `min/max`.
2. Cambiar el hit-test de cercanía a punto por distancia punto–segmento. El
   radio efectivo es `eraser_radius + stroke.width / 2`; un stroke de un punto
   usa distancia punto–punto.
3. Consultar primero el grid de strokes y después la metadata de chunks. Leer
   sólo chunks cuya caja expandida intersecte el círculo de la goma.
4. Añadir un contexto por contacto:

```text
ctx = Cache:beginErase()
hit, err = Cache:hitTest(cx, cy, radius, ctx)
Cache:endErase(ctx)
```

5. El contexto mantiene un LRU de chunks decodificados, no strokes completos,
   con límite explícito —inicialmente 8 chunks— y el último chunk acertado por
   stroke. Un chunk se lee como máximo una vez mientras permanezca en el LRU.
6. Main abre el contexto al primer sample de goma física o modo goma, y lo
   cierra en lift, cambio de herramienta, abort, Close, delete, suspend y
   teardown.
7. Ignorar muestras estacionarias y no repetir hit-test hasta mover al menos
   `max(1 canvas unit, radius / 3)`. No interpolar borrados sin pruebas físicas;
   el stroke completo desaparece al primer hit real.
8. Repair usa las mismas cajas de chunks para no decodificar partes de un
   stroke vecino que no pueden tocar la región. El viewport sigue siendo el
   límite físico de escritura.
9. Contadores dbg por operación, nunca por sample:
   candidates, chunks consultados, hits de LRU, chunks decodificados y píxeles
   reparados.

Pruebas mínimas:

- goma en el punto medio de un segmento largo;
- línea gruesa cuyo centro está en otra celda;
- stroke de un punto;
- seam entre chunks;
- topmost entre strokes superpuestos;
- muestras repetidas dentro del mismo chunk hacen una lectura;
- LRU nunca supera 8 y libera todo en lift/abort;
- un stroke muy largo consulta sólo los chunks cuyas cajas son relevantes;
- región de repair nunca escribe fuera del viewport;
- pending strokes se borran sin SQLite y participan en repair.

Criterio de salida: la precisión depende de la geometría del trazo, no de la
densidad de sus samples, y el coste común depende de strokes/chunks cercanos.

### Fase 6 — Esquema v1, modo futuro y backup WAL

Archivos principales:

- `ink_canvas_repository.lua`
- `ink_canvas_session.lua`
- `ink_canvas_overlay.lua`
- `main.lua`
- specs de repository/session/main y conformance

#### 6.1 Creación transaccional del esquema

1. Ejecutar `BEGIN`, todos los statements de `Repository.SCHEMA`, el
   `PRAGMA user_version`, y `COMMIT` como una unidad. Ante cualquier excepción,
   ejecutar `ROLLBACK` y devolver `schema_failed`.
2. No marcar `self.version` hasta confirmar COMMIT.
3. Si `user_version == 0` pero `sqlite_master` contiene una parte del esquema,
   no hacer DROP ni recrear automáticamente. Devolver `schema_failed` con log
   diagnóstico; los datos existentes quedan intactos.
4. No subir la versión: el formato resultante sigue siendo v1.

#### 6.2 Esquema futuro realmente no mutante

1. Separar `_connect` de la configuración mutante del journal. Leer primero
   `user_version`; si es futuro, no ejecutar `journal_mode=...`.
2. Añadir `findBookId(partial_md5, file_size)` de sólo lectura. `bookId` sigue
   siendo el camino de alta/actualización para esquemas compatibles.
3. Session usa `findBookId` en read-only, permite listar/abrir/rasterizar hojas
   existentes y no crea Queue.
4. Exponer `Session:isWritable()`. Main no activa drawing y el menú deshabilita
   create, delete, undo, pen y eraser. Hide y navegación siguen disponibles.
5. Overlay muestra una vez: `This sheet is read-only because it was created by
   a newer FingerInk version.`
6. Toda API mutante mantiene la guarda de repositorio aunque la UI ya la haya
   deshabilitado.

#### 6.3 Backup después de checkpoint verificable

1. Ejecutar `PRAGMA wal_checkpoint(TRUNCATE)` mediante statement que lea las
   tres columnas.
2. Aceptar sólo `busy == 0` y `log_frames == checkpointed_frames`; aceptar
   `-1/-1` cuando no existe WAL.
3. Ante busy, mismatch o error, no desconectar ni copiar el archivo principal;
   devolver `migration_checkpoint_failed` y dejar la base original operativa.
4. Sólo después de checkpoint exitoso: desconectar, copiar, reconectar y
   ejecutar la escalera de migración transaccional existente.

Pruebas mínimas:

- fault injection después de cada statement DDL deja `user_version == 0` y no
  presenta un schema completo falso;
- una base v0 parcialmente existente no se borra;
- base futura lista y pinta una hoja existente, pero no ejecuta SQL mutante;
- base futura sin book devuelve “sin hojas” read-only, no inserta `books`;
- checkpoint 0/N/N permite backup; 1/N/M lo impide;
- con SQLite real y segunda conexión lectora, un checkpoint bloqueado no crea
  backup incompleto;
- migración fallida conserva original y backup utilizable.

Criterio de salida: ningún path de compatibilidad o migración puede escribir en
un schema desconocido ni copiar deliberadamente un main file con WAL pendiente.

### Fase 7 — Rotación y propiedad de la barra

Archivos principales:

- `main.lua`
- `ink_canvas_overlay.lua`
- `ink_canvas_session.lua`
- `main_canvas_spec.lua`
- `canvas_overlay_spec.lua`

Trabajo:

1. En `FingerInk:onScreenResize`, si hay overlay activo, no ejecutar
   `rebuildBar()` para la barra independiente.
2. Pedir a overlay que reconstruya geometría/barra y, al terminar, reasignar
   `self.bar = overlay.bar`.
3. Si no hay hoja, conservar el camino actual de `rebuildBar`.
4. Asegurar que el router consulta geometría actual, no una `dimen` capturada
   antes de rotar.
5. Invalidar el build anterior de caché, cerrar su cursor y arrancar una nueva
   generación con el transform rotado.

Pruebas mínimas:

- las cuatro rotaciones con hoja loading, ready y load_failed;
- siempre hay una sola barra en el window stack;
- `self.bar == session:overlay().bar` con hoja abierta;
- Draw/Stop, Undo, Hide y cambio de altura alcanzables después de rotar;
- el batch de la geometría vieja no pinta ni llama `on_ready`;
- sin hoja, la ruta PDF conserva su barra y transform actuales.

Criterio de salida: ninguna rotación separa la barra que ve el usuario de la
barra que main cree poseer.

### Fase 8 — Escala, observabilidad y gates finales

#### 8.1 Pruebas sintéticas de escala

Extender `canvas_scale_spec.lua` con al menos:

- 10 000 strokes cortos y distribuidos;
- 2 500 strokes densos en una región;
- un stroke de 100 000 puntos;
- 1 000 ciclos draw/undo;
- rotación durante carga;
- COMMIT fallido con ocho operaciones/64 KiB pendientes;
- borrado repetido a lo largo de un stroke multichunk.

Medir mediante contadores deterministas, no tiempo de CI:

- puntos decodificados por tick;
- cursores/statements abiertos;
- chunks vivos en decoder/LRU;
- consultas durante repaint/page turn;
- candidatos y chunks durante erase/repair;
- operaciones conservadas después de fallo.

Gates:

- repaint de una hoja ready: cero decode y cero SQL;
- page turn: cero SQL de puntos y cero resolución masiva de xpointers;
- carga: `decoded_points_per_tick <= budget + MAX_POINTS`;
- un cursor de raster activo como máximo;
- LRU de goma dentro del límite;
- buffer BB8 único para la hoja activa;
- cola nunca supera sus límites sin programar/ejecutar flush, salvo que esté en
  estado failed y retenga datos para Retry.

#### 8.2 Verificación local y conformance

Desde la raíz del repositorio:

```sh
luajit test.lua
lua test.lua
```

Desde `fingerink.koplugin/`, usando la skill instalada:

```sh
KOREADER_QA="$HOME/.codex/skills/koreader-simulator-qa/scripts/koreader_qa.sh"
"$KOREADER_QA" preflight
"$KOREADER_QA" test
"$KOREADER_QA" smoke
```

Para conformance, desde el directorio del build KOReader:

```sh
./luajit /ruta/absoluta/fingerink.koplugin/tests/conformance.lua
./luajit /ruta/absoluta/fingerink.koplugin/tests/conformance.lua /ruta/a/juliet.epub
```

Registrar versión/commit real del runtime. Si no es v2026.07 exacto, marcar la
diferencia; un resultado de otro tag no cierra compatibilidad con v2026.07.

#### 8.3 Smoke SDL aislado

Usar estado temporal y no el perfil real del lector. Abrir un EPUB real y
verificar:

- ReaderUI carga sin traceback;
- se registra el libro por checksum+tamaño;
- hoja nueva y hoja persistida abren;
- loading impide tinta y ready la permite;
- Close/Retry/Delete/rotación conservan una barra;
- direct ink en PDF sigue funcionando con el feature de canvas inactivo.

SDL no valida Wacom, latencia, ghosting ni waveforms.

#### 8.4 Gate físico obligatorio en Kindle Scribe

No declarar la remediación terminada para distribución sin esta matriz:

| Caso | Resultado que registrar |
|---|---|
| 40/70/100% | alineación, clipping y alcance del asa |
| lápiz continuo | latencia respecto de tinta directa PDF |
| palma + lápiz | no navega ni dibuja fuera de la regla prevista |
| dedo sobre la hoja | suprimido mientras el dedo fuera puede navegar |
| goma física/manual | precisión en segmentos finos/gruesos y multichunk |
| 10k strokes | tiempo de apertura, memoria, respuesta del menú |
| rotación durante carga | sin crash, doble barra ni raster viejo |
| suspend con pending | `SaveSettings` hace durable o muestra fallo |
| SQLite lleno/fallo inducido seguro | Retry visible, sin cierre silencioso |
| reabrir libro | draw/erase/undo/delete siguen persistiendo correctamente |

Medir primero; no introducir coalescing de refresh en esta remediación salvo
que exista una comparación A/B en el dispositivo.

## 7. Stop conditions

El implementador debe detenerse y pedir revisión si ocurre cualquiera:

- la solución de identidad requiere cambiar ids ya escritos o migrar schema;
- hace falta guardar puntos de EPUB en DocSettings;
- una corrección exige interceptar eventos Linux fuera de la API de KOReader;
- el driver real no permite cerrar de forma fiable un statement conservado
  entre ticks;
- `wal_checkpoint` no entrega las tres columnas en el driver del runtime;
- soportar read-only obliga a mutar el journal de una base futura;
- una optimización aumenta memoria en proporción al número total de puntos;
- la ruta PDF o los 258 checks de stylus existentes retroceden;
- un test sólo puede pasar debilitando una aserción o reemplazando SQLite real
  por un fake en una afirmación de semántica SQL.

Ante el problema del cursor entre ticks, la alternativa permitida es leer un
chunk por consulta `(stroke_id, chunk_no)` y programar el siguiente tick. No se
permite volver a materializar todo el stroke.

## 8. Registro de validación externa

### Tema: fallo de COMMIT y retención de la transacción

- Motivo: decide si `Queue:close` puede descartar estado tras un COMMIT fallido.
- Fuente: [SQLite — Transactions](https://www.sqlite.org/lang_transaction.html).
- Verificado: COMMIT puede fallar con `SQLITE_BUSY`; en ese caso la transacción
  permanece activa y puede reintentarse.
- Impacto: nunca asumir durabilidad ni cerrar la cola cuando COMMIT falla;
  conservar operaciones y permitir Retry.
- Restricciones: semántica SQLite; el wrapper Lua debe propagar el error.
- Confianza: alta.

### Tema: resultado de `wal_checkpoint(TRUNCATE)`

- Motivo: copiar sólo el archivo principal con frames pendientes puede producir
  un backup incompleto.
- Fuente: [SQLite — PRAGMA wal_checkpoint](https://www.sqlite.org/pragma.html#pragma_wal_checkpoint).
- Verificado: devuelve `busy`, frames en WAL y frames checkpointed; TRUNCATE sólo
  trunca a cero al completar con éxito y puede quedar bloqueado por otros
  lectores/escritores.
- Impacto: leer y validar las tres columnas antes de desconectar/copiar.
- Restricciones: con `-1/-1` no hay WAL; debe tratarse como caso válido.
- Confianza: alta.

### Tema: ciclo de cierre y guardado de KOReader

- Motivo: el último flush debe ocurrir antes de que ReaderUI y DocSettings se
  cierren.
- Fuente: [KOReader v2026.07 — UIManager](https://github.com/koreader/koreader/blob/v2026.07/frontend/ui/uimanager.lua) y [ReaderUI](https://github.com/koreader/koreader/blob/v2026.07/frontend/apps/reader/readerui.lua).
- Verificado: el ciclo de cierre emite el evento de settings antes de retirar la
  UI; la ruta de suspend fuerza el guardado antes del evento Suspend.
- Impacto: conservar `onSaveSettings` como gate durable; `onSuspend` no lo
  reemplaza.
- Restricciones: contrato validado contra el tag v2026.07; repetir con el build
  exacto usado para empaquetar.
- Confianza: alta.

### Tema: timeouts de input y alcance de esta remediación

- Motivo: no reabrir accidentalmente el problema de hold/palma al tocar ciclos
  de goma o cierre.
- Fuente: [KOReader v2026.07 — Input](https://github.com/koreader/koreader/blob/v2026.07/frontend/device/input.lua).
- Verificado: los timeouts de Input tienen despacho propio y el reset de estado
  limpia timeouts/contactos; no todos los gestos diferidos pueden corregirse
  filtrando el resultado de `GestureDetector:feedEvent`.
- Impacto: los cambios de esta remediación se limitan al estado de goma del
  canvas y no modifican ADR-2 ni el backend de dedo.
- Restricciones: el hardware Scribe sigue necesitando validación física.
- Confianza: alta para API; no aplicable a latencia física.

### Tema: BLOB e INTEGER del driver KOReader

- Motivo: no perder las correcciones ya verificadas al introducir cursores.
- Fuente: [koreader-base — lua-ljsqlite3](https://github.com/koreader/koreader-base/blob/master/ffi/ljsqlite3.lua) y conformance local contra el driver real.
- Verificado: el boundary actual requiere normalizar INTEGER con `tonumber` y
  conservar `CAST(? AS BLOB)`/`CAST(points AS TEXT)` para strings binarias.
- Impacto: todas las nuevas APIs de cursor y chunk mantienen `num` y ambos CAST;
  los tests con NUL siguen siendo obligatorios.
- Restricciones: volver a verificar contra el commit de koreader-base incluido
  en el runtime objetivo.
- Confianza: alta.

## 9. Matriz final de trazabilidad del análisis

Esta tabla es el checklist de cierre. Ninguna fila puede desaparecer del PR de
remediación aunque la implementación agrupe tareas de otra manera.

| ID | Punto del análisis previo | Fase que lo corrige | Prueba/gate que lo demuestra |
|---|---|---|---|
| C1-a | id negativo queda en caché después del flush | 1.1–1.2 | flush por timer/umbral rekeyea cache y grid |
| C1-b | hit-test/repair consulta SQLite con id negativo | 1.2 | pending erase/repair con contador SQL cero |
| C1-c | persistido reabierto no existe en `Queue.real` y no se borra | 1.1 | reopen → erase/undo → flush → reopen |
| C1-d | undo persistido + draw reutiliza `seq` | 1.3 | DELETE pendiente + INSERT usa `max_seq + 1` |
| C1-e | erase parece funcionar y el stroke resucita | 1 + conformance | ciclo completo con SQLite real |
| M1-a | `Queue:close` se marca closed tras fallo | 2.1 | COMMIT fallido conserva `closed=false` y ops |
| M1-b | Session ignora error y libera queue/cache/overlay | 2.1 | Hide/switch fallidos conservan referencias y UI |
| M1-c | teardown no distingue fallo irrecuperable | 2.1 | forced close notifica y no afirma durabilidad |
| M2 | delete activo deja flags/bar/capture inconsistentes | 2.2 | delete activo success/failure en test de window stack |
| M3-a | `listCanvases` fallido se vuelve índice vacío | 3 | Index.open propaga error y Session queda unavailable |
| M3-b | `listStrokes`/decode fallido se vuelve hoja vacía/ready | 3–4 | estados load_failed, sin on_ready ni writes |
| M3-c | hit-test/repair oculta errores como misses | 3 | retorno `(nil, err)` bloquea edición y notifica |
| M4-a | `_select` materializa todos los blobs | 4.2 | cursor entrega un row por vez y máximo uno activo |
| M4-b | `Codec.join` materializa stroke completo | 4.1–4.3 | stroke 100k repartido en ticks/chunks |
| M4-c | `Codec.encode` duplica todos los blobs | 4.4 | callback incremental, rollback en fallo de chunk |
| M5-a | goma sólo mide puntos, no segmentos | 5 | hit en punto medio de segmento |
| M5-b | grid ignora grosor | 5 | línea gruesa cruzando límite de celda |
| M5-c | lectura SQLite por cada sample | 5 | LRU + umbral de movimiento + contador de lecturas |
| M5-d | peor caso de stroke largo no está acotado localmente | 4.3 + 5 | cajas por chunk; sólo chunks relevantes |
| M6 | creación del schema puede quedar parcial | 6.1 | fault injection DDL + SQLite real |
| m1 | rotación reemplaza `main.bar` por barra equivocada | 7 | `self.bar == overlay.bar`, una sola ventana |
| m2-a | no se valida `meta.codec` | 4.1 | codec futuro produce load_failed |
| m2-b | no se valida orden/recuento/seam de chunks | 4.1 | gaps, reorder, counts y joint corruptos |
| m3 | schema futuro dice read-only pero no puede abrir libro/hoja | 6.2 | findBookId + visualización sin SQL mutante |
| m4 | checkpoint WAL se ignora antes del backup | 6.3 | busy/mismatch abortan copia y migración |
| S1 | faltan contadores prometidos para escala | 5.9 + 8.1 | counters por operación, no por sample |
| S2 | falta probar runtime exacto v2026.07 | 8.2 | log de tag/commit y conformance sin MISMATCH |
| S3 | falta gate físico Scribe | 8.4 | matriz firmada con resultados reales |
| S4 | posible regresión de tinta directa PDF | 0 + 7 + 8 | suite heredada y smoke PDF sin canvas |
| S5 | no introducir coalescing sin medir | no objetivo + 8.4 | A/B físico requerido antes de cambiar refresh |
| S6 | hold de ruta de dedo preexistente | no objetivo | ADR-2 permanece documentado; no se afirma corregido |
| G1 | atomicidad de commits Git | fuera de alcance | no rebase/squash/reorganización de historia |

## 10. Definición de terminado

El trabajo puede considerarse listo para revisión cuando:

- todas las filas C1, M1–M6 y m1–m4 tienen cambio y prueba correspondiente;
- suites LuaJIT y Lua pasan sin reducir aserciones;
- preflight, sintaxis y smoke pasan y no muestran `SKIP` inesperado;
- conformance SQLite real cubre BLOB, INTEGER, cascades, identidad, DDL y WAL;
- los fallos inyectados conservan datos y estado recuperable;
- los límites por tick/chunk/LRU están expresados como aserciones;
- la documentación describe streaming, read-only y fallos tal como quedaron,
  no como se esperaba que quedaran;
- la ruta PDF permanece sin cambios funcionales;
- el gate físico del Scribe está ejecutado, o el PR queda explícitamente marcado
  “no listo para distribución” hasta completarlo;
- no se ha reescrito ni reorganizado la historia de commits existente.
