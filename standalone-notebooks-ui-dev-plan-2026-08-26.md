# Plan de implementación: interfaz de cuadernos independientes

- **ID:** `FI-NOTEBOOK-UI-MVP`
- **Fecha:** 2026-08-26
- **Repositorio:** `fingerink.koplugin`
- **Rama objetivo:** `codex/kindle-scribe-stylus`
- **Stack:** Lua/LuaJIT, widgets de KOReader, `lua-ljsqlite3`, raster de FingerInk, entrada Wacom a través de KOReader
- **Plan previo de dominio:** `standalone-notebooks-dev-plan-2026-08-26.md`
- **Propuesta visual analizada:** `/Users/christianstenger/Desktop/Propuesta UI Cuadernos FingerInk/Propuesta UI Cuadernos FingerInk.dc.html`
- **Objetivo:** activar el backend de cuadernos ya construido mediante una biblioteca y un editor de pantalla completa utilizables en FileManager y ReaderUI, seguros ante fallos de carga/guardado/entrada y adecuados para e-ink y lápiz.
- **Regla de idioma:** todo texto visible, etiqueta de accesibilidad, cadena base de gettext, identificador nuevo, comentario nuevo y documentación nueva que se incorpore al producto debe escribirse en inglés. El español de la propuesta es únicamente material de diseño.

Este documento es un plan de ejecución. No autoriza cambios de esquema, miniaturas, sincronización ni nuevas plantillas de papel.

## 1. Veredicto arquitectónico

La propuesta es implementable sobre el backend actual, pero no debe codificarse literalmente. La dirección correcta es mantener dos ventanas superiores —biblioteca y editor— y preservar el dominio sin dependencias de widgets. Antes de construir la UI hay que ajustar cuatro fachadas pequeñas y corregir varias suposiciones del diseño.

Las decisiones finales son:

1. La biblioteca será una ventana propia paginada, no una instancia de `Menu`. `MenuItem` asigna `tap` y `hold` a toda la fila y no ofrece un botón de acción **trailing** independiente. Existe un slot de estado a la izquierda, pero no cumple la anatomía propuesta ni da una solución estable para “abrir fila” más “acciones” con dos zonas separadas. La biblioteca debe usar componentes nativos de KOReader dentro de un widget propio; no debe copiar ni monkey-patchear el `MenuItem` privado.
2. La UI se abre desde FileManager y ReaderUI, pero abrir la biblioteca no cede el input, no cierra una hoja EPUB y no apaga Draw. El handoff ocurre sólo cuando el usuario abre o crea un cuaderno y se va a mostrar el editor.
3. Los 168 px del riel y 84 px de la franja son una referencia para un Scribe de 300 ppi, no constantes. Los objetivos físicos se resuelven con `Screen:scaleByDPI`; `Screen:scaleBySize` no garantiza milímetros salvo que exista un override de DPI.
4. `NotebookEditorWindow` será la única ventana de editor registrada en el stack. Todos sus hijos propagarán `show_parent = editor` para que `UIManager:setDirty` repinte la ventana superior correcta.
5. Las regiones de passthrough ya son dinámicas: `NotebookInput` evalúa las funciones `touch_passthrough` y `stylus_passthrough` en cada clasificación. No se añadirá `setPassthroughRegions`. El editor mantendrá un registro mutable de regiones que las funciones consultarán.
6. La salida no se decidirá con `state == "load_failed"`. Una carga fallida tras cambiar de página puede conservar `pending_current` o `pending_delete_page`, y en ese caso `close()` está deliberadamente bloqueado. La fachada expondrá `can_close` como capacidad aproximada y el comando Exit siempre verificará el resultado real de `closeNotebook()`.
7. El ordinal `3 / 57` queda fuera del MVP. Se mostrará el total de páginas y se deshabilitarán Previous/Next con flags cacheados. Esto evita una consulta `COUNT` en cada cambio de UI y no inventa un ordinal a partir de `sort_key`.
8. El snapshot de UI no ejecutará SQL ni se cacheará como una tabla mutable compartida. Cada llamada devolverá una tabla nueva calculada sólo con estado de sesión ya disponible y flags de navegación actualizados una vez por transición de página.
9. No se añadirá un `full` automático cada 32 trazos. Es una hipótesis de hardware, duplica parcialmente las promociones de refresco de KOReader y debe decidirse en el gate físico. Los cambios de página, entrada/salida, rotación y resume ya ofrecen puntos seguros para limpiar ghosting.
10. `onSuspend()` no repetirá el flush. En KOReader, `Device:_beforeSuspend()` llama `UIManager:flushSettings()` antes de emitir `Suspend`; FingerInk conservará el flush durable en `onSaveSettings()` y usará `onSuspend()` para abortar contacto y soltar captura.
11. La biblioteca no se recargará por cada batch durable de tinta mientras permanezca bajo el editor. Se marcará como stale y se volverá al primer lote cuando el editor se cierre.
12. No se guardará `last_notebook_id` ni “list density” en v1. La biblioteca ya ordena por actividad y siempre se abre primero. La única preferencia visual nueva será el lado del riel.

## 2. Alcance

### 2.1 Incluido

- Entrada “Notebooks” desde FileManager y ReaderUI.
- Biblioteca textual, sin thumbnails, con paginación keyset y pantallas discretas.
- Crear cuaderno con tres tamaños de papel y `template_kind = "blank"`.
- Renombrar y borrar un cuaderno con confirmación.
- Editor de pantalla completa en vertical y horizontal.
- Riel lateral fijo, franja informativa superior y papel acotado.
- Pen, Eraser, Undo, Previous page, Next page, Add page y More.
- Borrar la página actual, salvo que sea la última.
- Entrada mediante stylus moderno y fallback de dedo ya implementados.
- Rechazo de palma sobre el papel y protección de controles durante contacto del stylus.
- Estados `loading`, `ready`, `load_failed`, `save_failed`, `input_failed` y read-only.
- Retry de biblioteca, carga de página, guardado y entrada.
- Cierre durable, cambio de host, suspensión, reanudación y rotación.
- Copy base enteramente en inglés y preparado para gettext.
- Pruebas unitarias, conformance, smoke en FileManager/ReaderUI y matriz física pendiente.

### 2.2 No incluido

- Papel ruled, grid o dots y su renderer.
- Selector o miniaturas de páginas.
- Ordinal exacto de la página actual.
- Reordenar, insertar entre páginas o duplicar páginas.
- Miniaturas de cuadernos, portadas o previsualización de tinta.
- Búsqueda, carpetas, tags, papelera visible, exportación, OCR o sincronización.
- Presión, inclinación y hover.
- Chrome ocultable o modo de foco.
- Guardado de preferencias dentro de SQLite.
- Cambio de esquema de cuadernos.
- Tuning definitivo de waveforms o umbral de ghosting sin un Scribe físico.

## 3. Estado del repositorio y fuente de verdad

El backend de cuadernos existe sin UI y está sin commit en el worktree actual. La implementación debe preservar los cambios del usuario y trabajar sobre ellos; no debe restaurar ni reescribir archivos ajenos al alcance.

### 3.1 Módulos existentes que se conservan

| Archivo | Responsabilidad actual | Uso por la UI |
|---|---|---|
| `fingerink.koplugin/main.lua` | lifecycle de plugin, ReaderUI, herramientas compartidas, handoff de input | activa FileManager, crea el coordinador visual y conserva la única fuente de preferencias |
| `fingerink.koplugin/ink_notebook_repository.lua` | SQLite, keyset, metadata, páginas y trazos | no se usa directamente desde widgets |
| `fingerink.koplugin/ink_notebook_controller.lua` | repositorio lazy, una sesión activa, host lifecycle y purga | fachada única para biblioteca/editor |
| `fingerink.koplugin/ink_notebook_session.lua` | una página activa, navegación y gates durables | snapshot cohesivo y acciones del editor |
| `fingerink.koplugin/ink_notebook_input.lua` | clasificación de papel/chrome y state machine de stylus/dedo/goma | callbacks dinámicos de regiones y dirty boxes |
| `fingerink.koplugin/ink_surface_session.lua` | raster único, cola, undo y pending writes | sigue oculto detrás de NotebookSession |
| `fingerink.koplugin/ink_canvas_transform.lua` | fit/clip y conversiones pantalla/lienzo | reutilizado por viewport y dirty boxes |
| `fingerink.koplugin/ink_input_controller.lua` | exclusión global de captura y desarme seguro | sin cambios de arquitectura |

### 3.2 Restricciones confirmadas en el código

- `Repository:listNotebooks()` lista sólo metadata, por `updated_at DESC, id DESC`, con límite 50 por defecto y 200 máximo.
- `Controller:listNotebooks()` abre SQLite de forma lazy.
- `Controller:openNotebook()` exige viewport, hace preflight antes del handoff y mantiene sólo una sesión.
- `Session:_beforeSwitch()` no libera la página anterior hasta que `flush()` termina.
- `SurfaceSession` mantiene un solo raster y carga trazos por ticks.
- `SurfaceSession:pendingWrites()` y `SurfaceSession:undo()` ya existen, pero no deben ser consumidos directamente por los widgets.
- `NotebookInput` consulta callbacks de passthrough por evento y repara tinta provisional si una región interactiva aparece en mitad de un contacto dominado.
- `Session:close()` puede fallar y conservar la superficie para retry; `shutdown()` es la única salida forzada para teardown del host.
- `on_library_changed` puede emitirse por cambios durables frecuentes, por lo que no debe provocar repaints de una biblioteca cubierta.

### 3.3 Archivos que no se deben tocar

- Esquema SQL y migraciones, salvo que una prueba demuestre que la UI no puede funcionar con la API actual. El diseño no justifica una migración.
- Rutas directas de tinta PDF y hojas EPUB, excepto el punto de handoff ya existente.
- `ink_capture.lua` y `ink_input_controller.lua`, salvo un bug reproducible nuevo en sus contratos.
- Codecs, chunks y rasterización.
- CI o dependencias externas.

## 4. Revisión de la propuesta

### 4.1 Decisiones aceptadas

| Propuesta | Decisión de implementación |
|---|---|
| Siempre entrar por la biblioteca | Aceptada en ambos hosts |
| Biblioteca textual y paginada | Aceptada; widget propio con paginación discreta |
| A5 portrait, Letter portrait y A5 landscape | Aceptada; siempre blank |
| Riel lateral más franja superior | Aceptada; dimensiones escaladas, no píxeles fijos |
| Navegación sólo con botones | Aceptada |
| Chrome permanente | Aceptada |
| Herramientas arriba y navegación abajo | Aceptada |
| Destructivo sólo en More/Actions | Aceptada |
| Error persistente sobre el borde inferior del papel | Aceptada; no cambia fit_rect |
| Dos ventanas superiores: biblioteca y editor | Aceptada |
| Read-only como capacidad, no como error recuperable | Aceptada |
| Sin thumbnails, scroll continuo ni animaciones | Aceptada |

### 4.2 Decisiones modificadas

| Propuesta original | Corrección | Motivo |
|---|---|---|
| `Menu` con botón `⋯` trailing | `NotebookLibraryWindow` + filas propias | `MenuItem` no expone esa anatomía con dos hit targets separados |
| Preflight/handoff al entrar desde ReaderUI | Handoff al abrir o crear un cuaderno | La biblioteca no necesita viewport ni captura; fallar o cancelar no debe alterar el libro |
| 168/84 px constantes | `scaleByDPI` y mínimos de widgets KOReader | Conserva tamaño físico y evita asumir una única resolución |
| `Screen:scaleBySize` para mm | `Screen:scaleByDPI(mm * 160 / 25.4)` | `scaleBySize` depende del lado menor/600 salvo override de DPI |
| Exit habilitado en todo `loading`/`load_failed` | `can_close` + verificación real de `closeNotebook` | Cargas destino pendientes pueden bloquear cierre durable |
| Snapshot cacheado e “inmutable” | tabla nueva, sin SQL, flags cacheados por transición | Lua no ofrece inmutabilidad; un cache añade invalidación y riesgo de mezclar ticks |
| `3 / 57` si “entra” | sólo `page_count` en MVP | Evita COUNT/ordinal y no deduce posición de `sort_key` |
| Setter de regiones dinámicas | registro mutable leído por callbacks existentes | La API actual ya reevalúa las funciones por contacto |
| Recargar lote actual al volver | recargar primer lote | El cuaderno usado cambia de posición por `updated_at`; el primer lote es el resultado correcto y predecible |
| Indicador de carga tras 400 ms | estado estático de carga antes de la consulta | SQLite corre en el hilo UI; un timer no puede aparecer mientras una consulta síncrona bloquea |
| `fast` para texto de estado | `ui` para texto; `fast` sólo para inversión transitoria | KOReader recomienda `ui` para UI/texto nítido |
| `full` cada N=32 trazos | diferido al gate físico | No hay evidencia de dispositivo y KOReader ya promociona ciertos refrescos |
| Flush dentro de Suspend | flush en SaveSettings, release en Suspend | Es el orden real del lifecycle de KOReader |

### 4.3 Decisiones diferidas

- Ordinal de página.
- Plantillas no blank.
- Selector de páginas.
- Chrome colapsable.
- Umbral de ghosting por cantidad de trazos.
- Ajuste del guard de palma posterior al lift, salvo la arquitectura e inyección de reloj necesaria para medirlo.
- Densidad configurable de la biblioteca.

## 5. Política obligatoria de idioma e internacionalización

La propuesta está escrita en español, pero ninguna cadena española debe copiarse al código.

### 5.1 Reglas de implementación

1. Cada literal visible debe tener un msgid inglés: `_("Notebooks")`, nunca `_("Cuadernos")`.
2. Interpolación mediante `ffi/util.template`, no concatenación de frases traducibles.
3. Plurales mediante `local N_ = _.ngettext` y `T(N_(...))`.
4. Títulos de usuario pasan por `BD.auto(title)` y límites de anchura; no se traducen.
5. Iconos tienen `aria`/texto alternativo, tooltip o `help_text` en inglés cuando el widget lo permita.
6. No mostrar razones internas como `bad_title`, `commit_failed` o mensajes SQLite.
7. Nombres de módulos, clases, funciones, campos, settings, comentarios y tests nuevos en inglés.
8. No se agregan traducciones españolas a este PR. KOReader podrá traducir los msgids ingleses después.
9. Añadir una prueba de inventario de copy que cargue los módulos visuales y confirme que todas las cadenas especificadas son inglesas/localizables. No usar un detector genérico de idioma como sustituto de esta lista.

### 5.2 Copy canónico del MVP

El agente implementador debe usar estas cadenas base o una variante gramaticalmente equivalente acordada en revisión. No debe traducirlas al español.

| Contexto | Copy inglés |
|---|---|
| Menú y título | `Notebooks` |
| Crear | `New notebook` |
| Campo | `Notebook name` |
| Selector | `Paper size` |
| Presets | `A5 portrait`, `Letter portrait`, `A5 landscape` |
| Botones | `Create`, `Cancel`, `Close`, `Try again`, `Rename`, `Delete` |
| Biblioteca vacía | `No notebooks yet` |
| Ayuda vacía | `Create your first notebook to write by hand without opening a book.` |
| Loading biblioteca | `Loading notebooks…` |
| Error biblioteca | `Couldn’t open the notebook library.` |
| Cuerpo error biblioteca | `Your notebooks are still stored on this device. Try again, or restart KOReader.` |
| Nombre vacío | `Notebook name can’t be empty.` |
| Nombre largo | `Notebook name is too long. Use a shorter name.` |
| Crear falló | `Couldn’t create this notebook. Try again.` |
| Renombrar | `Rename notebook` |
| Borrar cuaderno | `Delete notebook` |
| Confirmación cuaderno | `Delete “%1”? This deletes its %2 and all ink. This can’t be undone.` |
| Borrar página | `Delete page` |
| Confirmación página | `Delete this page and its ink? The rest of the notebook won’t change. This can’t be undone.` |
| Última página | `A notebook must keep at least one page, so this page can’t be deleted.` |
| Estado durable | `Saved`, `Not saved` |
| Carga página | `Loading page…` |
| Error carga | `Couldn’t load this page.` |
| Cuerpo carga | `Your previous ink is still saved. Try loading the page again.` |
| Acción carga | `Retry loading` |
| Error guardado | `This page’s ink hasn’t been saved.` |
| Cuerpo guardado | `It is still on this device. You can’t leave this notebook or change pages until it is saved.` |
| Acción guardado | `Retry saving` |
| Error input | `Pen input stopped responding.` |
| Acción input | `Retry pen input` |
| Sólo lectura | `Read-only` |
| Cuerpo sólo lectura | `This notebook was created by a newer version of FingerInk. You can view it and change pages, but you can’t edit it.` |
| Contacto activo | `Lift the pen and try again.` |
| Límites | `First page`, `Last page` |
| Herramientas | `Pen`, `Eraser`, `Undo`, `Previous page`, `Next page`, `Add page`, `More`, `Exit notebook` |
| Banda | `Minimize`, `Error` |

Para el número de páginas usar `N_("1 page", "%1 pages", count)`. Para confirmaciones, insertar ese resultado ya pluralizado dentro del template principal.

## 6. Baseline oficial de KOReader

### 6.1 Revisiones resueltas el 2026-08-27 03:08:03 UTC

| Canal | Revisión |
|---|---|
| Estable | `v2026.07.1` — `9192014d8bd82a91dc1012473be0f238dedfdb54` |
| `koreader-base` estable | `6e4bc81af4e04f78d81677a323a780a71b29702a` |
| Desarrollo (`master`) | `5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8` |
| `koreader-base` desarrollo | `9f9b664083d8cdab967638781096f5b089cb2e36` |
| Runtime local | `v2025.08-100-g1d66e440b` — `1d66e440b61f36e2271da1f281a24e918293c56a` |
| `koreader-base` local | `22fe4d687197a91bd06f5266555cdfadc97b904f` |

El checkout local está limpio en archivos tracked y su submódulo coincide con el gitlink. Sirve para LuaJIT, SQLite y smoke visual, pero no prueba la API moderna de stylus ni el comportamiento e-ink del Scribe.

### 6.2 Matriz de compatibilidad

| Contrato | Estable | Desarrollo | Local | Consecuencia |
|---|---|---|---|---|
| Plugin `is_doc_only = false` en FileManager | Sí | Sí | Sí | activar el plugin en ambos hosts es compatible |
| `UIManager:show/close/setDirty` y stack de modales | Sí | Sí | Sí | dos ventanas superiores y modales son viables |
| `show_parent` para dirty de subwidgets | Sí | Sí | Sí | propagar el editor/biblioteca como parent |
| `FocusManager` con layout 2D | Sí | Sí | Sí | filas con body/Actions accesibles por five-way |
| `MenuItem` con tap/hold de fila | Sí | Sí | Sí | no usarlo para acción trailing independiente |
| `MultiInputDialog:addWidget` | Sí | Sí | Sí | diálogo de nombre + `RadioButtonTable` viable |
| `RadioButtonTable` exclusivo | Sí | Sí | Sí | usar para los tres presets |
| `Screen:scaleByDPI` | Sí | Sí | Sí | usar para objetivos físicos |
| `registerStylusCallback` | Sí | Sí | No en el runtime local | conservar fallback; gate moderno en estable/Scribe |
| callback único y consumo de slot antes de gestos | Sí | Sí | No verificable localmente | no instalar otro callback; usar InputController existente |
| SaveSettings antes de Suspend | Sí | Sí | Sí | no duplicar flush en `onSuspend` |

## 7. Arquitectura objetivo

```text
FileManager / ReaderUI
        │
        ▼
FingerInk (host adapter, settings, lifecycle)
        │
        ├── NotebookUI (coordinator, no SQL)
        │      ├── NotebookLibraryWindow (top-level, no input lease)
        │      └── NotebookEditorWindow  (top-level, owns UI regions)
        │             ├── ToolRail
        │             ├── InfoStrip
        │             ├── PaperViewport
        │             └── ErrorBand
        │
        ▼
NotebookController
        ├── NotebookSession ── SurfaceSession ── raster/queue/cache
        ├── NotebookInput ─── InputController ─── KOReader input
        └── NotebookRepository ────────────────── SQLite
```

Invariantes:

- Los widgets no importan Repository, Queue, Cache ni SQLite.
- LibraryWindow nunca posee input lease ni viewport.
- Sólo EditorWindow configura interacción y abre una NotebookSession.
- Sólo una NotebookSession y un raster existen a la vez.
- El registro de passthrough pertenece al editor; NotebookInput sólo consulta callbacks.
- El error band se pinta sobre el papel, pero no modifica `fit_rect` ni `clip_rect`.
- LibraryWindow y EditorWindow consumen cualquier gesto no manejado dentro de su pantalla completa; ReaderUI/FileManager nunca reciben un tap a través de ellas.
- Ningún botón ejecuta una acción de dominio si el snapshot lo deshabilita.
- Aun si el snapshot permite Exit, el editor no se cierra hasta que `closeNotebook()` devuelve éxito.
- Un `on_library_changed` bajo el editor sólo marca stale.
- Ninguna operación visual muestra error interno o SQL.

## 8. Archivos concretos

### 8.1 Nuevos

| Archivo | Contenido |
|---|---|
| `fingerink.koplugin/ink_notebook_ui.lua` | coordinador de ventanas, callbacks de controller, apertura/cierre y host teardown |
| `fingerink.koplugin/ink_notebook_library.lua` | LibraryWindow, NotebookRow, paginación, estados vacío/error/read-only y diálogos de biblioteca |
| `fingerink.koplugin/ink_notebook_editor.lua` | EditorWindow, ToolRail, InfoStrip, PaperViewport, ErrorBand y comandos |
| `fingerink.koplugin/ink_notebook_layout.lua` | cálculo puro de geometría física, presets y viewport |
| `fingerink.koplugin/ink_notebook_errors.lua` | normalización de razones internas a códigos estables; sin mensajes SQLite |
| `fingerink.koplugin/tests/notebook_ui_spec.lua` | coordinador, stack, copy y lifecycle |
| `fingerink.koplugin/tests/notebook_library_spec.lua` | lotes, filas, acciones, diálogos y read-only |
| `fingerink.koplugin/tests/notebook_editor_spec.lua` | layout, estados, herramientas, dirty y cierre durable |

No crear un archivo por cada subwidget. Los componentes pequeños y exclusivos de una ventana se quedan en el mismo módulo.

### 8.2 Existentes a modificar

| Archivo | Cambio acotado |
|---|---|
| `fingerink.koplugin/main.lua` | `is_doc_only=false`, registro de menú docless, creación lazy de NotebookUI, callbacks y setting del lado del riel |
| `fingerink.koplugin/ink_notebook_controller.lua` | lote UI `limit+1`, library status, `undo`, snapshot passthrough y callbacks durables |
| `fingerink.koplugin/ink_notebook_session.lua` | snapshot sin SQL, flags de vecinos, `undo`, dirty callback y capacidad de cierre |
| `fingerink.koplugin/ink_notebook_input.lua` | método público para presentar dirty box de undo y reloj/guard de toque inyectable si se habilita |
| `fingerink.koplugin/ink_surface_session.lua` | `canUndo()` O(1), sin exponer cache a UI |
| `fingerink.koplugin/tests/support.lua` | shims de widgets, FocusManager, RadioButtonTable, BD, datetime y Screen DPI |
| `fingerink.koplugin/tests/run.lua` | registrar nuevos specs |
| specs de notebook existentes | contratos nuevos sin reescribir pruebas de dominio |
| `README.md` | uso de Notebooks, alcance, copy inglés y gates físicos pendientes |
| `decisions.md` | ADR de biblioteca custom, handoff tardío, geometría DPI y salida durable |

## 9. Contratos nuevos o ampliados

### 9.1 `Controller:listNotebookBatch(cursor, limit)`

No cambiar `Repository:listNotebooks`. La fachada del controller consulta `limit + 1`, devuelve como máximo `limit` elementos y calcula si existe otro lote.

Contrato:

```lua
{
    items = { ... },          -- 0..50 metadata rows
    input_cursor = cursor,    -- copia del cursor usado o nil
    next_cursor = { updated_at = n, id = n } or nil,
    has_more = boolean,
    writable = boolean,
    read_only_code = "schema_newer" or nil,
}
```

Reglas:

- `limit` de UI: 50; consulta real: 51.
- Si hay 51 filas, quitar la última y poner `has_more=true`; `next_cursor` usa la fila visible 50.
- Si hay 50 o menos, `has_more=false` y `next_cursor=nil`.
- Todos los enteros ya vienen normalizados en el boundary de Repository.
- El resultado no incluye páginas ni trazos.
- Si falla el query, devolver `nil, reason`; no fabricar lista vacía.
- Exponer read-only sólo después de abrir el repositorio.

### 9.2 `Session:uiSnapshot()`

Contrato mínimo:

```lua
{
    state = "loading" | "ready" | "load_failed" |
            "save_failed" | "input_failed" | "closed",
    writable = boolean,
    can_ink = boolean,
    can_navigate = boolean,
    can_close = boolean,
    has_previous = boolean,
    has_next = boolean,
    page_count = integer,
    can_undo = boolean,
    pending_writes = integer,
    error_code = string or nil,
}
```

Reglas:

- Cada llamada devuelve una tabla nueva.
- No ejecuta consultas.
- `writable` requiere repositorio escribible, surface escribible y sesión no cerrada.
- `can_ink` requiere `state == "ready"`, writable, captura sana y ausencia de transición pendiente.
- `can_navigate` requiere ready o input_failed, sin save failure, sin contacto y sin metadata pendiente.
- `can_close=false` con contacto activo, `save_failed`, o carga destino con metadata pendiente. En los demás estados expresa una expectativa, no una garantía.
- `can_undo` usa `SurfaceSession:canUndo()` y queda false fuera de ready.
- `pending_writes` usa la cola existente y nunca fuerza flush.
- `error_code` se normaliza; la razón raw queda sólo para logger.
- No incluir `ordinal`.

### 9.3 Flags de navegación

Añadir a Session:

- `has_previous = false`
- `has_next = false`
- `_refreshNeighbours(page)`

`_refreshNeighbours` ejecuta como máximo dos queries `previousPage`/`nextPage` una vez cuando la página llega a ready. No se llama desde paint ni snapshot. Durante loading ambos flags son false. Después de append/delete/page switch se recalculan al completar el destino.

Si una query de vecino falla:

- no convertir la sesión en save_failed;
- marcar ambos botones conservadoramente deshabilitados;
- loggear la razón;
- emitir `error_code = "navigation_status_failed"` sólo si se decide presentar un retry global. En v1 es preferible un aviso no bloqueante y volver a calcular en la próxima transición.

### 9.4 Undo sin atravesar capas

Flujo:

1. ToolRail llama `controller:undo()`.
2. Controller delega en `session:undo()`.
3. Session llama `surface:undo()`.
4. Session pasa la cache box a un callback `on_dirty_box(box, "undo", session)` inyectado desde main.
5. NotebookInput reutiliza la conversión de `_dirty` para producir `screen_box` y `source_box`.
6. Editor blitea sólo esa región y usa refresh rápido/limpio según la política.

No devolver Transform ni Cache a la UI. No duplicar la aritmética de clip en EditorWindow.

### 9.5 Errores estables

`ink_notebook_errors.lua` normaliza por contexto:

| Código UI | Razones internas posibles | Superficie |
|---|---|---|
| `library_open_failed` | `no_driver`, `open_failed`, `schema_failed`, error de list | biblioteca |
| `schema_newer` | repositorio read-only | biblioteca/editor |
| `invalid_name` | `bad_title` | diálogo |
| `invalid_geometry` | `bad_geometry` | create/open; log + mensaje genérico |
| `create_failed` | transacción/commit create | diálogo |
| `rename_failed` | transacción/commit rename | diálogo |
| `delete_failed` | transacción/commit delete | diálogo/biblioteca |
| `page_load_failed` | cache/cursor/codec load | editor |
| `page_save_failed` | queue/commit/metadata save | editor |
| `pen_input_failed` | callback/lease errors | editor |
| `contact_active` | `contact_active` | mensaje transitorio |
| `no_viewport` | `no_viewport`, transform inválido | apertura/rotación |
| `closed` | lifecycle | log; no mensaje si teardown |

La presentación selecciona copy y acciones por `error_code`; logger recibe además la razón raw. No usar `tostring(err)` en TextWidget, Notification, InfoMessage o diálogo.

## 10. Diseño de biblioteca

### 10.1 Widget raíz

`NotebookLibraryWindow` extiende `FocusManager` o un InputContainer con FocusManager como raíz. Debe establecer:

- `covers_fullscreen = true`
- `modal = false`
- `show_parent = self`
- dimensiones de `Screen:getWidth()/getHeight()`
- handlers Back/Close que cierran sólo la biblioteca y vuelven al host
- layout reconstruible en `onSetDimensions`/rotación

Anatomía:

1. `TitleBar`: “Notebooks” y Close.
2. Área fija de lista.
3. Footer de navegación de pantalla/lote.
4. Acción primaria “New notebook” en posición estable.

No usar scroll. Calcular `rows_per_screen = max(1, floor(list_height / row_height))`; no fijar 9 como constante. El row height debe respetar 10 mm y dejar dos líneas de texto.

### 10.2 `NotebookRow`

Cada fila tiene dos hit targets independientes:

- cuerpo de fila: abre el cuaderno;
- botón trailing con texto accesible `Actions`: abre Rename/Delete.

El aspecto puede mostrar `⋯`, pero el label accesible y `help_text` debe ser `Actions`. Título en primera línea, metadata en segunda. Usar `BD.auto(title)`, truncado visual y el título completo en help/hold si KOReader lo permite sin ocultar la acción principal.

Focus layout por fila:

```text
[ open notebook body ][ Actions ]
```

En five-way, Left/Right cambia entre body/Actions; Up/Down mantiene columna cuando sea posible. Focus se representa con inversión; al restaurar texto usar `ui`.

No copiar código de `ui/widget/menu.lua`. Reusar `FrameContainer`, `HorizontalGroup`, `VerticalGroup`, `TextWidget`, `Button`, `InputContainer`, `FocusManager`, `Size` y `BD`.

### 10.3 Paginación

Estado de LibraryWindow:

```lua
batch = nil
cursor_stack = { nil }
cursor_index = 1
screen_in_batch = 1
loading = false
load_error_code = nil
stale = false
```

Reglas:

1. Mostrar la ventana y su estado `Loading notebooks…` antes de consultar.
2. Ejecutar `listNotebookBatch(nil, 50)` en `UIManager:nextTick` para permitir primer paint.
3. Dentro del lote, cambiar `screen_in_batch` sin SQL y repintar sólo lista+footer.
4. Al superar la última pantalla local y `has_more=true`, consultar `next_cursor`; no avanzar el cursor hasta recibir éxito.
5. Guardar cursores de entrada, no offsets ni índices absolutos.
6. Previous desde la primera pantalla del lote consulta el cursor anterior y reemplaza el lote.
7. Un fallo de lote conserva filas y cursor actuales; footer muestra Try again.
8. Rename/Delete mientras la biblioteca es visible recarga el primer lote. No intentar reconciliar en memoria dos órdenes por `updated_at`.
9. Cuando editor está encima, `markStale()` no consulta ni repinta. Al cerrar editor, recargar primer lote una sola vez.
10. Liberar referencias al lote anterior al reemplazarlo; la memoria debe permanecer O(50).

Footer sugerido en inglés:

- `Screen %1 of %2 · 50-item batch` sólo para pantallas dentro del lote.
- No mostrar total global de cuadernos.
- Para el último lote, “50-item batch” describe el límite, no el total. Puede omitirse si induce a error; la información funcional son Previous/Next.

### 10.4 Estado read-only

Durante la primera carga, New notebook está deshabilitado. Al recibir el batch:

- writable: habilitar Create/Rename/Delete;
- read-only: mostrar banner `Read-only` y explicación de schema más nuevo; las filas siguen abriendo; Create/Rename/Delete quedan deshabilitados.

No descubrir read-only dejando fallar primero el diálogo.

### 10.5 Diálogo de creación

Usar `MultiInputDialog` con:

- title `New notebook`;
- un campo `Notebook name`;
- `RadioButtonTable` añadido mediante `addWidget`;
- A5 portrait preseleccionado;
- botones Cancel/Create.

Presets lógicos:

```text
LOGICAL_UNITS_PER_MM = 8
A5 portrait:      round(148.0 * 8) × round(210.0 * 8) = 1184 × 1680
Letter portrait:  round(215.9 * 8) × round(279.4 * 8) = 1727 × 2235
A5 landscape:     1680 × 1184
template_kind:    blank
```

Validación cliente idéntica al repositorio: trim, no vacío, máximo 255 bytes UTF-8. Si falla create:

- mantener el diálogo abierto;
- conservar nombre y selección;
- mostrar copy de dominio, no raw SQL;
- no intentar `openNotebook`.

Create es transaccional para notebook+primera página, pero Create+Open son dos operaciones. Si create termina y open falla, el cuaderno queda correctamente creado y debe aparecer al volver a la biblioteca; no borrarlo para fingir atomicidad.

### 10.6 Rename/Delete

- Rename usa `InputDialog` con el nombre actual y la misma validación.
- Delete usa `ConfirmBox` con título, número pluralizado de páginas y acción irreversible.
- El botón Actions nunca ejecuta delete directamente.
- Si el editor invoca Delete notebook desde More, primero `closeNotebook`; sólo si termina se escribe el tombstone.
- Si close falla, mantener editor y error band. No cerrar la ventana ni actualizar la lista como si hubiera terminado.

## 11. Diseño del editor

### 11.1 Widget raíz y stack

`NotebookEditorWindow` es top-level, `covers_fullscreen=true`, no modal. Se muestra encima de LibraryWindow. No reemplaza el contenido interno de la biblioteca.

Flujo de apertura:

1. Library recibe row tap.
2. Construye EditorWindow con geometry y registro de regiones, pero no lo muestra todavía.
3. Configura `configureNotebookInteraction` con providers/callbacks que cierran sobre ese editor.
4. Llama `controller:openNotebook(id)`.
5. Sólo después de que el preflight y handoff hayan creado una sesión, muestra EditorWindow en loading.
6. Si falla antes de una sesión activa, permanece en biblioteca y muestra error allí.
7. Si `openNotebook` devuelve una sesión en `loading` o `load_failed`, muestra editor para hacer Retry.

Los callbacks se configuran antes de abrir, pero mientras el editor aún no está en el stack sólo actualizan su estado interno: no llaman `setDirty`. Esto cubre tanto una carga síncrona que llega a ready antes de `show` como una carga asíncrona posterior. El coordinador asigna un `editor_generation` y todos los callbacks/timers verifican que siguen apuntando al editor activo antes de tocar UI.

La biblioteca permanece debajo. Back/Exit del editor:

1. verificar snapshot y contacto;
2. llamar `controller:closeNotebook()`;
3. si falla, actualizar ErrorBand y permanecer;
4. si termina, `UIManager:close(editor, "full")`;
5. notificar al coordinador para recargar primer lote si stale.

No confiar en el evento `FlushSettings` de `UIManager:close` como veto: UIManager cierra el widget aunque el handler devuelva error. La durabilidad debe decidirse **antes** de llamar `UIManager:close`.

### 11.2 Geometría

Crear helpers puros en `ink_notebook_layout.lua`:

```text
physicalPixels(mm) = Screen:scaleByDPI(mm * 160 / 25.4)
target = max(physicalPixels(10), Size.item.height_large)
rail_width = max(physicalPixels(14), target + 2 * standard_padding)
info_height = max(physicalPixels(7), text_height + 2 * standard_padding)
gap = max(physicalPixels(2), Size.span.vertical_default)
```

Los valores 14 mm y 7 mm reproducen aproximadamente 168/84 px a 300 ppi, pero los mínimos se basan en contenido real. No repetir números en EditorWindow.

Resultado de `compute(screen_w, screen_h, rail_side)`:

```lua
{
    rail_rect = Geom,
    info_rect = Geom,
    paper_rect = Geom,
    fit_rect = Geom,
    clip_rect = Geom,
    target_size = integer,
    control_rects = { ... },
}
```

Reglas:

- rail left/right por setting `fingerink_notebook_rail_side`.
- `paper_rect` excluye rail e info strip.
- `fit_rect` y `clip_rect` se mantienen iguales durante un error.
- el transform centra la página según aspect ratio dentro de paper_rect.
- letterboxing pertenece al chrome/no-paper y no acepta tinta.
- orientación de pantalla cambia cajas, no `logical_w/h` de la página.
- si no cabe un target mínimo y un paper útil, devolver `nil, "no_viewport"`; no producir dimensiones negativas.

RTL y handedness son conceptos separados. `BD.mirroredUILayout()` ordena contenido textual/flechas; el setting de rail decide la mano. No invertir el setting automáticamente por RTL.

### 11.3 ToolRail

Orden visual:

```text
Exit notebook
Pen
Eraser
Undo

[non-interactive grip gap]

Previous page
Next page
Add page
More
```

Reglas:

- Pen/Eraser son excluyentes y reutilizan `self.eraser` del plugin.
- Pen width e Input mode continúan siendo settings compartidos con PDF/EPUB.
- El rail side es específico de notebooks.
- El gap central no tiene gesture range.
- Ningún icono es la única forma de comunicar selección: usar inversión/borde y label/help.
- Targets de al menos 10 mm.
- Disabled implica apariencia atenuada **y** ausencia de callback efectivo.
- Delete page y Delete notebook sólo aparecen en More y requieren ConfirmBox.
- More incluye Rename notebook, Delete page, Delete notebook, Input mode, Pen width y Rail side sólo si el diseño cabe sin duplicar settings inconsistentes. Los submenús reutilizan los métodos de settings existentes de FingerInk.

### 11.4 InfoStrip

Contenido estable, sin targets:

- título del cuaderno, truncado y `BD.auto`;
- total de páginas pluralizado;
- `First page` o `Last page` cuando aplica;
- `Saved`/`Not saved` si la señal es confiable;
- `Read-only` cuando corresponde.

No mostrar ordinal en v1. No reconstruir strip por cada segmento ni por cada batch durable.

Indicador durable:

- el editor marca “Not saved” una vez cuando una mutación entra a la cola;
- al callback durable, lee snapshot y cambia a “Saved” sólo si `pending_writes == 0`;
- repinta sólo el rect del label con `ui`;
- limitar cambios visuales a uno cada 2 s; colapsar estados intermedios;
- si el agente no puede demostrar la transición de pending de forma fiable, omitir ambos labels y documentar la desviación. Nunca adivinar `Saved`.

### 11.5 PaperViewport y dirty regions

El primer paint de una página ready:

1. llenar fondo de paper;
2. blitear el raster activo dentro del clip;
3. pintar borde/letterbox;
4. pintar ErrorBand por encima si existe.

Para tinta live, erase, repair y undo:

- usar `on_dirty(screen_box, kind, session, transform, source_box)`;
- verificar que session/transform siguen siendo los activos;
- blitear sólo `source_box` del raster a `screen_box`;
- intersectar con paper clip;
- nunca llamar paint del editor completo;
- usar la misma política de fast refresh ya probada por direct ink;
- no repintar rail, strip ni biblioteca.

### 11.6 ErrorBand

ErrorBand forma parte del árbol del editor y se pinta sobre el borde inferior de paper_rect. No es otra ventana top-level.

Estados:

- expanded: título, cuerpo, Retry y Minimize;
- minimized: tab `Error` más Retry accesible;
- absent: no error.

Reglas:

- save_failed no se puede descartar.
- load_failed puede minimizarse, no desaparecer hasta recovery.
- input_failed puede usar el tab compacto; navegación/exit siguen disponibles si snapshot lo permite.
- read-only va en InfoStrip, no en ErrorBand.
- la región expanded/minimized se publica al registro de passthrough **antes** de dirty/show.
- ocultar/minimizar no cambia paper fit.
- no permitir tinta debajo: state failures ya liberan captura; si aparece durante contacto, NotebookInput repara y suspende la secuencia.

## 12. Enrutado de input y modales

### 12.1 Registro de regiones

Editor mantiene:

```lua
interactive_regions = {
    rail = Geom,
    error_band = Geom or nil,
    modal = Geom or nil,
}
```

Callbacks configurados una vez antes de `openNotebook`:

- `stylus_passthrough(x, y)` devuelve true si el punto está en cualquier región interactiva.
- `touch_passthrough(x, y)` devuelve true sólo para región interactiva y cuando no está activo el guard de palma. Al proporcionar callback sustituye el fallback interno, por lo que debe clasificar explícitamente rail, ErrorBand y modal.

Como los callbacks cierran sobre la tabla y NotebookInput los invoca por contacto, sustituir una Geom actualiza la clasificación sin reconfigurar la sesión.

### 12.2 Orden seguro al mostrar un modal

Crear helper del editor `showModalSafely(widget, rect_provider)`:

1. comprobar `hasActiveContact`; si existe, no mostrar y emitir `Lift the pen and try again.`;
2. construir el widget sin mostrarlo;
3. calcular su región final cuando el widget ya la conoce; si no es estable antes del primer paint, usar temporalmente la pantalla completa;
4. publicar `interactive_regions.modal` antes de mostrarlo;
5. establecer `show_parent` correcto;
6. llamar `UIManager:show`;
7. al cerrar, cerrar widget primero y quitar la región en el siguiente tick seguro.

La región full-screen temporal es preferible a dejar un hueco de papel activo bajo un diálogo. Mientras exista, la ventana modal recibe la secuencia y las ventanas full-screen de FingerInk consumen los gestos no manejados; no se filtran al host inferior.

Para un error asíncrono, el orden es abort/release capture, reparar provisional, publicar ErrorBand, dirty. No esperar un modal.

### 12.3 Latches

- Un stylus que comienza sobre paper pertenece al papel hasta lift, salvo que aparezca una nueva región: en ese caso se repara provisional y se suspende, nunca se entrega media secuencia a GestureDetector.
- Un stylus que comienza sobre chrome pasa entero a KOReader UI.
- Un dedo que comienza sobre paper en modo stylus se suprime entero.
- Un dedo que comienza sobre rail puede accionar UI sólo si no hay stylus activo/guard.
- Un tap/swipe que no corresponde a un control es consumido por la ventana full-screen; nunca cambia la página del libro que está debajo.
- La goma física sigue `TOOL_TYPE_ERASER`; el toggle lógico Eraser usa la preferencia compartida.
- Nunca registrar un segundo stylus callback ni desregistrar dentro de su ejecución. InputController mantiene el desarme diferido existente.

### 12.4 Guard de palma en controles

Preparar `NotebookInput` para exponer `isStylusContactActive()` y un timestamp de último lift basado en `ui/time.now()` inyectable en tests. Política inicial:

- mientras stylus está activo, fingers no pasan al rail;
- después del lift, guard configurable de 300 ms;
- el valor debe ser una constante de notebook, no un setting visible en MVP;
- el gate físico puede reducirlo o eliminarlo si bloquea taps intencionales.

No aplicar este guard a la biblioteca, que no posee capture.

## 13. Matriz de estados y capacidades

| Estado/capacidad | Ink | Undo | Prev/Next | Add/Delete | Exit | Acción primaria |
|---|---:|---:|---:|---:|---:|---|
| library loading | — | — | batch disabled | Create disabled | Sí | esperar |
| library ready writable | — | — | según lote | Create/Rename/Delete | Sí | abrir/crear |
| library read-only | — | — | según lote | No | Sí | abrir |
| initial page loading, closeable | No | No | No | No | Sí | esperar |
| destination loading, pending metadata | No | No | No | No | No | esperar/retry si falla |
| ready writable | Sí | según `can_undo` | flags vecinos | Sí | Sí | escribir |
| ready read-only | No | No | flags vecinos | No | Sí | consultar |
| load_failed closeable | No | No | No | No | según `can_close` | Retry loading |
| load_failed con metadata pendiente | No | No | No | No | No | Retry loading |
| save_failed | No | No | No | No | No | Retry saving |
| input_failed | No | No | Sí si durable | Add/Delete según durable | Sí si durable | Retry pen input |
| rebuilding por rotación | No | No | No | No | según close capability | esperar |
| contacto activo | contacto actual | No | No | No | No | lift |

Regla transversal: si una operación síncrona cambia el estado después de que se pintó el botón, el resultado del dominio gana. La UI no asume éxito por el enabled state.

## 14. Lifecycle de hosts

### 14.1 Activación en FileManager

Modificar `FingerInk`:

1. `is_doc_only = false`.
2. En `init`, detectar docless como hoy.
3. Inicializar settings comunes y registrar `self.ui.menu:registerToMainMenu(self)` **antes** del return docless.
4. En docless no crear Store, CanvasSession, view module, toolbar ni Dispatcher reader-only.
5. `addToMainMenu` en FileManager añade un item directo `Notebooks` con `sorting_hint = "more_tools"`.
6. Callback crea NotebookUI lazy y abre LibraryWindow.

### 14.2 Activación en ReaderUI

- Conservar el submenu `Finger Ink` y añadir `Notebooks` como primer item.
- Abrir LibraryWindow no llama `prepareNotebookHandoff`.
- Al abrir una row, `openNotebook` realiza preflight y luego `before_open`:
  - si hay hoja EPUB, flush y close;
  - si falla, conservar hoja, Draw e input owner;
  - si Draw directo está activo, apagarlo y soltar lease;
  - adquirir notebook lease sólo cuando la página se abre.
- Al salir del editor, volver a LibraryWindow. Cerrar LibraryWindow vuelve al libro con Draw apagado si el notebook llegó a tomar la lease; no reactivar automáticamente el modo previo.

### 14.3 Save/Suspend/Resume

- `onSaveSettings`: controller flush; si falla, logger y estado save_failed permanecen.
- `onSuspend`: abortar contacto y liberar capture; no repetir flush.
- `onResume`: reconstruir/repaint full; reacquire sólo si snapshot sano.
- Si reacquire falla, mostrar input_failed y no hacer retry loop silencioso.
- LibraryWindow sin sesión no hace flush ni captura.

### 14.4 Rotación

Orden:

1. impedir nuevas acciones del rail;
2. abortar contacto si existe;
3. flush durable;
4. release capture;
5. calcular nuevo layout;
6. publicar nuevas regiones;
7. llamar `controller:onScreenResize(fit_rect, clip_rect)`;
8. mantener editor cubriendo el host durante rebuild;
9. en ready, blit completo y un único full;
10. recapturar sólo después de ready.

Si flush o geometría fallan, conservar la geometría/raster anterior y presentar error. No cerrar el editor ni dejar el host de debajo interactivo.

### 14.5 Cierre forzado del host

El coordinador distingue:

- cierre voluntario: puede ser bloqueado para retry;
- teardown de ReaderUI/FileManager: llama `controller:shutdown()` para liberar hook aun si pierde una cola no durable, loggea el error y cierra referencias visuales sin abrir diálogos nuevos.

`NotebookUI:shutdown()` debe ser idempotente. Después de ejecutarse:

- no queda editor/library en referencias del plugin;
- no queda callback programado que capture ventanas destruidas;
- InputController no tiene owner de notebooks;
- repositorio propio está cerrado.

## 15. Política de refresco e-ink

| Evento | Región | Tipo inicial |
|---|---|---|
| Abrir biblioteca | pantalla | `ui` |
| Focus de fila | fila | `fast`; restauración `ui` |
| Cambiar pantalla/lote | lista + footer | `ui` |
| Abrir/cerrar diálogo | rect del diálogo y descubierto | `ui` |
| Entrar al editor | pantalla | `full` |
| Segmento live/erase/repair | dirty box del papel | ruta fast ya probada |
| Tool toggle/estado | botón o label | `ui` |
| ErrorBand | su rect | `ui` |
| Cambio de página | paper/full editor al ready | un `full` |
| Salir del editor | pantalla descubierta | `full` después del flush |
| Rotación/resume | pantalla al ready | un `full` |
| Commit durable sin cambio visible | ninguna | ninguna |

No usar `partial` por costumbre dentro de FileManager/editor mixto; KOReader recomienda `ui` para UI y reserva `partial` principalmente para texto de ReaderUI. No usar `flashui` de forma sistemática; se medirá en hardware si los overlays dejan ghosting. No llamar `UIManager:setDirty` con un subwidget: siempre con su window-level `show_parent`.

## 16. Rendimiento y escala

### 16.1 Biblioteca con 5.000 cuadernos

- 51 filas máximo por consulta, 50 retenidas.
- Keyset por índice existente; nunca OFFSET.
- Un lote reemplaza al anterior.
- Filas construidas sólo para la pantalla visible; liberar widgets de la pantalla anterior.
- Sin thumbnails, raster, page rows ni stroke counts.
- No contar total global.
- No recargar mientras editor cubre la biblioteca.
- Una consulta/repaint por cambio de lote, no por fila.

### 16.2 Cuaderno con 1.000 páginas

- No `listPages` para editor.
- Navegación usa queries de vecino indexadas y O(1) filas.
- `page_count` viene de notebook metadata.
- Dos probes de vecino sólo al completar transición, no al pintar.
- Un único raster de página; la anterior se libera después del gate durable.
- Sin precarga de vecinas.
- Append hereda geometría actual y no renumera.

### 16.3 Página con mucha tinta

- Carga por chunks/ticks existente; UI no introduce bucle síncrono.
- PaperViewport no duplica stroke tables ni genera una imagen secundaria.
- Dirty boxes se recortan antes de blit/refresh.
- Guardado mantiene debounce/cola existente; no hacer flush por stroke, indicador o repaint.
- Undo borra sólo el último stroke y repara su box.
- ErrorBand no reconstruye raster.

### 16.4 Flash y main thread

- La consulta SQLite sigue siendo síncrona, pero está acotada por 51 metadata rows y un índice. Mostrar la ventana antes con nextTick mejora percepción, no convierte SQL en async.
- No introducir coroutines o threads nuevos para UI/SQLite.
- No programar decenas de timers por filas; un timer de estado durable por editor como máximo.
- Al reconstruir layout, crear el árbol fuera de paint y hacer un solo dirty.

## 17. Plan de implementación paso a paso

Cada fase debe terminar verde antes de comenzar la siguiente. No combinar UI completa y cambios de dominio en un único salto.

### Fase 0 — Baseline y guardas

**Archivos:** tests existentes, sin producción.

1. Ejecutar suite Lua, LuaJIT, preflight, sintaxis y conformance actual.
2. Registrar número de assertions y revisión local KOReader.
3. Confirmar que FileManager-shaped plugin permanece docless y no abre SQLite.
4. Confirmar que PDF/EPUB tests siguen verdes.
5. Guardar `git status --short`; no limpiar cambios existentes.

**Aceptación:** baseline reproducible y ninguna falla previa atribuida a la UI.

**Stop:** si el backend standalone no pasa sus propias pruebas, corregir o separar ese problema antes de activar UI.

### Fase 1 — Layout y copy puros

**Archivos:** nuevo `ink_notebook_layout.lua`, nuevo `ink_notebook_errors.lua`, specs de layout/error.

1. Implementar presets y conversión logical units/mm.
2. Implementar `physicalPixels` con `scaleByDPI` inyectable.
3. Implementar cálculo de rail/info/paper/fit/clip para cuatro rotaciones y ambos lados.
4. Validar dimensiones finitas, enteras y positivas.
5. Implementar normalizador de errores sin gettext ni raw exposure.
6. Crear inventario de copy inglés en tests.

**Aceptación:** geometría Scribe aproxima 168/84 sin hardcode; dispositivos pequeños conservan targets; no hay strings españolas.

**Stop:** si DPI del perfil no es fiable, conservar mínimos KOReader y marcar medición física; no volver a `scaleBySize` como equivalencia de mm.

### Fase 2 — Fachadas de controller/session

**Archivos:** controller, session, surface, notebook input y sus specs.

1. Añadir `listNotebookBatch` con limit+1.
2. Añadir read-only info al batch.
3. Añadir flags de vecinos cacheados y refresh por page_ready.
4. Añadir `SurfaceSession:canUndo`.
5. Añadir `Session:uiSnapshot`, sin SQL.
6. Añadir `Session:undo` y `Controller:undo` con callback dirty inyectado.
7. Emitir cambio de snapshot al recover/durable necesario para Saved.
8. Añadir capacidades de cierre y tests para initial load vs destination load.

**Aceptación:** widgets pueden implementarse sin tocar surface/repository; snapshot es cohesivo, barato y no contiene ordinal.

**Stop:** cualquier método llamado desde paint que ejecute SQL debe rediseñarse.

### Fase 3 — Activación host y coordinador

**Archivos:** main, nuevo `ink_notebook_ui.lua`, notebook_host_spec, notebook_ui_spec.

1. Cambiar `is_doc_only=false`.
2. Registrar menú antes del return docless.
3. Mantener todo Reader-only después del guard docless.
4. Crear `NotebookUI` lazy al tocar Notebooks.
5. Implementar estado de una library y un editor máximo.
6. Implementar shutdown idempotente.
7. Añadir Notebooks al submenu Reader y directo en FileManager.

**Aceptación:** FileManager carga y muestra el item sin acceder a document/view/doc_settings; abrir biblioteca no altera Draw/hoja/input de ReaderUI.

**Stop:** cualquier acceso docless a `self.view`, `self.store` o `self.ui.document` fuera de un guard.

### Fase 4 — Biblioteca custom

**Archivos:** nuevo library, support shims, library spec.

1. Construir root fullscreen y TitleBar.
2. Construir NotebookRow con body y Actions separados.
3. Implementar FocusManager y touch.
4. Implementar primer paint loading y query nextTick.
5. Implementar pantallas dentro de lote y cursor stack.
6. Mantener batch visible en error de siguiente lote.
7. Implementar empty/error/read-only.
8. Marcar stale sin repaint bajo editor.
9. Probar 5.000 rows en store sintético y O(50) references.

**Aceptación:** abrir fila y Actions son targets independientes; no hay scroll/thumbnail/OFFSET; Back vuelve al host.

**Stop:** si se empieza a copiar `MenuItem`, detener y volver a primitives públicas.

### Fase 5 — Crear, renombrar y borrar

**Archivos:** library/editor coordinador, specs.

1. MultiInputDialog + RadioButtonTable.
2. Validación y copy inglés.
3. Create transactional y open separado.
4. Rename con valor preservado en error.
5. Delete confirm con plural y tombstone.
6. Read-only deshabilita antes del callback.
7. Error raw sólo logger.

**Aceptación:** ningún fallo cierra diálogo o pierde texto; create exitoso/open fallido conserva notebook visible.

### Fase 6 — Editor estático y viewport

**Archivos:** nuevo editor, layout, specs.

1. Construir root, rail, strip y paper sin conectar tinta.
2. Propagar show_parent.
3. Configurar viewport y abrir session.
4. Pintar loading/ready/read-only.
5. Mostrar/cerrar encima de library.
6. Rotar ambas orientaciones con un solo árbol reconstruido.

**Aceptación:** fit/clip excluyen chrome; ninguna rotación cambia logical geometry; stack vuelve a library.

### Fase 7 — Tinta y herramientas

**Archivos:** editor, main, input, session/controller, specs.

1. Conectar on_dirty a blit regional.
2. Pen/Eraser y selección monocroma.
3. Undo vía façade.
4. Previous/Next con gates y flags.
5. Add page heredando geometry.
6. More + delete page/notebook.
7. Saved/Not saved throttled si señal fiable.

**Aceptación:** live ink no repinta chrome; undo no accede cache desde UI; límites no llaman navegación.

### Fase 8 — Regiones dinámicas, errores y recovery

**Archivos:** editor, input, errors, specs.

1. Registro mutable rail/error/modal.
2. `showModalSafely` con publicación antes de show.
3. ErrorBand expanded/minimized.
4. Retry load/save/input.
5. Matriz de capacidades y enabled state.
6. Cierre voluntario durable y bloqueado.
7. Guard de palma/reloj inyectable.
8. Mutaciones que inviertan el orden de regiones deben fallar tests.

**Aceptación:** no se dibuja debajo de overlays, no se entrega medio contacto, save_failed nunca cierra, load_failed respeta pending metadata.

### Fase 9 — Lifecycle y refresco

**Archivos:** main, coordinator/editor, specs/README/decisions.

1. SaveSettings/Suspend/Resume exactos.
2. Rotación ordenada y error rollback.
3. Teardown forzado sin diálogos.
4. Dirty policy por región.
5. Eliminar full/flash redundantes observados en logs.
6. Documentar gate físico.

**Aceptación:** input owner nil tras teardown; no callback a ventana cerrada; un full por transición mayor, nunca por segmento.

### Fase 10 — Validación y revisión independiente

1. Ejecutar todos los comandos de §19.
2. Mutation tests de los invariantes críticos.
3. Smoke en FileManager y ReaderUI con EPUB/PDF.
4. Comparar APIs contra SHAs estable/dev resueltos.
5. Revisar copy visible: sólo inglés.
6. Gate físico en Scribe antes de declarar soporte de hardware completo.

## 18. Pruebas requeridas

### 18.1 Unitarias

- Layout portrait/landscape, left/right, Scribe y perfil pequeño.
- Target >= 10 mm según DPI.
- Paper/rail/info sin overlap; error band no cambia fit.
- Presets exactos.
- Batch 0/1/50/51 y cursors.
- Cursor stack next/back y fallo que no avanza.
- Memory retention O(50), no acumulación.
- Body row abre; Actions no abre.
- Five-way focus y Back.
- Create valida bytes, conserva texto en error.
- Read-only bloquea mutations.
- Snapshot no llama repo después de page_ready.
- Flags vecinos se recalculan una vez por transición.
- `can_close` diferencia initial/destination load_failed.
- Exit no llama UIManager.close si domain close falla.
- Undo pinta sólo box.
- Error raw no aparece en widgets.
- on_library_changed bajo editor sólo marca stale.
- Dynamic error/modal region se publica antes de show.
- Stylus/palm/control latches y guard 300 ms con reloj falso.
- Rotate aborta, flush, resize y reacquire en orden.
- shutdown idempotente.

### 18.2 Integración

- FileManager init sin document; menú visible; SQLite lazy.
- ReaderUI abre biblioteca sin tocar lease.
- ReaderUI handoff sólo al seleccionar row.
- Hoja EPUB con flush fallido conserva estado.
- Direct PDF Draw conserva tests sin notebook abierto.
- Create -> editor -> ink -> close -> library -> reopen.
- Save failure conserva raster y bloquea exit/nav.
- Retry save recupera captura y estado.
- Destination load failure no avanza durable current page.
- Future schema abre library/editor read-only.
- Rotación con stroke abierto no acepta tinta perdida.
- Suspend/Resume sano e input_failed.

### 18.3 Mutation tests mínimos

Cada mutación debe ser detectada:

1. hacer handoff al abrir library;
2. usar `scaleBySize` para 10 mm;
3. mostrar modal antes de publicar región;
4. cerrar editor aunque closeNotebook falle;
5. habilitar Exit por `state == load_failed` ignorando pending metadata;
6. recargar library en cada durable batch;
7. acumular lotes en vez de reemplazarlos;
8. calcular ordinal en snapshot con query;
9. entregar a UI un raw SQLite error;
10. repintar editor completo por segmento;
11. desregistrar stylus callback dentro del callback;
12. usar copy español en un msgid visible.

### 18.4 Performance

Seed real SQLite:

- 5.000 notebooks;
- uno con 1.000 pages;
- una página densa con suficientes chunks para cargar durante múltiples ticks.

Assertions:

- `EXPLAIN QUERY PLAN` usa `notebooks_active_recent` y `pages_by_notebook`;
- no SQL OFFSET;
- listado pide 51;
- retained rows <= 50;
- snapshot/paint no ejecuta SQL;
- biblioteca cubierta no repinta ni consulta por commits;
- sólo un raster activo;
- ningún full por punto/stroke.

## 19. Verificación ejecutable

Desde la raíz del plugin:

```sh
luajit test.lua
lua test.lua
git diff --check
```

QA local:

```sh
/Users/christianstenger/.codex/skills/koreader-simulator-qa/scripts/koreader_qa.sh preflight
/Users/christianstenger/.codex/skills/koreader-simulator-qa/scripts/koreader_qa.sh test
```

Conformance real:

```sh
/Users/christianstenger/koreader/koreader/luajit \
  /Users/christianstenger/GitHub/fingerink.koplugin/fingerink.koplugin/tests/conformance.lua

/Users/christianstenger/koreader/koreader/luajit \
  /Users/christianstenger/GitHub/fingerink.koplugin/fingerink.koplugin/tests/conformance.lua \
  /Users/christianstenger/koreader/koreader/test/juliet.epub
```

Sintaxis:

```sh
find fingerink.koplugin -name '*.lua' -print0 | \
  xargs -0 -n1 /Users/christianstenger/koreader/koreader/luajit -b
```

Si el comando de sintaxis local requiere un output para `-b`, usar el wrapper de `koreader_qa.sh preflight` como autoridad y no escribir bytecode dentro del repositorio.

Smoke obligatorio:

1. FileManager sin documento: abrir Notebooks, crear, escribir, cerrar, reabrir.
2. ReaderUI con EPUB: abrir library sin handoff; abrir notebook; volver a libro.
3. ReaderUI con PDF: mismo flujo; confirmar que direct ink sólo cambia al abrir editor.
4. Portrait y landscape Scribe profile.
5. Teclado/renombrado con título largo y Unicode.
6. Future-schema read-only.
7. COMMIT bloqueado durante close/page change.

## 20. Gate físico Kindle Scribe

No puede sustituirse por emulador. La entrega no se declara final hasta medir:

- latencia live del editor frente a direct ink;
- palma sobre paper y palma cerca del rail;
- 300 ms post-lift: falsos taps bloqueados vs taps intencionales;
- goma posterior reportada como eraser;
- targets rail con mano izquierda/derecha;
- ghosting después de 8, 16, 32 y 64 trazos;
- full al cambiar página/rotar/volver a library;
- uso de ErrorBand y More con stylus;
- resume/suspend y rotación con pen apoyado;
- memoria y tiempo de apertura de página densa;
- legibilidad de textos `ui` y artefactos de `fast`.

Los resultados pueden ajustar constantes de refresh y guard, pero no deben cambiar los invariantes de durabilidad, stack, passthrough o un solo raster.

## 21. Riesgos y stop conditions

| Riesgo | Mitigación | Stop condition |
|---|---|---|
| FileManager carga rutas Reader-only | init dividido por host + test docless | cualquier acceso a document/view en FileManager |
| Lista custom pierde focus/RTL | FocusManager, BD, tests five-way | controles inaccesibles sin touch |
| Cierre pierde tinta | pre-close durable y no confiar en UIManager close | close visual con domain close fallido |
| Modal recibe media secuencia | región antes de show + latch | tinta bajo modal o gesture parcial |
| Biblioteca grande bloquea | keyset 51 rows, nextTick, O(50) | OFFSET, COUNT global o filas acumuladas |
| Cuaderno de 1.000 páginas degrada | neighbour queries + no ordinal/listPages | SQL desde paint/snapshot |
| Status Saved miente | pending real o se omite | label Saved con queue pendiente |
| Raw DB leakage | normalizador y logger | mensaje SQLite visible |
| Refresh excesivo | dirty regional y no N-traces | full por stroke o batch |
| Local runtime no prueba stylus moderno | fuente stable/dev + gate Scribe | declarar soporte físico sólo con SDL |

## 22. Criterios de aceptación

La implementación está lista para gate físico cuando:

- Notebooks aparece en FileManager y ReaderUI con UI y textos en inglés.
- La biblioteca no altera input/Draw/hoja de un libro hasta abrir un cuaderno.
- Biblioteca lista 5.000 notebooks con batches de 50, sin OFFSET ni crecimiento de memoria.
- Cada fila abre por su cuerpo y ofrece Actions como target separado.
- Create/Rename/Delete preservan input y texto en fallos.
- El editor usa un rail físico escalado, un strip y un paper viewport estable.
- Stylus dibuja sólo en paper; finger/palm no dibujan; chrome sigue operable.
- No hay tinta debajo de ErrorBand o modales.
- Undo/navegación/add/delete sólo usan fachadas.
- Save failure conserva raster, bloquea acciones peligrosas y ofrece Retry.
- Load failure respeta si cerrar es o no durablemente posible.
- Read-only permite ver/navegar y bloquea mutations antes del callback.
- Page changes, rotation, suspend/resume y voluntary exit respetan gates.
- No hay SQL en paint/snapshot ni full refresh por segmento.
- PDF y EPUB existentes mantienen sus suites.
- Lua, LuaJIT, conformance, preflight, smoke y mutation tests están verdes.
- Los únicos pendientes documentados son mediciones físicas Wacom/e-ink.

## 23. Trazabilidad de la propuesta

| Elemento de la propuesta | Destino en el plan |
|---|---|
| Biblioteca siempre primero | §§7, 10, 14 |
| Lista paginada | custom por limitación de Menu, §§4 y 10 |
| Tres presets | §§10.5 y 17/Fase 1 |
| Rail + strip | §11 |
| Botones de navegación | §§11.3 y 13 |
| Indicador sin ordinal | §§4.2, 9.2, 11.4 |
| No focus mode | §2.2 |
| Grupos de herramientas | §11.3 |
| Saved/Not saved | §11.4 con honestidad/omisión |
| Error persistente | §§11.6 y 13 |
| Orden de passthrough | §12 |
| Targets 10 mm | §§11.2 y 17/Fase 1, corregidos a DPI |
| Preferencias compartidas | §§11.3 y 14 |
| Dos ventanas top-level | §§7 y 11.1 |
| Flujos F1–F8 | §§10–14 y fases 3–9 |
| Escala 5.000/1.000 | §§16 y 18.4 |
| Refresh matrix | §15 |
| Copy español de la propuesta | sustituido por copy inglés en §5 |

## 24. Log de validación documental

### Tema: revisiones estable y development

- **Por qué:** las APIs de stylus/UI deben fijarse a versiones concretas.
- **Fuente:** resolver `koreader-docs-research`, GitHub Releases/API oficial.
- **Verificado:** estable `v2026.07.1`/`9192014…`, development `5e45c4…`, base SHAs y local revision.
- **Restricciones:** runtime local anterior a la API moderna de stylus.
- **Impacto:** compatibilidad de fuente y gate físico separados.
- **Confianza:** alta.

### Tema: FileManager y `is_doc_only`

- **Fuente estable:** [FileManager 9192014, líneas 417–425](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/apps/filemanager/filemanager.lua#L417-L425)
- **Fuente development:** [FileManager 5e45c4, líneas 417–425](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/apps/filemanager/filemanager.lua#L417-L425)
- **Verificado:** FileManager sólo instancia plugins con `not is_doc_only`.
- **Impacto:** cambiar flag y registrar menú antes del return docless.
- **Confianza:** alta.

### Tema: stack, `show/close`, dirty y `show_parent`

- **Fuente estable:** [UIManager 9192014, líneas 135–225](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/uimanager.lua#L135-L225), [dirty contract, líneas 550–625](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/uimanager.lua#L550-L625)
- **Fuente development:** [UIManager 5e45c4, líneas 194–260](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/ui/uimanager.lua#L194-L260), [refresh/show_parent contract, líneas 550–625](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/ui/uimanager.lua#L550-L625)
- **Verificado:** ventanas se apilan, close emite FlushSettings/CloseWidget, setDirty requiere window-level widget y `ui` es el default recomendado para UI.
- **Impacto:** library/editor top-level, modales encima, pre-close durable y show_parent propagado.
- **Confianza:** alta.

### Tema: limitación de `MenuItem`

- **Fuente estable:** [MenuItem gestures 9192014, líneas 101–130](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/widget/menu.lua#L101-L130), [tap/hold, líneas 513–550](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/widget/menu.lua#L513-L550)
- **Fuente development:** [MenuItem gestures 5e45c4, líneas 101–130](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/ui/widget/menu.lua#L101-L130), [tap/hold, líneas 510–550](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/ui/widget/menu.lua#L510-L550)
- **Verificado:** tap/hold cubren self.dimen y delegan a la fila; el layout público no expone un trailing action button independiente.
- **Impacto:** biblioteca propia con dos hit targets; no subclass/copy de MenuItem local.
- **Confianza:** alta.

### Tema: navegación five-way de la biblioteca custom

- **Fuente estable:** [FocusManager 9192014, layout y movimiento](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/widget/focusmanager.lua#L30-L45), [movimiento direccional](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/widget/focusmanager.lua#L220-L333)
- **Fuente development:** [FocusManager 5e45c4, layout y movimiento](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/ui/widget/focusmanager.lua#L30-L45), [movimiento direccional](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/ui/widget/focusmanager.lua#L220-L333)
- **Verificado:** FocusManager gestiona una matriz 2D de widgets focusables y ajusta movimiento horizontal en layouts mirrored.
- **Impacto:** cada fila puede exponer `[body, Actions]` sin crear un sistema de foco propio.
- **Confianza:** alta.

### Tema: diálogo de creación

- **Fuente estable:** [MultiInputDialog:addWidget 9192014, líneas 301–315](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/widget/multiinputdialog.lua#L301-L315), [RadioButtonTable](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/widget/radiobuttontable.lua)
- **Fuente development:** [MultiInputDialog:addWidget 5e45c4, líneas 301–315](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/ui/widget/multiinputdialog.lua#L301-L315), [RadioButtonTable](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/ui/widget/radiobuttontable.lua)
- **Verificado:** MultiInputDialog admite un widget añadido y RadioButtonTable mantiene selección exclusiva.
- **Impacto:** name field + presets sin diálogo custom completo.
- **Confianza:** alta.

### Tema: milímetros y escala

- **Fuente estable:** [framebuffer 6e4bc81, líneas 391–425](https://github.com/koreader/koreader-base/blob/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/framebuffer.lua#L391-L425)
- **Fuente development:** [framebuffer 9f9b664, líneas 391–425](https://github.com/koreader/koreader-base/blob/9f9b664083d8cdab967638781096f5b089cb2e36/ffi/framebuffer.lua#L391-L425)
- **Verificado:** scaleByDPI usa DPI/160; scaleBySize usa lado menor/600 y sólo incorpora DPI con override.
- **Impacto:** corregir la propuesta y usar scaleByDPI para objetivos físicos.
- **Confianza:** alta.

### Tema: stylus callback

- **Fuente estable:** [Input 9192014](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/input.lua)
- **Fuente development:** [Input 5e45c4](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/device/input.lua)
- **Verificado:** callback único, invocación por slot y eliminación de slots dominados antes de gesture detection.
- **Impacto:** reutilizar InputController y desarme diferido; no crear captura visual paralela.
- **Confianza:** alta para fuente, pendiente para hardware Scribe.

### Tema: SaveSettings antes de Suspend

- **Fuente estable:** [Generic Device 9192014, `_beforeSuspend`](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/generic/device.lua#L1094-L1101)
- **Fuente development:** [Generic Device 5e45c4, `_beforeSuspend`](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/device/generic/device.lua#L1094-L1101)
- **Verificado:** `flushSettings()` precede al broadcast `Suspend`.
- **Impacto:** durable gate en onSaveSettings; onSuspend sólo abort/release.
- **Confianza:** alta.

## 25. Revisión final obligatoria antes de implementar

El agente implementador debe confirmar explícitamente, antes de editar producción:

- que el worktree sigue conteniendo el backend descrito;
- que no apareció una UI de notebooks paralela;
- que las SHAs upstream no cambiaron de relevancia para el target;
- que el plan no intenta introducir español en source;
- que todas las desviaciones de §4 están entendidas;
- que no se confunde “abrir biblioteca” con “abrir notebook/input lease”;
- que ninguna optimización de refresh se presenta como probada en Scribe.

Si el repositorio contradice este plan, el repositorio gana. La desviación debe documentarse con la evidencia y sus pruebas; no debe resolverse silenciosamente.
