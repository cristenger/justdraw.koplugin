# Plan de desarrollo: cuadernos independientes

- Fecha: 2026-08-26
- Feature ID: `FI-STANDALONE-NOTEBOOKS-FOUNDATION`
- Rama base: `codex/kindle-scribe-stylus` en `3df3339`
- Alcance de entrega: arquitectura, persistencia y controladores de dominio listos para una UI posterior
- Stack: plugin KOReader en Lua/LuaJIT, `lua-ljsqlite3`, BlitBuffer, UIManager y API moderna de stylus de KOReader

## 1. Resultado arquitectónico

La funcionalidad es factible, pero no debe implementarse como un EPUB o PDF ficticio ni como otra variante de `CanvasSession` con campos de libro anulados. El cuaderno debe ser un dominio independiente que reutiliza la maquinaria de tinta y conserva sus propias reglas de identidad, navegación y persistencia.

La dirección recomendada es:

```text
Plugin host (main.lua)
├── ruta ReaderUI existente
│   ├── tinta directa en PDF, sin cambios funcionales
│   └── BookCanvasSession, anclada a libro/xpointer
├── NotebookController, sin dependencias de libro
│   ├── NotebookRepository, justdraw-notebooks.sqlite3
│   └── NotebookSession
│       └── InkSurfaceSession
│           ├── InkCanvasCache
│           ├── InkCanvasQueue
│           ├── InkCanvasCodec
│           └── InkSpatialGrid
└── InkInputController, singleton de proceso
    └── InkCapture, hook de bajo nivel ya existente
```

Esta entrega no diseña ni implementa la biblioteca visual ni la ventana final del cuaderno. Sí deja un contrato estable para que esa UI pueda añadirse sin volver a diseñar persistencia, captura, paginación o durabilidad.

## 2. Entradas inferidas

### Objetivo

Permitir crear cuadernos que no dependan de un libro, con páginas ordenadas, tinta persistente y navegación estable en un Kindle Scribe o dispositivo similar, reutilizando la ruta de lápiz ya validada por JustDraw.

### Restricciones conocidas

- KOReader estable objetivo: `v2026.07.1`, commit `9192014d8bd82a91dc1012473be0f238dedfdb54`.
- KOReader desarrollo validado: `master`, commit `5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8`.
- Runtime local: `v2025.08-100-g1d66e440b`; sirve para LuaJIT, SQLite, EPUB y smoke tests, pero no para validar la API moderna de stylus.
- Un solo callback de stylus puede estar registrado en `Device.input`.
- El dispositivo final usa e-ink: no se introducirán miniaturas, repintados animados, cargas completas de bibliotecas grandes ni transacciones masivas en un tick.
- La validación final de latencia, ghosting, goma y palma requiere un Scribe físico.
- Una página densa debe cargarse incrementalmente; una biblioteca grande no debe leer trazos para construir su listado.

### No objetivos

- Diseñar la UI de biblioteca, editor, diálogos de nombre o selector de plantillas.
- Exportar cuadernos, sincronizarlos o convertirlos al formato nativo de Amazon.
- Cuadernos compartidos entre dispositivos.
- Miniaturas, búsqueda OCR, presión, inclinación o hover.
- Reordenamiento arbitrario e inserción entre páginas en v1. V1 crea páginas al final; esta decisión evita renumeraciones y un algoritmo de orden fraccional prematuro.
- Unificar las dos bases SQLite existentes.
- Migrar lienzos EPUB a cuadernos ni viceversa.
- Cambiar el comportamiento visible de PDF o de las hojas EPUB.
- Afinar waveforms sin mediciones físicas.

## 3. Estado actual del repositorio

Baseline verificado el 2026-08-26:

- Árbol de trabajo limpio.
- `koreader_qa.sh preflight`: PASS.
- Sintaxis LuaJIT: 33 archivos PASS.
- Suite local con KOReader LuaJIT: 1395 comprobaciones, 0 fallos.
- CI actual ejecuta el barrido de sintaxis y `luajit test.lua` en Ubuntu.

No se encontraron `AGENTS.md`, `CLAUDE.md` ni reglas anidadas aplicables. La guía de CI está en `.github/workflows/tests.yml`.

### Módulos involucrados

| Archivo | Responsabilidad actual | Decisión |
|---|---|---|
| `justdraw.koplugin/main.lua` | Instancia KOReader, ReaderUI, entrada, barra, PDF y puente al canvas EPUB | Añadir una separación segura de host y delegar cuadernos; no reescribir la ruta lectora completa en este cambio |
| `justdraw.koplugin/ink_canvas_session.lua` | Mezcla dominio de libro, overlay y sesión de superficie | Extraer la parte genérica a `ink_surface_session.lua`; conservar aquí libro, xpointer, índice y overlay |
| `justdraw.koplugin/ink_canvas_cache.lua` | Un raster activo, carga incremental, grid y reparación | Reutilizar; aceptar una `surface` genérica manteniendo compatibilidad temporal con `canvas` |
| `justdraw.koplugin/ink_canvas_queue.lua` | Cola durable, batching, rollback y bloqueo tras error | Reutilizar sin duplicar; generalizar sólo el nombre del objeto de superficie si hace falta |
| `justdraw.koplugin/ink_canvas_codec.lua` | Codec versionado y chunked de puntos | Reutilizar sin modificar el formato |
| `justdraw.koplugin/ink_spatial_grid.lua` | Índice espacial de una superficie activa | Reutilizar sin cambios funcionales |
| `justdraw.koplugin/ink_canvas_transform.lua` | Escala de canvas y recorte de hoja EPUB | Generalizar con rectángulos separados de ajuste y recorte |
| `justdraw.koplugin/ink_capture.lua` | Hook global de stylus/dedo y desarme diferido | Mantener como capa de bajo nivel; envolver con un propietario explícito |
| `justdraw.koplugin/ink_contact_router.lua` | Enrutado específico barra/asa/hoja/lector | No reutilizar como router de cuaderno; sus destinos son propios de EPUB |
| `justdraw.koplugin/ink_canvas_repository.lua` | Base de libros, canvases, trazos y layout | No cambiar su esquema; copiar sus patrones probados en un repositorio separado |
| `justdraw.koplugin/ink_canvas_overlay.lua` | Hoja EPUB superpuesta con alturas 40/70/100 | No reutilizar para cuadernos |

### Patrones que deben preservarse

- Conversión de todo entero SQLite con `tonumber` en el límite del repositorio.
- Rechazo de `NaN`, `math.huge` y `-math.huge` antes de persistir o construir geometría.
- `CAST(? AS BLOB)` al escribir puntos y `CAST(points AS TEXT)` al leerlos, por el comportamiento real de `lua-ljsqlite3`.
- `PRAGMA foreign_keys=ON` en cada conexión.
- WAL sólo cuando `Device:canUseWAL()` lo permita; `TRUNCATE` como alternativa.
- Migraciones con checkpoint completo, cierre, copia de seguridad, transacción única y rechazo de peldaños ausentes.
- Apertura read-only ante un `user_version` futuro.
- Statements y cursores cerrados en éxito, error y EOF.
- Cola limitada por 0,25 s, 8 operaciones o 64 KiB, con las mismas operaciones retenidas si falla el COMMIT.
- Un único raster de página y decodificación por ticks.
- Desarme de stylus en dos fases; nunca retirar el callback dentro de `routeStylusEvents`.

### Archivos que no deben tocarse en esta entrega

- `justdraw.koplugin/ink_anchor.lua`
- `justdraw.koplugin/ink_anchor_index.lua`
- `justdraw.koplugin/ink_canvas_overlay.lua`, salvo que una prueba revele una regresión causada por el nuevo transform
- `justdraw.koplugin/ink_contact_router.lua`
- `justdraw.koplugin/ink_store.lua`, que pertenece a la tinta directa en PDF
- el esquema v1 de `ink_canvas_repository.lua`
- planes históricos ya cerrados

## 4. Correcciones al borrador previo

### 4.1 No extraer todo `main.lua` a un ReaderController en este PR

Mover casi dos mil líneas a otra clase y cambiar simultáneamente la instanciación del plugin convertiría una extensión de dominio en una reescritura de lifecycle. La separación se hará con una costura explícita de host y un `NotebookController` compuesto. La instancia actual seguirá siendo la ruta lectora cuando `self.ui.document` exista.

En una entrega posterior, y sólo con cobertura equivalente, esa ruta puede moverse mecánicamente a `ink_reader_controller.lua`. No es condición para que el dominio de cuadernos sea independiente.

### 4.2 No cambiar todavía `is_doc_only`

El backend sin UI no ofrece una entrada útil en FileManager. Este plan prepara y prueba una instancia con forma de FileManager, pero mantiene `is_doc_only = true` hasta que el siguiente trabajo implemente `NotebookWindow` y su menú. En ese PR se cambiará a `false` y se activará la ruta ya probada.

Esto evita introducir una segunda instancia productiva del plugin antes de que exista una función visible, y mantiene exactamente igual la ruta actual de lectura durante la construcción del backend.

### 4.3 Un `viewport` único no conserva el comportamiento EPUB

La hoja EPUB actual calcula la escala con la geometría de pantalla completa y recorta sólo la parte revelada. Si se usara la altura visible como único viewport, pasar de 40% a 70% cambiaría la escala y obligaría a reconstruir el raster.

El contrato correcto separa:

- `fit_rect`: base para calcular escala y tamaño del raster.
- `clip_rect`: región visible e interactiva.

Para EPUB, `fit_rect` puede extenderse por debajo de la pantalla y `clip_rect` es la parte revelada. Para un cuaderno, ambos rectángulos normalmente coinciden con el área de página disponible.

### 4.4 V1 sólo añade páginas al final

Un entero espaciado no resuelve por sí solo inserciones arbitrarias repetidas: termina necesitando rebalanceo. Como la UI se diseñará después y no existe todavía un requisito de reordenamiento, v1 usa `next_sort_key` monotónico y `appendPage`. Borrar una página no renumera nada. Insertar o reordenar queda como una extensión explícita con su propio diseño y migración.

### 4.5 El borrado lógico no debe terminar en un cascade masivo

La base de cuadernos no usará `ON DELETE CASCADE` en las relaciones grandes. Un `DELETE` de un cuaderno con miles de páginas podría convertir el trabajo diferido en una única operación larga. El purgador borrará primero chunks, luego trazos, páginas y por último el cuaderno, con límites por tick.

## 5. Contratos objetivo

### 5.1 `InkSurfaceSession`

Nuevo archivo: `justdraw.koplugin/ink_surface_session.lua`.

Responsabilidad: mantener una sola superficie activa, su cache, su cola y las operaciones de tinta. No conoce libros, xpointers, FileManager, ReaderUI, overlays ni navegación entre páginas.

Constructor:

```lua
InkSurfaceSession.new{
    repository = repository,
    surface = { id, logical_w, logical_h },
    transform = transform,
    writable = true_or_false,
    schedule = next_tick,
    scheduleIn = schedule_in,
    unschedule = unschedule,
    notify = notify,
    on_state_changed = callback,
}
```

API pública mínima:

```text
open() -> true | nil, reason
stateName() -> closed | loading | ready | load_failed | save_failed
surface() / cache()
addStroke(points, n, width, tool)
beginErase() / eraseAt(x, y, radius) / endErase()
undo()
repair(rect)
pendingWrites()
flush()
retryLoad()
retrySave()
close({ discard = false })
```

Invariantes:

- `addStroke`, goma y undo sólo aceptan cambios en `ready`, writable y sin error de guardado.
- El raster no incorpora tinta nueva si la cola ha rechazado la operación.
- Un fallo de COMMIT conserva cola y raster, cambia a `save_failed` y bloquea edición y cambio de página.
- `retryLoad` vacía primero una cola pendiente; nunca recarga SQLite sobre operaciones sólo en memoria.
- `close` es un gate durable. Si el flush falla, devuelve error y conserva todos los objetos necesarios para reintentar.
- `discard=true` sólo se admite cuando el propietario ya ha marcado la superficie para eliminación y se ha confirmado esa decisión.
- Sólo existe un cache/raster por `NotebookSession`.

Extracción desde `ink_canvas_session.lua`:

- Mover `_syncNextSeq`, `addStroke`, `beginErase`, `eraseAt`, `endErase`, `undo`, `repair`, `pendingWrites`, `flush`, `saveFailed`, `retrySave` y la coordinación cache/queue.
- Mantener en `CanvasSession`: identidad del libro, conexión de canvases, `AnchorIndex`, `createHere`, `marksAtPage`, `openCanvas`, overlay y actualización de recencia.
- `CanvasSession:openCanvas` construye un `InkSurfaceSession` y sigue exponiendo adaptadores con los nombres actuales. Los callers existentes no se cambian de una vez.

### 5.2 Interfaz de repositorio de trazos

Tanto `ink_canvas_repository.lua` como `ink_notebook_repository.lua` deben satisfacer este contrato consumido por cache/queue:

```text
transaction(fn)
listStrokes(surface_id)                  -- sólo metadata
openStrokeCursor(stroke_id)
readStrokeChunk(stroke_id, chunk_no)
addStroke(surface, stroke) -> row_id
deleteStroke(row_id)
```

El nombre interno `canvas` puede mantenerse como alias durante la extracción, pero ninguna decisión de la nueva sesión debe depender de `book_id`, `anchor_key` o `layout_hash`.

### 5.3 `InkInputController`

Nuevo archivo: `justdraw.koplugin/ink_input_controller.lua`.

Será un módulo singleton, igual que `ink_capture.lua`, porque `require` comparte el módulo aunque KOReader destruya FileManager y cree una nueva instancia en ReaderUI. `ink_capture.lua` sigue siendo el hook de bajo nivel.

Contrato:

```text
acquire(owner, capture_spec) -> lease | nil, reason
lease:isOwner(owner)
lease:hasActiveContact()
lease:release()              -- idempotente
controller:forceRelease(owner, reason)
controller:activeOwner()
```

Reglas:

- Sólo el token que adquirió la captura puede liberarla.
- Nunca hay dos leases activas.
- Cambiar de PDF/EPUB a cuaderno exige: abortar contacto abierto, liberar la lease anterior y adquirir la siguiente desde un tick seguro.
- No se cambia de destino en mitad de un contacto.
- Los errores del callback hacen inerte la lease inmediatamente y ejecutan `Capture:remove()` mediante el desarme diferido ya probado.
- Si existe un callback ajeno en KOReader, se devuelve `stylus_callback_busy` y no se altera.
- Cerrar un cuaderno no reactiva automáticamente el modo Draw anterior del libro.

`main.lua` dejará de llamar directamente `Capture:installStylus`, `Capture:installFinger` y `Capture:remove`; esas llamadas pasarán por este controlador. Esto asegura que una instancia en teardown no pueda desmontar la captura de otra instancia creada después.

La implementación añade `ink_notebook_input.lua` como adaptador sin widgets.
Este módulo reutiliza las rutas pen/eraser/finger probadas, transforma a
coordenadas lógicas, convierte ancho/radio de píxeles de pantalla una vez por
contacto y expone a la UI futura un destino de repaint en pantalla, su origen
separado en cache y regiones de passthrough para touch y stylus. Un overlay que
aparece durante un trazo repara la tinta live y mantiene el contacto suprimido
hasta lift; un down sin coordenadas permanece fail-closed hasta recibir
geometría fresca. En `auto`, la ruta stylus requiere tanto el callback moderno como
`Device.input.wacom_protocol == true`, igual que el lector.

### 5.4 Transformación de superficie

Evolucionar `ink_canvas_transform.lua` sin romper inicialmente su constructor antiguo:

```lua
Transform.new{
    logical_w = width,
    logical_h = height,
    fit_rect = { x, y, w, h },
    clip_rect = { x, y, w, h },
    align_x = "center",
    align_y = "top", -- o "center"
}
```

Métodos genéricos:

```text
toScreen / toCanvas
toCache / fromCache
cacheSize
visibleCanvasRect
contains
```

Adaptación EPUB durante la transición:

```text
fit_rect  = { x = 0, y = sheet_top, w = screen_w, h = screen_h }
clip_rect = { x = 0, y = sheet_top, w = screen_w, h = screen_h - sheet_top }
align_y   = top
```

Cuaderno:

```text
fit_rect = clip_rect = área de página disponible, descontando el chrome futuro
align_x = center
align_y = center o top, decisión de UI posterior
```

La rotación debe soltar captura, abortar el contacto incompleto, guardar, reconstruir transform/cache y reactivar captura sólo cuando la página vuelva a `ready`.

### 5.5 `NotebookRepository`

Nuevo archivo: `justdraw.koplugin/ink_notebook_repository.lua`.

Ruta: `DataStorage:getSettingsDir() .. "/justdraw-notebooks.sqlite3"`.

Debe repetir los patrones de seguridad de `ink_canvas_repository.lua`, pero no compartir su esquema ni importar datos. No extraer todavía un helper SQLite común: modificar dos repositorios maduros a la vez aumenta el riesgo y no aporta comportamiento al usuario.

#### Esquema v1

```sql
CREATE TABLE notebooks (
    id             INTEGER PRIMARY KEY,
    title          TEXT    NOT NULL,
    page_count     INTEGER NOT NULL DEFAULT 0 CHECK(page_count >= 0),
    next_sort_key  INTEGER NOT NULL DEFAULT 1024 CHECK(next_sort_key > 0),
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    deleted_at     INTEGER
);

CREATE TABLE notebook_pages (
    id             INTEGER PRIMARY KEY,
    notebook_id    INTEGER NOT NULL REFERENCES notebooks(id),
    sort_key       INTEGER NOT NULL,
    logical_w      INTEGER NOT NULL CHECK(logical_w > 0),
    logical_h      INTEGER NOT NULL CHECK(logical_h > 0),
    template_kind  TEXT    NOT NULL DEFAULT 'blank',
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    deleted_at     INTEGER,
    UNIQUE(notebook_id, sort_key),
    UNIQUE(id, notebook_id)
);

CREATE TABLE notebook_state (
    notebook_id     INTEGER PRIMARY KEY REFERENCES notebooks(id),
    current_page_id INTEGER NOT NULL,
    FOREIGN KEY(current_page_id, notebook_id)
        REFERENCES notebook_pages(id, notebook_id)
);

CREATE TABLE notebook_strokes (
    id           INTEGER PRIMARY KEY,
    page_id      INTEGER NOT NULL REFERENCES notebook_pages(id),
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
    deleted_at   INTEGER,
    UNIQUE(page_id, seq)
);

CREATE TABLE notebook_stroke_chunks (
    stroke_id    INTEGER NOT NULL REFERENCES notebook_strokes(id),
    chunk_no     INTEGER NOT NULL,
    point_count  INTEGER NOT NULL,
    points       BLOB    NOT NULL,
    PRIMARY KEY(stroke_id, chunk_no)
);

CREATE INDEX notebooks_active_recent
    ON notebooks(deleted_at, updated_at DESC, id DESC);
CREATE INDEX pages_by_notebook
    ON notebook_pages(notebook_id, deleted_at, sort_key, id);
CREATE INDEX pages_deleted
    ON notebook_pages(deleted_at, id);
CREATE INDEX state_by_current_page
    ON notebook_state(current_page_id);
CREATE INDEX strokes_by_page
    ON notebook_strokes(page_id, deleted_at, seq);
CREATE INDEX strokes_deleted
    ON notebook_strokes(deleted_at, id);
```

Notas del esquema:

- `notebook_state` usa una clave compuesta para impedir que un cuaderno apunte a una página de otro.
- No hay cascade en las relaciones voluminosas. Los padres no pueden desaparecer antes que sus hijos.
- `template_kind` desconocido se trata como `blank` en lectura; no se rechaza toda la página por una plantilla creada por una versión futura.
- `page_count` y `next_sort_key` son metadatos transaccionales. Nunca se recalculan al listar la biblioteca.
- Cada notebook activo conserva al menos una página. V1 rechaza borrar la última con `last_page`.
- Título y geometría se validan en el repositorio. Todo valor numérico se convierte con `tonumber` y debe ser finito.
- La implementación tombstonea también el stroke en Undo. Es una desviación
  deliberada del primer borrador del esquema: un `DELETE` físico del padre
  tendría que recorrer todos sus chunks de forma síncrona o fallaría por FK.
  Mantener `seq` incluso en filas borradas evita reutilizar una clave única; el
  purgador elimina después chunks y metadata dentro de sus cotas.
- Para que la purga tampoco haga un scan de todos los chunks activos, propaga
  el tombstone de notebook a páginas y de página a strokes en lotes acotados,
  apoyados por `pages_deleted` y `strokes_deleted`. `state_by_current_page`
  evita recorrer todo el estado de la biblioteca al comprobar que una página
  tombstoneada ya no es la página actual. Sólo después borra hojas.

#### API del repositorio

```text
open(opts) / close()
transaction(fn)
listNotebooks({ after_updated_at, after_id, limit })
getNotebook(id)
createNotebook({ title, logical_w, logical_h, template_kind })
renameNotebook(id, title)
softDeleteNotebook(id)
listPages(notebook_id, { after_sort_key, after_id, limit })
getPage(page_id)
appendPage(notebook_id, spec)
selectCurrentPage(notebook_id, page_id)
softDeletePage(notebook_id, page_id)
purgeDeletedBatch(limits)
listStrokes / openStrokeCursor / readStrokeChunk
addStroke / deleteStroke
```

`createNotebook` inserta cuaderno, primera página, `notebook_state` y contadores en una sola transacción. `appendPage` consume `next_sort_key` y lo incrementa en 1024 dentro de la misma transacción. No usa `MAX`, `OFFSET` ni renumeración.

`listNotebooks` usa paginación por clave `(updated_at, id)`, límite por defecto 50 y no hace joins con páginas, strokes o chunks. `listPages`, anterior y siguiente se resuelven con el índice `(notebook_id, deleted_at, sort_key, id)`.

#### Borrado y purga

La acción visible de borrar sólo marca `deleted_at` y actualiza los metadatos necesarios en una transacción corta. Al borrar un cuaderno completo también elimina su fila de `notebook_state` en esa misma transacción; restaurar desde papelera no es un objetivo v1. Al borrar una página de un cuaderno activo, mueve antes `current_page_id` a una vecina si fuese necesario. Así ninguna página que llegue al purgador sigue referenciada por el estado actual. El espacio queda reutilizable por SQLite cuando el purgador elimina después las filas; no se ejecuta `VACUUM` automáticamente.

`purgeDeletedBatch` trabaja de hojas a raíz y como máximo por tick:

- 64 chunks;
- 32 strokes que ya no tienen chunks;
- 8 páginas que ya no tienen strokes ni están referenciadas por `notebook_state`;
- 1 cuaderno sin state ni páginas.

Cada lote es su propia transacción. El controlador agenda el siguiente con `UIManager:nextTick`; no ejecuta un bucle hasta vaciar la papelera. No se purga mientras hay un trazo activo ni durante el primer paint de una página.

### 5.6 `NotebookSession`

Nuevo archivo: `justdraw.koplugin/ink_notebook_session.lua`.

Responsabilidad: un cuaderno abierto, una sola página activa y su `InkSurfaceSession`. No conoce widgets.

API:

```text
open(notebook_id)
notebook() / currentPage() / stateName()
appendPage(spec)
goToPage(page_id)
goPrevious() / goNext()
softDeleteCurrentPage()
flush()
retryLoad() / retrySave()
retryInput()
onScreenResize(fit_rect, clip_rect)
onSuspend() / onResume()
close()
shutdown() -- sólo para muerte inevitable del host
```

Secuencia obligatoria para cambiar de página:

```text
1. Rechazar si hay contacto activo.
2. Pausar y liberar captura.
3. Abortar cualquier trazo incompleto.
4. Flush de la superficie actual.
5. Si falla, conservar página/cache/cola actuales y devolver save_failed.
6. Cerrar cache actual.
7. Abrir la nueva InkSurfaceSession y cargar por ticks.
8. Persistir current_page_id sólo cuando la nueva página llegue a ready.
9. Adquirir captura de nuevo.
10. Solicitar un refresh completo al adaptador visual futuro.
```

Una carga fallida deja la sesión en `load_failed` con metadata suficiente para reintentar. No borra ni reemplaza la página anterior en SQLite. Al reiniciar se abre la última página que llegó a `ready` y quedó registrada en `notebook_state`.

### 5.7 `NotebookController`

Nuevo archivo: `justdraw.koplugin/ink_notebook_controller.lua`.

Responsabilidad: lifecycle de repositorio/sesión, operaciones de biblioteca y contrato con la UI posterior.

Características:

- Apertura perezosa de SQLite; cargar el plugin no abre la base.
- Una sola `NotebookSession` activa.
- Métodos de listado devuelven metadata paginada, no objetos con strokes.
- `openNotebook` hace preflight no mutante de repositorio, página y transform
  antes del handoff. Si ya existe otra sesión notebook, la cierra mediante el
  gate durable y repite el preflight para no consumir metadata anterior al flush.
- `closeNotebook`, cambio de página y cierre solicitado por UI se niegan si falla el flush.
- `onFlushSettings` fuerza flush síncrono de la cola activa.
- `onSuspend` no sustituye a `onFlushSettings`; sólo pausa captura y aborta contacto incompleto después del intento durable de KOReader.
- `onResume` vuelve a adquirir captura sólo si la página sigue ready, writable y sin errores pendientes.
- `onScreenResize` pausa captura mientras cache vuelve a `loading`.
- La geometría inicial y de resize procede de `viewport_provider`; el host
  productivo exige viewport y rechaza también clip/fit sin intersección visible.
- Un error de callback produce `input_failed`; persiste a través de Resume y
  navegación, y sólo `retryInput` rearma explícitamente una lease nueva.
- `shutdown` siempre libera el callback y cierra recursos aunque el último COMMIT falle; `close` normal conserva el gate y la ruta de retry.
- Errores de preflight de la base de cuadernos no desactivan PDF ni hojas EPUB.
  Una hoja EPUB abierta se guarda/cierra y libera su raster antes de crear el
  raster notebook; su fallo durable bloquea el handoff y conserva la ruta retry.
- La UI posterior recibirá cambios por callbacks (`on_state_changed`, `on_library_changed`) y no accederá a tablas internas.

Interfaz que la UI podrá consumir:

```text
listNotebooks(cursor, limit)
createNotebook(spec)
renameNotebook(id, title)
deleteNotebook(id)
openNotebook(id)
closeNotebook()
activeSession()
retryLoad() / retrySave()
retryInput()
runOnePurgeBatch()
schedulePurge()
```

## 6. Integración con KOReader

### FileManager y ReaderUI

KOReader carga plugins sin `is_doc_only` en FileManager con `{ ui = self }`. ReaderUI crea otra instancia con `{ dialog, view, ui, document }`. Al abrir un libro, FileManager recibe `ShowingReader`, ejecuta `onClose`, finaliza plugins y cierra su widget antes de crear ReaderUI.

Por ello:

- No se comparten instancias de `NotebookController` entre hosts.
- El repositorio se puede cerrar y reabrir; `notebook_state` conserva la posición.
- Sólo `InkInputController` es global, porque protege un recurso global de KOReader.
- La detección de host seguirá el patrón oficial `self.ui.document == nil`.
- En FileManager nunca se accede a `doc_settings`, `view`, `document`, `rolling` ni estado de página.

### Ventana futura

La UI posterior deberá ser un widget superior mostrado con `UIManager:show`, cubrir la pantalla y consumir los gestos dentro de su área. No se reutilizará `ink_canvas_overlay.lua`.

El cierre voluntario seguirá este orden:

```text
NotebookWindow solicita cierre
→ NotebookController:closeNotebook()
→ flush/close exitosos
→ release de captura
→ UIManager:close(window, "full")
```

No se debe llamar primero `UIManager:close`: KOReader envía `FlushSettings` y `CloseWidget`, pero su API no ofrece un veto de cierre. La ventana sólo puede garantizar el gate durable si el controlador decide antes si debe cerrarse.

Límite explícito: un cierre externo de KOReader después de un COMMIT fallido no puede ser cancelado por este plugin usando la API actual. La cola corta reduce la ventana de riesgo y `FlushSettings` reintenta, pero una garantía absoluta requeriría un journal de recuperación separado o un cambio en KOReader. Si el producto exige esa garantía, detener la implementación y diseñar esa ampliación antes de prometerla.

### Entrada

La API estable y dev entrega `{slot, id, x, y, tool, timev}` antes del reconocimiento de gestos y permite dominar sólo el evento del lápiz. Los cuadernos reutilizan exactamente el backend probado:

- stylus moderno cuando existe `registerStylusCallback`;
- ruta de dedo como compatibilidad;
- goma cuando `slot.tool` sea eraser;
- rechazo deliberado de dedo/palma mientras el stylus escribe;
- ningún desregistro dentro del callback.

## 7. Plan de implementación por fases

Cada fase debe terminar con suite verde. No avanzar acumulando una regresión para corregirla después.

### Fase 0 — Baseline y fixtures

Archivos:

- `justdraw.koplugin/tests/support.lua`
- `justdraw.koplugin/tests/run.lua`
- nuevo `justdraw.koplugin/tests/notebook_host_spec.lua`

Tareas:

1. Registrar el baseline de 1395/0 y 33 archivos de sintaxis.
2. Añadir un factory de UI con forma de FileManager: `ui.menu`, sin `document`, `view` ni `doc_settings`.
3. Añadir un factory ReaderUI que conserve el actual.
4. Añadir scheduler determinista y soporte para dos instancias secuenciales del plugin.
5. Probar que cargar una instancia FileManager simulada no toca APIs de documento.

Aceptación:

- Las pruebas existentes siguen idénticas.
- El stub no inventa APIs ausentes en FileManager estable/dev.

### Fase 1 — Costura segura de host

Archivos:

- `justdraw.koplugin/main.lua`
- `justdraw.koplugin/tests/main_canvas_spec.lua`
- `justdraw.koplugin/tests/notebook_host_spec.lua`

Tareas:

1. Introducir `self.is_docless = self.ui.document == nil` al inicio de `init`.
2. Separar inicialización común mínima de inicialización lectora.
3. Ejecutar Store, dispatcher reader, barra, `registerViewModule` y CanvasSession sólo en ReaderUI.
4. Hacer idempotentes los handlers de lifecycle cuando la ruta lectora no se inicializó.
5. Mantener `is_doc_only = true` durante esta entrega; la prueba instancia la clase explícitamente con el host FileManager.
6. No añadir ítem de menú, placeholder ni preference visible.

Aceptación:

- PDF y EPUB mantienen los tests actuales.
- El host FileManager simulado puede inicializar, recibir `SaveSettings`, `Suspend` y `CloseWidget` sin traceback.
- No se abre ninguna base al cargar el plugin.

### Fase 2 — Extraer `InkSurfaceSession`

Archivos:

- nuevo `justdraw.koplugin/ink_surface_session.lua`
- `justdraw.koplugin/ink_canvas_session.lua`
- `justdraw.koplugin/ink_canvas_cache.lua`
- `justdraw.koplugin/ink_canvas_queue.lua`
- nuevo `justdraw.koplugin/tests/surface_session_spec.lua`
- actualizar `justdraw.koplugin/tests/canvas_session_spec.lua`

Tareas:

1. Extraer únicamente lifecycle de cache/queue y operaciones genéricas.
2. Añadir `surface = opts.surface or opts.canvas` en cache/queue durante la transición; no hacer un rename mecánico masivo.
3. Hacer que CanvasSession componga SurfaceSession y conserve su API externa.
4. Portar primero los tests de fallo: COMMIT bloqueado, retry, carga síncrona/asíncrona, cierre fallido, undo de id local y reparación tras goma.
5. Probar que un callback de error de lectura nunca desmonta input directamente.

Aceptación:

- Ningún cambio visible en hojas EPUB.
- Los tests de mutación que detectaron tinta fantasma y cierre dentro del callback siguen fallando ante esas mutaciones.
- SurfaceSession se prueba con un objeto `{id, logical_w, logical_h}` sin campos de libro.

### Fase 3 — Propiedad explícita de captura

Archivos:

- nuevo `justdraw.koplugin/ink_input_controller.lua`
- `justdraw.koplugin/main.lua`
- mantener `justdraw.koplugin/ink_capture.lua` salvo ajustes mínimos necesarios
- nuevo `justdraw.koplugin/tests/input_controller_spec.lua`
- actualizar `justdraw.koplugin/tests/capture_filter_spec.lua`

Tareas:

1. Implementar lease con token de propietario.
2. Migrar la ruta reader actual al controller sin cambiar su estado de lápiz.
3. Cubrir owner obsoleto, release doble, adquisición concurrente y transición diferida tras error.
4. Simular FileManager A cerrado, ReaderUI B creado, y demostrar que A no puede liberar la captura de B.
5. Exponer `hasActiveContact` para gates de página/rotación.

Aceptación:

- Sólo `ink_input_controller.lua` llama a los métodos de instalación/eliminación de `ink_capture.lua` desde código de producto.
- Un callback de varios slots puede fallar sin convertir a nil el callback entre slots.
- Un callback ajeno nunca se sobrescribe.

### Fase 4 — Transform genérico sin regresión EPUB

Archivos:

- `justdraw.koplugin/ink_canvas_transform.lua`
- `justdraw.koplugin/ink_canvas_overlay.lua` sólo para adaptar parámetros si es necesario
- `justdraw.koplugin/tests/canvas_geometry_spec.lua`
- `justdraw.koplugin/tests/canvas_overlay_spec.lua`
- nuevo `justdraw.koplugin/tests/notebook_geometry_spec.lua`

Tareas:

1. Añadir `fit_rect`, `clip_rect` y alineación.
2. Mantener constructor antiguo como adaptador hasta migrar CanvasSession.
3. Conservar que 40/70/100 cambia recorte, no escala ni cache size.
4. Probar letterboxing, coordenadas fuera de clip, rotación y geometría no finita.
5. Probar un viewport de cuaderno con chrome descontado y round trip canvas/screen/cache.

Aceptación:

- Las fixtures de escala EPUB no cambian.
- Un punto fuera de `clip_rect` nunca comienza ni continúa un trazo.
- No hay distorsión al reabrir una página con otra orientación.

### Fase 5 — Base de cuadernos

Archivos:

- nuevo `justdraw.koplugin/ink_notebook_repository.lua`
- nuevo `justdraw.koplugin/tests/notebook_repository_spec.lua`
- `justdraw.koplugin/tests/conformance.lua`

Tareas:

1. Implementar apertura, pragmas, schema v1, cierre y modo read-only futuro.
2. Implementar create/list/get/rename, primera página transaccional, append y estado actual.
3. Implementar contrato de strokes/chunks con codec existente y casts BLOB/TEXT.
4. Implementar soft delete y un solo lote de purga por llamada.
5. Añadir keyset pagination y límites estrictos.
6. Añadir conformance contra SQLite real, no sólo recorder SQL.

Casos de prueba obligatorios:

- schema/constraints/FK/user_version;
- creación atómica de notebook + página + state;
- rollback en cada punto de esa transacción;
- enteros `int64 cdata` convertidos en la frontera;
- BLOB con varios NUL round-trip;
- metadata no finita rechazada;
- esquema futuro se abre read-only y no escribe;
- COMMIT `SQLITE_BUSY` conserva exactamente las operaciones;
- 10 000 páginas se listan sin consultar strokes/chunks;
- anterior/siguiente usa el índice y no `OFFSET`;
- borrar la última página se rechaza;
- soft delete es O(1) respecto de strokes;
- cada lote de purga respeta sus límites y puede reanudarse;
- cursor se cierra y reporta error real en EOF.

Aceptación:

- La base canvas existente no se abre ni migra durante estas pruebas.
- `EXPLAIN QUERY PLAN` demuestra uso de índices para biblioteca, páginas y strokes de la página activa.
- Ningún método de listado devuelve blobs de puntos.

### Fase 6 — Sesión y controlador de cuaderno sin UI

Archivos:

- nuevo `justdraw.koplugin/ink_notebook_session.lua`
- nuevo `justdraw.koplugin/ink_notebook_controller.lua`
- nuevo `justdraw.koplugin/tests/notebook_session_spec.lua`
- nuevo `justdraw.koplugin/tests/notebook_controller_spec.lua`
- `justdraw.koplugin/tests/notebook_scale_spec.lua`

Tareas:

1. Implementar apertura perezosa del repositorio.
2. Abrir una sola página a través de SurfaceSession.
3. Implementar gates de append, next/previous, close, suspend y rotación.
4. Persistir current page sólo tras carga ready.
5. Integrar lease de entrada mediante un destino sin widget, inyectable en tests.
6. Ejecutar purga sólo cuando no hay contacto ni primer paint.
7. Probar reapertura con una instancia nueva del controlador.
8. Ejecutar la purga cooperativa a un lote por tick hasta quedar limpia, y
   pausarla durante loading, save_failed o contacto activo.
9. Actualizar `updated_at` de página/cuaderno una vez por batch durable, dentro
   de la misma transacción que la tinta.

Casos de prueba obligatorios:

- COMMIT fallido bloquea cambio, append y close;
- retry exitoso permite continuar sin duplicar trazos;
- rotación con stroke abierto lo aborta y no deja punto fantasma;
- cache en loading nunca consume lápiz;
- suspend usa el flush previo y luego pausa captura;
- sólo una lease entre reader y notebook;
- abrir página densa carga chunks por ticks;
- cambiar entre 100 páginas mantiene un solo raster vivo;
- cerrar y reabrir restaura notebook y current page;
- Suspend/Resume libera y recupera captura; un callback fallido queda visible y reintentable;
- transform inválido conserva el raster previo y append no crea una página invisible;
- teardown forzado no deja callback global aun si falla el COMMIT final;
- fallo del repositorio notebook no altera PDF/EPUB;
- navegación read-only no escribe current page y append/delete no cierran la vista;
- una hoja EPUB activa se libera antes de abrir el raster notebook y un fallo
  de su flush bloquea el handoff;
- passthrough de stylus dentro de la página no deja tinta bajo overlays, incluso
  si el overlay aparece durante el contacto;
- un contacto sin coordenadas y un contacto ya pasado a GestureDetector se
  resuelven sin medias secuencias ni timers huérfanos.

Aceptación:

- El dominio es completamente ejercitable mediante API sin ReaderUI ni FileManager.
- No hay ningún xpointer, checksum de libro o `doc_settings` en módulos notebook.
- No se ha añadido UI visible.

### Fase 7 — Integración, documentación y gate para la UI posterior

Archivos:

- `justdraw.koplugin/main.lua`
- `justdraw.koplugin/tests/notebook_host_spec.lua`
- `README.md`
- `decisions.md`

Tareas:

1. Instanciar `NotebookController` de forma perezosa desde la costura de host, sin abrir DB.
2. Delegar `SaveSettings`, `Suspend`, resize y teardown cuando el controlador exista.
   Delegar también `Resume` y separar cierre durable (`close`) de destrucción
   inevitable del host (`shutdown`).
3. Documentar la base separada, límites v1 y riesgo residual de cierre externo tras fallo de COMMIT.
4. Registrar ADR: dominio separado, una superficie activa, input lease, append-only order y purge sin cascade.
5. Dejar definida la activación posterior: la UI deberá cambiar `is_doc_only=false`, registrar el menú en ambos hosts y usar exclusivamente el contrato del Controller.

Aceptación:

- Instancia reader sigue comportándose igual sin cuaderno activo.
- Instancia FileManager simulada crea/reabre controller sin APIs de documento.
- `git diff --check` limpio y toda la matriz de verificación verde.

## 8. Rendimiento y estabilidad teórica

### Memoria

En una pantalla Scribe de 1860×2480, un raster BB8 completo ocupa aproximadamente 4,6 MB antes de overhead. La arquitectura permite uno solo. No se mantienen páginas anteriores, thumbnails ni buffers de prefetch.

La metadata de biblioteca se pagina a 50 filas. La metadata de strokes sólo se carga para una página activa; los puntos se decodifican por chunks con los límites actuales del cache.

### CPU y responsividad

- Ningún listado usa `OFFSET` sobre miles de páginas.
- Anterior/siguiente son búsquedas indexadas alrededor de `sort_key`.
- La creación de una página escribe un número constante de filas.
- Borrar es una marca lógica constante; purgar cede después de cada lote.
- No se repinta durante un drag de chrome futuro salvo que el gate físico lo justifique.
- No se introduce coalescing de tinta live en esta fase. Se conserva el refresh por segmento ya probado; optimizarlo requiere medir latencia en el Scribe.

### Flash y SQLite

- La cola agrupa trazos antes del COMMIT.
- WAL/TRUNCATE sigue la capacidad reportada por Device.
- No se ejecuta `VACUUM` automáticamente.
- No se mantiene una transacción de lectura entre ticks: cada chunk se obtiene
  por `(stroke_id, chunk_no)` y el statement se abre/cierra dentro de esa llamada.
  `point_count` determina el número esperado, sin consulta EOF adicional.
- Sólo hay un escritor activo por Controller. Si otra conexión obtiene el lock, el error se conserva como `save_failed`; no se descarta ni se reintenta en un loop apretado.

### Biblioteca de 10 000 páginas

El tamaño de la biblioteca afecta el número de filas en índices, no la memoria de la sesión. Los caminos interactivos siguen siendo:

```text
listar notebooks: O(log N + limit)
listar páginas:   O(log N + limit)
prev/next:        O(log N)
append:           O(log N) por índices + O(1) filas
soft delete:      O(log N) + O(1) filas
cargar página:    O(strokes/chunks de esa página), repartido por ticks
```

No se promete una cota temporal exacta en Kindle sin medición, pero no queda ningún camino interactivo que recorra todos los trazos o todas las páginas.

## 9. Verificación

### Comandos locales obligatorios

Desde la raíz del repositorio:

```sh
git diff --check
luajit test.lua
lua test.lua
KOREADER_PLUGIN_DIR=/Users/christianstenger/GitHub/justdraw/justdraw.koplugin \
  /Users/christianstenger/.codex/skills/koreader-simulator-qa/scripts/koreader_qa.sh preflight
KOREADER_PLUGIN_DIR=/Users/christianstenger/GitHub/justdraw/justdraw.koplugin \
  /Users/christianstenger/.codex/skills/koreader-simulator-qa/scripts/koreader_qa.sh test
```

Conformance SQLite/KOReader desde el runtime:

```sh
cd /Users/christianstenger/koreader/koreader/koreader-emulator-arm64-apple-darwin25.1.0-debug/koreader
./luajit /Users/christianstenger/GitHub/justdraw/justdraw.koplugin/tests/conformance.lua
./luajit /Users/christianstenger/GitHub/justdraw/justdraw.koplugin/tests/conformance.lua \
  /Users/christianstenger/koreader/koreader/test/juliet.epub
```

Smoke con geometría Scribe aproximada:

```sh
KOREADER_PLUGIN_DIR=/Users/christianstenger/GitHub/justdraw/justdraw.koplugin \
KOREADER_SCREEN_WIDTH=1860 KOREADER_SCREEN_HEIGHT=2480 KOREADER_SCREEN_DPI=300 \
  /Users/christianstenger/.codex/skills/koreader-simulator-qa/scripts/koreader_qa.sh smoke kindle-paperwhite
```

Este preset sólo aporta el perfil Kindle disponible del simulador. La geometría no simula Wacom, palma, waveforms ni latencia física.

### Matriz de runtime

| Runtime | Obligatorio | Qué valida |
|---|---:|---|
| Lua 5.1+ local | Sí | Compatibilidad de lenguaje y lógica pura |
| LuaJIT CI | Sí | Sintaxis y suite completa |
| KOReader local v2025.08 | Sí | SQLite real, BlitBuffer, EPUB real, FileManager/Reader smoke; stylus moderno queda UNCHECKABLE |
| KOReader v2026.07.1 exacto | Sí antes de merge de UI | API moderna, lifecycle y smoke estable |
| KOReader dev `5e45c4b…` o posterior revalidado | Sí antes de merge de UI | Compatibilidad con desarrollo |
| Kindle Scribe físico | Sí antes de release | Latencia, palma, goma, rotación, suspend, ghosting y flash |

### Gate físico posterior

Medir al menos:

- latencia comparada con la tinta PDF actual;
- pérdida de muestras en trazos largos;
- stylus + palma + dedo fuera/dentro de página;
- goma posterior;
- 100 cambios de página seguidos;
- página con 1000+ strokes;
- suspensión inmediata después de escribir;
- COMMIT fallido inducido y retry;
- rotación en reposo y con contacto;
- ghosting tras cambios completos y tras escritura continua;
- tiempo de abrir biblioteca con 10 000 páginas sintéticas;
- crecimiento y reutilización del archivo SQLite después de purge.

## 10. Stop conditions

Detener la implementación y volver a diseño si ocurre cualquiera de estos casos:

- SurfaceSession necesita conocer xpointer, ReaderUI o widgets para funcionar.
- Se necesita más de un raster de página para satisfacer una operación v1.
- Cambiar de página puede liberar la cache después de un flush fallido.
- Un callback de input puede desmontar una lease ajena o desregistrarse dentro de su propio frame.
- Un listado de biblioteca accede a `notebook_strokes.points` o carga todos los pages.
- Borrar un notebook ejecuta un cascade proporcional a todo su contenido en un tick.
- El constructor FileManager toca `doc_settings`, `view` o `document`.
- La UI necesita acceso directo a SQL para implementar una acción.
- El runtime exacto estable contradice alguno de los contratos de lifecycle o input aquí citados.
- El producto exige impedir el cierre global de KOReader después de un fallo de COMMIT; la API actual no ofrece ese veto.
- Las pruebas EPUB/PDF existentes dejan de ser equivalentes antes de añadir comportamiento notebook.

## 11. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Regresión por extraer código de CanvasSession | Adaptadores con API actual y portar primero tests de fallo |
| Dos propietarios de stylus | Lease global por identidad y release ownership-safe |
| Tinta visible pero no durable | Queue acepta antes de raster; save_failed bloquea edición/navegación |
| Congelación con miles de páginas | keyset pagination, metadata-only, append O(1), purge por ticks |
| Gran delete en flash | soft delete y relaciones sin cascade voluminoso |
| WAL crece por cursor largo | lectura keyed por chunk; cada statement cierra dentro del mismo tick |
| Orientación cambia escala | logical geometry persistente, fit/clip separados y rebuild con captura pausada |
| Base futura | apertura read-only y cero escrituras |
| FileManager y ReaderUI reinstancian plugin | repositorio reabrible, state persistente y captura protegida por singleton |
| UI posterior fuerza rediseño | Controller con operaciones de dominio y callbacks, sin dependencia de widget |

## 12. Registro de validación externa

### Versiones KOReader

- Tema: resolución estable/desarrollo/base/local.
- Por qué: la API de stylus y lifecycle son dependientes de versión.
- Fuente: API oficial de releases y ramas de `koreader/koreader`, resuelta por `resolve_koreader_refs.py` el 2026-08-26.
- Verificado: estable `v2026.07.1` = `9192014d…`; dev = `5e45c4b…`; local = `1d66e440…`; gitlink `koreader-base` local coincide con su checkout.
- Restricción: el runtime local es anterior a la API moderna.
- Impacto: fuentes fijadas por commit y gate runtime separado.
- Confianza: alta.

### Carga en FileManager y ReaderUI

- Tema: instanciación del plugin en hosts docless/document.
- Por qué: `main.lua` actualmente asume ReaderUI.
- Fuentes: [FileManager estable](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/apps/filemanager/filemanager.lua#L417-L429), [FileManager dev](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/apps/filemanager/filemanager.lua#L417-L429), [ReaderUI estable](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/apps/reader/readerui.lua#L463-L476).
- Verificado: FileManager filtra `is_doc_only` y pasa sólo `ui`; ReaderUI pasa `dialog`, `view`, `ui` y `document`.
- Restricción: semántica igual en estable y dev inspeccionados.
- Impacto: host guard con `self.ui.document == nil`; ninguna API de documento en FileManager.
- Confianza: alta.

### Transición FileManager → ReaderUI

- Tema: lifetime de instancias.
- Por qué: define qué puede compartirse y quién libera input.
- Fuentes: [FileManager onShowingReader estable](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/apps/filemanager/filemanager.lua#L819-L849), [ReaderUI showReader estable](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/apps/reader/readerui.lua#L613-L641), [PluginLoader estable](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/pluginloader.lua).
- Verificado: `ShowingReader` cierra FileManager y `PluginLoader:finalize` elimina referencias registradas; ReaderUI crea otra instancia.
- Impacto: Controllers por host, repositorio reabrible, sólo el broker de captura es singleton.
- Confianza: alta.

### UIManager, stack y cierre

- Tema: ventana superior y orden de cierre.
- Por qué: el gate de guardado depende de cuándo se emiten eventos.
- Fuentes: [UIManager estable show/close](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/uimanager.lua#L156-L225), [UIManager estable sendEvent](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/uimanager.lua#L884-L930), [UIManager dev](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/ui/uimanager.lua#L215-L286).
- Verificado: los widgets están apilados; `close` envía primero `FlushSettings` y luego `CloseWidget`; el retorno no actúa como veto.
- Impacto: Controller hace flush antes de solicitar `UIManager:close`; límite documentado para cierres externos.
- Confianza: alta.

### API de stylus

- Tema: callback, datos y dominación del evento.
- Por qué: el cuaderno necesita lápiz y exclusión de palma.
- Fuentes: [Input estable](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/input.lua#L461-L518), [Input dev](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/device/input.lua#L462-L519).
- Verificado: callback singleton; datos `{slot,id,x,y,tool,timev}`; retorno true elimina el slot antes de gesture detection; iteración multi-slot relee el callback.
- Restricción: presente en estable/dev fijados, ausente en runtime local.
- Impacto: lease única y desarme diferido obligatorio.
- Confianza: alta.

### Transacciones SQLite

- Tema: atomicidad y fallo de COMMIT.
- Por qué: página, current state y strokes no pueden quedar a medias.
- Fuente: [SQLite Transactions](https://www.sqlite.org/lang_transaction.html).
- Verificado: un COMMIT puede devolver `SQLITE_BUSY` y la transacción permanece activa; statements terminan al cerrar/reset/finalizar cursors.
- Impacto: rollback explícito, operaciones retenidas y cursores cerrados en todos los caminos.
- Confianza: alta.

### Foreign keys y cascades

- Tema: integridad y coste de borrado.
- Por qué: miles de hijos pueden convertir un delete en trabajo masivo.
- Fuente: [SQLite Foreign Key Support](https://www.sqlite.org/foreignkeys.html).
- Verificado: FK debe habilitarse por conexión; `CASCADE` propaga el delete a hijos; constraints pueden ser diferidos.
- Impacto: FK ON siempre, clave compuesta para current page y sin cascades voluminosos.
- Confianza: alta.

### WAL y checkpoints

- Tema: concurrencia y crecimiento de sidecar.
- Por qué: una lectura larga o muchos commits afectan flash y rendimiento.
- Fuente: [SQLite Write-Ahead Logging](https://www.sqlite.org/wal.html).
- Verificado: un writer a la vez; readers y writer pueden coexistir; lectores largos detienen checkpoints y un WAL grande degrada lecturas.
- Impacto: no conservar transacciones de lectura entre ticks, cerrar cursores y mantener un escritor lógico.
- Confianza: alta.

### Índices y paginación

- Tema: biblioteca y páginas grandes.
- Por qué: evitar scans/sorts y memoria temporal con 10 000 páginas.
- Fuente: [SQLite Query Planner](https://www.sqlite.org/queryplanner.html).
- Verificado: índices multicolumna satisfacen filtro + orden; sin índice, ORDER BY requiere sort y almacenamiento temporal; lookup indexado escala aproximadamente con `(K+1)·log N`.
- Impacto: índices compuestos, keyset pagination y `EXPLAIN QUERY PLAN` en conformance.
- Confianza: alta.

### Simulador local

- Tema: capacidad de verificación disponible.
- Por qué: distinguir prueba real de emulación incompleta.
- Fuente: skill local `koreader-simulator-qa`, preflight y suite ejecutados el 2026-08-26.
- Verificado: runtime `v2025.08-100`, preflight PASS, 33 archivos sintácticos y 1395 tests PASS.
- Restricción: no reproduce digitalizador Wacom, palma, latencia ni waveforms; stylus moderno no es verificable allí.
- Impacto: gate estable exacto y Scribe físico siguen obligatorios.
- Confianza: alta sobre el runtime local, nula para comportamiento físico.

## 13. Trazabilidad de requisitos

| Requisito del análisis inicial | Cobertura en este plan |
|---|---|
| Cuadernos sin libro | Dominio `NotebookRepository`/`NotebookSession`, sin book/xpointer |
| Disponible eventualmente desde FileManager y ReaderUI | Costura de host y activación diferida a la UI posterior |
| Reutilizar tinta probada | `InkSurfaceSession` sobre Cache/Queue/Codec/Grid |
| Base separada | `justdraw-notebooks.sqlite3`, schema/migraciones independientes |
| Una captura de stylus | `InkInputController` con lease única |
| Geometría persistente | logical dimensions + fit/clip transform |
| Muchos cuadernos/páginas | metadata-only, keyset, índices, un raster |
| Página densa | streaming por chunks/ticks |
| Guardado estable | cola bounded, flush gates, retry y save_failed |
| Borrado escalable | soft delete + purga leaf-first por lotes, sin VACUUM |
| Rotación segura | captura pausada, stroke abortado, cache reconstruida |
| UI separada | Controller estable; ningún widget notebook en esta entrega |
| No romper PDF/EPUB | archivos no tocables, adaptadores y suite de regresión |
| Validación física posterior | matriz y gate Scribe explícitos |

## 14. Definición de terminado de esta entrega

La fundación queda terminada cuando:

- los módulos de repositorio, superficie, sesión, controller e input lease existen y cumplen sus contratos;
- una prueba crea un cuaderno y múltiples páginas, dibuja, guarda, cambia de página, cierra y reabre con una instancia nueva;
- una biblioteca sintética de 10 000 páginas no lee strokes ni ejecuta trabajo O(N) en un tick interactivo;
- la conformance SQLite crea además 10 000 páginas reales y demuestra listado
  keyset de 50 filas;
- fallos de load/COMMIT dejan una ruta de retry sin tinta fantasma;
- PDF y EPUB conservan toda la suite previa;
- conformance SQLite real es verde;
- stable/dev source contracts siguen vigentes;
- README/ADR explican límites y gates pendientes;
- no hay UI visible ni se ha cambiado `is_doc_only`.

El siguiente trabajo puede entonces concentrarse exclusivamente en `NotebookWindow`, biblioteca, menús y ergonomía e-ink. Su primer cambio de integración será activar `is_doc_only=false` y usar los contratos de este plan, no acceder al SQL ni a `InkCapture` directamente.
