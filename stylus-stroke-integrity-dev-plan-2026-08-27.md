# JD-STYLUS-STROKE-INTEGRITY — plan de desarrollo

Fecha: 2026-08-27
Estado: listo para ejecución por fases; no se ha modificado código de producción
Repositorio: `/Users/christianstenger/GitHub/justdraw`
Plugin: `justdraw.koplugin`
Rama de trabajo propuesta: `codex/stylus-stroke-integrity`
KOReader estable validado: `v2026.07.1` (`9192014d8bd82a91dc1012473be0f238dedfdb54`)
KOReader desarrollo validado: `master` a 2026-08-27 (`60ce80ed1e6c0ad79a7e86be470dac1ac80960d2`)

## 1. Entradas de la tarea

| Campo | Decisión |
| --- | --- |
| Feature / fix ID | `JD-STYLUS-STROKE-INTEGRITY` |
| Objetivo | Impedir que muestras pertenecientes a contactos o instantes físicos diferentes terminen dentro del mismo stroke; acotar el trabajo por contacto; eliminar costes evitables al levantar el lápiz; y alinear el refresh del cuaderno con la política e-ink de JustDraw. |
| Stack | Plugin KOReader en Lua/LuaJIT; `Device.input`; `GestureDetector`; `BlitBuffer`; `UIManager`; persistencia existente en sidecar/SQLite. |
| Hardware principal | Kindle Scribe y dispositivos comparables con digitalizador y lápiz. |
| Compatibilidad | Mantener la ruta de dedo, la tinta directa en documentos, el canvas EPUB y los cuadernos independientes. La API moderna de stylus exige KOReader `v2026.07+`. |
| Restricciones | Un único callback de stylus en KOReader; tablas de slot persistentes y mutables; callback sin máscara pública de ejes cambiados; hot path sin asignaciones por muestra cuando Diagnostics está apagado; e-ink con latencia y waveforms que sólo se pueden validar físicamente. |
| No objetivos | Smoothing, presión, inclinación, hover como función de producto, predicción de palma, shapes, coalescing temporal de tinta, cambios de esquema/codec, interceptar evdev raw, parchear KOReader, cambiar el formato de sidecar o rediseñar la UI. |
| Alcance Git | Commits nuevos y cohesivos sobre una base limpia que ya contenga el rename a JustDraw. No reescribir, dividir ni reorganizar commits históricos. |
| Archivo esperado | `stylus-stroke-integrity-dev-plan-2026-08-27.md` |

## 2. Resultado arquitectónico

La arquitectura actual de dibujo sigue siendo utilizable. El renderizador y la persistencia no unen por sí solos strokes correctamente finalizados. El defecto está antes: JustDraw posee dos máquinas de estado de stylus que interpretan como geometría nueva una tabla de slot cuyos campos KOReader conserva y actualiza de forma independiente.

La corrección no debe fusionar toda la lógica de notebooks, EPUB y tinta directa. Debe extraer una sola capa física y compartida que normalice una secuencia de stylus, y dejar que cada dominio conserve su política geométrica, su UI y su persistencia.

```text
KOReader Device.input
  │  slot mutable: slot/id/x/y/tool/timev
  ▼
InkCapture
  │  ownership del callback, guard, desarme diferido, rotación raw→screen
  ▼
InkStylusSequence                 ← nueva normalización física compartida
  │  slot/id/proximity/delivery/geometry pending/budget
  ├── tinta directa (main.lua)    → página / barra / diálogo / sidecar
  ├── canvas EPUB (main.lua)      → InkContactRouter / cache / SQLite
  └── notebook (adapter)          → papel / rail / cache / SQLite

InkRender + SurfaceSession + Queue
  └── sólo reciben strokes ya delimitados
```

La entrega debe dividirse en dos hitos:

1. **Hito de observabilidad y semántica segura:** replay fiel, diagnóstico en notebooks, ownership de slot/ID, fallback Wacom, presupuesto acotado y tests de paridad.
2. **Hito de coherencia geométrica:** seleccionar y activar la regla exacta de bootstrap de coordenadas después de capturar una traza real del Scribe. La API pública no expone qué eje cambió en un frame; no se debe inventar un número fijo de muestras ni un umbral de distancia.

El segundo hito tiene un stop condition real. Si la traza muestra que no existe señal pública suficiente para distinguir un eje antiguo de un movimiento horizontal/vertical legítimo, el plugin debe fallar de forma conservadora y abrir una propuesta upstream para añadir metadata de frescura. No debe interceptar eventos Linux por debajo de KOReader.

## 3. Línea base y precondición Git

### 3.1 Estado observado

La inspección se realizó en `codex/rename-justdraw`, `HEAD bf76b6bb106be4ed886d4afbadf9a2535db77eb5` (`docs(notebooks): record architecture and UI delivery`). El worktree no constituye todavía una base auditable:

- `fingerink.koplugin/**` aparece borrado;
- `justdraw.koplugin/` aparece completo y sin tracking;
- README, decisiones, planes, workflow y shim de tests aparecen modificados.

Esto no exige reescribir historia ni resolver la atomicidad de commits anteriores. Sí exige registrar primero el rename actual en una base identificable. De lo contrario, Git no puede mostrar qué hunks pertenecen a esta remediación.

### 3.2 Gate previo obligatorio

Antes de implementar:

1. Registrar el rename a JustDraw sin mezclar ninguna corrección de stylus.
2. Ejecutar `git status --short` y confirmar que el árbol está limpio, o que sólo contiene cambios de usuario expresamente excluidos.
3. Guardar el SHA base en el encabezado del PR/plan ejecutado.
4. Crear `codex/stylus-stroke-integrity` desde ese SHA.
5. No usar `git reset --hard`, no restaurar cambios del usuario y no reordenar commits históricos.

### 3.3 Baseline funcional verificado

Comandos ejecutados el 2026-08-27:

```sh
cd /Users/christianstenger/GitHub/justdraw
git diff --check
lua test.lua

cd /Users/christianstenger/GitHub/justdraw/justdraw.koplugin
KOREADER_PLUGIN_DIR=/Users/christianstenger/GitHub/justdraw/justdraw.koplugin \
  /Users/christianstenger/.codex/skills/koreader-simulator-qa/scripts/koreader_qa.sh test
```

Resultado:

- `git diff --check`: limpio;
- Lua: 2.348 comprobaciones, 0 fallos;
- KOReader LuaJIT: sintaxis 58/58, 2.348 comprobaciones, 0 fallos.

Estos resultados son una línea base, no evidencia de que el defecto no exista. Los tests actuales entregan secuencias demasiado perfectas y el KOReader local (`v2025.08-100-g1d66e440b`) no contiene la API moderna de stylus.

## 4. Inventario del repositorio

### 4.1 Responsabilidades que se conservan

| Archivo | Área relevante | Decisión |
| --- | --- | --- |
| `justdraw.koplugin/ink_capture.lua` | `supportsStylus`, `isStylusSlot`, `fail`, `removeDeferred`, `dropContact`, `installStylus`, `toScreen` | Mantener como límite de integración con KOReader. No colocar aquí la nueva FSM. |
| `justdraw.koplugin/ink_input_controller.lua` | lease process-wide y release diferido | Mantener. La nueva secuencia vive dentro de cada lease, no sustituye el ownership. |
| `justdraw.koplugin/ink_contact_router.lua` | clasificación geométrica EPUB y cancelación de palmas | Mantener como política EPUB; no convertirlo en normalizador Wacom. |
| `justdraw.koplugin/main.lua` | segunda FSM actual; tinta directa y canvas EPUB; Diagnostics; refresh directo | Migrar al normalizador compartido sin fusionar stores ni routers. |
| `justdraw.koplugin/ink_notebook_input.lua` | primera FSM actual; papel, rail, dedo, eraser y live ink | Migrar sólo su ruta de stylus. La ruta de dedo queda intacta. |
| `justdraw.koplugin/ink_notebook_session.lua` | adquisición/liberación del lease y gates de navegación | Mantener sus gates y releases diferidos. |
| `justdraw.koplugin/ink_render.lua` | DDA de segmentos | Añadir recorte de trabajo; no cambiar geometría persistida ni estilo visual. |
| `justdraw.koplugin/ink_canvas_cache.lua` | live raster y registro/indexación al lift | Permitir registrar un stroke ya rasterizado sin pintarlo otra vez. |
| `justdraw.koplugin/ink_surface_session.lua` | validación, cola, cache y secuencia | Propagar el token de live raster (cache, generation y completitud); mantener queue-first y rollback. |
| `justdraw.koplugin/ink_canvas_session.lua` | fachada EPUB | Propagar la opción sin cambiar comportamiento por defecto. |
| `justdraw.koplugin/ink_canvas_queue.lua` | batch y transacción SQLite | Sacar el flush por umbral del callback; conservar flush síncrono de lifecycle. |
| `justdraw.koplugin/ink_notebook_editor.lua` | blit regional y refresh hardcoded `fast` | Respetar `live_fast` y añadir limpieza de calidad O(1). |
| `justdraw.koplugin/ink_notebook_ui.lua` | construcción/configuración del editor | Inyectar `get_live_fast` y conservar el resto del contrato UI. |

### 4.2 Patrones que deben preservarse

- `InkCapture` se vuelve inerte dentro del callback y se desregistra en un tick seguro.
- Un callback de error nunca desregistra `input.stylus_callback` desde `routeStylusEvents`.
- `InkInputController` impide que FileManager y ReaderUI posean el callback a la vez.
- Las coordenadas se convierten con `Capture.toScreen`; no se debe duplicar la fórmula de rotación.
- La cola se modifica antes del cache; si el cache falla, se retira la operación pendiente.
- Un fallo de guardado bloquea edición y conserva operaciones para Retry.
- La tinta viva se blitea directamente a `Screen.bb`; `setDirty(nil, ...)` solicita sólo el refresh regional.
- Los textos visibles del producto se mantienen en inglés y pasan por gettext.
- La nueva FSM y Diagnostics no añaden tablas, strings de log ni un segundo `pcall` por muestra cuando Diagnostics está apagado; el `pcall` de contención existente en `InkCapture.guard` se conserva.

### 4.3 Tests y CI existentes

- `test.lua` carga `justdraw.koplugin/tests/run.lua` independientemente del cwd.
- `tests/support.lua` ya modela slots persistentes y un `GestureDetector` con contactos/timers.
- `tests/run.lua` registra las suites por nombre.
- `.github/workflows/tests.yml` hace syntax sweep bajo LuaJIT y ejecuta el shim raíz.
- Los tests de SQLite/cache/session ya cubren transacciones, rollback, reopen y conformance real.

### 4.4 Archivos fuera de alcance

No modificar, salvo evidencia nueva y una ampliación explícita del scope:

- `ink_canvas_repository.lua`;
- `ink_notebook_repository.lua`;
- schemas o migraciones;
- `ink_canvas_codec.lua` y su formato binario;
- `ink_store.lua` y el formato sidecar;
- `ink_anchor.lua` / `ink_anchor_index.lua`;
- library, templates, purge o navegación de notebooks;
- `_meta.lua`;
- dependencias o workflow de CI;
- código core de KOReader o evdev raw.

## 5. Invariantes de corrección

La implementación se considera incorrecta si rompe cualquiera de estas reglas:

1. **No retener la tabla `slot`.** Copiar `slot`, `id`, `x`, `y`, `tool` y `timev` a escalares al entrar. KOReader reutiliza y muta la tabla.
2. **Ownership explícito.** Sólo `owner_slot` y `owner_id` pueden añadir puntos o terminar la secuencia activa.
3. **Lift ajeno inocuo.** Un `id < 0` de otro slot no finaliza, no persiste y no resetea el contacto dueño.
4. **Reemplazo de tracking ID.** Un ID positivo nuevo en el mismo slot finaliza/aborta la secuencia anterior antes de abrir la nueva en Type-B.
5. **Fallback Wacom estrecho.** `TOOL_FINGER` con ID positivo es boundary sólo si `wacom_protocol == true`, el slot es `pen_slot` y ese slot posee la secuencia.
6. **Herramienta estable.** `TOOL_FINGER` de proximity-out no convierte una goma o lápiz activo en dedo. Se conserva el último tool no-FINGER.
7. **Delivery monotónica.** Mientras la secuencia esté indecisa se pueden dominar frames preliminares y luego entregar el primer down coherente. Una vez que un frame se entregó a `GestureDetector`, no se puede reclamar la secuencia salvo que se pruebe que el frame todavía no llegó al detector o que `Capture:dropContact(slot)` devuelva `true`.
8. **No UI debajo de ink.** Una secuencia dominada que cruza hacia barra/modal no se devuelve a gestos: se termina o aborta la tinta y queda suspendida hasta el boundary.
9. **Lift idempotente.** Un lift tardío después de proximity-out no crea otro stroke, otro edit event ni otro `penUp`.
10. **Geometría pendiente no visible.** Un punto cuya coherencia no está probada no se dibuja ni se persiste.
11. **Fail closed.** Si se supera el presupuesto o se detecta una secuencia incoherente no recuperable, reparar tinta viva, no persistir el stroke y dominar hasta el lift.
12. **Trabajo acotado.** Ningún contacto puede hacer crecer indefinidamente un vector ni obligar al DDA a iterar hasta una coordenada extrema fuera de viewport.
13. **Persistencia fiel.** No suavizar, decimar, dividir ni reordenar los puntos aceptados; no cambiar schema ni codec.
14. **Finger intacto.** La ruta legacy de dedo conserva su conducta. Se añaden tests, no una nueva FSM de dedo.
15. **Fin lógico ≠ fin físico.** Terminar/abortar tinta por modal, borde o budget no llama todavía `on_contact_end` ni `router:penUp`; la palma sigue suprimida hasta lift, proximity-out, replacement o teardown físico.
16. **Desarme seguro.** Toda retirada descubierta dentro del callback usa `releaseDeferred` / `Capture.removeDeferred`.
17. **Diagnóstico opt-in.** Coordenadas se registran sólo tras acción explícita, de forma local, acotada y sin títulos, rutas, xpointers ni tablas mutables.
18. **Sin coste nuevo oculto.** La nueva FSM y Diagnostics no añaden tablas, strings de log ni un segundo `pcall` por muestra cuando Diagnostics está apagado. El `pcall` de contención ya existente en `InkCapture` se conserva.

## 6. Contrato de la nueva capa compartida

### 6.1 Nuevos módulos

Crear `justdraw.koplugin/ink_limits.lua`, sin dependencias, como única fuente de los defaults `MAX_OPEN_POINTS = 8192` y `MAX_CONTACT_SAMPLES = 32768`. Crear `justdraw.koplugin/ink_stylus_sequence.lua` para la FSM. Los hosts y `SurfaceSession` reciben el mismo límite resuelto; no repetir el literal en dos capas.

Responsabilidad única: convertir snapshots escalares del callback en una secuencia física delimitada. No debe conocer widgets, SQLite, libros, notebooks ni `UIManager`.

Contrato orientativo, que el implementador debe mantener estrecho:

```lua
local Limits = require("ink_limits")
local sequence = StylusSequence.new{
    wacom_protocol = input.wacom_protocol == true,
    pen_slot = input.pen_slot,
    tool_finger = Capture.TOOL_FINGER,
    to_screen = Capture.toScreen,
    max_open_points = Limits.MAX_OPEN_POINTS,
    max_contact_samples = Limits.MAX_CONTACT_SAMPLES,

    -- route: "draw" | "block" | "pass"
    -- effect: "ink" | "erase" | nil
    classify = function(x, y, tool) -- route, effect, reason
    end,
    on_contact_start = function(reason) -- true | nil, reason
    end,
    -- action: "continue" | "finish_suspend" | "abort_suspend"
    on_point = function(x, y, tool, is_first) -- action | nil, reason
    end,
    on_finish = function(reason) -- true | nil, reason
    end,
    on_abort = function(reason) -- true | nil, reason
    end,
    on_contact_end = function(reason) -- true | nil, reason
    end,
    -- se invoca desde afterFrame, nunca desde routeStylusEvents
    on_domain_error = function(reason, phase) end,
    drop_contact = function(slot) return Capture:dropContact(slot) end,
    trace = function(...) end, -- nil/cheap cuando Diagnostics está off
}

sequence:feed(slot)       -- devuelve boolean: true domina, false entrega
sequence:afterFrame()     -- cierra el ordinal de SYN para Diagnostics
sequence:abort(reason, clear_history)
sequence:reset(clear_history)
sequence:hasInkContact()
sequence:hasOwnedPhysicalContact()
sequence:hasForwardedContact()
sequence:isLifecycleBlocked()
sequence:forwardedSlot()
```

El spec se construye antes de que `Capture:installStylus` ejecute `resolveTools`; por tanto no se puede instanciar el objeto de forma eager en `captureSpec`. Usar una factory lazy dentro del primer `stylus_handler`:

```text
stylus_handler(slot)
  → sequence = sequence or newSequence(Capture.input or Device.input)
  → sequence:feed(slot)

frame_handler(slots)
  → ejecutar filtro residual existente
  → si sequence existe, sequence:afterFrame()
```

En ese momento `Capture.input`, `pen_slot`, `wacom_protocol` y `Capture.TOOL_*` ya corresponden al runtime que acaba de instalar el callback. `abort` y el frame handler deben tolerar que nunca haya llegado un evento y `sequence` siga nil. Añadir un test que instale dos fake runtimes con constants/pen slots diferentes y compruebe que la segunda adquisición no reutiliza metadata de la primera.

Los callbacks de host no son fire-and-forget. Todos los wrappers de lifecycle deben normalizar éxito a `true`, aunque la función subyacente de KOReader/Router retorne nil:

- `on_contact_start`, `on_finish`, `on_abort` y `on_contact_end` devuelven `true` o `nil, reason`;
- `on_point` devuelve una acción o `nil, reason`;
- `finish_suspend` conserva el stroke aceptado una vez y pasa a `suspended`;
- `abort_suspend` es effect-aware: repara/descarta tinta ink; para eraser cierra el contexto y conserva deletes ya aceptados;
- un error de dominio esperado **no se lanza** al guard genérico. El host repara lo que corresponda, devuelve `nil, reason`, la secuencia marca `pending_domain_error`, pasa a suspendida/ending y sigue devolviendo `true` para el owner del frame;
- `afterFrame`, después del filtro residual del mismo SYN, invoca una vez `on_domain_error(reason, phase)`. Ese callback solicita `lease:releaseDeferred`/`Capture.removeDeferred`; no desregistra dentro de `routeStylusEvents`;
- sólo una excepción de programación imprevista llega a `InkCapture.guard`, cuyo comportamiento fail-open existente se conserva;
- no añadir otro `pcall` por muestra dentro de la secuencia.

`on_contact_start` fallido no abre efecto; domina hasta cerrar el frame y solicita el desarme diferido. Si falla `on_finish` durante un lift, el host repara, el estado se marca físicamente terminado, `on_contact_end` se ejecuta exactamente una vez y después `afterFrame` entrega el error. Si `on_contact_end` falla, se marca igualmente como ejecutado antes de programar el error para que el teardown no lo repita. Los wrappers EPUB deben hacer, por ejemplo, `router:penUp(); return true`.

Orden al terminar físicamente un contacto:

```text
host on_finish/on_abort, si aún corresponde
→ actualizar estado interno a idle/proximity_wait y marcar efecto inactivo
→ on_contact_end exactamente una vez
→ Adapter:_maybeEmitEditChanged, que ya observa la secuencia inactiva
→ afterFrame/on_domain_error, si quedó un error esperado pendiente
```

`on_contact_end` no se llama por un aborto lógico mid-contact. Es exclusivamente para lift propietario, proximity-out Wacom, ID replacement, cambio de modalidad PEN↔ERASER o teardown físico.

### 6.2 Estados

| Estado | Significado |
| --- | --- |
| `idle` | No hay secuencia física dueña. |
| `contact_pending` | Existe `id >= 0`, pero todavía no hay par geométrico evaluable. |
| `geometry_pending` | Hay candidatos de posición, pero la policy no ha probado que formen una muestra coherente. |
| `active_draw` | El plugin domina y envía puntos al host. |
| `active_block` | El plugin domina sin dibujar, por ejemplo sobre texto fuera del canvas EPUB. |
| `active_pass` | El contacto pertenece a `GestureDetector`; todos sus frames normales, incluido lift, se entregan. |
| `suspended` | El plugin sigue dominando, pero ya terminó/abortó su efecto hasta el boundary. |
| `proximity_wait` | El fallback Wacom cerró una secuencia dominada y espera lift tardío o un nuevo PEN/ERASER. No bloquea navegación por sí solo. |
| `forwarded_wait_lift` | El tool salió de proximidad, pero un `GestureDetector.Contact` ya entregado debe recibir todavía `id=-1` para formar/cancelar su tap normal. |

`ending` puede existir como transición local, pero no debe quedar observable entre callbacks.

### 6.3 Transiciones mínimas

| Estado / evento | Guarda | Acción | Return |
| --- | --- | --- | --- |
| `idle`/plugin-owned, `id == nil` | — | Registrar hover; no abrir/cerrar secuencia | `true` |
| `active_pass`/`forwarded_wait_lift`, `id == nil` | owner forwarded | No reclamar el Contact | `false` |
| `idle`, `id >= 0` | — | Copiar owner slot/ID/tool/time; `on_contact_start`; pasar a pending | `true` mientras no haya clasificación |
| pending, coordenada aún no coherente | owner | Guardar sólo escalares candidatos | `true` |
| pending, policy acepta; `classify == draw` | owner | `active_draw`; emitir primer punto | `true` |
| pending, policy acepta; `classify == block` | owner | `active_block` | `true` |
| pending, policy acepta; `classify == pass` | owner y nunca forwarded | `active_pass` | `false` |
| `active_draw`, misma secuencia | owner | Evaluar boundary dinámico; emitir punto o ejecutar `finish_suspend`/`abort_suspend` una vez | `true` |
| `active_block`, misma secuencia | owner | No dibujar ni cambiar a draw dentro del contacto | `true` |
| `active_pass`, misma secuencia | owner | No tocar host | `false` |
| cualquier estado, positivo/lift de slot stylus ajeno | no-owner | No cambiar owner; entregar todos los frames de esa secuencia ajena de forma coherente | `false` |
| `active_draw`/block/pending/suspended, ID positivo distinto | mismo slot Type-B | Cerrar por estado: draw finish; block sin tinta; pending descarta; suspended conserva; ejecutar `on_contact_end`; después `on_contact_start` de la nueva generación y abrir pending | según nueva clasificación; `true` mientras pending |
| `active_pass`, ID positivo distinto | mismo slot Type-B | Intentar `dropContact`; sólo tras éxito cerrar estado viejo, `on_contact_end`, `on_contact_start` y abrir pending | `true` sólo tras drop exitoso |
| plugin-owned, PEN↔ERASER con ID positivo | mismo slot/ID | Boundary de modalidad: finish ink o cerrar erase preservando deletes; `on_contact_end`; nuevo `on_contact_start`; pending con tool nuevo | `true` |
| `active_pass`, PEN↔ERASER positivo | forwarded | No reclamar ni reiniciar host; mantener pass hasta lift | `false` |
| pending, owner lift o proximity-out Wacom | nunca forwarded | Ejecutar `geometry:onLift`. Si devuelve dot coherente y `classify=draw`, emitir un punto y finish; block descarta; pass se descarta+trace porque GestureDetector nunca recibió down; después `on_contact_end`; lift va a idle y proximity va a `proximity_wait` | `true` |
| `active_draw`/`active_block`/suspended, `TOOL_FINGER` positivo | Wacom + pen_slot + owner | Finish/cerrar/conservar una vez según estado; `on_contact_end`; `proximity_wait` | `true` |
| `active_pass`, `TOOL_FINGER` positivo | Wacom + pen_slot + owner | No retirar todavía el Contact; marcar efecto físico terminado y esperar `id=-1` | `false` (`forwarded_wait_lift`) |
| `forwarded_wait_lift`, lift tardío | owner | Entregar lift, `on_contact_end` si aún no ocurrió y resetear | `false` |
| `forwarded_wait_lift`, nuevo PEN/ERASER positivo | mismo pen slot, lift ausente | Intentar `dropContact`; si tiene éxito: cerrar viejo → `on_contact_end` → `on_contact_start` nuevo → pending. Si falla: no reclamar, pasar y desarmar/notificar tras el frame; el Contact sólo se da por limpio después de su lift físico | `true` sólo tras drop exitoso |
| `proximity_wait`, lift tardío | owner | Reset idempotente | `true` |
| `proximity_wait`, PEN/ERASER positivo | pen_slot | Abrir nueva generación aun si KOReader reutiliza el ID fijo | pending |
| `active_draw`, owner lift | draw | Revalidar modal; finish o abort; reset interno; `on_contact_end` | `true` |
| `active_block`/suspended, owner lift | owner | No crear tinta; reset interno; `on_contact_end` | `true` |
| `active_pass`, owner lift | owner | Reset y `on_contact_end`, sin callbacks de tinta | `false` |
| `active_draw(effect=ink)`, punto 8.193 | owner | `on_abort("point_budget")`, reparar, notificar después del frame, `suspended`; mantener contacto físico activo | `true` |
| cualquier plugin-owned, muestra 32.769 | owner | Aplicar la política por estado de §6.4, saturar contador y suspender dominio hasta boundary | `true` |

Un `dropContact == false` no demuestra ausencia de Contact. No usar `GestureDetector:dropContacts()` como fallback normal porque eliminaría dedos ajenos. Tras fallo, conservar delivery `false`, no abrir tinta nueva y aceptar que Contact/timers sólo quedan garantizados como limpios después del lift físico; si el lift nunca llega, el diagnóstico debe decirlo, no prometer una limpieza inexistente.

### 6.4 Presupuesto de contacto

Usar dos límites internos. Sus defaults viven una sola vez en el nuevo módulo puro `ink_limits.lua`; los constructors aceptan override sólo para tests y builds QA explícitas, nunca como setting/UI ni default de producción:

- `MAX_OPEN_POINTS = 8192` para el vector de tinta;
- `MAX_CONTACT_SAMPLES = 32768` para evitar trabajo de dominio infinito en una secuencia.

Razón:

- el primer límite acota el array Lua a 16.384 números;
- su payload codificado estimado queda alrededor de 32 KiB, aproximadamente la mitad del umbral actual de cola; el footprint real de la tabla Lua es mayor y se mide por separado;
- deja margen para otras operaciones antes de 64 KiB;
- ambos son defensas contra un contacto huérfano, no definiciones semánticas de lift.

No importar `ink_canvas_codec` desde la capa de input. La coincidencia con el presupuesto persistente se documenta y prueba por integración, no se convierte en dependencia de producción.

Al exceder `MAX_OPEN_POINTS` durante ink:

1. no aceptar ni pintar el punto 8.193;
2. abortar y reparar todo el stroke vivo;
3. no persistir una fracción;
4. suspender el efecto hasta lift/proximity boundary sin fingir que el contacto físico terminó;
5. mostrar una única notificación, en el siguiente tick seguro:
   `Stroke stopped because the pen contact did not end. Lift the pen and try again.`

No dividir automáticamente en varios strokes: cambiaría Undo, introduciría I/O mientras el lápiz sigue abajo y ocultaría un boundary perdido.

`MAX_CONTACT_SAMPLES` cuenta cada callback del owner con `id >= 0`, incluidos pares duplicados; no cuenta hover `id=nil`, foreign slots ni el lift negativo. El contador satura en el máximo y nunca vuelve a crecer. La política cuando llega primero es:

- `active_draw` ink: abortar/reparar todo el stroke, igual que point budget;
- eraser: cerrar el erase context una vez y conservar borrados ya aceptados; no existe rollback del gesto completo;
- pending/block: descartar candidatos o cerrar block, entrar en suspended sin host work adicional;
- suspended: ignorar en O(1) hasta boundary;
- active_pass/forwarded: no reclamar por budget; continuar devolviendo false hasta lift/drop.

Este cap acota trabajo y memoria del dominio, no el número inevitable de invocaciones del callback mientras el dispositivo siga reportando un contacto huérfano. Un cambio PEN↔ERASER con ID aún positivo es boundary de modalidad para una ruta dominada; nunca se mezclan ambos efectos dentro de un stroke. Para pass permanece forwarded hasta lift.

La notificación programada debe capturar owner/lease/editor generation y cancelarse o ignorarse tras close, rotation, page/session switch o nueva adquisición, para no aparecer en otro cuaderno.

## 7. Coherencia de geometría y gate de traza

### 7.1 Lo que la API permite saber

El callback público ofrece `{slot, id, x, y, tool, timev}`. No ofrece una máscara de campos actualizados. `x` e `y` presentes sólo indican el estado acumulado del slot, no que ambos ejes hayan cambiado en ese `SYN_REPORT`.

Por eso quedan prohibidas como solución final, sin evidencia física:

- “descartar exactamente una/dos muestras”;
- “aceptar cuando el par sea distinto del último lift”;
- “un salto mayor a N píxeles es lift”;
- “un delta de tiempo por sí solo separa contactos”;
- comparar `slot.timev` con `time.now()`.

`timev` es un valor FTS derivado del timestamp del evento. Se permiten deltas entre dos `timev` válidos de la misma secuencia usando `ui/time`; si es nil, repetido o regresivo, la heurística temporal se desactiva. Inicialmente se usa sólo para diagnóstico.

### 7.2 Interface de policy

La lógica de `geometry_pending` debe quedar encapsulada dentro de `ink_stylus_sequence.lua`, con una función pura/testeable que devuelva múltiples valores, no una tabla por muestra:

```text
observe(raw_x, raw_y, timev, phase)
  → pending
  → accept, accepted_x, accepted_y, reason
  → reject, reason

onLift(raw_x, raw_y, timev)
  → dot, accepted_x, accepted_y
  → discard, reason
```

Mientras devuelve `pending`, no se llama `classify`, no se pinta y no se persiste. Si el contacto termina pendiente, sólo se puede recuperar un dot final cuando la policy trace-backed pruebe que esa coordenada es coherente; nunca se construye un segmento usando candidatos pendientes.

### 7.3 Diagnóstico necesario antes de seleccionar policy

Crear `justdraw.koplugin/ink_stylus_trace.lua` o una unidad equivalente con estas propiedades:

- sesión explícita de 60 segundos o 8.192 eventos, lo que ocurra primero; `max_events` es inyectable en tests y cada escenario físico usa una sesión separada;
- fuente: `direct`, `epub_canvas` o `notebook`;
- ordinal de evento y ordinal de frame/SYN;
- escalares copiados: `slot`, `id`, `tool`, `x`, `y`, `timev`;
- estado anterior y siguiente;
- delivery anterior y siguiente;
- decisión: `pending`, `accept`, `begin`, `append`, `lift`, `split_id`, `proximity_out`, `suspend`, `discard`, `abort_budget`, `pass`;
- razón y deltas `dx`, `dy`, `dt` cuando existan;
- log después de decidir, no antes;
- nunca guardar la tabla `slot`, título, path, xpointer, ID de libro/cuaderno ni contenido persistido.

El callback corre antes del wrapper residual. Para numerar frames sin tocar KOReader:

1. cada callback usa `completed_frame + 1`;
2. el `frame_handler`, que corre una vez después de `routeStylusEvents`, llama `sequence:afterFrame()`;
3. todos los slots del mismo frame comparten ordinal;
4. mantener además un ordinal de evento para diagnosticar frames multi-slot.

Privacidad: una secuencia de coordenadas puede reconstruir parcialmente la escritura aunque no contenga texto explícito. Al activar Diagnostics, mostrar en inglés:

`Pen coordinates will be written to the local KOReader log for up to 60 seconds. JustDraw does not upload them; shared logs may contain them.`

Diagnostics sigue siendo opt-in, local y acotado. Al alcanzar un límite debe emitir una sola línea `trace_truncated=time_limit|event_limit`. Cuando está apagado, `trace` debe ser nil o un branch barato, sin crear tablas/strings por muestra. El test usa un límite inyectado de 3–5; no itera 8.192 eventos sólo para probar el corte. Como el logging puede perturbar latencia, la traza se usa para reproducción corta y separada, no como modo permanente.

### 7.4 Matriz de decisión después de la traza

| Evidencia física | Acción permitida |
| --- | --- |
| El primer frame es sticky y el siguiente trae XY atómico de forma consistente | Implementar policy Wacom que mantiene pending hasta ese frame completo; probar same-pixel dot y líneas H/V. |
| X/Y llegan partidos pero existe una señal pública estable y reproducible que identifica cuándo ambos son actuales | Codificar esa señal con tests de replay exactos y fallback fail-closed. No usar sólo distancia. |
| X/Y llegan partidos de forma variable y el callback no ofrece señal de frescura | **STOP.** No activar una heurística. Proponer a KOReader metadata `changed_x/changed_y` o snapshot por SYN y mantener el plugin en fail-closed para secuencias ambiguas. |
| El defecto sólo aparece en foto, desaparece con full refresh y nunca está en screenshot/reopen | No cambiar geometry policy por ese caso; tratarlo en la política e-ink. |
| La línea aparece en screenshot y reaparece al reabrir | Es geometría real; el replay debe reproducir la lista exacta de puntos antes de continuar. |

Toda policy elegida debe pasar, como mínimo, el replay adversarial:

```text
lift anterior            100,100
down sticky              100,100
repetición sticky        100,100
actualización X          500,100
actualización Y          500,600
lift                     500,600
```

Resultado válido: no existe ningún stroke con `(100,100)→(500,100)→(500,600)`. Es aceptable fallar de forma visible y no guardar nada durante el gate; no es aceptable persistir una L.

## 8. Políticas de cada host

La secuencia física se comparte. Las siguientes políticas siguen en sus módulos actuales.

| Dominio | `pass` | `draw` | `block` | Boundary/abort |
| --- | --- | --- | --- | --- |
| Tinta directa | diálogo o barra al comenzar | página | no aplica | cruzar hacia barra termina al borde y suspende; diálogo mid-stroke aborta y domina hasta lift |
| Canvas EPUB | diálogo, barra, handle | canvas | texto del reader | conservar `router:penContact(nil,nil)` al down, `penContact(x,y)` sólo tras aceptar geometría y `penUp()` exactamente una vez |
| Notebook | rail, error band, modal, fuera del papel | papel | no aplica | overlay mid-stroke aborta/repara; `last_stylus_lift_time` permanece en Adapter |

Detalles obligatorios:

- `active_pass` no dibuja ni cambia store/cache. Un proximity-out anómalo mantiene delivery `false` para que el posterior `id=-1` complete el tap de barra/rail.
- Si llega un nuevo PEN antes de ese lift, reclamar sólo después de un `dropContact == true`; si el drop falla o lanza, no dominar la nueva secuencia y desarmar/notificar de forma diferida.
- `hasInkContact` indica sólo un efecto ink/erase abierto. `hasOwnedPhysicalContact` permanece true en pending, draw, block y suspended. `hasForwardedContact` cubre pass/forwarded hasta lift/drop. `isLifecycleBlocked` se deriva por estado: true en `contact_pending`, `geometry_pending`, `active_draw`, `active_block`, `suspended`, `active_pass` y `forwarded_wait_lift`; false sólo en `idle` y `proximity_wait`.
- EPUB `reader` se domina para mantener la palma sin girar página, pero no dibuja. `active_block` nunca se transforma en draw porque el pen cruza hacia el canvas.
- `on_finish` y `on_abort` cierran sólo el efecto. `router:penUp()` se llama desde `on_contact_end`, no por modal/budget/outside mientras el lápiz siga físicamente apoyado.
- En `active_draw`, el host reevalúa regiones dinámicas por muestra: outside/bar puede devolver `finish_suspend`; modal/error overlay devuelve `abort_suspend`. Para ink, abort repara; para eraser, cierra el contexto y conserva deletes ya aceptados. En el lift se revalida modal una última vez aunque no haya llegado otra coordenada.
- Los contactos touch residuales siguen en `onStylusTouchFrame`, `routeCanvasTouch` o el frame handler del Adapter; no se mueven a la FSM de stylus.
- En notebook, `on_edit_changed` se emite después del reset interno y sólo cuando no queda contacto residual/forwarded. Es distinto de `on_physical_contact_end`: este último se emite para cada `on_contact_end` (draw, erase, pass, pending, block, proximity/replacement), aunque no haya edición, y permite al Editor rearmar timers de calidad.
- Eraser conserva la herramienta anterior a `TOOL_FINGER`; proximity-out no produce un trazo de dedo.
- `abort/reset` externos intentan retirar cualquier Contact forwarded. Si falla, no dominan ni abren tinta nueva para ese slot y dejan que el lift físico limpie GestureDetector; no prometen limpiar timers antes de ese lift.
- Historia geométrica: lift/proximity normal preserva baseline dentro del lease; nuevo lease, backend, página/sesión, resize/rotation, close o error la limpian; suspend lógico mid-contact no la borra hasta el boundary.
- Un fallo esperado de cache/queue se repara sin lanzar, domina el owner del frame y solicita desarme desde `afterFrame`; una excepción imprevista queda para el guard ya existente. `queue_backpressure` se trata aparte como rechazo transitorio recuperable de Fase 5.3.

## 9. Plan de implementación paso a paso

### Fase 0 — Establecer una base auditable

**Archivos de producción:** ninguno.

1. Completar el rename pendiente a JustDraw como cambio separado.
2. Confirmar que `justdraw.koplugin/` está trackeado.
3. Guardar SHA base y resultados de baseline.
4. Crear rama `codex/stylus-stroke-integrity`.

**Gate:** no iniciar Fase 1 si el plugin completo sigue apareciendo como untracked.

### Fase 1 — Replay realista y Diagnostics compartido

**Crear:**

- `justdraw.koplugin/tests/input_replay.lua`;
- `justdraw.koplugin/ink_stylus_trace.lua`;
- tests específicos de Diagnostics/replay.

**Modificar:**

- `tests/support.lua` sólo para fakes compartidos;
- `tests/run.lua` para registrar suites;
- `main.lua` para poseer una sesión Diagnostics común;
- `ink_notebook_input.lua` para publicar decisiones del notebook;
- `ink_notebook_ui.lua` y `ink_notebook_editor.lua` para poder armarla desde el editor fullscreen;
- `notebook_input_spec.lua`, `notebook_editor_spec.lua` y tests actuales de pipeline;
- el comentario de pin en `tests/support.lua`: usar el commit estable exacto `9192014d…`, no una versión no resuelta.

#### 1.1 Replayer

Construir un replayer pequeño del contrato callback/per-SYN, no afirmar que reproduce la traducción raw Linux. Debe ofrecer dos niveles:

1. **Unit replay:** alimenta snapshots persistentes directamente a `InkStylusSequence`.
2. **Integration replay:** instala `InkCapture` mediante `Capture:installStylus` o el lease real, llama `input.stylus_callback(input, slot)` y después invoca una sola vez el `gd.feedEvent` ya envuelto. No llama además al `frame_handler`, porque el wrapper lo ejecuta.

El bus mantiene:

- una tabla persistente por slot;
- un conjunto ordenado de slots tocados desde el SYN anterior;
- cada slot aparece una sola vez aunque cambien varios campos;
- sólo los slots tocados forman `MTSlots`;
- `dirty_slots` se limpia tras `syn()`, las tablas no;
- frames multi-slot conservan orden.

Uso unitario orientativo:

```lua
replay:set(slot, { id = 4 })       -- sólo muta campos nombrados
replay:syn()
replay:set(slot, { x = 500 })
replay:syn()
```

Pipeline de integración:

```text
slot persistente mutado
→ input.stylus_callback instalado por Capture
→ slots dominados se retiran
→ gd.feedEvent envuelto ejecuta frame_handler una vez
→ GestureDetector recibe lo restante
```

La traducción BTN/ABS de Wacom se valida con fuente oficial y transcript físico, no duplicando `handleKeyBoardEv` en tests.

#### 1.2 Trazas

Integrar Diagnostics en los dos handlers actuales sólo para obtener evidencia. Mantener la sesión al migrar a `InkStylusSequence`, de modo que no se cree un sistema de diagnóstico desechable.

El menú principal actual no es alcanzable dentro del editor fullscreen. Añadir a `Editor:showMore` un item gettext en inglés `Stylus diagnostics`, inyectado por `NotebookUI` hacia la misma sesión del plugin. Antes de armarla, mostrar el warning de privacidad de §7.3. No empezar el gate Scribe si no se puede activar desde el propio notebook.

Añadir tests que prueben:

- el item del editor arma Diagnostics y registra `source=notebook`;
- dos slots en el mismo SYN comparten frame y tienen distinto event ordinal;
- la decisión registrada es posterior a la transición;
- mutar la tabla original después no cambia lo registrado;
- los límites inyectados de eventos/tiempo detienen la sesión y registran la causa;
- Diagnostics off no crea registros;
- no aparece título/path/xpointer en las líneas.

#### 1.3 Captura física

Instalar esta build de observabilidad en un Scribe con KOReader estable actual. Registrar:

- revisión exacta KOReader y firmware;
- `wacom_protocol`, `pen_slot`, tool constants;
- 20 dots separados, incluidos dos en el mismo píxel;
- 50 strokes cortos con lift y nuevo down en otra zona;
- líneas horizontales, verticales y diagonales legítimas;
- pen y back eraser;
- taps en todos los controles;
- palma apoyada;
- lift rápido y nuevo down lejos;
- portrait y landscape.

Armar sesiones separadas por escenario para no consumir el event budget con el primer stroke. No avanzar a la policy geométrica final sin clasificar la traza con §7.4.

### Fase 2 — Implementar `InkStylusSequence` en aislamiento

**Crear:**

- `justdraw.koplugin/ink_limits.lua`;
- `justdraw.koplugin/ink_stylus_sequence.lua`;
- `justdraw.koplugin/tests/stylus_sequence_spec.lua`.

Implementar primero la semántica que sí está confirmada por KOReader:

1. snapshot escalar y ownership slot/ID;
2. hover inerte;
3. foreign slot/lift inocuo;
4. positive ID replacement en Type-B;
5. fallback Wacom `TOOL_FINGER` sólo para pen slot owner;
6. conservación de PEN/ERASER;
7. `active_pass` normal conserva delivery hasta lift; reclaim sólo tras drop confirmado;
8. lift/proximity idempotente y separación `proximity_wait` / `forwarded_wait_lift`;
9. finish-vs-abort definido por estado y fin lógico separado del físico;
10. abort/reset externo con drop obligatorio y matriz `clear_history`;
11. budgets de vector/muestras con semántica distinta para ink/eraser;
12. contrato de acciones/errores del host;
13. transición y trace sink;
14. geometry policy seleccionada en la Fase 1.

No integrar con main/notebook hasta que la suite pura pase.

#### Casos unitarios obligatorios

- hover con `id=nil` antes y durante contacto;
- down sin coordenadas;
- stale XY repetido más de una vez;
- X→Y e Y→X por frames separados;
- XY fresco en el mismo SYN;
- dots reales en el mismo píxel, incluido pending recuperado al lift/proximity; route pass pendiente se descarta sin sintetizar un tap;
- Wacom FINGER con ID positivo finaliza una secuencia dominada una sola vez;
- FINGER en slot ordinario/non-Wacom no activa fallback;
- tap pass normal con orden `PEN → TOUCH → FINGER → TOUCH_UP` entrega exactamente un tap al control;
- nuevo PEN con mismo ID antes del lift de un pass sólo se reclama tras drop exitoso;
- drop devuelve false, `getContact` lanza o `dropContact` lanza: no se reclama el nuevo PEN; tras desarme el lift físico sigue entregándose y sólo entonces se exige que Contact/timers queden limpios;
- nuevo PEN con mismo ID fijo después de proximity-out dominado abre otra secuencia;
- late lift idempotente;
- ID positivo distinto separa dos secuencias: draw hace finish, pending descarta, suspended no resucita y pass limpia Contact;
- positivo y lift de slot ajeno no terminan owner y mantienen delivery coherente;
- eraser conserva tool; PEN↔ERASER positivo cierra/end el host anterior, llama end→start en orden y no mezcla modalidades; pass permanece forwarded;
- passthrough completo incluyendo lift;
- abort/reset externo de pass llama drop y maneja su resultado;
- `on_point` devuelve continue/finish_suspend/abort_suspend y no inicia un segundo stroke en el mismo contacto;
- modal aparecido después de la última muestra pero antes del lift aborta en la revalidación final; modal mid-erase conserva hits aceptados y cierra el contexto una vez;
- budget/modal abort mantiene el contacto físico activo hasta boundary;
- punto 8.193 de ink aborta, no se emite y rearma después del lift;
- sample cap de eraser conserva borrados aceptados, cierra contexto y suspende; duplicados hacen abort de ink y pending/block se suspenden; pass nunca se reclama;
- `on_contact_start`/`on_point`/`on_finish`/`on_contact_end` esperado fallido repara cuando corresponde, domina el owner del frame, marca end una vez y solicita release desde `afterFrame`, sin llegar al guard ni duplicar callbacks;
- nil/non-finite coordinates nunca llegan al host;
- cambio de lease/page/rotation limpia historia; suspend lógico no;
- lazy init usa constants del runtime actual;
- excepción de programación imprevista se propaga al guard exterior; errores de dominio esperados nunca lo hacen.

#### Mutation gate de la fase

Cada una de estas mutaciones manuales debe romper al menos un test:

- aceptar el primer sticky pair;
- aceptar X-only como geometría coherente;
- eliminar boundary `TOOL_FINGER`;
- aplicar boundary Wacom a todos los fingers;
- ignorar ID replacement;
- dejar que foreign lift cierre owner;
- retener `slot` en Diagnostics;
- hacer que proximity-out de un pass domine el lift del toolbar;
- ignorar el booleano de `dropContact`;
- eliminar el límite de puntos;
- lanzar un error esperado al guard fail-open;
- hacer `isLifecycleBlocked=false` durante suspended.

Ejecutar mutaciones sólo en un worktree/copia temporal de un commit limpio, nunca sobre la rama de implementación. Guardar una tabla `mutación → test que falló` y retirar el worktree temporal al terminar.

### Fase 3 — Migrar notebooks primero

**Modificar:**

- `ink_notebook_input.lua`;
- `notebook_input_spec.lua`;
- `notebook_session_spec.lua` cuando el gate de contacto lo requiera.

Pasos:

1. Preparar en `captureSpec` una factory lazy; instanciar la secuencia dentro del primer `stylus_handler`, después de que `Capture:installStylus` haya resuelto constants, `pen_slot` y `wacom_protocol`.
2. Mapear `stylus_passthrough`/papel a `pass`/`draw`.
3. Mapear `_beginInk`, `_continueInk`, `_finishInk` y `_discardLiveInk` a callbacks host.
4. Conservar `last_stylus_lift_time`, `control_guard`, contacts de dedo y residual en Adapter.
5. Reemplazar los campos duplicados `stylus_active`, `stylus_slot`, `stale_down`, etc. Sólo eliminarlos cuando todos sus usos estén migrados.
6. Hacer que `hasActiveContact` combine `sequence:isLifecycleBlocked()` con touch residual/finger; publicar por separado ink/forwarded para tests.
7. En abort/switch/resize, retirar un Contact forwarded y comprobar el resultado antes de resetear; reparar live ink y limpiar historia según la matriz de §8.
8. Si persistencia/cache falla al finish, reparar tinta, devolver `nil, reason` sin lanzar, dominar el frame y solicitar release diferido desde `afterFrame`; `queue_backpressure` sigue la recuperación automática de Fase 5.3.
9. Exponer desde Adapter `on_physical_contact_end(session, reason)` exactamente una vez por cada `sequence.on_contact_end`, independiente de `edit_pending`; mantenerlo como callback no-UI hasta que Fase 6 lo conecte.
10. Proteger la notificación next-tick por generation para que close/rotation no la entregue a otro editor.

**Acceptance notebook:**

- cada contacto válido produce exactamente un stroke;
- la lista completa de puntos nunca contiene el conector adversarial;
- Undo elimina sólo el último contacto físico;
- close/reopen reproduce la misma lista;
- rail/error/modal siguen alcanzables con lápiz;
- palma no abre hold sobre papel;
- edit callback corre después del reset; `on_physical_contact_end` corre también para pass/pending/block sin edición;
- rotation/session switch pending y active no dejan captura o raster vivo;
- active pass normal genera el tap; forced replacement limpia Contact o falla sin reclamar;
- modal/budget abort mantiene la palma suprimida y navegación/close responde `contact_active` hasta boundary;
- lazy init toma tools/pen slot de la adquisición actual.

### Fase 4 — Migrar tinta directa y canvas EPUB

**Modificar:**

- `main.lua`;
- `main_canvas_spec.lua`;
- tests de la máquina principal/pipeline;
- crear `tests/stylus_route_parity_spec.lua`;
- `tests/conformance.lua` para ciclos persistentes reales.

#### 4.1 Tinta directa

1. Reemplazar `onStylusEvent` por la delegación a la secuencia.
2. Mantener `InkCapture`, `InkInputController`, `onStylusTouchFrame`, suppression y store.
3. Mapear página/bar/dialog según §8; `on_point` devuelve explícitamente continue/finish_suspend/abort_suspend.
4. Conservar `startStroke`, `addPoint`, `endStroke`, `abortStroke` como callbacks de dominio.
5. Revalidar diálogo al lift antes de persistir el stroke.
6. Verificar dot, eraser, toolbar, dialog mid-stroke, Stop, callback error y lifecycle.

#### 4.2 EPUB

1. Usar la misma secuencia de main; no crear una tercera.
2. Inyectar `InkContactRouter` como policy geométrica.
3. Llamar `penContact(nil,nil)` al empezar la secuencia física, antes de geometría.
4. Llamar `penContact(x,y)` sólo al aceptar una posición.
5. Llamar `penUp()` desde `on_contact_end` una vez para lift, proximity-out, replacement o teardown físico. **No** llamarlo por modal, outside o budget abort mientras el stylus siga apoyado.
6. Mantener `routeCanvasTouch` y `routeCanvasFinger` fuera de la FSM de stylus.
7. Probar `canvas→reader→canvas`: termina una sola vez y no abre un segundo stroke; `reader→canvas` permanece block.
8. Probar que modal/budget abort conserva `router.pen_down` y sigue clasificando una palma sobre reader como palm hasta el boundary.

#### 4.3 Paridad

La misma tabla de replay debe ejecutarse contra:

- notebook: cache/queue y SQLite;
- tinta directa: lista en `InkStore`;
- EPUB: coordenadas lógicas, cache/queue y reopen.

Assertions mínimas:

- dos contactos → dos strokes;
- Undo elimina sólo el segundo;
- ningún punto híbrido;
- finger navigation sigue funcionando fuera del canvas;
- PDF no abre sesión canvas;
- error de dominio positivo mantiene el owner fuera de GestureDetector, filtra el residual, deja Capture inerte sólo después de `afterFrame` y lo retira en el siguiente tick; una excepción imprevista conserva el comportamiento fail-open del guard;
- active pass normal produce exactamente un tap en cada control;
- modal entre última muestra y lift no persiste tinta oculta;
- abort lógico no libera palm rejection antes del boundary;
- foreign positive/lift nunca altera owner.

Añadir ciclos con stores reales, no sólo grabadores:

- Canvas EPUB: dos contactos adversariales → commit → close repository → reopen → decode; exactamente dos strokes sin connector.
- Notebook: mismo ciclo mediante controller/surface SQLite real; reopen de página y Undo elimina sólo el segundo.
- Direct ink: ciclo save/reopen con LuaSettings real cuando esté disponible; como mínimo doc-settings fake completo más un claim real separado.

Extender `tests/conformance.lua` con `JUSTDRAW_CONFORMANCE_STRICT_STYLUS=1`. En modo normal `UNCHECKABLE` sigue siendo diagnóstico válido para runtimes antiguos; en modo strict cuenta como fallo sólo para el set explícito de claims requeridas: tool constants, `register/unregisterStylusCallback`, `routeStylusEvents`, `pen_slot`, slots persistentes y APIs per-slot de GestureDetector. Añadir un test del runner: runtime fake antiguo sale 0 en modo normal y distinto de 0 en strict; runtime moderno completo sale 0 en strict.

No eliminar el código duplicado antiguo hasta que estas pruebas pasen en las tres rutas. Después, buscar con `rg` los campos `stylus_active`, `stylus_stale_xy`, `stale_down`, `stylus_slot` y confirmar que no queda una FSM paralela accidental.

### Fase 5 — Acotar raster y persistencia en el hot path

Esta fase es independiente del boundary; no mezclar sus pruebas con la selección de geometry policy.

#### 5.1 Recortar el DDA y su dirty coverage antes de iterar

**Modificar:** `ink_render.lua`, `ink_canvas_cache.lua` y `main.lua` (`refreshBox`).
**Crear:** `tests/render_spec.lua`; ampliar el claim BlitBuffer de `tests/conformance.lua`.

Implementar un recorte numérico allocation-free contra:

```text
[-half, bb:getWidth()-1+half] × [-half, bb:getHeight()-1+half]
```

Usar `getWidth/getHeight`, no campos `.w/.h`, porque BlitBuffer puede estar rotado. `Render.segment` debe devolver cobertura efectiva como escalares (`painted, left, top, right, bottom`), no una tabla. La cobertura es half-open `[left,right) × [top,bottom)`: `painted=false` implica cuatro nil; de lo contrario `w=right-left` y `h=bottom-top`, ambos positivos. `Cache:drawSegment` y la ruta directa usan esa cobertura ya recortada; no vuelven a calcular dirty boxes desde endpoints corruptos.

Requisitos:

- early return para endpoints, width o dimensiones no finitos/inválidos y segmento totalmente fuera;
- volver a validar `dx`, `dy`, `steps` y bounds después de restas/intersección: dos números finitos como ±1e308 pueden producir infinito;
- si un nib finito es mayor que el viewport, pintar como máximo la intersección completa del viewport, sin pasar dimensiones absurdas a `paintRect`;
- preservar exactamente el loop actual cuando ambos extremos están dentro;
- para cruces, limitar los índices DDA al intervalo visible con un margen de una muestra;
- no modificar los puntos almacenados;
- no introducir tablas dentro de `Render.segment`;
- enrutar o validar también los branches `n==1` de `Render.stroke` y `Render.points`, que hoy no llaman `segment`.

Tests deterministas por contador/píxel:

- totalmente dentro: output idéntico al renderer de referencia;
- dot dentro/fuera y exactamente sobre cada uno de los cuatro bordes a través de `segment`, `stroke` y `points`;
- horizontal, vertical, diagonal y corners;
- widths pares/impares y nib mayor que viewport;
- ±`1e9` totalmente fuera: 0 `paintRect` y 0 refresh;
- cruce ±`1e9`: llamadas proporcionales al viewport+nib y dirty box dentro de pantalla;
- ±`1e308` y delta desbordado: fail-closed, trabajo/dirty acotados;
- real `Render.segment` sobre BlitBuffer no escribe fuera ni wrappea.

#### 5.2 Evitar la segunda rasterización al lift

**Modificar:**

- `ink_canvas_cache.lua`;
- `ink_surface_session.lua`;
- `ink_canvas_session.lua`;
- `ink_notebook_input.lua`;
- `main.lua` sólo en `endCanvasStroke`;
- specs de cache/surface/canvas/notebook.

Extender de forma compatible:

```text
Cache:addStroke(meta, points, n, opts)
SurfaceSession:addStroke(points, n, width, tool, opts)
CanvasSession:addStroke(points, n, width, tool, opts)
```

No usar un booleano desnudo. Capturar desde el primer `drawSegment`:

- identidad del objeto cache;
- `cache.generation`;
- un flag `live_raster_complete`.

Cada segmento posterior debe confirmar la misma cache/generation; si cambia durante el contacto, marcar el live raster incompleto. Al registrar, pasar `opts.raster_cache`, `opts.raster_generation` y `opts.live_raster_complete`. `Cache:addStroke` omite exclusivamente `_paintStroke` cuando sigue `ready`, la identidad/generation coinciden y el flag es true. En cualquier mismatch, rasteriza el stroke completo una sola vez.

Extender los retornos de forma compatible con escalares extra: cuando el registro sí pinta, `Cache:addStroke` devuelve además `painted, left, top, right, bottom` en coordenadas de cache; cuando omite, devuelve `false` y nils. `SurfaceSession:addStroke` y `CanvasSession:addStroke` propagan esos extras sin cambiar el primer retorno ID. Notebook `_finishInk` y `endCanvasStroke` consumen la cobertura sólo cuando habían suministrado un token vivo: blitean la cache actual y solicitan el refresh correspondiente en ese mismo frame. Si hay una ventana superior, no atraviesan el modal; conservan un repaint pendiente generation-safe para después de cerrarlo.

Siempre debe:

- registrar `meta` / `by_id`;
- indexar grid y live chunks;
- reconciliar local ID con row ID;
- mantener rollback si queue/cache falla.

Pasar el token sólo desde Notebook `_finishInk` y `endCanvasStroke`, después de probar que dot/segmentos se pintaron en esa misma generación. La llamada por defecto sigue pintando para reload, tests y callers programáticos.

Acceptance:

- misma cache/generation completa: delta `paintRect` al registrar = 0 para n=1 y n>1;
- live paint → rebuild/generation change → add con token viejo pinta exactamente una vez, propaga la cobertura y el host blitea/refresca toda esa región en el mismo frame;
- buffer antes/después del registro idéntico cuando se omite; los retornos son `painted=false` y coords nil;
- rebuild/reopen rasteriza el stroke una vez;
- undo/erase/markPersisted sin regresión;
- fallo de queue elimina la tinta viva mediante repair.

#### 5.3 Sacar el flush por umbral del callback y aplicar backpressure duro

**Modificar:** `ink_canvas_queue.lua`, `ink_surface_session.lua`, `canvas_queue_spec.lua`, `surface_session_spec.lua`, `tests/conformance.lua` y `tests/support.lua`.

El trigger `scheduleIn(0)` no es por sí solo una cota: varios callers síncronos podrían añadir más trabajo antes de bombear el loop. Implementar ambas capas:

1. **Trigger suave:** por debajo de umbral, `scheduleIn(0.25, action)`; al alcanzar ops/bytes, cancelar delayed y armar la misma closure estable con `scheduleIn(0, action)`.
2. **Admission ceiling:** comprobar antes de mutar `next_local/ops/bytes`:
   - `hard_ops = max_ops + 1`;
   - calcular bytes de insert con el chunking real: `chunks(n) = 1` para `n <= 1`; en otro caso `ceil((n - 1) / (Codec.MAX_POINTS - 1))`, y `encoded_bytes(n) = chunks * Codec.HEADER + 4 * (n + chunks - 1)` por los puntos seam repetidos;
   - `SurfaceSession`, que ya requiere Codec y `ink_limits`, inyecta siempre en producción una función escalar `estimate_insert_bytes(n)` y `max_single_op_bytes = encoded_bytes(Limits.MAX_OPEN_POINTS)`; Queue no adquiere dependencia con Codec/input y no posee otro default silencioso;
   - `hard_bytes = max_bytes + max_single_op_bytes`;
   - deletes siguen acotados por ops; una operación individual mayor o una admisión que cruce el hard ceiling devuelve `queue_backpressure`/`operation_too_large`, conserva la cola intacta y mantiene el urgent flush armado.
3. **Lifecycle:** `flush`, Retry, close, SaveSettings y gates suspend/navigation siguen síncronos/atómicos; no mantener transacciones abiertas entre ticks.

La closure estable conserva `scheduled_kind = delayed|urgent` y due time; al ejecutarse/cancelarse limpia timer/kind antes de actuar. Delayed→urgent siempre cancela por identidad antes de rearmar. Actualizar el comentario de cabecera de Queue: el umbral solicita commit en el próximo tick; no lo ejecuta en el callback.

Definir recuperación por clase de rechazo:

- `queue_backpressure` es transitorio y no pone `Queue.failed`. Notebook y canvas EPUB reparan la tinta viva, muestran una sola notificación generation-safe (`Stroke was not saved because the write queue is busy. Try again.`), cierran/rechazan sólo el efecto de tinta y dejan correr el urgent commit. Si el rechazo ocurrió mid-contact, la FSM queda `suspended`, mantiene ownership, `isLifecycleBlocked` y palm suppression; `on_contact_end` espera lift/proximity/replacement/teardown. Tras COMMIT exitoso el siguiente contacto físico funciona automáticamente, sin Retry manual ni reinstalar captura.
- `operation_too_large` no debería ser alcanzable con `ink_limits` coherente. Si aparece, reparar y tratarlo como error de dominio/configuración: desarme diferido después del frame; no marcar la cola como transaction-failed.
- sólo un fallo real dentro de la transacción activa `save_failed` y el flujo Retry existente.

Añadir un scheduler de test con reloj virtual, due-time, FIFO estable, identidad de action, `advance(seconds)` y `unschedule` real. El fake actual mete todo en una FIFO, ignora delay y no puede validar estas reglas.

Añadir clock monotónico inyectable a Queue y un único resumen `dbg` por transacción: ops, bytes estimados, elapsed_ms y success/failure. Nunca log por punto; los tests usan clock falso y no asertan wall time.

Acceptance:

- el op que cruza el soft threshold retorna antes de cualquier transaction;
- delayed se reemplaza por un único urgent action y un tick ejecuta una transaction;
- el constructor de producción de `SurfaceSession` sin overrides recibe `Limits.MAX_OPEN_POINTS`, estimator y hard ceiling no-nulos; los estimates para n=1/1.024/1.025/8.192 coinciden con la suma real de blobs, incluidos headers y seams;
- 100 adds síncronos nunca superan hard ops/bytes; los rechazados no mutan ids/ops/cache; un test queue→surface→adapter provoca `queue_backpressure` mid-contact, repara/notifica y ejecuta urgent COMMIT, pero conserva `isLifecycleBlocked=true` y 0 `on_contact_end` hasta lift; después acepta el siguiente stroke sin Retry;
- close/SaveSettings antes del tick cancela y hace durable;
- callback ya extraído que corre tras close/generation change es inocuo;
- fallo async conserva ops, marca `failed` y bloquea edición;
- local ID cruza la costura async: add retorna ID negativo, cache lo registra, tick COMMIT hace `markPersisted` y `Queue.real` queda vacío;
- Undo y close antes del tick conservan la semántica actual;
- ninguna llamada `addStroke/removeStroke` toca SQLite antes de retornar.

### Fase 6 — Política e-ink escalable para notebooks

**Modificar:**

- `ink_notebook_ui.lua`;
- `ink_notebook_editor.lua`;
- `notebook_editor_spec.lua`;
- `tests/support.lua` sólo si el scheduler virtual de Fase 5.3 aún no expone generation/cancelación;
- help/README en inglés.

#### 6.1 Respetar setting y kinds reales

Inyectar al Editor:

```lua
get_live_fast = function() return plugin.live_fast end
```

`Editor:onDirty` debe reconocer exactamente los kinds que ya produce el dominio:

| `kind` | `live_fast == true` | `live_fast == false` | Acumulador de calidad |
| --- | --- | --- | --- |
| `"ink"` | `fast` | `partial` | Añadir el dirty box sólo si se emitió `fast`. |
| `"erase"` | `fast` para conservar responsividad | `partial` | Añadir el dirty box si se emitió `fast`; la goma también deja residuos DU. |
| `"repair"` | `partial` inmediato | `partial` inmediato | Antes del repair, incluir cualquier unión fast pendiente en ese mismo partial y vaciarla. |
| `"undo"` | `partial` inmediato | `partial` inmediato | Igual que repair; no dejar un burst fast pendiente detrás de una operación destructiva. |

Conservar `UIManager:setDirty(nil, mode, exact_box)` para que KOReader sólo programe refresh regional y no repinte widgets. Normalizar/clipear cada box contra `paper_rect` antes de unirla o enviarla. Un dirty box vacío no incrementa counters.

Conectar `Adapter.on_physical_contact_end` → `NotebookUI` (validando editor generation) → `Editor:onPhysicalContactEnd(session, reason)`. Este método sólo actúa si `quality_waiting_for_contact_end` está activo: limpia el latch y arma exactamente un cleanup delayed/immediate según counters; si hay modal, transfiere al latch uncover. No depende de `edit_pending` ni de que cambie `can_undo`.

El getter se consulta en cada dirty/edit boundary; no copiar el setting al construir el editor. Transiciones en caliente:

- `true → false`: emitir primero un `partial` de la unión fast pendiente, cancelar su timer y luego entrar en modo partial;
- `false → true`: empezar un acumulador vacío; no reutilizar boxes antiguos.

#### 6.2 Cleanup regional O(1)

Cuando live fast está activo, acumular cuatro escalares y estado constante, nunca una lista:

```text
quality_min_x / quality_min_y / quality_max_x / quality_max_y
quality_strokes
quality_contact_had_fast_dirty
quality_waiting_for_contact_end
quality_waiting_for_uncover
quality_action         -- una closure estable
quality_scheduled_kind -- nil | delayed | immediate
quality_generation
```

Usar el scheduler virtual y la semántica de identidad definidos en Fase 5.3. La closure estable debe limpiar `quality_scheduled_kind` antes de hacer trabajo. Delayed→immediate cancela por identidad y rearma una sola vez.

Política inicial para gate físico:

1. Cada dirty `ink`/`erase` enviado como `fast` expande la unión.
2. `quality_strokes` incrementa **una vez por contacto completado** que produjo al menos un dirty fast, no por segmento ni por callback de edit repetido.
3. Al cerrar ese contacto, rearmar cleanup a 0,35 s de inactividad.
4. Si se acumulan 8 contactos o la unión alcanza 25% del área del papel, cancelar el delayed y armar el mismo action en el siguiente tick.
5. El callback valida editor, sesión, página, transform, cache y `quality_generation` antes de refrescar.
6. Si al vencer existe un contacto físico activo, limpiar sólo la marca del timer, conservar unión/counters y activar `quality_waiting_for_contact_end`. Mientras el latch esté activo, `onDirty` sólo expande la unión: no agenda otro delayed/immediate. El boundary físico limpia el latch y rearma exactamente una vez.
7. Si existe `Stack.above(self)`, no refrescar a través del modal: conservar la unión, activar `quality_waiting_for_uncover` y no rearmar por cada dirty. `_closeModal` rearma un cleanup inmediato una vez, salvo que haya solicitado/probado un repaint completo del papel que permita vaciar la unión.
8. Si sigue vigente, descubierto y sin contacto, emitir un único `partial` sobre la unión y limpiar acumulador/latches.
9. No pedir `full` manual; dejar que KOReader promueva partial según su contador.

Los defaults 0,35 s / 8 / 25% son constantes internas provisionales, no settings. La unión usa memoria O(1), pero su rectángulo puede acercarse al área completa del papel si strokes caen en esquinas opuestas. Medir ese peor caso en Scribe. Sólo si la medición muestra una pausa inaceptable considerar un número fijo pequeño de tiles (4–8); no introducir ahora una lista O(N).

Cancelar timer, incrementar generation y limpiar el acumulador en:

- page-ready o repaint completo **confirmado** que ya vuelve a dibujar el papel;
- resize/rotation;
- close/shutdown;
- cambio de sesión/página/cache/transform.

Un dirty actual descartado porque `Stack.above(self)` nunca llegó a `Screen.bb`, por lo que no se añade a la unión. Una unión fast anterior sí representa píxeles visibles y no se borra sólo porque apareció el modal. Se conserva sin timer hasta `_closeModal`, y entonces se limpia con un partial o con un repaint completo explícito. Si aparece save error, el partial de `repair` absorbe esa unión cuando sea visible. Nunca ejecutar un timer stale sobre otro editor ni punch-through sobre el modal. La llamada que marca el fin de contacto debe ocurrir antes del early return actual de `onEditChanged` basado en `can_undo`, porque dos strokes consecutivos pueden dejar ese booleano sin cambios.

Acceptance automatizada con reloj virtual:

- N dirty boxes no vacíos con fast on → N `fast` y exactamente 1 `partial` union al cerrar el burst;
- `quality_strokes` avanza una vez por contacto aunque tenga miles de segmentos;
- fast off → `partial` por dirty box y 0 cleanup extra;
- `erase` fast acumula cleanup; `repair` y `undo` hacen partial inmediato y absorben la unión previa;
- a t=0,349 s no hay cleanup y a t=0,350 s sí;
- vencimiento durante contacto emite 0 partial, activa el latch y cientos de dirty posteriores producen 0 schedules; cualquier boundary físico rearma exactamente una vez; stroke A → timeout durante tap pass sin edición → lift agenda un cleanup;
- delayed→immediate deja un solo action;
- cambio true→false limpia la unión una vez; false→true empieza vacío;
- ningún `setDirty(Editor, ...)` por muestra;
- boxes siempre quedan dentro de paper y una unión corner-to-corner sigue acotada;
- timer de ventana cerrada/rotada/generation anterior es inocuo;
- fast union previa → modal → timer/dirty no atraviesan el diálogo; al cerrar existe exactamente un partial/repaint que resuelve la unión;
- acumulador mantiene memoria O(1) con miles de contactos.

#### 6.3 Mutation gate de raster, queue y refresh

En el mismo worktree temporal limpio definido en Fase 2, cada mutación debe romper un test:

- reintroducir `_paintStroke` al registrar un live raster válido;
- aceptar el token con cache o generation distinta;
- quitar clipping DDA o volver a construir dirty box desde endpoints raw;
- volver a ejecutar flush SQLite síncrono desde `addStroke`;
- ignorar el hard admission ceiling;
- hardcodear `"fast"` en notebook;
- eliminar el partial cleanup;
- incrementar `quality_strokes` por segmento;
- permitir que un callback de generation anterior refresque el editor nuevo;
- eliminar `quality_waiting_for_contact_end` y volver a agendar por cada segmento.

Guardar en el artefacto de QA la tabla `mutación → test que falló`; no commitear ninguna mutación.

### Fase 7 — Documentación y ADR

**Modificar:**

- `spec.md`;
- `decisions.md` con `ADR-21 — Normalize stylus sequences before routing ink`;
- `requirements.md` si hace falta expresar el presupuesto;
- `README.md` y ayuda de Diagnostics/refresh.

Actualizar especialmente:

1. La tabla actual de `onStylusEvent` que describe el guard de un solo sticky pair.
2. La frase “once a frame has been dominated…” por la invariante correcta: pending puede dominar antes de entregar; después de entregar sólo se reclama tras `dropContact`.
3. ADR-17/18: la clasificación geométrica sigue por dominio, pero el boundary físico es compartido.
4. `TOOL_FINGER`: normalmente selecciona touch, salvo proximity-out Wacom estrecho y documentado.
5. Diagnostics también cubre notebooks y advierte sobre coordenadas locales.
6. `live_fast`: notebooks usan fast en vivo y un cleanup partial regional al cerrar un burst.
7. Known limits: la API no entrega presión, inclinación ni máscara X/Y; el gate físico sigue siendo obligatorio.

Todo texto de UI/documentación del producto debe quedar en inglés. Este plan puede estar en español; los strings implementados no.

## 10. Matriz de verificación

### 10.1 Gates Git y suites locales por fase

Antes y después de cada commit:

```sh
cd /Users/christianstenger/GitHub/justdraw
git status --short
git diff --check
lua test.lua

cd /Users/christianstenger/GitHub/justdraw/justdraw.koplugin
KOREADER_PLUGIN_DIR=/Users/christianstenger/GitHub/justdraw/justdraw.koplugin \
  /Users/christianstenger/.codex/skills/koreader-simulator-qa/scripts/koreader_qa.sh preflight
KOREADER_PLUGIN_DIR=/Users/christianstenger/GitHub/justdraw/justdraw.koplugin \
  /Users/christianstenger/.codex/skills/koreader-simulator-qa/scripts/koreader_qa.sh test
```

Después de preparar cada commit, ejecutar además `git diff --check --cached`. Los tres archivos nuevos críticos deben estar rastreados, no sólo presentes en disco:

```sh
git ls-files --error-unmatch justdraw.koplugin/ink_limits.lua
git ls-files --error-unmatch justdraw.koplugin/ink_stylus_sequence.lua
git ls-files --error-unmatch justdraw.koplugin/ink_stylus_trace.lua
git ls-files --error-unmatch justdraw.koplugin/tests/input_replay.lua
```

Aplicar el mismo gate a cualquier suite nueva. No fijar un total exacto de asserts: exigir 0 fallos, syntax sweep completo y que `tests/run.lua` cargue todas las suites añadidas.

### 10.2 Smoke y pruebas visibles locales

El comando automatizado existente sólo valida discovery/carga básica en FileManager y ausencia de traceback; no navega UI ni abre documentos:

```sh
cd /Users/christianstenger/GitHub/justdraw/justdraw.koplugin
KOREADER_PLUGIN_DIR=/Users/christianstenger/GitHub/justdraw/justdraw.koplugin \
KOREADER_SCREEN_WIDTH=1860 \
KOREADER_SCREEN_HEIGHT=2480 \
KOREADER_SCREEN_DPI=300 \
  /Users/christianstenger/.codex/skills/koreader-simulator-qa/scripts/koreader_qa.sh smoke default
```

Con SDL/display disponible, ejecutar además `koreader_qa.sh launch default` y recorrer manualmente library → notebook → editor, previous/next page, rail y modal. ReaderUI con EPUB y PDF requiere una prueba manual dirigida o ampliar explícitamente el runner para abrir esos documentos; no atribuir esos flujos a `smoke`. Stylus moderno, latencia y waveform nunca quedan validados por SDL.

En la inspección de planificación, el smoke/conformance headless no pudo completarse por indisponibilidad SDL. No marcarlo PASS hasta obtener una ejecución con display y log sin traceback.

### 10.3 Conformance en KOReader exacto

Preparar dos checkouts aislados y **compilados**, no sólo árboles fuente:

- estable `v2026.07.1` / `9192014d8bd82a91dc1012473be0f238dedfdb54`;
- desarrollo `60ce80ed1e6c0ad79a7e86be470dac1ac80960d2`, o el nuevo SHA resuelto/documentado el día de implementación.

Para cada checkout, ejecutar un gate mecánico equivalente al siguiente, sustituyendo rutas/expected sin dejar placeholders en el log final:

```sh
set -euo pipefail
CHECKOUT=/ruta/al/checkout-exacto
EXPECTED_SHA=9192014d8bd82a91dc1012473be0f238dedfdb54
PLUGIN=/Users/christianstenger/GitHub/justdraw/justdraw.koplugin
EPUB=/ruta/a/juliet.epub
PREFLIGHT_LOG=/tmp/justdraw-preflight-stable.log
CONFORMANCE_LOG=/tmp/justdraw-conformance-stable.log
QA=/Users/christianstenger/.codex/skills/koreader-simulator-qa/scripts/koreader_qa.sh

test "$(git -C "$CHECKOUT" rev-parse HEAD)" = "$EXPECTED_SHA"
KOREADER_REPO="$CHECKOUT" KOREADER_PLUGIN_DIR="$PLUGIN"   "$QA" preflight > "$PREFLIGHT_LOG"
RUNTIME=$(sed -n 's/^Selected runtime: //p' "$PREFLIGHT_LOG")
test -n "$RUNTIME"
EXPECTED_GIT_REV=$(git -C "$CHECKOUT" describe HEAD)
case "$EXPECTED_GIT_REV" in
  *-*) RELEASE_DATE=$(git -C "$CHECKOUT" show -s --format=%cs HEAD)
       EXPECTED_GIT_REV="${EXPECTED_GIT_REV}_${RELEASE_DATE}" ;;
esac
test "$(tr -d '\r\n' < "$RUNTIME/git-rev")" = "$EXPECTED_GIT_REV"

KOREADER_REPO="$CHECKOUT" KOREADER_PLUGIN_DIR="$PLUGIN" "$QA" test
KOREADER_REPO="$CHECKOUT" KOREADER_PLUGIN_DIR="$PLUGIN" "$QA" smoke default
cd "$RUNTIME"
JUSTDRAW_CONFORMANCE_STRICT_STYLUS=1   ./luajit "$PLUGIN/tests/conformance.lua" "$EPUB" > "$CONFORMANCE_LOG"
! rg -q '^MISMATCH' "$CONFORMANCE_LOG"
! rg -q '^UNCHECKABLE[[:space:]]+(Input exports|registerStylusCallback|routeStylusEvents|pen_slot|getMtSlot|GestureDetector)' "$CONFORMANCE_LOG"
```

El SHA completo se comprueba contra el checkout. Para `git-rev`, el gate replica el Makefile de KOReader: `git describe HEAD` en un tag completo y, si el describe contiene `-`, añade `_<fecha ISO del commit>`. `KOREADER_REPO` es obligatorio: el runner selecciona el runtime compilado dentro de ese checkout. Guardar `Selected runtime`, `Runtime revision` y ambos logs como evidencia.

El proceso debe salir distinto de cero si una claim strict está `UNCHECKABLE`, no sólo confiar en el `rg` posterior. Rechazar cualquier `MISMATCH`. Si el runtime no expone `registerStylusCallback`, no es el runtime correcto para cerrar esta tarea. El local `v2025.08-100-g1d66e440b` sirve sólo para frontend, raster y rutas legacy.

### 10.4 Gates automatizados de rendimiento e integridad

Estos criterios no dependen de habilidad manual ni se trasladan al Scribe:

- 8.193 muestras ink y 10.000 muestras sintéticas: vector nunca supera 8.192, no se guarda un stroke parcial y el siguiente contacto funciona;
- sample cap de eraser: conserva eliminaciones aceptadas y cierra una sola vez sin crecimiento posterior;
- registro con token cache/generation válido añade 0 `paintRect`; mismatch pinta una vez;
- segmentos ±1e9/±1e308 hacen trabajo proporcional al viewport y dirty boxes acotadas;
- estimates en límites de chunk coinciden con los blobs reales; 100 adds síncronos respetan hard ops/bytes y no llaman SQLite antes de retornar;
- virtual scheduler prueba 0,349/0,350 s, delayed→urgent, cancelación y callbacks stale;
- ciclos SQLite/LuaSettings reales hacen commit, close, reopen y preservan exactamente los boundaries.

Registrar máximos de points, samples, ops, bytes y elapsed de cada transacción desde los contadores/resúmenes de test; no inferirlos por vídeo.

Añadir un benchmark QA aislado tanto bajo Lua como LuaJIT: estabilizar con `collectgarbage("collect")`, medir `collectgarbage("count")` antes y después de construir 8.192 puntos, alimentar hasta 10.000 para probar que el abort no sigue creciendo y medir tras reset+GC. Registrar los deltas y la liberación; no fijar un umbral exacto frágil de memoria o tiempo en CI ni interpretar retención del allocator como un stroke vivo.

### 10.5 Matriz física Kindle Scribe

Registrar build KOReader, SHA del plugin y firmware. Para probar visualmente la notificación del cap usar sólo una build QA explícita y no-production con constructor override `max_open_points=8`; el límite de producción 8.192 no es un setting y queda cubierto por §10.4.

Ejecutar en notebook, tinta directa PDF y canvas EPUB, cubriendo:

- portrait y landscape;
- `live_fast` on/off;
- tema claro/oscuro si cambia waveform visible;
- pen y back eraser;
- palma en papel más finger en controles;
- rail/bar/handle/modal;
- 500 ciclos lift→nuevo down, incluidos saltos verticales grandes;
- dots repetidos y líneas H/V/diagonal largas legítimas;
- strokes en esquinas opuestas para medir un partial union casi de pantalla completa;
- Undo, close/reopen, suspend/resume y rotation mid-contact;
- fallo de guardado/retry si se puede inducir de forma segura.

Para cada artefacto:

1. screenshot KOReader;
2. fotografía física;
3. full refresh sin cerrar;
4. Undo una vez;
5. close/reopen;
6. conservar una traza Diagnostics corta y separada.

Criterios físicos de aceptación:

- 0 conectores, L o rectángulos persistidos en 500 secuencias;
- ningún stroke mezcla contactos según la traza;
- toolbar/rail siempre alcanzable;
- ninguna palma produce hold/page turn durante ink;
- no se pierde el comienzo perceptible de H/V/dots en la policy elegida;
- la build QA del cap avisa, repara y permite el siguiente contacto;
- cleanup no recorta tinta ni refresca el rail;
- partial corner-to-corner no produce una pausa inaceptable;
- no freeze perceptible entre lift y siguiente down;
- un full refresh elimina sólo ghosting; reopen reproduce sólo geometría válida.

Medir con vídeo de alta velocidad, comparando build anterior/nueva:

- pen-down → primer píxel;
- lift → disponibilidad del siguiente stroke;
- frecuencia/modo/área de refresh;
- ghosting antes/después del cleanup.

Las transacciones, delta de `paintRect`, caps y backpressure pertenecen al gate automatizado, no al vídeo físico.

## 11. Matriz de trazabilidad del análisis previo

| Hallazgo | Trabajo que lo cubre | Test/gate que impide perderlo |
| --- | --- | --- |
| Coordenadas híbridas crean L/rectángulos | Fases 1, 2 y gate de §7 | replay sticky/repeated/X→Y/Y→X; assert lista completa y dirty boxes prohibidas |
| Lift perdido une dos contactos | FSM owner + fallback Wacom + ID replacement | proximity-out, same fixed ID, late lift y Undo de dos contactos |
| Tracking ID fijo del Scribe no basta | estado `proximity_wait` y tool semantics | nuevo PEN mismo ID después de FINGER produce otro stroke |
| ID positivo nuevo en Type-B | split por ID | dos IDs en mismo slot → dos strokes |
| Lift de otro slot | ownership explícito | multi-slot frame no termina owner |
| Render no inventa strokes | paridad de point lists antes/después de cache/SQLite | reopen conserva exactamente strokes delimitados; ninguna ruta une dos |
| Stroke abierto ilimitado | caps 8.192 ink / 32.768 samples | 10k ink no supera cap ni persiste una fracción; eraser conserva borrados aceptados y se suspende al sample cap |
| Trabajo duplicado al lift | token cache/generation/live-raster | contador `paintRect` delta 0 sólo con token vigente; mismatch repinta una vez |
| DDA O(distancia corrupta) | clip antes del loop | ±1e9 acotado por viewport |
| Flush SQLite dentro del lift | scheduler estable + hard admission ceiling | 0 transactions antes de retornar; 1 tras tick; 100 adds no exceden ops/bytes |
| Notebook fuerza fast | `get_live_fast` + modes por kind | fast/partial según setting |
| Ghosting/rectángulos e-ink | acumulador O(1) + partial cleanup generation-safe | unión, timer virtual, setting transitions, cancelación y gate físico screenshot/full refresh |
| Diagnostics no observa notebook | trace compartida | fuente notebook presente; decisión post-transition |
| Tests llamaban handlers aislados | `input_replay.lua` | pipeline route→filter→GestureDetector obligatorio |
| Slot table mutable | snapshot escalar | mutación posterior no cambia FSM/trace |
| `timev` ignorado | trace/delta seguro, no boundary inicial | nil/repeated/regressive; no comparación con `time.now()` |
| Callback singleton/error dentro del frame | conservar Capture/lease | error con varios slots: inert now, remove next tick |
| Palm/toolbar reachability | delivery latch + `dropContact` | timers/contact map vacíos y tap llega a control |
| Error de dominio esperado en callback | `pending_domain_error` + release desde `afterFrame` | owner no llega a GestureDetector; residual filtrado; unhook next tick; finish/end una vez |
| Dot sólo coherente al boundary | `geometry:onLift` | dot draw de un punto o descarte explícito; nunca segmento desde candidatos stale |
| Cambio cache/generation mid-contact | token validado + cobertura fallback | pinta una vez, propaga box y blit/refresh ocurre en el mismo frame válido |
| Backpressure antes de bombear UI | hard ceiling + recuperación transitoria | reparación/notificación, urgent COMMIT y siguiente stroke sin Retry |
| Modal durante fast cleanup | latches contact/uncover | cero punch-through y un cleanup/repaint al descubrir |
| Passthrough sin edición termina durante cleanup | callback físico Adapter→UI→Editor | tap pass/lift rearma exactamente un cleanup aunque `edit_pending=false` |
| Persistencia no es origen | no schema/codec changes | conformance SQLite/sidecar sin migraciones |
| Regresión raw Wacom de KOReader | registrar revisión y actualizar | gate rechaza builds afectadas antes de atribuir fallo al plugin |

## 12. Riesgos y mitigaciones

| Riesgo | Severidad | Mitigación |
| --- | --- | --- |
| La API no distingue eje fresco de sticky | Crítica | Diagnostics primero; policy trace-backed; stop/upstream si es indeterminable. |
| Una transición true/false deja Contact/timer | Crítica | delivery explícita, `dropContact` antes de reclaim y pipeline tests reales. |
| Un error esperado cae al guard fail-open | Crítica | no lanzar errores de dominio; dominar owner, filtrar frame y release desde `afterFrame`. |
| Rebuild mid-contact pinta cache pero no pantalla | Mayor | retornar cobertura fallback y obligar blit/refresh generation-safe. |
| Fallback `TOOL_FINGER` aplicado a touch normal | Mayor | guard triple Wacom + pen_slot + owner; test non-Wacom. |
| Nuevo módulo cambia tres dominios a la vez | Mayor | migración notebook→direct→EPUB, tests de paridad y commits separados. |
| Cap descarta un stroke ink legítimo muy largo | Mayor pero fail-safe | límite alto, mensaje visible, reparación y gate físico; ink no persiste una fracción. Eraser conserva sólo borrados ya aceptados porque no existe rollback transaccional del gesto completo. |
| Flush async amplía la ventana hasta el siguiente tick | Moderada | hard admission ceiling, lifecycle flush síncrono, ninguna transacción abierta y tests close/SaveSettings. |
| Backpressure transitorio bloquea edición como save failure | Mayor | clase separada, repair+notificación, urgent COMMIT y recuperación automática. |
| Cleanup reprograma por cada muestra o cruza modal | Mayor | latches O(1) por contact/uncover, timer estable y pruebas con miles de dirty. |
| Partial cleanup introduce latencia | Mayor en Scribe | idle/budget O(1), no full manual, A/B físico y ajuste sólo de constantes/policy. |
| Diagnostics revela forma de escritura | Privacidad | opt-in, warning, 60 s/8.192 eventos, sesiones cortas separadas, local y sin upload/metadata de documento. |
| Rename untracked oculta el diff | Mayor de revisión | baseline limpio y SHA antes de implementar; no reescribir historia. |
| Local KOReader antiguo da falsa confianza | Mayor | gate exacto `v2026.07.1` + Scribe; local sólo para frontend. |

## 13. Stop conditions

Detener implementación o merge si ocurre cualquiera:

1. El rename no está trackeado y no hay SHA base auditable.
2. La policy geométrica requiere adivinar N muestras, distancia o tiempo sin traza física.
3. El Scribe reparte X/Y de forma variable y el callback no permite probar frescura.
4. Se propone leer evdev raw o parchear core KOReader dentro del plugin.
5. Un contacto ya forwarded se domina sin probar que aún no llegó a GestureDetector o sin que `dropContact` haya devuelto `true`. El proximity-out normal de `active_pass` debe seguir entregándose hasta su lift tardío.
6. Queda un Contact o `pending_hold_timer` después del lift final, drop exitoso, replacement completado o teardown que sí logró retirarlo. `forwarded_wait_lift`, y la retención tras teardown precedido por drop fallido, son estados esperados sólo hasta el lift físico.
7. Se desregistra el callback dentro de `routeStylusEvents`.
8. La nueva FSM/Diagnostics añade tablas, strings de log o un segundo `pcall` por punto cuando Diagnostics está apagado.
9. El cap de ink divide silenciosamente o persiste una fracción. Para eraser, los borrados ya aceptados deben quedar explícitamente conservados y el contexto debe cerrarse una sola vez.
10. Aparecen cambios de schema, codec, repository, anchors o sidecar.
11. El finger backend cambia conducta fuera de tests de regresión.
12. La queue mantiene una transacción SQLite abierta entre ticks, acepta más allá del hard ceiling o muta IDs/ops al rechazar.
13. Se omite raster por un booleano sin validar cache identity, generation y completitud viva.
14. El cleanup requiere full por stroke, ejecuta un timer stale, entra en rearmado continuo durante contacto o bloquea perceptiblemente el siguiente down.
15. `router:penUp()` se llama por un fin lógico mientras el contacto físico sigue apoyado.
16. Diagnostics no puede activarse desde el notebook fullscreen o retiene metadata/contenido no permitido.
17. El replay de integración evita `InkCapture`, llama dos veces el frame handler o no modela dirty slots por SYN.
18. Los módulos/suites nuevos no aparecen en `git ls-files` y el diff preparado no es auditable.
19. Un error de dominio esperado se lanza al guard fail-open, o `on_contact_end` puede repetirse tras fallo.
20. `isLifecycleBlocked()` devuelve false en pending/block/suspended mientras el contacto sigue apoyado.
21. Un fallback de raster pinta cache sin propagar/blitear su cobertura.
22. `queue_backpressure` exige Retry manual o marca `Queue.failed` sin fallo transaccional.
23. El cleanup agenda repetidamente durante contacto/modal en vez de usar latches, o depende de `on_edit_changed` y queda varado tras un pass sin edición.
24. El modo conformance strict puede salir 0 con una claim stylus requerida `UNCHECKABLE`.
25. La ruta stylus queda `UNCHECKABLE` en KOReader exacto.
26. No se completa el gate físico Scribe.

## 14. Estrategia de commits

No reescribir ni reorganizar los commits anteriores. Sobre la nueva rama:

1. `test(input): add persistent-slot replay and bounded stylus tracing`
2. `fix(input): normalize stylus contact ownership and Wacom boundaries`
3. `fix(input): route notebook direct and EPUB ink through shared sequence`
4. `perf(ink): bound raster work and defer threshold persistence`
5. `fix(notebooks): honor e-ink refresh policy and clean fast ink`
6. `docs(input): record stylus sequence invariants and hardware gate`

Cada commit debe pasar la suite. Si la traza obliga a detener la geometry policy, el primer commit de observabilidad puede entregarse por separado; no etiquetar el defecto como resuelto.

## 15. Desviaciones deliberadas respecto al análisis inicial

1. **Se comparte sólo la normalización física.** No se fusionan adapters, routers, widgets ni persistencia.
2. **La invariante no es “una vez dominado, siempre dominado”.** Pending puede consumir frames preliminares y luego entregar el primer down coherente; después de forwarded sólo se reclama tras `dropContact`.
3. **`timev` no define lift/frescura por sí solo.** Se registra y sólo se usa en deltas si la traza valida una política combinada.
4. **No hay umbral de distancia inicial.** Una línea larga puede ser legítima.
5. **El budget de ink aborta; no divide.** Preserva Undo y evita I/O mid-contact. El sample cap de eraser conserva los borrados ya aceptados, porque no existe una reparación equivalente del gesto completo.
6. **El cap inicial es 8.192, no 16.384.** Mantiene una operación muy por debajo de 64 KiB y reduce memoria Lua; no crea una dependencia con Codec.
7. **No se añade checksum/migración.** La persistencia vuelve permanente un stroke malo, pero no origina el boundary incorrecto.
8. **El refresh de calidad es regional y diferido.** No se fuerza full ni se altera todavía la ruta directa PDF ya probada en hardware.

## 16. Registro de validación documental

### Tema: revisiones estable y desarrollo

- **Por qué:** las APIs de KOReader y su comportamiento pueden cambiar.
- **Fuente:** [release oficial `v2026.07.1`](https://github.com/koreader/koreader/releases/tag/v2026.07.1), tag dereferenciado a [`9192014d…`](https://github.com/koreader/koreader/tree/9192014d8bd82a91dc1012473be0f238dedfdb54), y desarrollo [`60ce80ed…`](https://github.com/koreader/koreader/tree/60ce80ed1e6c0ad79a7e86be470dac1ac80960d2).
- **Verificado:** stable/base `6e4bc81…`; dev/base `9f9b6640…`; contratos relevantes equivalentes en ambas revisiones.
- **Disponibilidad:** refs resueltas y contenido real leído el 2026-08-27 mediante Firecrawl, no desde snippets.
- **Impacto:** pin de fuentes y gate doble stable/dev.
- **Confianza:** alta.

### Tema: contrato y orden del callback de stylus

- **Por qué:** la FSM depende de qué recibe y cuándo puede dominar un evento.
- **Fuente:** [KOReader `device.input` estable, callback y routing](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/input.lua#L460-L518) y [documentación generada oficial](https://koreader.rocks/doc/modules/device.input.html).
- **Verificado:** callback `{slot,id,x,y,tool,timev}`; se ejecuta antes de GestureDetector; `true` retira sólo ese slot; el callback es singleton.
- **Disponibilidad:** API moderna en KOReader `v2026.07+`; runtime local `v2025.08` no sirve para este gate.
- **Impacto:** delivery state, coexistencia y pipeline de replay.
- **Confianza:** alta.

### Tema: slots persistentes y ejes actualizados independientemente

- **Por qué:** es la causa de coordenadas híbridas.
- **Fuente:** [actualización de eventos/ejes](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/input.lua#L1051-L1097) y [construcción/reutilización de slots](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/input.lua#L1381-L1446).
- **Verificado:** KOReader conserva campos del slot y sólo reemplaza el campo asociado al evento recibido; el callback no recibe changed-mask.
- **Disponibilidad:** comportamiento equivalente en stable y dev revisados.
- **Impacto:** geometry pending, snapshot escalar, trace gate y prohibición de heurísticas fijas.
- **Confianza:** alta sobre el defecto del plugin; media-alta sobre el desencadenante físico hasta traza Scribe.

### Tema: protocolo Wacom y Kindle Scribe

- **Por qué:** `TOOL_FINGER` con ID positivo y el ID fijo del pen slot afectan boundaries.
- **Fuente:** [traducción Wacom oficial](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/input.lua#L707-L791) y [definición Scribe](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/kindle/device.lua#L1829-L1889).
- **Verificado:** BTN_TOUCH down asigna `pen_slot`, up asigna `-1`; TOOL PEN/RUBBER out cambia tool a FINGER sin forzar ID; Scribe activa `wacom_protocol`.
- **Disponibilidad:** stable/dev revisados.
- **Impacto:** fallback estrecho, same-ID generation y tool retention.
- **Confianza:** alta.

### Tema: tracking ID Type-B

- **Por qué:** otros dispositivos pueden usar IDs positivos nuevos para contactos nuevos.
- **Fuente:** [Linux Multi-touch Protocol](https://docs.kernel.org/input/multi-touch-protocol.html) y [event codes](https://docs.kernel.org/input/event-codes.html).
- **Verificado:** tracking ID identifica el contacto en un slot; `-1` marca su fin en protocolo Type-B.
- **Disponibilidad:** contrato kernel, no específico de KOReader.
- **Impacto:** split por ID para no-Wacom sin asumir que resuelve el ID fijo del Scribe.
- **Confianza:** alta.

### Tema: `timev` y FTS

- **Por qué:** evitar mezclar clocks o tratar el timestamp como indicador mágico de frescura.
- **Fuente:** [KOReader `ui/time.lua`](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/time.lua) y escritura de `timev` en `device/input.lua`.
- **Verificado:** `timev` se deriva con `time.timeval(ev.time)` y usa fixed-point time; las restas entre valores compatibles son válidas.
- **Disponibilidad:** stable/dev; el origen concreto del clock del evento puede variar por backend.
- **Impacto:** usar sólo deltas internos inicialmente; manejar nil/repeated/regressive; no comparar con `time.now()`.
- **Confianza:** alta.

### Tema: scheduling seguro fuera del callback

- **Por qué:** sacar SQLite del lift sin perder cancelación/lifecycle.
- **Fuente:** [KOReader `UIManager:scheduleIn`, `nextTick` y `unschedule`](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/uimanager.lua#L335-L448).
- **Verificado:** next tick equivale a schedule con delay 0; `unschedule` identifica la función programada.
- **Disponibilidad:** stable/dev revisados.
- **Impacto:** queue threshold programa el mismo callback a 0 y conserva flush lifecycle síncrono.
- **Confianza:** alta.

### Tema: `setDirty(nil, ...)` y modos de refresh

- **Por qué:** el editor blitea manualmente y no debe repintar widgets por muestra.
- **Fuente:** [KOReader UIManager estable](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/uimanager.lua#L1059-L1175) y [documentación oficial](https://koreader.rocks/doc/modules/ui.uimanager.html).
- **Verificado:** `nil` encola refresh sin paint de widget; fast es baja fidelidad y no incrementa el contador de promoción; partial sí participa en promociones periódicas.
- **Disponibilidad:** stable/dev conservan el contrato; flags de scrolling/avoid flashing pueden modificar la decisión efectiva.
- **Impacto:** fast live, partial cleanup, no full manual y tests por modo/región.
- **Confianza:** alta en scheduling; media en percepción física hasta Scribe.

### Tema: waveforms MTK del Scribe

- **Por qué:** distinguir geometría persistida de ghosting/rectángulos del panel.
- **Fuente:** [koreader-base estable `framebuffer_mxcfb.lua`](https://github.com/koreader/koreader-base/blob/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/framebuffer_mxcfb.lua#L586-L621) y [mapeo de modos MTK](https://github.com/koreader/koreader-base/blob/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/framebuffer_mxcfb.lua#L829-L914).
- **Verificado:** fast se asocia típicamente con DU/monochrome y partial con una waveform de mayor fidelidad en MTK; el backend contiene lógica para evitar upgrades silenciosos del driver.
- **Disponibilidad:** depende de backend/firmware/dispositivo real.
- **Impacto:** política regional y gate screenshot/full refresh/reopen.
- **Confianza:** alta en código; media en aspecto/latencia física.

### Tema: regresión reciente de Wacom raw

- **Por qué:** no atribuir al plugin una regresión temporal de KOReader.
- **Fuente:** [issue oficial #15164](https://github.com/koreader/koreader/issues/15164) y [revert oficial `c6f6e75`](https://github.com/koreader/koreader/commit/c6f6e75).
- **Verificado:** hubo una regresión al habilitar eventos Wacom raw y el cambio se revirtió.
- **Disponibilidad:** registrar la revisión exacta instalada; actualizar antes de comparar si pertenece al intervalo afectado.
- **Impacto:** precondición del gate físico.
- **Confianza:** alta.

## 17. Definición de terminado

El trabajo no está terminado cuando “los tests pasan”. Está terminado sólo cuando:

1. el rename es base Git auditable;
2. existe replay persistente per-SYN;
3. Diagnostics captura notebook/direct/EPUB con decisiones post-state;
4. una traza Scribe seleccionó o bloqueó explícitamente la geometry policy;
5. las tres rutas usan una sola normalización física;
6. slot/ID/proximity/foreign lift/passthrough cumplen invariantes;
7. memoria, DDA, queue y SQLite tienen caps/admission y trabajo acotado incluso antes de bombear el event loop;
8. notebook respeta fast/partial y limpia bursts sin repintar UI;
9. suites Lua/LuaJIT, conformance strict exacta y smoke pasan; ninguna claim stylus requerida queda UNCHECKABLE;
10. el gate físico cumple los criterios de §10.5;
11. cada fila de §11 tiene test o evidencia asociada;
12. docs/ADR describen lo implementado, no lo planeado.
