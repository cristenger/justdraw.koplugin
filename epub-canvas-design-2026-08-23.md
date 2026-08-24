# FingerInk: lienzo EPUB anclado y escalable — diseño revisado

Fecha: 2026-08-23

Feature ID: `FI-CANVAS-001`

Base: rama `codex/kindle-scribe-stylus`, tras `FI-SCRIBE-STYLUS-002`

Estado: **implementado**. Ver §15 para el registro de ejecución y las
desviaciones deliberadas respecto de este documento.

Documentos previos: [`kindle-scribe-stylus-dev-plan-2026-08-23.md`](kindle-scribe-stylus-dev-plan-2026-08-23.md),
[`kindle-scribe-stylus-remediation-plan-2026-08-23.md`](kindle-scribe-stylus-remediation-plan-2026-08-23.md)

## 0. Resultado de la revisión

La idea de producto sigue siendo viable: una hoja superpuesta, anclada al libro
por un xpointer, evita ligar cada punto manuscrito al texto reflowable. Lo que no
escala es la primera arquitectura que la acompañaba. Este documento la sustituye.

Se mantienen estas decisiones:

- los trazos viven en coordenadas propias del lienzo;
- la hoja aparece desde la parte inferior y puede ocupar 40, 70 o 100% de la
  pantalla;
- el texto queda visible por encima de la hoja;
- con el lienzo abierto, el dedo puede navegar fuera de la hoja cuando no hay
  un contacto de lápiz activo;
- el dibujo directo actual sobre PDF y su clave `fingerink_strokes` no cambian.

Se reemplazan cinco piezas del diseño anterior:

| Diseño anterior | Decisión revisada | Motivo |
| --- | --- | --- |
| Todos los lienzos y puntos en `fingerink_canvases` dentro de `metadata.lua` | SQLite dedicada, BLOBs de puntos y carga perezosa | `DocSettings:flush()` serializa y reescribe toda la tabla; el coste crece con todas las notas del libro |
| `ReaderUI < hoja < barra`, tres ventanas ordinarias | Una sola ventana compuesta `InkCanvasOverlay`, con hoja y barra como hijos | `UIManager` no propaga automáticamente un evento ordinario a ventanas inferiores; una sola ventana elimina una pila frágil |
| Supresión según la posición de cada gesto | Destino fijado al comienzo de cada contacto/slot | Un contacto que cruza hoja, texto o barra no puede cambiar de dueño a mitad de secuencia |
| Escalado sólo por el ancho | Transformación uniforme `aspect-fit`, con inversa única | La rotación y las pantallas con otra relación de aspecto deben conservar todo el lienzo sin deformarlo |
| `paintTo` vuelve a recorrer todos los vectores | Caché raster acotada al lienzo activo, índice espacial y repintado por región | El coste de pintar o borrar deja de depender de todos los puntos del libro |

Una corrección deliberada respecto de la versión anterior: vuelve a aparecer
`getDocumentRenderingHash(true)`, pero sólo para identificar una **caché
descartable de localización**. El xpointer sigue siendo la verdad del anclaje.
Un reflow invalida páginas resueltas y marcas; no modifica el lienzo ni sus
trazos.

## 1. Objetivo, límites e invariantes

### 1.1 Objetivo funcional

El lector puede crear una hoja en blanco desde una posición de un EPUB, escribir
con el lápiz del Kindle Scribe, cambiar la altura visible, cerrar la hoja y
recuperarla desde su posición del libro. Cientos de lienzos cerrados no deben
hacer más lenta cada página ni mantener sus trazos en memoria.

La hoja es una superposición de frontend. No inserta espacio en CREngine, no
forma parte del DOM y no altera el reflow del EPUB.

### 1.2 Invariantes

1. La identidad de un trazo es `(canvas_id, stroke_id)`; nunca una página EPUB.
2. El xpointer ancla el lienzo. Una página resuelta es sólo una caché.
3. Sólo el lienzo activo puede tener puntos decodificados o caché raster en
   memoria.
4. `paintTo` no consulta SQLite, no resuelve xpointers y no recorre la colección
   completa de vectores.
5. Ninguna muestra del lápiz escribe en disco.
6. El destino de un contacto se fija una vez y no cambia hasta su lift.
7. La barra se pinta y recibe entrada por encima de la hoja dentro de la misma
   ventana.
8. Una operación fallida de base de datos no crea una base vacía ni descarta la
   cola pendiente en silencio.
9. Un ancla que ya no se resuelve se conserva y aparece como recuperable.
10. El formato actual de tinta directa en PDF no se migra ni se reutiliza para
    los lienzos EPUB.

## 2. Comportamiento visible

### 2.1 Abrir, mantener y cambiar de lienzo

- `Abrir hoja` en una vista sin lienzos crea uno en el principio de la vista.
- Si hay uno en la vista, lo abre.
- Si hay varios, muestra un selector local; no elige el primero en silencio.
- Pasar página con la hoja abierta **no cambia el lienzo activo**. La hoja queda
  fijada hasta que el usuario la cierre o elija otra. Esto permite consultar
  otras páginas mientras se escribe.
- Antes de cambiar de lienzo se confirma la cola pendiente, se libera la caché
  anterior y sólo entonces se carga el siguiente.
- `Eliminar hoja` forma parte de v1, pide confirmación y borra en cascada sus
  trazos.

La lista global de todos los lienzos sigue fuera de v1. Sí entra un acceso
mínimo a los anclajes no encontrados: contador, fecha de modificación y acción
para abrir o eliminar. Sin esto, conservar un xpointer inválido no sirve al
usuario.

### 2.2 Altura de la hoja

La altura es estado de interfaz, no del contenido. Se guarda como preferencia
global de FingerInk y usa paradas de 40, 70 y 100%. Cerrar corresponde a 0%.

El asa usa `hold_pan`, como `MovableContainer`. Durante el arrastre no se
repinta la hoja; la altura se calcula y se aplica al soltar. KOReader sigue este
patrón para evitar repintados continuos en e-ink. Si la prueba física demuestra
que hace falta respuesta, sólo se añade una línea indicadora estrecha; no un
repintado completo por movimiento.

## 3. Persistencia

### 3.1 Por qué el sidecar monolítico queda descartado

`DocSettings:flush()` ejecuta `dump(data, nil, true)` y escribe el resultado
completo. Guardar `fingerink_canvases` allí haría que una nueva raya serializara
de nuevo todos los puntos acumulados. También duplicaría ese volumen en las
copias de seguridad de metadatos que el usuario tenga activadas.

Una sonda local con el `dump.lua` real de KOReader v2026.07 midió el formato
actual de trazo:

| Puntos en un trazo | Salida Lua |
| ---: | ---: |
| 25 | 1.896 bytes |
| 100 | 6.749 bytes |
| 600 | 40.151 bytes |
| 2.000 | 136.651 bytes |

Son aproximadamente 67 bytes por punto. Mil trazos de 600 puntos ocuparían
unos 38,3 MiB sólo en la representación Lua. Un par `x/y` normalizado en dos
enteros de 16 bits ocupa 4 bytes antes del overhead de SQLite. La diferencia es
suficiente para no usar el sidecar como almacén nuevo.

### 3.2 Ubicación e identidad del libro

La base se crea en:

```lua
DataStorage:getSettingsDir() .. "/fingerink.sqlite3"
```

Es la misma ubicación global que usa el plugin oficial Statistics para su base.
No se coloca un archivo arbitrario dentro de `.sdr`: `DocSettings.updateLocation`
sólo conoce `metadata.lua`, la portada personalizada y metadatos personalizados;
un archivo adicional no seguiría de forma fiable un mover, copiar o borrar.

El repositorio se abre en `onReaderReady(config)`, no en `init()`. `ReaderUI`
calcula `partial_md5_checksum` antes de emitir `ReaderReady`. La clave de libro
es `(partial_md5_checksum, file_size)`, donde el tamaño se obtiene con
`lfs.attributes(document.file, "size")`; `last_path` sirve para diagnóstico, no
como identidad. Dos copias byte a byte idénticas comparten los lienzos si
comparten la misma base de FingerInk. Un libro copiado por sí solo a otro
dispositivo no lleva las notas: sincronización y exportación siguen fuera de
alcance. El backup del lector debe incluir `fingerink.sqlite3`, no sólo la
carpeta `.sdr` del libro. Con WAL activo, el backup se hace con KOReader cerrado
o incluye también los archivos `-wal`/`-shm`.

Si falta el checksum o el tamaño, no se usa la ruta como sustituto silencioso.
La apertura del repositorio se aplaza o la función de lienzo queda en sólo
lectura con un mensaje; una ruta rompería las notas al renombrar el libro.

### 3.3 Esquema v1

El esquema exacto puede expresarse así. Los nombres son contrato para la
implementación y para las pruebas de migración:

```sql
CREATE TABLE books (
    id           INTEGER PRIMARY KEY,
    partial_md5  TEXT    NOT NULL,
    file_size    INTEGER NOT NULL,
    last_path    TEXT,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    UNIQUE(partial_md5, file_size)
);

CREATE TABLE canvases (
    id                    INTEGER PRIMARY KEY,
    book_id               INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
    anchor_kind           TEXT    NOT NULL CHECK(anchor_kind IN ('xpointer', 'page')),
    anchor_key            TEXT    NOT NULL,
    anchor_raw            TEXT,
    anchor_normalized     TEXT,
    anchor_dom_version    INTEGER,
    fixed_page            INTEGER,
    logical_w             INTEGER NOT NULL,
    logical_h             INTEGER NOT NULL,
    created_at            INTEGER NOT NULL,
    updated_at            INTEGER NOT NULL,
    UNIQUE(book_id, anchor_key),
    UNIQUE(id, book_id)
);

CREATE TABLE canvas_layout_cache (
    canvas_id      INTEGER NOT NULL,
    book_id        INTEGER NOT NULL,
    layout_hash    TEXT    NOT NULL,
    resolved_page  INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    PRIMARY KEY(canvas_id, layout_hash),
    FOREIGN KEY(canvas_id, book_id)
        REFERENCES canvases(id, book_id) ON DELETE CASCADE
);

CREATE TABLE strokes (
    id           INTEGER PRIMARY KEY,
    canvas_id    INTEGER NOT NULL REFERENCES canvases(id) ON DELETE CASCADE,
    seq          INTEGER NOT NULL,
    width        REAL    NOT NULL,
    tool         INTEGER NOT NULL,
    codec        INTEGER NOT NULL,
    point_count  INTEGER NOT NULL,
    min_x        REAL    NOT NULL,
    min_y        REAL    NOT NULL,
    max_x        REAL    NOT NULL,
    max_y        REAL    NOT NULL,
    created_at   INTEGER NOT NULL,
    UNIQUE(canvas_id, seq)
);

CREATE TABLE stroke_chunks (
    stroke_id    INTEGER NOT NULL REFERENCES strokes(id) ON DELETE CASCADE,
    chunk_no     INTEGER NOT NULL,
    point_count  INTEGER NOT NULL,
    points       BLOB    NOT NULL,
    PRIMARY KEY(stroke_id, chunk_no)
);

CREATE INDEX canvases_by_book ON canvases(book_id, updated_at);
CREATE INDEX layout_by_page
    ON canvas_layout_cache(book_id, layout_hash, resolved_page, canvas_id);
CREATE INDEX strokes_by_canvas ON strokes(canvas_id, seq);
```

`anchor_key` es `xp:<xpointer normalizado>` cuando existe; para layout fijo es
`page:<n>`. La restricción evita duplicados creados por taps repetidos.

El BLOB usa un codec versionado. En v1 cada punto se normaliza a `0...65535` en
ambos ejes y se codifica como dos `uint16` little-endian. No se depende de
`string.pack`, ausente en LuaJIT 5.1: `ink_canvas_codec.lua` usa `string.char` y
`string.byte`, con tests de ida y vuelta, límites y payload truncado. Un chunk
contiene como máximo 1.024 puntos y repite el punto de unión necesario para que
un segmento no se corte entre chunks. `stroke_id` conserva la semántica de
undo y borrado aunque un trazo tenga varios chunks.

Los puntos de lienzos cerrados nunca se convierten a tablas Lua. Para construir
o reparar la caché activa se leen chunks por orden, se decodifica uno, se pinta
y se libera antes del siguiente.

No existe una migración desde `fingerink_canvases`: esa clave pertenecía sólo
al diseño y nunca llegó a producción. `fingerink_strokes` continúa en el
sidecar con el formato actual.

### 3.4 Journal, migraciones y errores

El repositorio sigue el precedente de Statistics:

- `require("lua-ljsqlite3/init")`;
- `PRAGMA foreign_keys=ON` en cada conexión;
- `PRAGMA journal_mode=WAL` sólo si `Device:canUseWAL()`; en caso contrario,
  `TRUNCATE`;
- versión mediante `PRAGMA user_version`;
- checkpoint, conexión cerrada y copia de seguridad antes de cualquier
  migración;
- migración completa dentro de una transacción;
- si `user_version` es mayor que el conocido, abrir sin escritura y explicar
  que el KOReader/plugin es más antiguo;
- no usar `synchronous=OFF`, no ejecutar `VACUUM` al cerrar y no recrear
  automáticamente una base que falle al abrir.

Las páginas liberadas por borrados pueden reutilizarse dentro de SQLite. Reducir
físicamente el archivo será una acción de mantenimiento posterior; no debe
introducir una pausa impredecible durante lectura o suspensión.

## 4. Anclaje y descubrimiento

### 4.1 Crear un ancla EPUB

Al crear el lienzo:

1. obtener `anchor_raw = document:getXPointer()`;
2. obtener `anchor_normalized = document:getNormalizedXPointer(anchor_raw)`;
3. guardar el `cre_dom_version` actual;
4. si ambos valores faltan o son inválidos, no crear una hoja que luego no
   pueda encontrarse;
5. usar el normalizado para `anchor_key` cuando exista y conservar el raw como
   fallback para libros que todavía usan un DOM antiguo.

Al cargar, se prueba primero el xpointer adecuado a la versión DOM actual y
luego el alternativo. `isXPointerInDocument` valida el resultado. Un fallo no
borra la fila: marca el lienzo como huérfano recuperable.

Esto no puede delegarse a la migración interna de `ReaderRolling`: su lista de
xpointers incluye sólo la última posición y `page/pos0/pos1` de anotaciones. No
conoce las tablas de FingerInk. Guardar la forma normalizada desde el nacimiento
evita depender de ese recorrido cerrado.

### 4.2 Índice por página

No se llama `isXPointerInCurrentPage` para cada lienzo en cada repintado. Al
abrir el libro se carga sólo la metadata de `canvases` y se construye:

```text
anchor_by_id[canvas_id] = metadata pequeña
canvas_ids_by_page[resolved_page] = { id, ... }
orphan_ids = { id, ... }
```

Para un hash de layout ya conocido, `canvas_layout_cache` llena el segundo mapa
sin resolver xpointers. Cuando el hash cambia, las entradas antiguas se ignoran
y la resolución se reparte en lotes mediante `UIManager:nextTick`: cada lote
ejecuta `getPageFromXPointer` sobre pocas anclas y publica sus resultados. Al
terminar cada lote, una transacción del mismo tamaño guarda sólo esas filas y
reutiliza un único statement preparado. Las filas parciales son caché derivada
segura: si falta una se resuelve de nuevo. Sólo el lote final poda layouts
antiguos, evitando una ráfaga SQLite O(número de lienzos) en el último tick.

La tabla no crece con cada prueba de tipografía: después de completar un índice
se conservan, como máximo, el layout actual y el anterior de ese libro. Las
filas más antiguas se eliminan dentro de la misma transacción. Mientras el
índice actual esté incompleto, la marca puede aparecer progresivamente y la
acción de crear queda deshabilitada con `Indexando notas…`; así no se crea un
duplicado sólo porque un ancla existente todavía no se resolvió.

`DocumentRerendered`, cambios de tipografía, márgenes o rotación fuerzan una
nueva lectura de `getDocumentRenderingHash(true)` y reconstruyen este índice.
No tocan `strokes`. `PageUpdate` y `PosUpdate` obtienen del mapa sólo los
candidatos de la página actual y las páginas visibles que informe
`getVisiblePageNumberCount()`. Sobre ese conjunto acotado se confirma
`isXPointerInCurrentPage`; nunca se recorre el libro completo. El `paintTo` de
la marca sólo lee el resultado ya preparado para la vista y no ejecuta SQL ni
una llamada CREngine.

## 5. Coordenadas y renderizado

### 5.1 Transformación única

El lienzo conserva `logical_w × logical_h`, la geometría con la que nació. En
cada pantalla se calcula un rectángulo virtual de una pantalla completa:

```text
scale    = min(screen_w / logical_w, screen_h / logical_h)
draw_w   = logical_w * scale
draw_h   = logical_h * scale
offset_x = (screen_w - draw_w) / 2
offset_y = 0

screen_x = offset_x + canvas_x * scale
screen_y = sheet_top + offset_y + canvas_y * scale

canvas_x = (screen_x - offset_x) / scale
canvas_y = (screen_y - sheet_top - offset_y) / scale
```

La alineación vertical es superior porque la hoja revela el lienzo de arriba
hacia abajo. Los laterales que queden fuera de `draw_w` son margen, no lienzo.
El grosor se multiplica por `scale`. Toda entrada, hit test, borrado, caché y
pintado usa este objeto `CanvasTransform`; no se duplican fórmulas en `main.lua`
y el widget.

Al rotar o cambiar tamaño se aborta el trazo en curso, se descarta la caché
raster, se reconstruye la transformación y se vuelve a rasterizar desde la
base. Los datos vectoriales no se reescriben. A 100% debe quedar visible el
lienzo completo, con letterboxing si la relación de aspecto cambió.

### 5.2 Recorte real

Recortar únicamente la caja de `refreshFast` no evita escribir píxeles fuera
de la hoja. El destino de tinta en vivo es un `BlitBuffer:viewport()` limitado
al rectángulo visible. Un viewport comparte la memoria del buffer original y
acota la escritura sin reservar otro framebuffer.

El flujo de un segmento es:

```text
punto de lápiz
  -> coordenada lógica
  -> actualizar stroke en curso
  -> dibujar en la caché del lienzo activo
  -> copiar sólo la caja sucia a Screen.bb:viewport(sheet_rect)
  -> acumular caja de refresh
```

Las cajas se agrupan por tick, no se refresca una vez por muestra. El intervalo
inicial será el ya previsto de 8–16 ms y se ajustará sólo con el Scribe físico.
La acción programada se guarda como función y se cancela pasando esa misma
referencia a `UIManager:unschedule`; no se trata el retorno de `scheduleIn`
como un handle.

### 5.3 Caché activa e índice espacial

Hay una única caché raster BB8 del tamaño físico del lienzo transformado. En un
Scribe de 1860 × 2480 su cota es aproximadamente 4,4 MiB. Se libera al cerrar o
cambiar de lienzo.

La apertura sigue estos pasos:

1. leer sólo filas de `strokes` del lienzo activo, sin `points`;
2. construir una cuadrícula espacial en memoria a partir de sus bounding boxes;
3. rasterizar los chunks en lotes cooperativos;
4. mostrar un estado `Cargando tinta…` y bloquear edición hasta terminar;
5. una vez lista, `paintTo` blitea la caché y no recorre vectores.

El tamaño de celda se elige una vez a partir de la geometría de pantalla y se
mantiene constante durante la sesión. Un stroke se registra en todas las celdas
que toca. El borrador obtiene candidatos de esas celdas, los examina de arriba
hacia abajo y sólo decodifica sus chunks. Tras borrar o deshacer:

- invalida la bounding box afectada, alineada a celdas;
- limpia esa región de la caché;
- consulta el índice por trazos que intersectan la región;
- vuelve a pintar sólo esos trazos sobre un viewport de la región.

El peor caso de muchos trazos totalmente superpuestos sigue siendo lineal en
ese lienzo; no existe una estructura que lo elimine sin más complejidad. La
arquitectura evita que el caso normal dependa de puntos de otros lienzos o de
todo el libro.

Durante captura se eliminan duplicados consecutivos y se conserva siempre el
punto final. No se introduce simplificación geométrica agresiva en v1: cualquier
umbral adicional debe compararse contra trazos reales del Scribe. El chunking
ya pone una cota al tamaño de cada objeto temporal y de cada fila BLOB.

## 6. Ventana y enrutado de entrada

### 6.1 Una sola ventana compuesta

`InkCanvasOverlay` es la única ventana que se entrega a `UIManager:show`. Ocupa
la pantalla para recibir entrada, pero sólo pinta la hoja, el asa y la barra:

```text
UIManager
└─ InkCanvasOverlay                 ventana ordinaria superior
   ├─ sheet/background + cache      se pinta primero
   ├─ resize handle
   └─ InkBar                        se pinta y despacha al final

ReaderUI                            ventana inferior
```

La barra deja de insertarse y retirarse para quedar por encima de otra ventana.
Se convierte en hijo embebible. El orden de pintado y hit test `hoja -> asa ->
barra` queda bajo test.

`UIManager:sendEvent` no ofrece por sí solo el evento a `ReaderUI` si la ventana
superior devuelve `false`. Para los eventos destinados al lector, el overlay
usa el patrón ya probado por `InkBar:windowBelow()` y llama explícitamente al
primer widget ordinario inferior. Si se abre un diálogo por encima, éste recibe
la entrada normalmente y el callback del lápiz fija `dialog` como passthrough
hasta el lift.

### 6.2 ContactRouter y destinos fijados

La clasificación se hace en el primer frame con coordenadas frescas y se guarda
por slot. El orden es:

```text
dialog > bar > resize_handle > canvas > reader_text
```

Los destinos son:

| Destino | Lápiz | Dedo en modo stylus | Dedo en modo finger |
| --- | --- | --- | --- |
| `dialog` | passthrough | passthrough | passthrough |
| `bar` | GestureDetector/overlay | GestureDetector/overlay | GestureDetector/overlay |
| `handle` | GestureDetector/overlay | GestureDetector/overlay | GestureDetector/overlay |
| `canvas` | dominar y dibujar/borrar | suprimir como palma | dibujar con la ruta compatible |
| `reader` | dominar sin dibujar | reenviar a ReaderUI | reenviar a ReaderUI |

Cruzar un borde no cambia el destino. Un lápiz que empezó en el lienzo sigue
dominado y su dibujo queda recortado; no pulsa un botón al cruzar la barra. Uno
que empezó en la barra permanece en passthrough. Se preservan las guardas
actuales para coordenadas pegajosas del slot y para no cambiar dominación a
media secuencia.

### 6.3 Palma y navegación

En backend stylus, los slots táctiles destinados a `canvas` se quitan del array
antes de `GestureDetector:feedEvent`. Así nunca crean `hold` ni el tap diferido.
Si una clasificación tardía encuentra un contacto ya creado, se usa
`getContact(slot)` seguido de `dropContact(contact)` para limpiar sus timers sin
afectar otros slots.

Mientras hay un contacto de lápiz dominado, todo dedo nuevo se fija como
`palm`, incluso si cae sobre el texto. Un dedo que ya estaba abajo al comenzar
el lápiz también se cancela. Su destino sigue suprimido hasta su propio lift.
Esto evita que la mano pase página mientras se escribe. Sin lápiz activo, un
dedo que empieza fuera de la hoja conserva navegación normal.

La compatibilidad ADR-2 se mantiene sin cambios para el dibujo directo actual
sobre PDF. Dentro del nuevo lienzo no se intenta promover un contacto de
`canvas` a `reader` cuando aparece un segundo dedo: se aborta el trazo y ambos
slots quedan suprimidos hasta sus lifts. Dos dedos que empiezan fuera de la hoja
siguen perteneciendo al lector. Esta diferencia es necesaria para conservar el
destino fijo por slot; entregar al GestureDetector un contacto que empezó
oculto a media secuencia recrearía taps y holds espurios. Ambas superficies se
prueban por separado, además del pipeline completo `routeStylusEvents ->
feedEvent -> InkCanvasOverlay`.

## 7. Guardado y ciclo de vida

### 7.1 Cuándo se escribe

Durante un trazo sólo se modifica memoria y caché. En el lift se codifica el
trazo y se añade una operación a una cola pequeña. La cola se confirma en una
transacción cuando ocurre cualquiera de estos límites:

- han pasado como máximo 250 ms;
- hay 8 operaciones pendientes;
- hay 64 KiB pendientes;
- se cambia o cierra el lienzo;
- llega `SaveSettings`;
- se cierra el documento.

Los valores de tiempo y tamaño son constantes agrupadas, no preferencias de UI.
Se pueden ajustar tras medir, pero la ventana de pérdida por cierre abrupto
nunca puede crecer sin límite.

Cada comando pendiente tiene claves deterministas. Un insert se identifica por
`(canvas_id, seq)`; un retry que encuentre esa fila comprueba su metadata y lo
trata como ya aplicado, en vez de duplicarlo. Delete y update son idempotentes.
Si un trazo todavía pendiente se deshace o borra, se elimina su insert de la
cola en vez de escribir primero y borrar después.

`onSaveSettings()` es el gate obligatorio. En KOReader, `Device:_beforeSuspend`
llama primero `UIManager:flushSettings()` y sólo después emite `Suspend`.
Guardar exclusivamente en `onSuspend()` sería demasiado tarde. El orden de
cierre normal también emite `SaveSettings` y vacía `doc_settings` antes de
`CloseDocument`.

### 7.2 Fallos

Una transacción fallida conserva la cola en memoria, detiene nueva edición del
lienzo y muestra `No se pudo guardar; Reintentar`. No se marca como confirmada
ni se abre una base nueva. Si el usuario cierra aun con error, se registra de
forma visible que las últimas operaciones no están durables; el plugin no puede
prometer recuperación tras apagar el proceso.

`onCloseDocument()` intenta un último flush defensivo, cancela por referencia
las acciones programadas, libera caché y cierra la conexión. `onSuspend()` sigue
deteniendo captura y sirve de defensa, pero no es el mecanismo de persistencia.

## 8. Contratos de escala

Estos contratos son más útiles que un tiempo medido en macOS, que no predice la
flash ni el panel del Scribe:

| Operación | Contrato |
| --- | --- |
| Abrir un libro | Carga identidad y metadata de anclas; no selecciona BLOBs de puntos |
| Construir índice nuevo | Resolución y persistencia SQLite acotadas al mismo lote por tick; prune sólo al finalizar |
| Cambiar página con índice listo | Cero SQL y cero scan global; lookup por página más validación de candidatos visibles |
| Pintar una vista | Blit de caché; cero SQL y cero recorrido vectorial |
| Añadir una muestra | O(1), sin disco y sin asignar una tabla nueva por punto |
| Terminar un trazo | O(puntos del trazo), nunca O(puntos del libro) |
| Abrir un lienzo | O(puntos de ese lienzo), en lotes cooperativos |
| Borrar | O(candidatos espaciales + puntos de esos candidatos), no O(libro) |
| Memoria estable | O(anclas del libro + metadata del lienzo activo + caché raster + trazo actual) |
| Guardar | Reescribe filas afectadas dentro de SQLite; no serializa el sidecar completo |

Instrumentación de depuración, apagada por defecto, debe registrar por operación:
anclas cargadas, chunks leídos, candidatos de borrado, duración de rasterizado,
duración de commit, bytes pendientes y tamaño de la base. Nunca se registra una
línea por muestra del lápiz.

Fixtures sintéticos obligatorios:

1. 200 lienzos × 200 trazos × 50 puntos: 2 millones de puntos cerrados. Abrir
   el libro no puede decodificar ninguno.
2. Un lienzo denso de 5.000 trazos × 100 puntos: la construcción debe ceder
   entre lotes y `paintTo` posterior no debe recorrer 500.000 puntos.
3. Un trazo continuo de más de 10.000 puntos: chunks acotados, unión visual
   continua y una sola acción de undo/borrado.
4. 500 anclas con un hash de layout nuevo: resolución incremental; pasar página
   mientras se construye no ejecuta un scan síncrono de las 500.
5. Borrado y undo repetidos: la base reutiliza espacio y no ejecuta `VACUUM`
   automáticamente.

No se fijan milisegundos de aceptación para el dispositivo sin medirlo. El gate
físico comparará página, apertura de hoja, latencia de tinta, commit, ghosting y
uso de memoria contra el plugin sin lienzo.

## 9. Archivos y responsabilidades

| Archivo | Cambio | Responsabilidad |
| --- | --- | --- |
| `fingerink.koplugin/ink_canvas_repository.lua` | Crear | Conexión SQLite, esquema, migraciones, transacciones, consultas perezosas y fallos |
| `fingerink.koplugin/ink_canvas_codec.lua` | Crear | Codec BLOB versionado y chunks; ninguna dependencia UI |
| `fingerink.koplugin/ink_anchor.lua` | Crear | Crear/validar raw + normalized xpointer y ancla de página fija |
| `fingerink.koplugin/ink_anchor_index.lua` | Crear | Metadata, hash de layout, resolución incremental, índice de página y huérfanos |
| `fingerink.koplugin/ink_canvas_cache.lua` | Crear | Caché BB8, cuadrícula espacial, rasterizado por lotes e invalidación regional |
| `fingerink.koplugin/ink_canvas_overlay.lua` | Crear | Ventana compuesta, hoja, asa, transformación, pintado y forwarding |
| `fingerink.koplugin/ink_contact_router.lua` | Crear | Estado por slot y destinos latchados; sin persistencia ni widgets |
| `fingerink.koplugin/ink_bar.lua` | Modificar | Convertir en hijo embebible y añadir acciones de lienzo; quitar propiedad de la pila |
| `fingerink.koplugin/ink_capture.lua` | Modificar | Permitir filtrar slots táctiles dominados antes de `feedEvent`, manteniendo desregistro seguro |
| `fingerink.koplugin/ink_render.lua` | Modificar mínimo | Pintar sobre viewport/caché con transformación explícita; sin conocer SQLite |
| `fingerink.koplugin/main.lua` | Modificar | Coordinar repositorio, overlay, backend, eventos y lifecycle |
| `fingerink.koplugin/ink_store.lua` | No modificar para esta función | Seguir siendo el store de tinta directa por página/PDF |
| `fingerink.koplugin/tests/support.lua` | Modificar | Stubs fieles de SQLite, viewport, timers, pila y eventos |
| `fingerink.koplugin/tests/run.lua` | Modificar | Tests unitarios, pipeline real y fixtures de escala |
| `README.md`, `spec.md`, `decisions.md` | Modificar | UX, límites, formato y ADR de persistencia/overlay |

No se copiará la arquitectura de `drawnotes.koplugin`. Ese plugin abre un
segundo `DocSettings` del mismo libro y vacía snapshots completos; aquí sería
posible sobrescribir metadata viva y conservar el mismo coste monolítico. La
lección útil es negativa: una sola fuente de verdad y ningún `DocSettings:flush`
propio para los lienzos.

## 10. Orden de implementación

Cada fase deja la suite verde y puede revisarse por separado.

### Fase 1 — Codec y repositorio aislados

1. Crear el codec con golden vectors y validación estricta.
2. Crear una base temporal en tests, schema v1 e índices.
3. Probar create/read/delete, orden `seq`, cascadas, rollback, schema futuro y
   copia antes de migración.
4. Probar que `listCanvases(book_id)` no selecciona `stroke_chunks.points`.

Gate: ninguna integración UI; `fingerink_strokes` y `ink_store.lua` sin diff.

### Fase 2 — Anclas e índice

1. Crear raw + normalized xpointer en `ReaderReady`.
2. Cargar metadata, no puntos.
3. Reutilizar `resolved_page` sólo con el mismo layout hash.
4. Resolver misses en lotes cancelables; invalidar en `DocumentRerendered`.
5. Exponer `currentCanvasIds()` y `orphanCanvasIds()` sin CRE/SQL en `paintTo`.

Gate: el fixture de 500 anclas permite pasar página mientras continúa la
resolución.

### Fase 3 — Transformación y caché

1. Implementar `CanvasTransform` y sus tests de ida/vuelta en retrato,
   paisaje y letterboxing.
2. Implementar cache BB8 y rasterizado streaming por chunks.
3. Construir índice espacial sólo con metadata.
4. Reparar una región tras erase/undo y demostrar que no se repinta fuera.
5. Hacer `paintTo` un blit comprobable por contador de llamadas al renderer.

Gate: tras completar la carga densa, diez `paintTo` no decodifican ningún BLOB.

### Fase 4 — Overlay compuesto

1. Embebir hoja, asa y barra en una ventana.
2. Pintar la barra al final y darle prioridad de hit test.
3. Reenviar explícitamente eventos `reader` al widget inferior.
4. Implementar alturas imantadas y reconstrucción por rotación.
5. Añadir selector local, borrar y recuperación de huérfanos.

Gate: nunca hay más de una ventana ordinaria de FingerInk y la barra sigue
alcanzable en 40/70/100%.

### Fase 5 — Router y lápiz

1. Extraer del estado actual de `main.lua` las guardas de slot persistente,
   coordenadas rancias y dominación estable.
2. Añadir destinos por slot y tests de cruce en ambas direcciones.
3. Filtrar palmas antes del GestureDetector y limpiar contactos tardíos por
   slot, no globalmente.
4. Probar el pipeline real `routeStylusEvents -> feedEvent -> overlay`, incluidos
   `hold`, tap diferido, diálogo, barra, asa, pen + palm y goma.
5. Mantener una suite separada para el backend finger y ADR-2.

Gate: ninguna secuencia cambia de passthrough a dominada o viceversa antes de
su lift.

### Fase 6 — Guardado y lifecycle

1. Añadir cola acotada, micro-batch y flush forzado.
2. Integrar `onSaveSettings`, cambio de lienzo, cierre, error y retry.
3. Cancelar todos los callbacks por referencia en teardown.
4. Probar fallo de commit, suspensión inmediatamente tras lift y cierre con
   operación pendiente.

Gate: una transacción fallida conserva la operación; una confirmada no vuelve a
aplicarse tras reabrir.

### Fase 7 — Escala, documentación y Scribe

1. Ejecutar los fixtures de §8 y guardar contadores, no sólo tiempo total.
2. Ejecutar la suite desde raíz y con el QA de KOReader.
3. Actualizar ADRs y límites de backup/sincronización.
4. Instalar en Scribe y medir las variables físicas pendientes.

Gate: no declarar terminada la función hasta completar la matriz física mínima.

## 11. Verificación

### 11.1 Comandos de repositorio

```sh
lua test.lua
luajit test.lua
cd fingerink.koplugin && luajit tests/run.lua
```

Con el runtime de KOReader:

```sh
koreader_qa.sh preflight
koreader_qa.sh test
koreader_qa.sh launch --book <epub-de-prueba>
```

La suite debe conservar el barrido sintáctico y la conformance del arnés. Los
tests de SQLite usan una base temporal y la eliminan sólo después de cerrar la
conexión.

### 11.2 Matriz física mínima

- EPUB pequeño y EPUB con cientos de anclas.
- Retrato y paisaje; alturas 40/70/100%.
- Lápiz, goma posterior, dedo fuera de hoja y palma dentro/fuera durante pen.
- Cambio de fuente, margen, interlineado y modo de página/scroll.
- Suspensión inmediatamente después de un trazo corto y de un erase.
- Apertura de lienzo denso: memoria, tiempo hasta primer paint, latencia posterior.
- Cincuenta trazos cortos seguidos: duración de commits y ausencia de pausas.
- Reinicio de KOReader y reapertura tras cada caso de guardado.

## 12. Alcance v1

Dentro:

- crear, abrir, cambiar y eliminar un lienzo;
- selector de lienzos de la vista actual;
- acceso mínimo a huérfanos;
- xpointer raw + normalizado e índice por layout;
- persistencia SQLite perezosa;
- caché raster activa e índice espacial;
- hoja 40/70/100%, retrato y paisaje;
- lápiz, goma, rechazo de palma y navegación táctil fuera de la hoja;
- guardado acotado y recuperación ante errores de base;
- pruebas unitarias, pipeline, estrés y gate físico.

Fuera:

- lista global y búsqueda entre todos los lienzos válidos;
- exportación o sincronización entre dispositivos;
- cuaderno multi-hoja;
- dibujar encima del texto EPUB;
- presión, inclinación y hover;
- simplificación geométrica avanzada;
- habilitar la nueva hoja sobre PDF/layout fijo; el campo `anchor_kind='page'`
  queda reservado para una fase posterior;
- migrar el store existente de tinta PDF;
- compactación manual de la base.

## 13. Riesgos y condiciones de parada

| Riesgo | Respuesta |
| --- | --- |
| SQLite no está disponible en un runtime | No caer al sidecar monolítico; desactivar lienzos con explicación |
| Schema más nuevo | Sólo lectura; nunca bajar versión ni recrear |
| Corrupción o I/O error | Conservar archivo y cola; parar edición, ofrecer retry y diagnóstico |
| Libro renombrado o movido | Identidad por checksum + tamaño, no ruta |
| Dos libros distintos colisionan en checksum parcial y tamaño | Mostrar `last_path`/metadatos en diagnóstico; si aparece en pruebas, ampliar clave antes de liberar, no después |
| Xpointer desaparece | Conservar como huérfano accesible; nunca borrar automáticamente |
| Cambio de DOM | Guardar raw + normalizado; no depender de la migración cerrada de ReaderRolling |
| Resolución de muchas anclas bloquea | Lotes cancelables y caché por layout; ninguna resolución en page turn/paint |
| Lienzo activo extremadamente denso | Streaming de chunks, caché acotada y edición bloqueada durante construcción |
| Muchos trazos se superponen | Peor caso documentado; medir candidatos y considerar R-tree sólo con evidencia |
| Commit introduce pausa | Micro-batch acotado; medir en Scribe antes de ampliar ventana |
| Palma fuera de hoja pasa página | Todo dedo nuevo queda suprimido mientras pen está activo; navegación vuelve tras lift |
| Overlay deja al lector sin eventos | Forwarding explícito y tests con la pila real del arnés |
| Callback stylus ya ocupado | Mantener la negativa segura existente; no encadenar un singleton ajeno |

Se detiene la implementación y se revisa arquitectura si ocurre cualquiera de
estas condiciones:

- el runtime incluido en el Scribe no carga `lua-ljsqlite3`;
- no se puede obtener una identidad estable en `ReaderReady`;
- filtrar un slot individual exige cambiar APIs globales de KOReader de forma
  incompatible;
- una migración no puede hacerse transaccionalmente con backup verificable;
- la caché de un solo lienzo excede el presupuesto de memoria observado en el
  dispositivo;
- un diálogo o la barra obliga a reintroducir ventanas ordinarias que compiten
  por ser la superior.

## 14. Registro de validación documental

Las fuentes de KOReader se revisaron en el tag **v2026.07**. El contenido clave
se volvió a recuperar con Firecrawl el 2026-08-23; las líneas locales se usaron
para completar los fragmentos que GitHub no renderizó en la extracción.

### Tema: callback stylus y orden del pipeline

- Por qué: el router depende de dominar sólo el slot de lápiz antes del
  reconocimiento gestual.
- Fuente: [`frontend/device/input.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/device/input.lua).
- Verificado: `registerStylusCallback` guarda un único callback;
  `routeStylusEvents` se ejecuta antes de `feedEvent` y elimina los slots cuyo
  callback devuelve `true`.
- Restricción: KOReader v2026.07; callback singleton.
- Impacto: conservar negativa si está ocupado y filtrar touch residual antes de
  GestureDetector.
- Confianza: alta.

### Tema: timers y eliminación por slot

- Por qué: un hold y un tap diferido no pueden quedar vivos tras suprimir una
  palma.
- Fuente: [`frontend/device/gesturedetector.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/device/gesturedetector.lua) y
  [`frontend/device/input.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/device/input.lua).
- Verificado: `dropContact(contact)` limpia timers `hold` y `double_tap` del
  slot; los callbacks vencidos se despachan desde `Input:waitEvent`.
- Restricción: API interna de frontend, no contrato de plugin estable.
- Impacto: encapsular el uso en `ink_capture.lua`, cubrir con conformance y parar
  si cambia.
- Confianza: alta para v2026.07, media a futuro.

### Tema: pila y propagación de UI

- Por qué: la propuesta anterior dependía de tres ventanas y de que un evento
  bajara por la pila.
- Fuente: [`frontend/ui/uimanager.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/ui/uimanager.lua).
- Verificado: `show` apila widgets; `sendEvent` entrega entrada al widget
  ordinario superior y no llama automáticamente al siguiente si devuelve
  `false`.
- Impacto: una sola ventana compuesta y forwarding explícito.
- Confianza: alta.

### Tema: anclas y migración DOM

- Por qué: un xpointer propio no entra por arte de magia en las migraciones de
  KOReader.
- Fuente: [`frontend/document/credocument.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/document/credocument.lua) y
  [`frontend/apps/reader/modules/readerrolling.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/apps/reader/modules/readerrolling.lua).
- Verificado: existen `getNormalizedXPointer`, `isXPointerInDocument`,
  `getPageFromXPointer`, `isXPointerInCurrentPage`,
  `getVisiblePageNumberCount` y el hash de render. La migración de
  `ReaderRolling` enumera sólo posición y anotaciones.
- Impacto: raw + normalizado propios; página resuelta tratada como caché por
  layout.
- Confianza: alta.

### Tema: identidad disponible en ReaderReady

- Por qué: la base global necesita una clave que sobreviva al renombrado.
- Fuente: [`frontend/apps/reader/readerui.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/apps/reader/readerui.lua) y
  [`plugins/statistics.koplugin/main.lua`](https://github.com/koreader/koreader/blob/v2026.07/plugins/statistics.koplugin/main.lua).
- Verificado: `ReaderUI` crea `partial_md5_checksum` antes de `ReaderReady` y
  Statistics lo lee en `onReaderReady`.
- Impacto: abrir `CanvasRepository` en ese evento, no en `init`.
- Confianza: alta.

### Tema: coste y movilidad de DocSettings

- Por qué: el volumen esperado convierte el formato de persistencia en una
  decisión de rendimiento y de integridad.
- Fuente: [`frontend/docsettings.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/docsettings.lua),
  [`frontend/luasettings.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/luasettings.lua),
  [`frontend/dump.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/dump.lua) y
  [`frontend/util.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/util.lua).
- Verificado: flush serializa la tabla completa; `updateLocation` sólo trata los
  artefactos conocidos; la escritura normal no es una transacción de base de
  datos.
- Impacto: SQLite global, no tabla grande ni archivo compañero arbitrario en
  `.sdr`.
- Confianza: alta.

### Tema: patrón SQLite soportado por KOReader

- Por qué: no conviene inventar journal ni migraciones para el dispositivo.
- Fuente: [`plugins/statistics.koplugin/main.lua`](https://github.com/koreader/koreader/blob/v2026.07/plugins/statistics.koplugin/main.lua).
- Verificado: uso de `lua-ljsqlite3`, base bajo `getSettingsDir`,
  `user_version`, migraciones y selección `WAL`/`TRUNCATE` mediante
  `Device:canUseWAL()`.
- Impacto: el repositorio copia ese patrón y añade claves foráneas/backup propio.
- Confianza: alta.

### Tema: guardado antes de suspensión y cierre

- Por qué: guardar en `onSuspend` perdería el último micro-batch.
- Fuente: [`frontend/device/generic/device.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/device/generic/device.lua) y
  [`frontend/apps/reader/readerui.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/apps/reader/readerui.lua).
- Verificado: `_beforeSuspend` hace `flushSettings` antes de emitir `Suspend`;
  `ReaderUI:saveSettings` emite `SaveSettings` antes de vaciar DocSettings.
- Impacto: `onSaveSettings` es el flush durable obligatorio.
- Confianza: alta.

### Tema: viewport y coste de memoria

- Por qué: el refresh recortado no basta para impedir escritura fuera de la
  hoja.
- Fuente: [`ffi/blitbuffer.lua`](https://github.com/koreader/koreader-base/blob/master/ffi/blitbuffer.lua).
- Verificado: `viewport` crea un objeto acotado sobre la misma memoria; no
  reserva otro buffer.
- Restricción: fuente de koreader-base revisada el 2026-08-23; confirmar el SHA
  del submódulo al ejecutar la fase 3.
- Impacto: clipping real en render live y en reparación regional.
- Confianza: alta para la implementación revisada, pendiente de fijar SHA.

### Tema: arrastre en e-ink

- Por qué: la altura de la hoja no debe forzar refresco completo continuo.
- Fuente: [`frontend/ui/widget/container/movablecontainer.lua`](https://github.com/koreader/koreader/blob/v2026.07/frontend/ui/widget/container/movablecontainer.lua).
- Verificado: `hold_pan` sólo marca movimiento; posición y refresco se aplican
  en `hold_release`.
- Impacto: alturas imantadas y repaint al soltar; indicador fino sólo tras gate
  físico.
- Confianza: alta.

## 15. Registro de ejecución

Fecha de implementación: 2026-08-24. Tras la revisión cruzada y su remediación:
1.391 comprobaciones, 0 fallos, bajo `lua` y bajo el LuaJIT de KOReader; conformance:
44 afirmaciones, 0 discrepancias con `test/leaves.epub`. El smoke aislado carga
el plugin en ReaderUI, abre la base y registra el libro por checksum+tamaño.
El runtime local es `v2025.08-100-g1d66e440b_2025-10-05`, por lo que este
resultado no sustituye la repetición contra v2026.07 exacto y deja la API de
stylus como `UNCHECKABLE`. La línea base anterior era 1.044/42.

### 15.1 Fases

| Fase | Estado |
| --- | --- |
| 1 — Codec y repositorio | Completa |
| 2 — Anclas e índice | Completa |
| 3 — Transformación y caché | Completa |
| 4 — Overlay compuesto | Completa |
| 5 — Router y lápiz | Completa |
| 6 — Guardado y lifecycle | Completa |
| 7 — Escala y documentación | Completa salvo el gate físico |

El gate físico de §11.2 sigue **sin ejecutar**: requiere un Kindle Scribe.

### 15.2 Correcciones a este documento

Tres cosas de §3 resultaron falsas al probarlas contra el runtime real, y las
tres son de consecuencia:

1. **Los BLOB no son BLOB.** `lua-ljsqlite3` liga una cadena Lua como TEXT
   aunque la columna se declare `BLOB`, y SQL se detiene en el primer NUL:
   `length()` sobre un blob de puntos responde 1. La implementación usa
   `CAST(?n AS BLOB)` al entrar y `CAST(points AS TEXT)` al salir, con lo que
   el valor almacenado es un blob real y ambos lados siguen siendo cadenas Lua.
   Verificado en `conformance.lua`.

2. **Los enteros vuelven como cdata int64.** `1LL == 1` es cierto, pero
   `t[1LL]` y `t[1]` son claves distintas y `1LL .. ""` lanza. Un índice de
   páginas construido con la salida cruda del driver perdería todas las
   búsquedas en silencio. Todo entero se convierte en el límite del
   repositorio.

3. **`partial_md5_checksum` no es un campo de `ReaderUI`.** Vive en los ajustes
   del documento, donde `ReaderUI` lo calcula camino a `ReaderReady`. La
   primera versión lo leía de `self.ui` y desactivaba la función en todos los
   EPUB con un mensaje diciéndolo. Lo encontró la prueba de humo, no la
   revisión.

### 15.3 Desviaciones deliberadas

- **Archivos.** §9 preveía la transformación dentro de `ink_canvas_overlay.lua`
  y la rejilla espacial dentro de `ink_canvas_cache.lua`. Ambas se extrajeron a
  `ink_canvas_transform.lua` e `ink_spatial_grid.lua`: son lógica pura,
  compartida por varios módulos, y se prueban mejor solas. Se añadieron
  `ink_stack.lua` (una sola copia de la regla de reenvío, que existía duplicada
  en la barra y habría vuelto a duplicarse en el overlay) y
  `ink_canvas_session.lua` (main.lua ya tenía 1.100 líneas antes de esto).

- **Refresco por segmento, no agrupado por tick.** §5.2 pedía agrupar las cajas
  sucias cada 8–16 ms. La implementación refresca por segmento, que es
  exactamente lo que hace la tinta directa hoy y lo único que está probado en el
  hardware del usuario. Agrupar es una optimización que debe medirse en el
  Scribe antes de introducirla; hacerlo a ciegas arriesga que la tinta en vivo
  se sienta peor que la ruta ya probada. **Pendiente para el gate físico.**

- **La palma se retira antes del GestureDetector.** §6.3 lo pedía y ADR-13
  parecía contradecirlo. No hay contradicción: ADR-13 habla de un contacto que
  ya existe, y retirar un slot en su *primer* frame significa que el Contact
  nunca se abre. Es además obligatorio, no defensa adicional: un gesto emitido
  no lleva número de slot, y el overlay entrega a propósito los gestos por
  encima de la hoja al libro. Ver ADR-17.

- **La barra nunca se degrada a palma.** §6.3 dice que todo dedo nuevo se fija
  como `palm` mientras el lápiz está apoyado. Se aplica al lienzo y al texto,
  no a la barra ni al asa: el orden de clasificación de §6.2 pone `bar` antes,
  y poder pulsar Stop con el lápiz apoyado es la única salida de una sesión de
  dibujo.

- **Un dedo ya apoyado se cancela sólo si era del lienzo o del lector.** Misma
  razón.

### 15.4 Lo que sigue sin cubrir

- El gate físico completo de §11.2.
- El intervalo de agrupación de refresco (§5.2), a medir en el dispositivo.
- Instrumentación: hay contadores por operación en nivel `dbg` (rasterizado,
  commit, reparación, apertura de sesión y contacto de goma: candidatos,
  chunks consultados/decodificados y hits de LRU). No se registra el tamaño de
  la base ni la duración en milisegundos; eso pide un reloj y una medida real,
  no una estimación de escritorio.

### 15.5 Endurecimiento de escala e integridad (remediación 2026-08-23)

La implementación posterior conserva el modelo de lienzo/xpointer, pero cambia
los límites internos que no escalaban con trazos o bases grandes:

- La identidad negativa sólo existe mientras un INSERT está pendiente. Después
  de COMMIT, Queue publica el id SQLite y Cache cambia sus claves y su entrada
  de grid antes de liberar los puntos vivos. `seq` es monotónico por sesión y
  no retrocede al deshacer.
- La carga ya no materializa un stroke completo. Repository entrega un cursor
  de una fila/chunk, Codec valida incrementalmente versión, orden, recuentos y
  seams, y Cache trabaja con un presupuesto inicial de 8192 puntos y 32 chunks
  por tick. El pico transitorio es un chunk, además del raster BB8, metadata y
  el LRU acotado.
- La goma usa distancia a segmentos y grosor visible, primero filtra por stroke
  y luego por cajas de chunk. Un contexto por contacto reutiliza como máximo
  ocho chunks y se destruye en lift/abort/cierre.
- Errores de lectura dejan `load_failed`, no una hoja vacía. Retry hace durable
  la cola antes de releer SQLite, evitando que un INSERT pendiente desaparezca
  o que un DELETE pendiente reaparezca en el raster.
- La caché de páginas se persiste por lotes del mismo tamaño que la resolución
  de xpointers. Cada lote reutiliza un statement y sólo el último ejecuta el
  prune, por lo que miles de hojas no terminan en una escritura monolítica.
- Un cierre interactivo que no logra guardar conserva hoja, barra, cache y
  operaciones. Delete sólo cambia estado visible después del DELETE durable.
- La creación de schema v1 es transaccional. Un schema futuro se reabre `ro` y
  sólo se consulta con `findBookId`; una migración WAL exige las tres columnas
  de `wal_checkpoint(TRUNCATE)` completas antes de copiar el archivo principal.

Estas correcciones no cambian `SCHEMA_VERSION = 1`, la ruta de tinta directa
PDF, el refresh por segmento ni ADR-2. El gate físico y la verificación contra
el runtime exacto KOReader v2026.07 continúan siendo requisitos de distribución.
