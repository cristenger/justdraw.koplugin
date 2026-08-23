# Plan de remediación: backend de stylus de FingerInk

> **Para ejecutores automáticos:** SUB-SKILL OBLIGATORIA: usar
> `superpowers:subagent-driven-development` (recomendado) o
> `superpowers:executing-plans` para implementar tarea por tarea. Los pasos
> usan casillas (`- [ ]`) para seguimiento.

Fecha: 2026-08-23
Fase: **planificación e investigación**. Este documento no se acompaña de
ningún cambio de código.
Feature ID: `FI-SCRIBE-STYLUS-002`
Base: rama `codex/kindle-scribe-stylus`, commit `8df4eb2`, árbol limpio
Plan predecesor / spec: [`kindle-scribe-stylus-dev-plan-2026-08-23.md`](kindle-scribe-stylus-dev-plan-2026-08-23.md)

**Objetivo:** cerrar los cinco defectos confirmados que quedaron abiertos tras
la implementación y la revisión de tres agentes, corregir el fallo de fidelidad
del arnés de tests que los ocultaba, y dejar el gate físico de Scribe listo para
ejecutarse en una sola sesión de hardware.

**Arquitectura:** dos etapas separables. La Etapa 1 son arreglos quirúrgicos
sobre la arquitectura actual, sin cambio de diseño. La Etapa 2 mueve la
*supresión* de entrada residual del array de retorno de `feedEvent` a la capa de
widgets (`InkBar:onGesture`), donde KOReader entrega **todos** los gestos —
incluidos los que nacen de temporizadores — ya rotados y con posición. La Etapa 2
va tras un spike con criterio de aceptación explícito y en commit propio,
revertible.

**Stack:** plugin KOReader en Lua/LuaJIT; suite propia sin dependencias.

---

## Restricciones globales

Heredadas del plan predecesor; se aplican a **todas** las tareas.

- KOReader mínimo documentado para stylus: **v2026.07**. Ruta de dedo: v2026.03.
- **No modificar ningún archivo del core de KOReader.**
- **No cambiar el formato persistido** `fingerink_strokes`.
- No tocar: `ink_render.lua`, `ink_store.lua`, `demo.mp4`, el checkout
  `/Users/christianstenger/koreader/koreader` ni sus plugins instalados, ni la
  rama `upstream/claude/pdf-ink-annotations`.
- **Enmienda al §6.6 del plan predecesor:** la Etapa 2 sí modifica
  `ink_bar.lua`. El §6.6 lo permitía sólo "si un test revela una regresión
  real"; aquí se toca por diseño. **Requiere aprobación explícita del autor
  antes de empezar la Etapa 2** (ver la puerta de decisión en §4).
- Los commits **no** llevan firmas de autoría de Anthropic/Claude: ni
  `Co-Authored-By`, ni líneas "Generated with Claude Code".
- Logging (§13 del plan predecesor): conservar logs de transición, nunca
  registrar cada coordenada indefinidamente, y **nunca** incluir rutas de
  archivo, títulos ni ningún dato de los libros del usuario.
- Cada commit deja la suite en verde.
- Rama: continuar en `codex/kindle-scribe-stylus`, un commit por tarea.

---

## 1. Problemas observados

Severidad, cómo se confirmó cada uno, y la fuente. Nada aquí es una sospecha:
R1, R4 y R5 se reprodujeron ejecutando el plugin real contra el arnés; R2, R3 y
R9 se verificaron leyendo el código de KOReader en el tag **v2026.07**.

| # | Severidad | Problema | Confirmación |
| --- | --- | --- | --- |
| **R1** | Alta | **Ruta stylus: una palma apoyada deja la barra inalcanzable con el dedo.** `touch_geom_latched` es un booleano por *secuencia*, no por *slot*: el primer contacto residual decide por todos. Con una palma fuera de la barra ya apoyada, un dedo que pulsa **Stop** se traga. Como "pulsa Stop para volver a leer" es la única salida del modo stylus, es un bloqueo parcial (el lápiz sí alcanza la barra). | Reproducido: probe sobre el pipeline real → el frame del dedo sobre la barra emite **0** gestos. `main.lua:646` |
| **R2** | Media | **Ruta dedo: un dedo quieto sigue disparando `hold`.** El temporizador de hold se registra en `Contact:handleNonTap` y su gesto se devuelve **directamente desde `Input:waitEvent`**, sin pasar por `feedEvent`. Vaciar el array de retorno no puede detenerlo. Con doble tap habilitado, el `tap` diferido se escapa igual. | Código v2026.07: [gesturedetector.lua:675](https://github.com/koreader/koreader/blob/v2026.07/frontend/device/gesturedetector.lua#L675), [input.lua:1584](https://github.com/koreader/koreader/blob/v2026.07/frontend/device/input.lua#L1584). `disable_double_tap = true` por defecto ([input.lua:166](https://github.com/koreader/koreader/blob/v2026.07/frontend/device/input.lua#L166)), así que el `tap` diferido sólo afecta a quien active doble tap. Documentado hoy como límite conocido en `README.md`. |
| **R3** | Media | **Ruta stylus: el gesto de una palma simultánea se escapa con el tap del lápiz sobre la barra.** La decisión de emitir es por frame; los gestos llevan `pos` pero no `slot`. | Documentado en `README.md` y cubierto por test. Origen: `main.lua:620-663`. |
| **R4** | Baja | **`stylus_frame_ui` sobrevive a un desarme por error.** Si un handler levanta a mitad de frame, la bandera queda en `true`, `resetStylusState` no la limpia, y el primer frame táctil residual tras reanudar el dibujo deja salir sus gestos. | Reproducido: probe → tras `Capture:fail`, `stylus_frame_ui == true`; el primer frame de palma tras reiniciar emite **1** gesto. `main.lua:355-362` |
| **R5** | Baja | **Un punto del lápiz colocado exactamente donde se levantó el anterior se pierde en silencio.** Falso positivo de la heurística de coordenadas rancias: se descarta el frame de contact-down y, si la secuencia es sólo down+lift, no queda nada que guardar. | Reproducido: probe → dos puntos en (400,400) producen **1** trazo almacenado. `main.lua:528-530` |
| **R9** | Alta (tests) | **El arnés propaga los eventos de widget al revés que KOReader.** El stub llama a su propio handler *antes* que a los hijos; el `WidgetContainer` real llama a los hijos primero. Es decir: en el arnés `InkBar:onGesture` se traga el tap antes de que ningún `Button` lo vea, y en el dispositivo pasa lo contrario. Los tests de `ink_bar` pasan por la razón equivocada, y ninguno prueba que un botón llegue a dispararse. | Código v2026.07: [widgetcontainer.lua](https://github.com/koreader/koreader/blob/v2026.07/frontend/ui/widget/container/widgetcontainer.lua) `handleEvent` → `propagateEvent` (hijos) → `Widget.handleEvent` (propio). Stub invertido en `tests/support.lua:265-277`. |
| **R6** | Bloqueante | **La Fase 6 (gate físico en Kindle Scribe) sigue sin ejecutarse.** La Definición de Terminado la exige. Nada verificado localmente cubre Wacom real, ghosting, latencia ni firmware Kindle. Además arrastra la pregunta abierta §0.3: si el kernel del Scribe emite `BTN_STYLUS`. | §9 y §14 del plan predecesor. |
| **R7** | Media | **No hay CI: la suite sólo corre si alguien la ejecuta a mano.** | Verificado: la suite ya corre bajo Lua 5.5 del sistema con **254 pasadas / 1 fallo**, y el único fallo es el global `unpack` en `tests/support.lua:268`. Un shim de una línea la hace portable a CI sin KOReader. |
| **R8** | Media | **La ruta de stylus nunca se ha ejecutado contra código real de KOReader.** El runtime local es v2025.08 y no tiene `registerStylusCallback`; todo lo que valida la ruta de lápiz son stubs escritos por nosotros. | `frontend/version.lua` del checkout local: `v2025.08-100-g1d66e440b`. |

### 1.1 Lo que NO es un problema

Comprobado durante esta investigación y descartado, para que nadie lo vuelva a
mirar:

- **`feedEvent` siempre se llama tras `routeStylusEvents`**, incluso si el
  frame se queda sin slots. Las cinco variantes de `handleTouchEv` lo hacen sin
  condición ([input.lua:1085-1087](https://github.com/koreader/koreader/blob/v2026.07/frontend/device/input.lua#L1085), y las variantes Snow/Phoenix/Legacy/mixta).
  Así que `stylus_frame_ui` no puede quedarse colgado *durante la operación
  normal*; sólo por la vía de error de R4.
- **Todos los gestos táctiles llevan `pos`** (`tap`, `hold`, `pan`, `swipe`,
  `multiswipe`, y las variantes de dos dedos), y llegan al widget **ya
  ajustados por rotación** vía `adjustGesCoordinate`. La Etapa 2 no necesita
  ninguna transformación de coordenadas propia.

---

## 2. Diagnóstico de fondo

R1, R2 y R3 son el mismo error de diseño con tres caras: **el punto de
supresión está equivocado.**

Suprimir vaciando el array que devuelve `feedEvent` tiene tres consecuencias
que ya se han cobrado un bug crítico y cuatro más:

1. **Es ciego a los gestos nacidos de temporizadores** (`hold`, `tap`
   diferido). Salen por `Input:waitEvent` sin tocar `feedEvent` → R2. El
   parche actual, `dropContact`, funciona pero es destructivo: mata el estado
   del contacto en GestureDetector, por eso la ruta de dedo no puede usarlo sin
   romper ADR-2.
2. **Es todo-o-nada por frame.** Los gestos llevan posición, pero la decisión
   se toma antes de que existan → R3.
3. **Obliga al plugin a duplicar la contabilidad de contactos** de
   GestureDetector para reconstruir qué está pasando. Cada bug de esa
   contabilidad es un bug de comportamiento: R1 es exactamente eso, y el bug
   crítico que encontró la revisión (`stylus_frame_ui`) también.

El punto correcto ya existe y ya está en el repositorio. `InkBar` es el widget
más alto de la pila y **ya tiene `onGesture`**; `UIManager:sendEvent` ofrece
cada evento de entrada al widget no-toast más alto y **se detiene si devuelve
true** ([uimanager.lua:884-910](https://github.com/koreader/koreader/blob/v2026.07/frontend/ui/uimanager.lua#L884)),
y los gestos de temporizador entran por el mismo camino
(`handleInputEvent` → `event_handlers.__default__` → `sendEvent`,
[uimanager.lua:52](https://github.com/koreader/koreader/blob/v2026.07/frontend/ui/uimanager.lua#L52)).

Supresión en esa capa = por gesto, con posición exacta, cubriendo la vía de
temporizador, y sin tocar el estado interno de GestureDetector. Eso es R2 y R3
resueltos de una vez, `dropSuppressedContacts` borrado, y la contabilidad de
contactos de `onStylusTouchFrame` reducida o eliminada.

**Lo que la Etapa 2 no cambia:** la captura sigue donde está. `feedEvent` es el
único sitio donde se ven coordenadas de contacto crudas, y los gestos son
demasiado gruesos para dibujar con ellos. La separación queda: la capa de
captura decide *si este contacto entinta*; la capa de widget decide *si este
gesto llega a la aplicación*.

**Riesgo principal de la Etapa 2:** si la barra no es el widget más alto, la
supresión desaparece en silencio. Hoy el invariante "dibujar implica barra
visible" ya se mantiene (`setBarShown(false)` llama a `setDrawing(false)`), pero
la Etapa 2 lo convierte en requisito de seguridad, no de UX. Ver T7.

---

## 3. Estructura de archivos

| Archivo | Estado | Responsabilidad tras el cambio |
| --- | --- | --- |
| `fingerink.koplugin/main.lua` | Modificar | Etapa 1: latch por slot, reset de bandera, recuperación del punto perdido, diagnóstico. Etapa 2: `onStylusTouchFrame` se reduce a contabilidad de contactos |
| `fingerink.koplugin/ink_bar.lua` | Modificar (**sólo Etapa 2**) | Pasa a ser el filtro de gestos: decide qué llega a la aplicación mientras se dibuja |
| `fingerink.koplugin/ink_capture.lua` | Modificar (**sólo Etapa 2**) | Pierde `dropSuppressedContacts` y `drop_suppressed` |
| `fingerink.koplugin/tests/support.lua` | Modificar | Orden de propagación correcto, shim `unpack`, `_window_stack` real, `sendEvent` fiel, `Button` que registra recepción |
| `fingerink.koplugin/tests/run.lua` | Modificar | Tests nuevos por cada R; los de `touch_geom_latched` pasan a nivel de comportamiento |
| `fingerink.koplugin/tests/conformance.lua` | **Crear** | Sonda que contrasta las suposiciones del arnés contra el `Device` real del runtime que haya |
| `.github/workflows/tests.yml` | **Crear** | CI: LuaJIT, suite + barrido de sintaxis |
| `README.md` | Modificar | Retirar los límites que dejen de ser ciertos; añadir el modo diagnóstico |
| `spec.md` | Modificar | Documentar la capa de supresión que quede |
| `decisions.md` | Modificar | ADR-13; ADR-11 marcado *superseded in part* si entra la Etapa 2 |
| `kindle-scribe-stylus-dev-plan-2026-08-23.md` | Modificar | §0.0 actualizado con el estado real |

---

## 4. Etapas y puertas de decisión

```
Etapa 1  T1 T2 T3 T4 T5        arreglos quirúrgicos + arnés + CI     sin puerta
   |
   +--> PUERTA A: ¿autorizado tocar ink_bar.lua? (enmienda al §6.6)
   |
Etapa 2  T6 T7 T8              supresión en capa de widget            spike con criterio
   |
   +--> PUERTA B: ¿el spike de T6 cumple su criterio de aceptación?
   |         no -> abortar Etapa 2, ejecutar T9 (arreglo quirúrgico de R2),
   |               R3 sigue documentado como límite conocido
   |
Etapa 3  T10 T11               conformidad de runtime + gate físico    requiere hardware
```

**Etapa 1 es entregable por sí sola.** Si el autor no autoriza la Etapa 2, la
Etapa 1 más T9 deja el plugin en un estado defendible y R3 documentado.

---

## 5. Etapa 1 — arreglos quirúrgicos

### Tarea T1: El latch geométrico pasa a ser por slot (R1)

**Archivos:**
- Modificar: `fingerink.koplugin/main.lua` (`resetContacts`, `onStylusTouchFrame`)
- Test: `fingerink.koplugin/tests/run.lua`

**Interfaces:**
- Consume: `self.contacts`, `self.n_contacts`, `self.passthrough`, `FingerInk:inBar`
- Produce: `self.contacts[slot]` deja de ser `true` en la ruta stylus y pasa a
  ser una de tres cadenas: `"new"` (contacto visto, aún sin coordenadas),
  `"bar"` (sus primeras coordenadas cayeron en la barra), `"page"` (fuera). La
  ruta de dedo sigue escribiendo `true`. Todas son verdaderas, así que
  `if not self.contacts[slot]` sigue significando "contacto nuevo" en las dos
  rutas. El campo `self.touch_geom_latched` **desaparece**.

- [ ] **Paso 1: escribir el test que falla**

En la sección `full input frame pipeline` de `tests/run.lua`:

```lua
t:case("a resting palm does not make the toolbar unreachable", function()
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()
    local bar = p.bar.dimen

    -- The palm lands first, off the toolbar, and used to latch the decision
    -- for every later contact in the sequence.
    pumpFrame(input, bus, { { slot = 0, fields = { id = 1, x = 300, y = 600 } } })

    -- A finger now reaches for Stop. It is the only way out of stylus mode.
    local n = pumpFrame(input, bus,
        { { slot = 1, fields = { id = 2, x = bar.x + 5, y = bar.y + 5 } } })

    t:check(n > 0, "the toolbar tap survives a resting palm")
    t:eq(p.passthrough, true, "the bar contact latched passthrough on its own slot")
    t:eq(p.contacts[0], "page", "the palm is remembered as off-bar")
    t:eq(p.contacts[1], "bar", "the finger is remembered as on-bar")
end)
```

- [ ] **Paso 2: ejecutarlo y verlo fallar**

```sh
cd /Users/christianstenger/GitHub/fingerink.koplugin/fingerink.koplugin
~/.claude/skills/koreader-simulator-qa/scripts/koreader_qa.sh test
```

Esperado: FAIL con `the toolbar tap survives a resting palm` y
`(got 0, want true)` en el latch.

- [ ] **Paso 3: implementar**

En `resetContacts`, borrar la línea `self.touch_geom_latched = false`. En
`init`, borrar `self.touch_geom_latched = false`.

En `onStylusTouchFrame`, sustituir el cuerpo del bucle por:

```lua
        if not Capture:isStylusSlot(ev) then
            local slot = ev.slot or 0
            local id = ev.id

            if id and id >= 0 then
                if not self.contacts[slot] then
                    -- "new" until this contact's first frame with coordinates
                    -- decides where it started. The latch is per slot: a palm
                    -- that landed off the toolbar must not answer for the
                    -- finger reaching for Stop.
                    self.contacts[slot] = "new"
                    self.n_contacts = self.n_contacts + 1
                end
                if self.contacts[slot] == "new" and ev.x and ev.y then
                    local x, y = Capture.toScreen(ev.x, ev.y)
                    if self:inBar(x, y) then
                        self.contacts[slot] = "bar"
                        self.passthrough = true
                    else
                        self.contacts[slot] = "page"
                    end
                end
            else
                if self.contacts[slot] then
                    self.contacts[slot] = nil
                    self.n_contacts = self.n_contacts - 1
                end
                if self.n_contacts <= 0 then
                    self.n_contacts = 0
                    self.passthrough = false
                end
            end
        end
```

- [ ] **Paso 4: arreglar el test que asertaba el campo eliminado**

En `tests/run.lua` hay una aserción `t:eq(p.touch_geom_latched, false, "geometry latch released")`.
Sustituirla por una del mismo hecho a nivel de comportamiento, que sobrevive a
la Etapa 2:

```lua
    t:eq(next(p.contacts), nil, "contact bookkeeping released")
```

- [ ] **Paso 5: ejecutar la suite entera**

Esperado: PASS, sin `SKIP`.

- [ ] **Paso 6: commit**

```bash
git add fingerink.koplugin/main.lua fingerink.koplugin/tests/run.lua
git commit -m "fix: latch the toolbar decision per contact, not per frame

A palm resting off the toolbar answered for every later contact in the
sequence, so a finger reaching for Stop was swallowed. Stop is the only
way out of stylus drawing mode, which made this a lock-out."
```

---

### Tarea T2: La bandera por frame se limpia con el resto del estado (R4)

**Archivos:**
- Modificar: `fingerink.koplugin/main.lua` (`resetStylusState`)
- Test: `fingerink.koplugin/tests/run.lua`

**Interfaces:**
- Consume: `FingerInk:resetStylusState`, `Capture:fail`
- Produce: nada nuevo. `resetStylusState` pasa a limpiar `stylus_frame_ui`.

Orden que hay que respetar: en la rama de lift, `onStylusEvent` llama a
`resetStylusState()` y **después** a `stylusFrameResult(...)`, así que limpiar
la bandera dentro de `resetStylusState` no destruye la decisión del frame de
lift — se vuelve a escribir justo después.

- [ ] **Paso 1: escribir el test que falla**

En la sección `full input frame pipeline` de `tests/run.lua`, que es donde viven
`pumpFrame`, `reset` y `newPlugin`:

```lua
t:case("an error disarm does not leave the pen's frame flag set", function()
    local input = reset{ wacom_protocol = true }
    local p = newPlugin()
    p:setDrawing(true)

    -- A raise inside the stylus handler returns the guard's fail value without
    -- ever reaching stylusFrameResult, so the flag keeps whatever it held.
    p.stylus_frame_ui = true
    Capture:fail("boom")
    env.UIManager:flush()

    t:eq(p.stylus_frame_ui, false, "the per-frame flag was cleared with the rest")

    p:setDrawing(true)
    local bus = support.newSlotBus()
    local n = pumpFrame(input, bus, { { slot = 0, fields = { id = 1, x = 300, y = 600 } } })
    t:eq(n, 0, "the first palm frame after restarting is still suppressed")
end)
```

- [ ] **Paso 2: ejecutarlo y verlo fallar**

Esperado: FAIL con `(got true, want false)` y `(got 1, want 0)`.

- [ ] **Paso 3: implementar**

En `resetStylusState`, añadir como última línea:

```lua
    self.stylus_frame_ui = false
```

y actualizar el comentario de la función:

```lua
--- Per-sequence pen state. `stylus_lift_x/y` deliberately survives, because it
--- is how the next contact-down detects stale coordinates. `stylus_frame_ui`
--- does not: a raise mid-frame skips stylusFrameResult entirely and would
--- otherwise leave it set for the next session's first residual frame.
```

- [ ] **Paso 4: ejecutar la suite**

Esperado: PASS.

- [ ] **Paso 5: commit**

```bash
git add fingerink.koplugin/main.lua fingerink.koplugin/tests/run.lua
git commit -m "fix: clear the pen's per-frame flag when stylus state resets"
```

---

### Tarea T3: Recuperar el punto que la heurística de coordenadas rancias descarta (R5)

**Archivos:**
- Modificar: `fingerink.koplugin/main.lua` (`resetStylusState`, `onStylusEvent`, `onStylusPoint`)
- Test: `fingerink.koplugin/tests/run.lua`

**Interfaces:**
- Consume: `Capture.toScreen`, `FingerInk:onStylusPoint`, `FingerInk:endStroke`
- Produce: dos campos nuevos de estado por secuencia:
  `self.stylus_inked` (booleano, true en cuanto la secuencia aplica un punto) y
  `self.stylus_tool` (la última herramienta *real* vista, es decir distinta de
  `Capture.TOOL_FINGER`, o nil).

Por qué recuperar desde el frame de lift y no afinar la heurística: en el caso
verdadero-rancio el lápiz sí bajó en algún sitio, y para cuando llega el lift el
digitalizador ya ha reportado su posición real. En el falso positivo, la
posición del lift es exactamente la correcta. Las dos ramas quieren el mismo
dato.

- [ ] **Paso 1: escribir el test que falla**

En la misma sección `full input frame pipeline`:

```lua
t:case("a dot placed where the last one lifted is not lost", function()
    local p, input = pipelinePlugin()
    local bus = support.newSlotBus()

    pumpFrame(input, bus, { { slot = 4, fields = { id = 4, x = 400, y = 400, tool = 1 } } })
    pumpFrame(input, bus, { { slot = 4, fields = { id = -1 } } })
    pumpFrame(input, bus, { { slot = 4, fields = { id = 5, x = 400, y = 400, tool = 1 } } })
    pumpFrame(input, bus, { { slot = 4, fields = { id = -1 } } })

    t:eq(#p.store:get(p:currentPage()), 2, "both dots were stored")
end)
```

- [ ] **Paso 2: ejecutarlo y verlo fallar**

Esperado: FAIL con `(got 1, want 2)`.

- [ ] **Paso 3: implementar**

En `resetStylusState`, añadir:

```lua
    self.stylus_inked = false
    self.stylus_tool = nil
```

En `init`, añadir las mismas dos líneas junto al resto del estado de lápiz.

En `onStylusEvent`, dentro de la rama `id >= 0`, justo después de la línea que
lee `local id, x, y, tool = ...` no hay sitio; hacerlo dentro de la rama, antes
del bloque `if x and y and not self.stylus_stale_xy then`:

```lua
        -- Remember the last tool that was not the TOOL_TYPE_FINGER a pen slot
        -- reports on its way out of proximity: the lift frame often carries
        -- exactly that, and the recovered point must not silently become ink
        -- when the user was erasing.
        if tool ~= nil and tool ~= Capture.TOOL_FINGER then
            self.stylus_tool = tool
        end
```

En `onStylusPoint`, marcar que la secuencia entintó:

```lua
function FingerInk:onStylusPoint(x, y, tool)
    if self.stylus_suspended then return end
    if self:inBar(x, y) then
        self:endStroke()
        self.stylus_suspended = true
        return
    end
    self.stylus_inked = true
    self:applyPoint(x, y, tool)
end
```

En `onStylusEvent`, rama de lift, insertar la recuperación **antes** de
`endStroke`:

```lua
    local was_passthrough = self.stylus_passthrough
    -- A contact-down frame judged stale is sometimes a false positive: the pen
    -- really did come back down where it lifted last time. If the sequence
    -- produced no point at all, recover it from the lift frame, which by now
    -- carries a real position.
    if not was_passthrough and not self.stylus_inked
        and not self.stylus_suspended and x and y then
        local sx, sy = Capture.toScreen(x, y)
        self:onStylusPoint(sx, sy, self.stylus_tool)
    end
    if not was_passthrough then
        self:endStroke()
    end
```

- [ ] **Paso 4: ejecutar la suite**

Esperado: PASS. Comprobar en particular que sigue pasando
`no phantom point was painted from the stale position` — la recuperación no
debe reintroducir el punto fantasma, porque en ese test la secuencia sí produce
puntos posteriores y `stylus_inked` queda en true.

- [ ] **Paso 5: mutación de verificación**

Sustituir `not self.stylus_inked` por `false` y confirmar que el test nuevo
falla. Revertir.

- [ ] **Paso 6: commit**

```bash
git add fingerink.koplugin/main.lua fingerink.koplugin/tests/run.lua
git commit -m "fix: recover the pen point the stale-coordinate guard discards

The guard compares the contact-down frame against the previous lift, so a
pen that comes back down on the same spot is judged stale. When the whole
sequence produced nothing, take the position from the lift frame."
```

---

### Tarea T4: Corregir la fidelidad del arnés de widgets (R9)

**Archivos:**
- Modificar: `fingerink.koplugin/tests/support.lua`
- Test: `fingerink.koplugin/tests/run.lua`

**Interfaces:**
- Produce: `WidgetContainer:handleEvent` propaga a hijos primero;
  `unpack` disponible en cualquier Lua; el stub `Button` expone
  `Button.seen` (array de `event.handler` recibidos) para poder afirmar el
  orden; `UIManager._window_stack` se mantiene de verdad en `show`/`close`;
  `UIManager:sendEvent(event)` reproduce la semántica real (widget no-toast más
  alto primero, parada si devuelve true).

Esta tarea es prerrequisito de la Etapa 2: sin ella, el spike de T6 se validaría
contra un modelo de despacho invertido.

- [ ] **Paso 1: escribir el test que falla**

```lua
t:describe("test harness fidelity")

t:case("widget containers offer events to children before themselves", function()
    reset()
    local seen = {}
    local Container = env.WidgetContainer:extend{}
    function Container:onGesture() seen[#seen + 1] = "parent"; return nil end
    local child = { handleEvent = function() seen[#seen + 1] = "child"; return nil end }
    local c = Container:new{ child }

    c:handleEvent({ handler = "onGesture", args = { {} } })

    t:eq(seen[1], "child", "the child saw the event first")
    t:eq(seen[2], "parent", "the container's own handler ran second")
end)
```

- [ ] **Paso 2: ejecutarlo y verlo fallar**

Esperado: FAIL con `(got parent, want child)`.

- [ ] **Paso 3: implementar**

Al principio de `tests/support.lua`, tras `local support = {}`:

```lua
-- LuaJIT and Lua 5.1 expose unpack as a global; 5.2+ moved it to table.
-- Keeping both alive is what lets this suite run in CI without KOReader.
local unpack = unpack or table.unpack
```

Sustituir `WidgetContainer:handleEvent` por el orden real
(`frontend/ui/widget/container/widgetcontainer.lua` @ v2026.07: `propagateEvent`
sobre los hijos y sólo después el handler propio):

```lua
    --- KOReader's dispatch order: children first, in array order, then our own
    --- handler. Getting this backwards makes a toolbar button unreachable in
    --- the fake while it works on the device, or the reverse — which is
    --- precisely the class of bug this suite exists to catch.
    function WidgetContainer:handleEvent(event)
        for i = 1, #self do
            local child = self[i]
            if type(child) == "table" and child.handleEvent then
                if child:handleEvent(event) then return true end
            end
        end
        local handler = self[event.handler]
        if type(handler) == "function" then
            return handler(self, unpack(event.args or {}))
        end
    end
```

Exportar el contenedor para los tests: `env.WidgetContainer = WidgetContainer`.

Hacer que `UIManager:show` mantenga la pila real, para que `InkBar:windowBelow`
pueda probarse sin stub:

```lua
    function UIManager:show(w)
        self.shown[#self.shown + 1] = w
        self._window_stack[#self._window_stack + 1] = { widget = w }
    end
```

Añadir el despacho fiel:

```lua
    --- Mirrors UIManager:sendEvent @ v2026.07: toasts never consume, the
    --- topmost non-toast widget gets first refusal and stops propagation when
    --- it returns true.
    function UIManager:sendEvent(event)
        local top
        for i = #self._window_stack, 1, -1 do
            local w = self._window_stack[i].widget
            if w.toast then
                w:handleEvent(event)
            else
                top = w
                break
            end
        end
        if not top then return end
        return top:handleEvent(event) and true or false
    end
```

Dar al stub `Button` un registro de recepción:

```lua
    function Button:new(o)
        o = setmetatable(o or {}, Button)
        o.texts = { o.text }
        o.seen = {}
        return o
    end
    function Button:handleEvent(event)
        self.seen[#self.seen + 1] = event.handler
        return false
    end
```

- [ ] **Paso 4: reparar la caída que esto provoca**

`support.lua:322` sobrescribe `InkBar:windowBelow` para devolver
`env.window_below`. Con la pila real ya no hace falta, pero **quitarla en esta
tarea no**: mantenerla, y anotar por qué queda:

```lua
    -- windowBelow is still stubbed: newPlugin registers the ReaderUI fake as
    -- env.window_below without ever showing it through UIManager, so the real
    -- implementation would find nothing under the bar. Removing this stub is
    -- part of T7, together with pushing ReaderUI onto the stack.
```

- [ ] **Paso 5: ejecutar la suite y arreglar la regresión de `ink_bar`**

El test `swallow gestures that land on the bar but miss every button` cambia de
significado con el orden correcto: ahora los `Button` ven el gesto antes. El
stub `Button:handleEvent` devuelve false siempre, así que el resultado final no
cambia — pero **la aserción hay que reforzarla** para que el test pruebe el
orden y no sólo el resultado:

```lua
    t:eq(p.bar.draw_btn.seen[1], "onGesture", "the buttons got first refusal")
```

- [ ] **Paso 6: confirmar la portabilidad a Lua sin KOReader**

```sh
lua test.lua
```

Esperado: `N passed, 0 failed` — el mismo total que bajo el LuaJIT de KOReader.
Antes de esta tarea daba `254 passed, 1 failed`.

- [ ] **Paso 7: commit**

```bash
git add fingerink.koplugin/tests/support.lua fingerink.koplugin/tests/run.lua
git commit -m "test: propagate widget events in KOReader's order

The fake called its own handler before its children; the real
WidgetContainer does the opposite. Every ink_bar test was passing for the
wrong reason. Also makes the suite run on any Lua, not just LuaJIT."
```

---

### Tarea T5: CI (R7)

**Archivos:**
- Crear: `.github/workflows/tests.yml`
- Modificar: `README.md` (sección Tests)

**Interfaces:**
- Consume: el shim `unpack` de T4. **T4 es prerrequisito estricto**: sin él el
  job falla.
- Produce: un workflow que corre en cada push y PR.

- [ ] **Paso 1: escribir el workflow**

```yaml
name: tests

on:
  push:
  pull_request:

jobs:
  suite:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install LuaJIT
        run: sudo apt-get update && sudo apt-get install -y luajit

      - name: Syntax sweep
        run: |
          set -e
          n=0
          for f in $(find fingerink.koplugin -name '*.lua'); do
            luajit -b "$f" /dev/null
            n=$((n + 1))
          done
          echo "LuaJIT syntax: $n files"
          test "$n" -ge 8

      - name: Run the suite
        run: |
          set -o pipefail
          luajit test.lua | tee result.txt
          grep -q '0 failed' result.txt
```

> ⚠️ CORREGIDO al implementar: la afirmación original de este plan —que la suite
> devuelve 0 pase o falle— era falsa. `tests/run.lua` termina en
> `os.exit(t:report() and 0 or 1)`, así que el código de salida ya distingue. Se
> verificó inyectando un `check` fallido: exit 1 y `grep` en rojo. El `grep` se
> mantiene como segunda red por si alguien cambia el final del runner.

- [ ] **Paso 2: verificar el workflow en local**

```sh
cd /Users/christianstenger/GitHub/fingerink.koplugin
for f in $(find fingerink.koplugin -name '*.lua'); do lua -e "assert(loadfile('$f'))"; done
lua test.lua | tail -3
```

Esperado: sin errores de sintaxis y `0 failed`.

- [ ] **Paso 3: actualizar el README**

En la sección `## Tests`, sustituir el bloque de comandos por:

```sh
luajit test.lua                       # from the repository root
luajit tests/run.lua                  # from inside fingerink.koplugin/
lua test.lua                          # any Lua 5.1+, no LuaJIT needed
```

y añadir tras el párrafo que empieza "Both run the same suite":

```
Every push and pull request runs the same suite on CI, plus a syntax sweep
over every Lua file in the plugin.
```

- [ ] **Paso 4: commit**

```bash
git add .github/workflows/tests.yml README.md
git commit -m "ci: run the suite and a syntax sweep on every push"
```

---

## 6. PUERTA A — autorización para la Etapa 2

**No empezar T6 sin respuesta.** La Etapa 2 modifica `ink_bar.lua`, que el §6.6
del plan predecesor puso fuera de alcance. Lo que hay que decidir:

- **Sí:** se gana R2 y R3 arreglados, `dropSuppressedContacts` eliminado, y la
  contabilidad de contactos del plugin reducida. Se paga con un refactor de una
  funcionalidad recién escrita y sin validar en hardware, y con una dependencia
  nueva y dura del invariante "la barra es el widget más alto".
- **No:** ejecutar T9 en su lugar. R2 queda arreglado de forma quirúrgica en la
  ruta de dedo, R3 sigue documentado como límite conocido, y el diseño no se
  mueve antes del gate físico.

**Recomendación: sí, pero después del gate físico (Etapa 3), no antes.** El
argumento es de secuencia, no de diseño: la Etapa 2 es la respuesta correcta a
un diagnóstico correcto, pero refactorizar la ruta de entrada justo antes de la
única sesión de hardware disponible significa que el gate probaría código sin
rodaje. Orden propuesto: Etapa 1 → T9 → Etapa 3 (gate) → Etapa 2 con el
comportamiento real ya medido.

---

## 7. Etapa 2 — supresión en la capa de widget

### Tarea T6: Spike — probar que la capa de widget ve lo que debe

**Archivos:**
- Modificar: `fingerink.koplugin/tests/support.lua` (montar la pila completa)
- Test: `fingerink.koplugin/tests/run.lua` (sección nueva)

**Interfaces:**
- Consume: `UIManager:sendEvent` de T4, `InkBar:handleEvent`, `InkBar:onGesture`
- Produce: nada de producción. El entregable es la evidencia.

**Criterio de aceptación del spike — los tres tienen que cumplirse:**

1. Un `Event` de gesto enviado con `UIManager:sendEvent` mientras la barra está
   arriba llega a `InkBar:onGesture` con `pos` en coordenadas de pantalla.
2. Con un diálogo empujado sobre la barra, ese mismo envío **no** llega a
   `InkBar:onGesture` y sí al diálogo.
3. Un gesto cuyo `pos` cae dentro de la barra se puede distinguir de uno fuera
   usando sólo `InkBar:contains`, sin ninguna transformación de coordenadas.

- [ ] **Paso 1: montar la pila real en el arnés**

En `support.newPlugin`, empujar el falso ReaderUI a la pila antes de crear el
plugin, y retirar el stub de `windowBelow` que T4 dejó anotado:

```lua
    -- ReaderUI has to be a real entry in the stack: the bar's forwarding and
    -- the whole suppression decision are defined relative to what sits below.
    env.UIManager._window_stack = { { widget = ui } }
    env.window_below = ui
```

y borrar la línea `function InkBar:windowBelow() return env.window_below end`
junto con su comentario.

- [ ] **Paso 2: escribir los tres tests del criterio**

```lua
t:describe("spike / widget-layer gesture visibility")

local function gestureEvent(x, y, name)
    return { handler = "onGesture", args = { { ges = name or "tap",
        pos = { x = x, y = y } } } }
end

t:case("a gesture reaches the bar while it is topmost", function()
    local p = drawingPlugin()
    local seen = {}
    local original = p.bar.onGesture
    p.bar.onGesture = function(self, ges) seen[#seen + 1] = ges; return original(self, ges) end

    env.UIManager:sendEvent(gestureEvent(300, 600))

    t:eq(#seen, 1, "the bar saw the gesture")
    t:eq(seen[1].pos.x, 300, "position arrives in screen coordinates")
end)

t:case("a dialog above the bar takes the gesture instead", function()
    local p = drawingPlugin()
    local seen = 0
    local original = p.bar.onGesture
    p.bar.onGesture = function(self, ges) seen = seen + 1; return original(self, ges) end

    local dialog_got = false
    local dialog = { handleEvent = function() dialog_got = true; return true end }
    env.UIManager:show(dialog)

    env.UIManager:sendEvent(gestureEvent(300, 600))

    t:eq(seen, 0, "the bar never saw it")
    t:eq(dialog_got, true, "the dialog did")
end)

t:case("bar membership is decidable from ges.pos alone", function()
    local p = drawingPlugin()
    local bar = p.bar.dimen
    t:eq(p.bar:contains(bar.x + 5, bar.y + 5), true, "inside")
    t:eq(p.bar:contains(bar.x - 50, bar.y + 5), false, "outside")
end)
```

- [ ] **Paso 3: ejecutar**

Esperado: los tres PASS. Si alguno falla, **detenerse** y llevar el resultado a
la PUERTA B.

- [ ] **Paso 4: commit**

```bash
git add fingerink.koplugin/tests/support.lua fingerink.koplugin/tests/run.lua
git commit -m "test: stand up the real window stack and prove the widget layer sees gestures"
```

---

## 8. PUERTA B — resultado del spike

- **Los tres criterios pasan:** continuar con T7 y T8.
- **Alguno falla:** abortar la Etapa 2, revertir T6 si conviene, y ejecutar T9.
  Registrar en `decisions.md` qué criterio falló y por qué — eso convierte el
  intento en información y no en tiempo perdido.

---

### Tarea T7: Mover la supresión a `InkBar:onGesture` (R2, R3)

**Archivos:**
- Modificar: `fingerink.koplugin/ink_bar.lua` (`onGesture`)
- Modificar: `fingerink.koplugin/main.lua` (`onTouchFrame`, `onStylusTouchFrame`, `stylusFrameResult`)
- Modificar: `fingerink.koplugin/ink_capture.lua` (borrar `dropSuppressedContacts` y `drop_suppressed`)
- Test: `fingerink.koplugin/tests/run.lua`

**Interfaces:**
- Consume: `FingerInk.drawing`, `FingerInk.input_backend`, `FingerInk.passthrough`,
  `InkBar:contains`
- Produce: `InkBar:suppresses(ges)` → booleano. Es la única decisión de
  supresión que queda; `onGesture` la consulta.

**Contrato de `InkBar:suppresses`:**

```
suppresses(ges) == true  cuando  el plugin está dibujando
                          y      el backend está instalado
                          y      el plugin no está en passthrough
                          y      (ges.pos es nil  o  ges.pos cae fuera de la barra)
```

`ges.pos == nil` se suprime por defecto: un gesto sin posición no se puede
atribuir, y dejarlo pasar mientras se dibuja es exactamente el fallo que se está
cerrando.

- [ ] **Paso 1: escribir los tests que fallan**

```lua
t:describe("widget-layer suppression")
```

(El helper `gestureEvent` es el que define T6; estos tests van después de aquella
sección en el mismo archivo.)

```lua
t:case("a timer-born hold is swallowed while drawing", function()
    local p = drawingPlugin()
    -- hold never passes through feedEvent: Input:waitEvent dispatches it
    -- straight from a setTimeout callback. This is the only layer that sees it.
    local consumed = env.UIManager:sendEvent(gestureEvent(300, 600, "hold"))
    t:eq(consumed, true, "the hold was consumed by the bar")
end)

t:case("a gesture aimed at the toolbar is not swallowed", function()
    local p = drawingPlugin()
    local bar = p.bar.dimen
    t:eq(p.bar:suppresses({ ges = "tap", pos = { x = bar.x + 5, y = bar.y + 5 } }), false,
        "the toolbar keeps its taps")
end)

t:case("a palm gesture is suppressed even when the pen taps the bar", function()
    local p = drawingPlugin()
    local bar = p.bar.dimen
    -- The old per-frame decision released both. Position is per gesture.
    t:eq(p.bar:suppresses({ ges = "tap", pos = { x = bar.x + 5, y = bar.y + 5 } }), false,
        "the pen's tap on the bar survives")
    t:eq(p.bar:suppresses({ ges = "pan", pos = { x = 300, y = 600 } }), true,
        "the palm's pan in the same frame does not")
end)

t:case("a gesture with no position is suppressed while drawing", function()
    local p = drawingPlugin()
    t:eq(p.bar:suppresses({ ges = "multiswipe" }), true, "unattributable, so suppressed")
end)

t:case("nothing is suppressed once drawing is off", function()
    local p = drawingPlugin()
    p:setDrawing(false)
    t:eq(p.bar:suppresses({ ges = "tap", pos = { x = 300, y = 600 } }), false,
        "reading works again")
end)
```

- [ ] **Paso 2: ejecutarlos y verlos fallar**

Esperado: FAIL con `attempt to call a nil value (method 'suppresses')`.

- [ ] **Paso 3: implementar en `ink_bar.lua`**

```lua
--[[--
Whether this gesture must not reach the application.

This is the plugin's suppression point. It sits here rather than in the capture
hook because UIManager offers *every* gesture to the topmost non-toast widget
first — including `hold` and the deferred single `tap`, which are produced by
Input:setTimeout callbacks and dispatched straight from Input:waitEvent without
ever passing through GestureDetector:feedEvent. A filter down there cannot see
them. See ADR-13.

Gestures arrive rotation-adjusted, so `pos` is already in screen coordinates and
no transform is needed. A gesture with no position cannot be attributed to a
contact, and letting one through mid-stroke is the failure being closed here, so
it is suppressed too.
]]
function InkBar:suppresses(ges)
    local p = self.plugin
    if not (p.drawing and p.input_backend) then return false end
    if p.passthrough then return false end
    if ges.pos and self:contains(ges.pos.x, ges.pos.y) then return false end
    return true
end

function InkBar:onGesture(ges)
    if ges.pos and self:contains(ges.pos.x, ges.pos.y) then
        -- Landed on the bar but missed every button: the border, the padding,
        -- the gaps. Swallow it rather than forward it into a page turn.
        return true
    end
    return self:suppresses(ges)
end
```

- [ ] **Paso 4: simplificar los filtros residuales en `main.lua`**

`onStylusTouchFrame` deja de decidir qué se emite. Conserva sólo la contabilidad
de contactos y el latch de passthrough, y devuelve siempre `true`:

```lua
--[[--
Residual contact bookkeeping for the stylus backend.

Since ADR-13 the *suppression* decision lives in InkBar:suppresses, per gesture
and by position. What stays here is the state that decision reads: how many
non-pen contacts are down, and whether any of them started on the toolbar.

Always returns true. Emptying feedEvent's return array is no longer how anything
is suppressed.
]]
function FingerInk:onStylusTouchFrame(slots)
    if not self.passthrough and self:dialogOnTop() then
        self.passthrough = true
    end

    local slots_len = #slots
    for i = 1, slots_len do
        local ev = slots[i]
        if not Capture:isStylusSlot(ev) then
            local slot = ev.slot or 0
            local id = ev.id

            if id and id >= 0 then
                if not self.contacts[slot] then
                    self.contacts[slot] = "new"
                    self.n_contacts = self.n_contacts + 1
                end
                if self.contacts[slot] == "new" and ev.x and ev.y then
                    local x, y = Capture.toScreen(ev.x, ev.y)
                    if self:inBar(x, y) then
                        self.contacts[slot] = "bar"
                        self.passthrough = true
                    else
                        self.contacts[slot] = "page"
                    end
                end
            else
                if self.contacts[slot] then
                    self.contacts[slot] = nil
                    self.n_contacts = self.n_contacts - 1
                end
                if self.n_contacts <= 0 then
                    self.n_contacts = 0
                    self.passthrough = false
                end
            end
        end
    end

    return true
end
```

Borrar `FingerInk:stylusFrameResult` por completo y sustituir cada
`return self:stylusFrameResult(v)` de `onStylusEvent` por `return v`. Borrar
`self.stylus_frame_ui` de `init` y de `resetStylusState`.

`onTouchFrame` (ruta de dedo) conserva su lógica de passthrough — la usa
`suppresses` — y también pasa a devolver siempre `true`:

```lua
    -- Suppression moved to InkBar:suppresses; this hook is capture only.
    return true
```

- [ ] **Paso 5: borrar `dropSuppressedContacts` de `ink_capture.lua`**

Quitar la función entera, el campo `drop_suppressed`, sus asignaciones en
`installFinger` / `installStylus` / `_forget`, y la llamada en el wrapper. El
wrapper se reduce a:

```lua
    wrapper = function(gd_self, slots)
        if not (self.active and self.feed_wrapper == wrapper) then
            return original(gd_self, slots)
        end
        handler(slots)
        return original(gd_self, slots)
    end
```

Actualizar el comentario de cabecera del módulo: ya no describe supresión.

- [ ] **Paso 6: ejecutar la suite completa**

Esperado: PASS. Se caerán los tests que afirmaban el mecanismo viejo
(`suppressing a frame drops the contacts, killing their hold timers`, y las
aserciones de conteo de gestos por frame). **Reescribirlos al nivel de
comportamiento nuevo, no borrarlos**: lo que cada uno protegía sigue siendo
cierto, sólo cambia dónde se decide.

- [ ] **Paso 7: mutaciones de verificación**

Inyectar las cuatro y confirmar que cada una rompe al menos un test:
1. `suppresses` devuelve siempre `false`.
2. `suppresses` ignora `p.passthrough`.
3. `suppresses` devuelve `false` cuando `ges.pos == nil`.
4. `onGesture` devuelve `nil` en vez de `self:suppresses(ges)`.

- [ ] **Paso 8: commit**

```bash
git add fingerink.koplugin/ink_bar.lua fingerink.koplugin/main.lua \
        fingerink.koplugin/ink_capture.lua fingerink.koplugin/tests/run.lua
git commit -m "refactor: suppress input at the widget layer, per gesture

Emptying feedEvent's return array could not see hold or the deferred tap
- they come from Input:setTimeout and are dispatched straight from
waitEvent - and it decided per frame, so a palm's gesture escaped with the
pen's toolbar tap. UIManager offers every gesture to the topmost widget,
already rotated and positioned, which is both problems at once."
```

---

### Tarea T8: Documentar la Etapa 2

**Archivos:**
- Modificar: `decisions.md` (ADR-13; ADR-11 pasa a *superseded in part*)
- Modificar: `spec.md`, `README.md`

- [ ] **Paso 1: añadir ADR-13**

```markdown
## ADR-13 — Suppress at the widget layer, not in the capture hook

**Context.** Clearing `GestureDetector:feedEvent`'s return array suppressed
only what feedEvent produced. `hold` and the deferred single `tap` come from
`Input:setTimeout` callbacks dispatched directly by `Input:waitEvent`
(input.lua:1584 @ v2026.07), so they escaped it. The stylus route papered over
this with `dropContact`, which is destructive and unusable on the finger route
because ADR-2 needs that contact state alive. The decision was also per frame,
so a palm's gesture left with the pen's toolbar tap.

**Decision.** Suppress in `InkBar:onGesture`. `UIManager:sendEvent` offers every
input event to the topmost non-toast widget and stops when it returns true
(uimanager.lua:884 @ v2026.07), timer-born gestures included. Gestures arrive
rotation-adjusted and carry `pos`, so the decision is per gesture and needs no
coordinate transform. The capture hook keeps only its original job: observing
contacts to draw from.

**Consequences.** The timer path is covered, palm rejection becomes per gesture,
`dropSuppressedContacts` is gone and the plugin's contact bookkeeping shrinks.
The price is a hard dependency on the toolbar being the topmost widget — the
invariant "drawing implies a visible toolbar" stops being a UX promise and
becomes a safety requirement.
```

Y en ADR-11, cambiar el encabezado a
`## ADR-11 — Stylus callback *plus* a residual touch filter *(superseded in part by ADR-13)*`,
manteniendo el cuerpo y añadiendo al final:

```markdown
**Superseded in part.** The residual filter no longer suppresses; it only keeps
contact bookkeeping. Suppression moved to the widget layer. See ADR-13.
```

- [ ] **Paso 2: retirar del README los límites que dejaron de ser ciertos**

Borrar los dos bullets de `## Known limits`:
- "**Stylus route, narrow case:** …"
- "**Finger route: a stationary finger can still trigger a long-press.** …"

y añadir en su lugar:

```markdown
- **Both routes: touch gestures are filtered by position while drawing.** A
  gesture that lands on the toolbar goes to the toolbar; everything else is
  swallowed until you press Stop. This includes long-presses, which used to slip
  through on the finger route.
```

- [ ] **Paso 3: actualizar `spec.md`**

En la sección de máquinas de estado, sustituir la descripción del filtro
residual por el contrato de `InkBar:suppresses` tal cual está en T7.

- [ ] **Paso 4: commit**

```bash
git add decisions.md README.md spec.md
git commit -m "docs: record the widget-layer suppression decision"
```

---

### Tarea T9: Alternativa si la PUERTA B falla — arreglo quirúrgico de R2

**Ejecutar sólo si la Etapa 2 se aborta.**

**Archivos:**
- Modificar: `fingerink.koplugin/ink_capture.lua`
- Test: `fingerink.koplugin/tests/run.lua`

**Interfaces:**
- Produce: `Capture` gana `mute_timers` (booleano, true en la ruta de dedo) y
  una función local `muteContactTimers(gd, slots)`.

**Por qué esto funciona sin `dropContact`:** el temporizador de hold se registra
una sola vez, en el contact-down (`if new_tap and not self.pending_hold_timer`,
gesturedetector.lua:673 @ v2026.07), y su callback comprueba
`self.pending_hold_timer` antes de emitir nada. Poner ese campo a nil deja el
temporizador inerte **sin destruir el contacto**, así que el gesto de dos dedos
de ADR-2 sigue funcionando. Lo mismo vale para `pending_double_tap_timer`.

- [ ] **Paso 1: escribir el test que falla**

```lua
t:case("the finger backend neuters the hold timer without dropping the contact", function()
    local input = reset()
    local p = newPlugin()
    p:setDrawing(true)
    local gd = input.gesture_detector
    local bus = support.newSlotBus()

    local gd_self = gd
    gd.feedEvent(gd_self, bus:frame(0))
    local contact = gd:getContact(0)

    t:check(contact ~= nil, "the contact is still alive for the two-finger gesture")
    t:eq(contact.pending_hold_timer, nil, "its hold timer was neutered")
    t:eq(#gd.dropped, 0, "and nothing was dropped")
end)
```

(El arnés ya modela `pending_hold_timer`: ver `newGestureDetector` en
`tests/support.lua`, que lo asigna al abrir un contacto.)

- [ ] **Paso 2: ejecutarlo y verlo fallar**

- [ ] **Paso 3: implementar en `ink_capture.lua`**

```lua
--[[--
Make a suppressed contact's pending timers inert, without dropping it.

`hold` and the deferred single `tap` are registered through `Input:setTimeout`
and dispatched straight from `Input:waitEvent`, so clearing feedEvent's return
array cannot stop them. `dropContact` can, but it destroys the contact, and the
finger backend needs that state alive for ADR-2's two-finger gesture.

Both timer callbacks re-check their `pending_*` field before emitting anything
(gesturedetector.lua:641 and :675 @ v2026.07), and the hold timer is only ever
registered on the initial contact down, so clearing the field is enough and
nothing re-arms it.
]]
local function muteContactTimers(gd, slots)
    if type(gd.getContact) ~= "function" then return end
    for i = 1, #slots do
        local ev = slots[i]
        local slot = ev and ev.slot
        if slot ~= nil then
            local contact = gd:getContact(slot)
            if contact then
                if contact.pending_hold_timer then
                    contact.pending_hold_timer = nil
                    if gd.input and type(gd.input.clearTimeout) == "function" then
                        gd.input:clearTimeout(slot, "hold")
                    end
                end
                if contact.pending_double_tap_timer then
                    contact.pending_double_tap_timer = false
                    if gd.input and type(gd.input.clearTimeout) == "function" then
                        gd.input:clearTimeout(slot, "double_tap")
                    end
                end
            end
        end
    end
end
```

Llamarla desde el wrapper en la rama suprimida cuando `self.mute_timers`, y
poner `self.mute_timers = true` en `installFinger` (la ruta de stylus sigue con
`dropContact`, que es estrictamente más fuerte).

- [ ] **Paso 4: documentar el efecto colateral en el README**

```markdown
- **Finger route: a two-finger *hold* does not fire while drawing.** Suppressing
  the long-press means the first finger's hold timer is disarmed, and a
  two-finger hold needs it. Two-finger tap, swipe and pan are unaffected.
```

- [ ] **Paso 5: commit**

```bash
git add fingerink.koplugin/ink_capture.lua fingerink.koplugin/tests/run.lua README.md
git commit -m "fix: neuter suppressed contacts' timers on the finger route"
```

---

## 9. Etapa 3 — conformidad y gate físico

### Tarea T10: Sonda de conformidad de runtime (R8)

**Archivos:**
- Crear: `fingerink.koplugin/tests/conformance.lua`
- Modificar: `README.md`, `kindle-scribe-stylus-dev-plan-2026-08-23.md` (§10)

**Interfaces:**
- Consume: el `Device` real del runtime en que se ejecute
- Produce: un informe línea a línea con tres estados por afirmación: `OK`,
  `MISMATCH`, `UNCHECKABLE` (la API no existe en este runtime)

El objetivo es que cada suposición del arnés tenga un contraste ejecutable
contra KOReader de verdad, y que las que el runtime local no puede verificar
salgan **nombradas** en lugar de silenciadas.

- [ ] **Paso 1: escribir la sonda**

```lua
--[[--
Contrast the test harness's assumptions against the KOReader runtime that is
actually installed. Run it under the emulator's LuaJIT with KOReader's own
package.path; it needs a real Device, not a session.

Three outcomes per claim. UNCHECKABLE is a first-class result: the local
runtime is older than the stylus API, and pretending otherwise is how a suite
ends up proving only what it already believed.
]]
local Device = require("device")
local Input = Device.input

local rows = {}
local function claim(name, checkable, ok, detail)
    if not checkable then
        rows[#rows + 1] = { "UNCHECKABLE", name, detail or "API absent in this runtime" }
    elseif ok then
        rows[#rows + 1] = { "OK", name, detail or "" }
    else
        rows[#rows + 1] = { "MISMATCH", name, detail or "" }
    end
end

claim("gesture_detector.feedEvent is a function on the instance",
    true, type(Input.gesture_detector.feedEvent) == "function")
claim("GestureDetector exposes getContact and dropContact",
    true, type(Input.gesture_detector.getContact) == "function"
      and type(Input.gesture_detector.dropContact) == "function")
claim("Screen:getTouchRotation exists",
    true, type(Device.screen.getTouchRotation) == "function")
claim("Input exports the TOOL_TYPE_* constants",
    Input.TOOL_TYPE_PEN ~= nil,
    Input.TOOL_TYPE_FINGER == 0 and Input.TOOL_TYPE_PEN == 1
      and Input.TOOL_TYPE_ERASER == 2 and Input.TOOL_TYPE_HIGHLIGHTER == 3,
    "TOOL_TYPE_PEN = " .. tostring(Input.TOOL_TYPE_PEN))
claim("registerStylusCallback / unregisterStylusCallback exist",
    type(Input.registerStylusCallback) == "function",
    type(Input.unregisterStylusCallback) == "function")
claim("pen_slot is defined",
    Input.pen_slot ~= nil, true, "pen_slot = " .. tostring(Input.pen_slot))
claim("ev_slots hands out persistent tables",
    Input.ev_slots ~= nil,
    Input.ev_slots and Input.getMtSlot
      and rawequal(Input:getMtSlot(0), Input:getMtSlot(0)))
claim("UIManager:sendEvent stops on a consuming widget",
    true, type(require("ui/uimanager").sendEvent) == "function")

local bad = 0
for _, r in ipairs(rows) do
    io.write(string.format("%-12s %-52s %s\n", r[1], r[2], r[3]))
    if r[1] == "MISMATCH" then bad = bad + 1 end
end
io.write(string.format("\n%d claims, %d mismatches\n", #rows, bad))
```

- [ ] **Paso 2: ejecutarla contra el runtime local**

```sh
KO=/Users/christianstenger/koreader/koreader/koreader-emulator-arm64-apple-darwin25.1.0-debug/koreader
cd "$KO" && ./luajit \
  /Users/christianstenger/GitHub/fingerink.koplugin/fingerink.koplugin/tests/conformance.lua
```

Esperado en v2025.08: **0 mismatches**, con `registerStylusCallback` y
`TOOL_TYPE_*` marcados `UNCHECKABLE`. Cualquier `MISMATCH` es un stub que miente
y hay que arreglar el stub, no la sonda.

- [ ] **Paso 3: documentar el comando**

Añadirlo al §10 del plan predecesor y a la sección Tests del README, con la
advertencia de que `UNCHECKABLE` no es un pase.

- [ ] **Paso 4: commit**

```bash
git add fingerink.koplugin/tests/conformance.lua README.md \
        kindle-scribe-stylus-dev-plan-2026-08-23.md
git commit -m "test: contrast the harness's assumptions against the live runtime"
```

---

### Tarea T11: Modo diagnóstico para el gate físico (R6, §0.3, R5)

**Archivos:**
- Modificar: `fingerink.koplugin/main.lua` (menú, `onStylusEvent`)
- Modificar: `README.md`
- Test: `fingerink.koplugin/tests/run.lua`

**Interfaces:**
- Produce: `FingerInk:diag(slot, sx, sy)`, `self.diag_until`, `self.diag_lines`.
  Ítem de menú *Log stylus diagnostics (60 s)*.

**Por qué existe:** hay una sola sesión de hardware disponible y tres preguntas
que sólo el hardware responde (¿emite `BTN_STYLUS` el Scribe?, ¿el frame de
contact-down trae coordenadas rancias de verdad?, ¿cuál es la latencia
percibida?). Volver del Scribe con "no pasó nada" y sin datos obliga a un
segundo viaje.

**Restricción de §13, no negociable:** volumen acotado, y ni rutas, ni títulos,
ni contenido de libros. Sólo números del digitalizador.

- [ ] **Paso 1: escribir el test que falla**

```lua
t:case("diagnostics stop on their own", function()
    local p = drawingPlugin()
    p:startDiagnostics()
    t:check(p.diag_until ~= nil, "diagnostics armed")

    for _ = 1, 600 do p:diag({ slot = 4, id = 4, tool = 1 }, 10, 10) end

    t:eq(p.diag_until, nil, "the line budget disarmed them")
    t:check(#env.logs.info <= 520, "and the log did not run away")
end)
```

- [ ] **Paso 2: ejecutarlo y verlo fallar**

- [ ] **Paso 3: implementar**

En `init`: `self.diag_until = nil; self.diag_lines = 0`.

```lua
local DIAG_SECONDS = 60
local DIAG_MAX_LINES = 500

--[[--
One bounded diagnostic session for the physical Scribe gate.

Bounded twice on purpose - by wall clock and by line count - because the only
thing worse than no data from a hardware session is a log that filled the device
and got truncated at the interesting part.

Logs digitizer numbers only: slot, tracking id, tool, and whether this frame's
coordinates repeat the previous lift. No paths, no titles, nothing from the
book. See the plan's stopping conditions.
]]
function FingerInk:startDiagnostics()
    self.diag_until = os.time() + DIAG_SECONDS
    self.diag_lines = 0
    logger.info("FI-DIAG start", "pen_slot", Device.input.pen_slot,
        "wacom", tostring(Device.input.wacom_protocol),
        "backend", tostring(self.input_backend))
end

function FingerInk:diag(slot, sx, sy)
    if not self.diag_until then return end
    if self.diag_lines >= DIAG_MAX_LINES or os.time() > self.diag_until then
        logger.info("FI-DIAG end", self.diag_lines, "lines")
        self.diag_until = nil
        return
    end
    self.diag_lines = self.diag_lines + 1
    logger.info("FI-DIAG", slot.slot, slot.id, tostring(slot.tool),
        sx, sy, tostring(self.stylus_stale_xy))
end
```

Llamar a `self:diag(slot, x, y)` como primera línea de `onStylusEvent`, tras
leer `id, x, y, tool`.

Añadir al menú, justo antes de *Clear this page*:

```lua
            {
                text = _("Log stylus diagnostics (60 s)"),
                enabled_func = function() return self.input_backend == "stylus" end,
                keep_menu_open = false,
                callback = function() self:startDiagnostics() end,
                help_text = _([[Writes one line per pen event to crash.log for a minute, capped at 500 lines: slot, tracking id, tool and whether the position repeated. Digitizer numbers only — nothing from the book. For reporting hardware problems.]]),
            },
```

- [ ] **Paso 4: ejecutar la suite**

- [ ] **Paso 5: commit**

```bash
git add fingerink.koplugin/main.lua fingerink.koplugin/tests/run.lua README.md
git commit -m "feat: add a bounded stylus diagnostic log for the hardware gate"
```

---

### Tarea T12: Ejecutar el gate físico (R6)

**Requiere un Kindle Scribe con KOReader v2026.07 o posterior. No es
automatizable.**

- [ ] **Paso 1: preparar**

Instalar la rama en el dispositivo, anotar en el PR **modelo exacto y versión
exacta de KOReader**, y confirmar antes de nada que el digitalizador se abrió:
buscar `We failed to auto-detect` en el log. Si aparece, el problema es la
detección de FBInk y no el plugin — condición de parada del §13.

- [ ] **Paso 2: ejecutar los 17 puntos del §9 del plan predecesor**

Los dos primeros con el diagnóstico activo:

- Punto 7 (**botón lateral**): expectativa falsable ya escrita. Con el
  diagnóstico activo, mantener el botón y buscar en la salida una línea con
  `tool` = 2 mientras se mantiene. Sale → predicción confirmada. No sale → el
  kernel del Scribe no emite `BTN_STYLUS`; anotarlo y **no compensarlo en el
  plugin**.
- Punto 17 (**hover 10 s**): con el diagnóstico activo, comprobar en la salida
  si el frame de contact-down trae `stale=true`. Eso decide si la heurística de
  R5 estaba resolviendo un problema real o inventado.

- [ ] **Paso 3: registrar el resultado**

Añadir al plan predecesor una sección `## 17. Resultado del gate físico` con:
modelo, versión, los 17 puntos con veredicto, la respuesta a la pregunta de
`BTN_STYLUS`, el veredicto sobre coordenadas rancias, y latencia/ghosting
observados. Si el ghosting o la latencia molestan, **ahí** empieza la Fase 7 del
plan predecesor y no antes.

- [ ] **Paso 4: cerrar la Definición de Terminado**

Recorrer los diez puntos del §14 del plan predecesor y marcar cada uno.

---

## 10. Riesgos de este plan

| Riesgo | Mitigación |
| --- | --- |
| La Etapa 2 rompe la ruta de dedo que hoy funciona | Commit propio y revertible; T6 es un spike con criterio; la ruta de dedo conserva su lógica de passthrough intacta |
| La barra deja de ser el widget más alto y la supresión desaparece en silencio | El invariante ya existe; T7 lo convierte en requisito documentado en ADR-13. Si el gate físico muestra un caso donde no se cumple, es condición de parada |
| T1 se rehace en T7 | Deliberado y acotado: el **test** de T1 está escrito a nivel de comportamiento y sobrevive al refactor; sólo se reescribe la implementación |
| El arreglo de R5 reintroduce el punto fantasma | El test de fantasma existente se mantiene y se ejecuta en el paso 4 de T3; hay una mutación que lo verifica |
| T9 suprime un gesto legítimo de dos dedos (hold) | Documentado en el README como parte de la propia tarea; `two_finger_tap/swipe/pan` no se ven afectados |
| CI verde sin haber corrido nada | El job hace `grep -q '0 failed'`: la suite no usa el código de salida |
| El gate físico vuelve sin datos | T11 existe exactamente para eso, y sus dos límites están puestos para que el log sobreviva |
| `os.time()` en el diagnóstico tiene resolución de un segundo | Suficiente: el límite duro real es el de líneas |

## 11. Condiciones de parada

Además de las del §13 del plan predecesor:

- El spike de T6 falla cualquiera de sus tres criterios → PUERTA B, no forzar.
- La sonda T10 devuelve un `MISMATCH` → hay un stub que miente; parar y
  arreglar el stub antes de seguir, porque todo lo verificado con él queda en
  duda.
- La suite baja de comprobaciones netas tras un refactor → algo se borró en vez
  de reescribirse.

## 12. Definición de terminado de esta remediación

- R1, R4 y R5 tienen cada uno un test que falla antes del arreglo y pasa después,
  y una mutación que lo verifica.
- R9 corregido, y la suite da el mismo total bajo el LuaJIT de KOReader y bajo
  un Lua cualquiera.
- R7: CI en verde sobre un push real.
- R8: `conformance.lua` corre contra el runtime local con 0 mismatches y las
  afirmaciones no verificables **nombradas**.
- R2 y R3: cerrados por la Etapa 2, o R2 cerrado por T9 y R3 documentado, con la
  elección registrada en `decisions.md`.
- R6: §9 del plan predecesor ejecutado en hardware, resultado escrito, y el §14
  recorrido punto por punto.
- README, spec y decisions describen lo implementado y ningún límite listado
  sigue siendo cierto por accidente.

## 13. Registro de verificación de este documento

| Afirmación | Cómo se comprobó |
| --- | --- |
| R1, R4, R5 reproducibles | Probe ejecutado contra `main.lua`/`ink_capture.lua` reales a través del arnés, replicando `routeStylusEvents` + `feedEvent` |
| `hold` no pasa por `feedEvent` | `gesturedetector.lua:675` y `input.lua:1584-1586` @ v2026.07, descargados y leídos |
| `disable_double_tap` por defecto true | `input.lua:166` @ v2026.07 |
| `feedEvent` se llama siempre tras `routeStylusEvents` | Las cinco variantes de `handleTouchEv` en `input.lua` @ v2026.07 |
| `sendEvent` ofrece al widget más alto y para si consume | `uimanager.lua:884-910` @ v2026.07 |
| Los gestos de temporizador entran por `sendEvent` | `uimanager.lua:52` (`__default__`) y `:1441` @ v2026.07 |
| Todos los gestos llevan `pos` | `handleSwipe`, `handlePan`, `handleTwoFingerPan`, `two_finger_tap` en `gesturedetector.lua` @ v2026.07 |
| `WidgetContainer` despacha a hijos primero | `widgetcontainer.lua` @ v2026.07: `handleEvent` → `propagateEvent` → `Widget.handleEvent` |
| El temporizador de hold sólo se arma en el contact-down | `gesturedetector.lua:673` @ v2026.07 (`if new_tap and not self.pending_hold_timer`) |
| La suite corre bajo Lua sin KOReader | `lua test.lua` → `254 passed, 1 failed`, único fallo el global `unpack` |
| El runtime local no tiene la API de stylus | `frontend/version.lua` del checkout: `v2025.08-100-g1d66e440b` |
