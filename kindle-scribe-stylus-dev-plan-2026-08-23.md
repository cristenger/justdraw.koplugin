# FingerInk: plan de desarrollo para Kindle Scribe y stylus

Fecha: 2026-08-23
Auditado: 2026-08-23 (revisión de ingeniería, sin escribir código de producción)
Feature ID: `FI-SCRIBE-STYLUS-001`
Repositorio base: `fingerink.koplugin`, rama `main`, commit `300169f`
Rama de implementación sugerida: `codex/kindle-scribe-stylus`
Alcance de entrega: un PR incremental contra `main`; no mezclar la rama no fusionada `upstream/claude/pdf-ink-annotations`
Stack: plugin KOReader en Lua/LuaJIT, KOReader **v2026.07** o posterior para stylus, Kindle Scribe/Wacom, framebuffer e-ink `mxcfb`

---

## 0. Resumen de auditoría

### 0.0 Estado de implementación (2026-08-23)

Fases 0 a 5 implementadas en la rama `codex/kindle-scribe-stylus`. Suite:
**184 comprobaciones, 0 fallos**, ejecutada con el LuaJIT de KOReader tanto por
`koreader_qa.sh test` como por el shim de raíz. `preflight` PASS, barrido de
sintaxis 8 ficheros PASS, y ReaderUI carga el plugin sobre un PDF a geometría
Scribe (1860×2480 @300 dpi) sin ningún traceback.

Un probe de integración contra el `Device` real del runtime v2025.08 confirma
que los stubs de la suite describen la realidad: `pen_slot == 4`,
`gesture_detector.feedEvent` es función, `Screen:getTouchRotation` existe (el
fallback es defensivo, como afirmaba §4.4), `registerStylusCallback` es `nil` en
ese runtime y por tanto `auto` resuelve a `finger`.

Dos correcciones surgieron al implementar, ambas registradas abajo:

- `Capture:resolveTools` reasigna siempre las cuatro constantes en lugar de sólo
  las exportadas, para que no arrastren el valor de un `Input` anterior.
- `auto` **no** incluye `Device:isSDL()`. Ver el ❌ REMOVED en §5.1.

La Fase 6 (gate físico en Kindle Scribe) sigue pendiente y es obligatoria antes
de declarar compatibilidad. Nada de lo verificado localmente cubre Wacom real,
ghosting ni firmware Kindle.

### 0.1 Veredicto

**Necesita revisiones — incluidas en este documento.** La investigación de fondo del plan original es buena: el contrato del callback, la revocación de la regresión del Scribe, las fórmulas de rotación, el pin de `koreader-base` y la semántica de `scheduleIn` se verificaron todos contra el código fuente del tag y son correctos. Lo que fallaba era el detalle: una versión mínima demasiado alta, una afirmación falsa sobre la visibilidad de las constantes de herramienta, un modelo mental equivocado sobre el ciclo de vida de los datos de slot, y una omisión de clase crash (ningún `pcall` en toda la cadena entre el callback del plugin y el bucle principal de KOReader).

Con las correcciones de §0.2 aplicadas, el plan es implementable. Sin la corrección crítica #1 (contención de errores), un único error de Lua durante el dibujo tumba KOReader y deja el monkey patch instalado.

### 0.2 Cambios críticos

1. **Contención de errores obligatoria.** No existe `pcall` en ningún punto entre `Input.stylus_callback(...)` y el bucle principal: `routeStylusEvents` llama al callback directamente ([input.lua:506](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L506)), `Input:waitEvent` llama a `handleTouchEv` sin proteger ([input.lua:1691](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L1691)) y ni `UIManager:handleInput` ni `reader.lua` lo envuelven. Ambos handlers del plugin deben ejecutarse bajo `pcall` y auto-desarmarse ante error. Ver §5.9.
2. **La versión mínima es v2026.07, no v2026.07.2.** `registerStylusCallback` y los exports `Input.TOOL_TYPE_*` aparecen en v2026.07, y el revert de la regresión del Scribe se fusionó el 2026-07-12, antes de ese tag. `frontend/device/input.lua` es **byte-idéntico** entre v2026.07, v2026.07.1 y v2026.07.2.
3. **Las constantes de herramienta son públicas.** `Input.TOOL_TYPE_FINGER/PEN/ERASER/HIGHLIGHTER` se exportan en [input.lua:1831-1834](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L1831) y la propia suite de KOReader las usa. Leerlas de `Device.input`, con fallback local; no declararlas a ciegas.
4. **Los datos de slot son tablas persistentes y compartidas.** `initMtSlot` no resetea campos y `MTSlots` guarda referencias a `ev_slots`. `id`, `x` e `y` sobreviven entre frames y entre trazos. Las reglas del callback deben ser por *transición*, idempotentes, y el plugin nunca debe retener la tabla del slot.
5. **`tool` no puede gobernar el dibujo.** Al salir de proximidad el pen slot recibe `tool = TOOL_TYPE_FINGER` ([input.lua:763](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L763)) y `routeStylusEvents` lo sigue enrutando por número de slot. Sólo las transiciones de `id` inician y terminan trazos.
6. **`auto` basado sólo en `wacom_protocol` excluye a todos los Kobo con stylus.** Ese flag sólo lo activan los tres Scribe y la reMarkable. Ampliar la regla y documentar la ruta manual.
7. **La decisión de dominación debe latcharse, y el plan debe decir por qué.** Un `false`→`true` a mitad de secuencia deja un `Contact` huérfano con temporizador de hold pendiente; un `true`→`false` crea un contacto nuevo a media pluma y emite un tap espurio al levantar.
8. **`test.lua` en la raíz no lo ejecuta la skill de QA.** `koreader_qa.sh test` sólo corre `$PLUGIN_DIR/tests/run.lua` y su barrido de sintaxis sólo cubre `find $PLUGIN_DIR -name '*.lua'`. Tal como estaba escrito, §10 y §14 habrían reportado verde saltándose la suite entera.
9. **`auto` no debe incluir `isSDL()`.** Corregido al implementar: el ratón del emulador no emite `ABS_MT_TOOL_TYPE`, así que `auto` → `stylus` dejaría el emulador sin poder dibujar. Ver el ❌ REMOVED de §5.1.
10. **La supresión residual es por frame, no por gesto.** Los gestos llevan `pos` pero no `slot`, así que un frame con lápiz en passthrough más una palma deja salir también el gesto de la palma. Documentado como limitación conocida con test y plan de contingencia.
11. **`UIManager:debounce` existe pero es el primitivo equivocado** para tinta en vivo: es un debounce *trailing* portado de underscore.js. Anotado explícitamente para que nadie lo tome por atajo en la Fase 7.

### 0.3 Preguntas abiertas

Requieren hardware o una decisión del autor antes de implementar:

- **¿El digitalizador del Scribe emite `BTN_STYLUS`?** El código predice que el botón lateral, en un dispositivo no-SDL, activa `stylus_eraser_active` y reescribe `tool` a `ERASER` mientras se mantiene pulsado. Si el kernel del Scribe no emite `BTN_STYLUS`, el botón lateral simplemente no hace nada. Sólo verificable en un Scribe.
- **¿La suite de la skill de QA debe vivir dentro del `.koplugin`?** Ponerla en `fingerink.koplugin/tests/` la hace auto-descubrible pero la empaqueta hacia el dispositivo (unos pocos KB). La alternativa es invocación explícita y perder la integración con la skill. §6.4 propone las dos entradas; el autor decide si acepta el peso.
- **¿Se declara compatibilidad con Kobo Elipsa/Sage?** El backend `stylus` explícito debería funcionar allí (esos paneles reportan `ABS_MT_TOOL_TYPE`), pero no hay hardware para probarlo. La recomendación es no declararlo y dejar la opción manual accesible.
- **Percepción física de refresh y ghosting.** Sin cambios respecto al plan original: no se puede evaluar sin un Scribe.

---

## 1. Resultado que debe entregar la implementación

FingerInk debe conservar su funcionamiento actual con dedo en dispositivos como Kindle Paperwhite y añadir una ruta específica para stylus que funcione en Kindle Scribe sin parchear KOReader.

Cuando el modo efectivo sea stylus:

- la punta del lápiz dibuja;
- una herramienta reportada por KOReader como goma borra trazos completos;
- el dedo y la palma no dibujan, no cancelan el trazo del lápiz y no generan gestos de lectura mientras `Draw` está activo;
- la barra sigue siendo alcanzable con dedo o lápiz;
- los menús y diálogos que queden por encima del lector siguen pudiendo cerrarse;
- `Stop`, suspensión y cierre liberan todos los hooks que el plugin todavía posea;
- **un error de Lua en cualquiera de los dos handlers no tumba KOReader y no deja hooks instalados**;
- los trazos existentes y su formato persistido siguen siendo compatibles.

> ⚠️ REVISED: versión mínima bajada de v2026.07.2 a v2026.07 — `frontend/device/input.lua` es byte-idéntico en v2026.07, v2026.07.1 y v2026.07.2 (verificado descargando los tres tags y haciendo `diff`), `registerStylusCallback` y los exports `TOOL_TYPE_*` aparecen por primera vez en v2026.07, y el revert de la regresión del Scribe se fusionó el 2026-07-12, antes del tag v2026.07. Exigir v2026.07.2 rechazaría dos releases perfectamente válidos sin ninguna justificación técnica. Fuente: https://github.com/koreader/koreader/blob/v2026.07/frontend/device/input.lua

El soporte de stylus tendrá como versión mínima documentada **KOReader v2026.07**. La línea base *probada* será la que se use en la Fase 6, que debe declararse explícitamente en el PR. El modo con dedo seguirá usando la ruta heredada y no dependerá de la API nueva.

## 2. No objetivos

No incluir en este PR:

- presión, inclinación, hover o variación dinámica del ancho;
- herramienta highlighter/color;
- exportación o escritura dentro del PDF;
- corrección del anclaje de EPUB, scroll continuo o reflow;
- cambio del formato `fingerink_strokes`;
- una modificación de `frontend/device/input.lua` o de cualquier archivo de KOReader;
- optimización especulativa de refresh, simplificación de puntos o guardado con debounce antes de medir un Scribe real;
- soporte certificado para todos los lectores con stylus. La implementación debe ser razonablemente genérica, pero la matriz de aceptación de este trabajo es Kindle Scribe.

## 3. Estado actual del repositorio

No hay `AGENTS.md`, `CLAUDE.md`, reglas de proyecto, CI ni configuración de tests en el checkout. La rama está limpia al iniciar este plan.

### Módulos actuales

| Archivo | Responsabilidad actual | Impacto del cambio |
| --- | --- | --- |
| `fingerink.koplugin/main.lua` | Ciclo de vida, estado de contactos, toolbar, trazos, menú y persistencia | Cambio principal: modo de entrada, backend efectivo y estado stylus |
| `fingerink.koplugin/ink_capture.lua` | Monkey patch temporal de `GestureDetector:feedEvent` y transformación de coordenadas | Cambio principal: backend dual, propiedad segura de callback/hook, contención de errores y detección de stylus |
| `fingerink.koplugin/ink_bar.lua` | Barra nativa y reenvío de eventos al widget inferior | No debería requerir cambio de producción; sí cobertura de regresión |
| `fingerink.koplugin/ink_render.lua` | Rasterización DDA sin asignación por punto | No tocar en este PR |
| `fingerink.koplugin/ink_store.lua` | Trazos por página y hit test del borrador | No tocar en este PR |
| `fingerink.koplugin/_meta.lua` | Nombre y descripción | Actualizar descripción para dedo y stylus |
| `README.md` | Instalación, uso, límites y comando de tests | Actualizar compatibilidad, modos y requisitos de versión |
| `requirements.md` | Objetivos originales del Paperwhite | Ampliar sin eliminar compatibilidad con Paperwhite |
| `spec.md` | Especificación declarada como fuente de verdad | Documentar las dos rutas y sus máquinas de estado |
| `decisions.md` | ADR-1 a ADR-10 | Añadir ADR-11; **marcar ADR-1 como superseded y ADR-3 como superseded-in-part** |

> 🆕 ADDED: la supersesión de ADRs faltaba. `decisions.md` ADR-1 se titula literalmente “Hook `GestureDetector:feedEvent`, **not** the stylus callback” y afirma que “`registerStylusCallback` also does not exist in v2026.03”. Ese ADR queda invalidado por este trabajo y por el tag v2026.07; dejarlo en pie hace que el repositorio se contradiga a sí mismo. ADR-3 (“un dedo dibuja, dos dedos pasan”) queda superseded-in-part porque en backend `stylus` desaparece el passthrough de dos dedos (§5.3).

### Funciones que se deben preservar

- `FingerInk:setDrawing` sólo instala captura mientras el modo de dibujo está activo.
- `FingerInk:onTouchFrame` mantiene la regla actual de un dedo dibuja y dos dedos pasan al lector en backend `finger`.
- `FingerInk:onContactPoint` impide pintar sobre la barra.
- `FingerInk:endStroke` agrega al store sólo al levantar el contacto.
- `FingerInk:paintTo` sigue siendo la representación autoritativa.
- `InkBar:handleEvent` continúa reenviando únicamente los cuatro handlers que llegan por `UIManager:sendEvent`.
- La barra siempre es visible cuando `drawing == true`.

### Defectos existentes que este PR debe corregir de paso

> 🆕 ADDED: el plan original listaba lo que hay que preservar pero no lo que ya está mal en las mismas funciones que va a tocar. Arreglarlos ahora es más barato que después, y el segundo es una pérdida de datos observable.

1. **`Capture:remove` restaura incondicionalmente.** `Device.input.gesture_detector.feedEvent = self.original` sobrescribe lo que haya, aunque otro código haya encadenado su propio wrapper encima. Ver §5.4.
2. **`FingerInk:teardown` pierde el trazo en vuelo.** No llama a `abortStroke` ni a `resetContacts`; al cerrar el documento con el lápiz apoyado el trazo se descarta en silencio y el estado de contactos se filtra al siguiente documento abierto en la misma sesión. `setDrawing(false)` sí lo hace bien; `teardown` debe hacer lo mismo.
3. **No hay `onResume`.** `onSuspend` llama a `setDrawing(false)`, lo cual es correcto, pero conviene documentar por qué no hace falta un `onResume` simétrico (§5.10).

### Tests disponibles

El README afirma que `luajit test.lua` existe, pero `main` no contiene ese archivo. El historial sí contiene un `test.lua` en el commit no fusionado `ddefe627`, perteneciente a una funcionalidad PDF distinta. Se debe reutilizar su estilo de runner y stubs, no hacer cherry-pick del commit completo.

> ⚠️ REVISED: la ubicación del runner cambia. Verificado leyendo `~/.claude/skills/koreader-simulator-qa/scripts/koreader_qa.sh`: `run_tests()` sólo ejecuta `$PLUGIN_DIR/tests/run.lua` (líneas 153-157) y su barrido de sintaxis recorre `find "$PLUGIN_DIR" -type f -name '*.lua'` (línea 150). Un `test.lua` en la raíz del repositorio no se ejecuta **ni se comprueba sintácticamente**; el comando imprimiría `SKIP no tests/run.lua found` y §14 daría por buena una suite que nunca corrió. Ver §6.4.

## 4. Evidencia externa que gobierna el diseño

### 4.1 Contrato del callback

> ✅ VERIFIED: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L461-L515 — firma, campos del slot, semántica de `true`, y que `routeStylusEvents` se invoca inmediatamente antes de `gesture_detector:feedEvent` en las cinco variantes de `handleTouchEv` (líneas 1085, 1127, 1193, 1254, 1304).

KOReader v2026.07 y posteriores incluyen:

```lua
Input:registerStylusCallback(callback)
Input:unregisterStylusCallback()
```

La invocación efectiva es `callback(input, slot)`, donde `slot` contiene `{slot, id, x, y, tool, timev}`. Devolver un valor verdadero domina el evento y lo retira de `MTSlots` antes de `GestureDetector:feedEvent`; devolver `false` o `nil` permite que KOReader lo convierta en gesto.

La implementación sólo almacena un `self.stylus_callback`. Registrar otro callback lo reemplaza. No existe API pública para encadenar callbacks ni para consultar al propietario.

> 🆕 ADDED: nada en el core de KOReader v2026.07.2 registra un callback de stylus (`grep -rn "registerStylusCallback" frontend/ plugins/` sólo encuentra la definición). Por tanto `stylus_callback_busy` sólo puede deberse a un plugin de terceros. Los dos candidatos conocidos son `pencil.koplugin` y `stylus-annotations.koplugin`, ambos nombrados en el propio ADR-1 del repositorio.

**Qué slots recibe realmente el callback.** `is_stylus` en [input.lua:488-491](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L488) es una disyunción:

```lua
local is_stylus = slot.tool == TOOL_TYPE_PEN
    or slot.tool == TOOL_TYPE_ERASER
    or slot.tool == TOOL_TYPE_HIGHLIGHTER
    or (self.pen_slot and slot.slot == self.pen_slot)
```

La última cláusula es la que importa en Wacom: **cualquier** frame que toque el pen slot llega al callback, tenga el `tool` que tenga, incluido `TOOL_TYPE_FINGER`. Ver §4.2.

**Reescritura de herramienta por botón lateral.** Sólo cuando `slot.tool == TOOL_TYPE_PEN`, `routeStylusEvents` reescribe `tool` a `ERASER` o `HIGHLIGHTER` según `stylus_eraser_active` / `stylus_highlighter_active`. Esos flags los activan `BTN_STYLUS` y `BTN_STYLUS2` en dispositivos no-SDL ([input.lua:747-753](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L747)).

### 4.2 Herramientas y Wacom

> ⚠️ REVISED: el plan original afirmaba que las constantes “son `local` en KOReader; el plugin no puede importarlos” y ordenaba declarar equivalentes locales. Es falso. Se exportan al final del módulo, en [input.lua:1831-1834](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L1831), y la propia suite de KOReader las consume como `Input.TOOL_TYPE_PEN` / `Input.TOOL_TYPE_ERASER` (ver [spec/unit/input_spec.lua:160-249](https://github.com/koreader/koreader/blob/v2026.07.2/spec/unit/input_spec.lua#L160)). Declararlas a ciegas rompería en silencio si upstream renumerara.

Los valores verificados en el tag son:

```lua
TOOL_TYPE_FINGER      = 0
TOOL_TYPE_PEN         = 1
TOOL_TYPE_ERASER      = 2
TOOL_TYPE_HIGHLIGHTER = 3
```

**Cómo debe leerlas el plugin.** Preferir siempre el valor exportado y usar el literal sólo como red de seguridad para runtimes donde el export no exista:

```lua
-- ink_capture.lua
local input = Device.input
Capture.TOOL_ERASER = (input and input.TOOL_TYPE_ERASER) or 2
```

En el protocolo Wacom, KOReader usa un slot de lápiz separado (`pen_slot = main_finger_slot + 4`, es decir 4), reconoce `BTN_TOOL_PEN` y `BTN_TOOL_RUBBER`, y usa `BTN_TOUCH` para los estados down/lift.

> ⚠️ REVISED: la regla “`id == nil` no debe interpretarse como lift; sólo `id < 0` finaliza el trazo” es correcta pero describe el caso menos frecuente y deja fuera el que de verdad va a morder. El caso real es el contrario: **`id` es pegajoso**.

**Ciclo de vida de los datos de slot (crítico).** Verificado en [input.lua:1381-1387, 1423-1450](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L1381):

- `self.ev_slots[slot]` es una tabla **persistente** por número de slot. `initMtSlot` sólo la crea si no existe; nunca limpia campos.
- `newFrame()` vacía `MTSlots` y `active_slots`, pero **no** `ev_slots`.
- `MTSlots` contiene *referencias* a esas tablas persistentes. El propio KOReader lo comenta en `feedEvent`: “tev is actually a simple reference to Input's self.ev_slots[slot]”.

Consecuencias directas para el plugin:

1. `id == nil` sólo ocurre antes del primerísimo tracking id de ese slot en la sesión. Después de un lift, `id` queda en `-1` y **se repite frame tras frame** mientras el lápiz esté en hover sobre el pen slot. El handler de `id < 0` debe ser **idempotente**: finalizar como mucho una vez por secuencia.
2. `x` e `y` **sobreviven** al lift. Un frame de hover puede traer las coordenadas del final del trazo anterior. Nunca deducir “hay contacto” de la presencia de `x`/`y`.
3. El plugin **no debe retener la tabla `slot`** ni pasarla a una closure diferida. Copiar `slot.id`, `slot.x`, `slot.y`, `slot.tool` a variables locales en la primera línea del handler. Guardar la tabla significa observar mutaciones futuras.

> ⚠️ REVISED: añadida la regla de que `tool` no gobierna el dibujo. Verificado en [input.lua:757-767](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L757) y confirmado por el test de KOReader en [spec/unit/input_spec.lua:239-252](https://github.com/koreader/koreader/blob/v2026.07.2/spec/unit/input_spec.lua#L239): con `BTN_TOOL_PEN`/`BTN_TOOL_RUBBER` a valor 0 (lápiz fuera de proximidad), KOReader hace `setCurrentMtSlot("tool", TOOL_TYPE_FINGER)` **sobre el pen slot**. Como `is_stylus` sigue casando por número de slot, ese frame llega al callback con `tool == 0`. Una implementación que decidiera “dibujar” a partir de `tool ~= ERASER` pintaría en un frame de salida de proximidad.

**Regla derivada:** sólo las transiciones de `id` inician y terminan trazos. `tool` selecciona *qué* hace el punto (tinta o borrado), nunca *si* hay punto.

La API pública no promete presión ni tilt en el slot. Aunque el parser conoce las constantes Linux correspondientes, el contrato del callback no las expone y la ruta Wacom no las copia al slot entregado al plugin.

### 4.3 Kindle Scribe

> ✅ VERIFIED: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/kindle/device.lua — `KindleScribe` (L1168), `KindleScribe3` (L1186) y `KindleScribeColorSoft` (L1218) son `isMTK = yes`, `display_dpi = 300`, `touch_dev = "/dev/input/touch"`; sus `init()` hacen `self.input.wacom_protocol = true` en L1888, L1951 y L2014 respectivamente. Ninguno sobrescribe `handleTouchEv`, así que usan `Input:handleTouchEv` por defecto, que sí llama a `routeStylusEvents`.

> ⚠️ REVISED: precisión sobre `INPUT_SCALED_TABLET` y `touch_dev`. El plan original decía “La detección general abre `INPUT_TOUCHSCREEN` y `INPUT_SCALED_TABLET`. Esto evita depender de coordenadas sin escalar”, y luego listaba como condición de parada “el dispositivo entrega coordenadas sin escalar pese a `INPUT_SCALED_TABLET`”. Ese modo de fallo no existe tal como está descrito.

`match_mask` en [device.lua:545](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/kindle/device.lua#L545) es la máscara que se pasa a `fbink_input_scan`. FBInk clasifica un digitalizador como `INPUT_SCALED_TABLET` **sólo si** su rango ABS coincide con la resolución de pantalla; si no, lo clasifica como `INPUT_TABLET`, que no está en la máscara. El modo de fallo real no es “coordenadas mal colocadas” sino **“ningún evento de lápiz en absoluto”**. La condición de parada de §13 se corrige en consecuencia.

Dos matices más:

- `touch_dev = "/dev/input/touch"` **sólo se usa como fallback** cuando `fbink_input_scan` falla por completo ([device.lua:563-571](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/kindle/device.lua#L563)). En ese camino degradado se abre el panel táctil y **no** el digitalizador; es decir, si aparece `We failed to auto-detect the proper input devices` en el log, el stylus no va a funcionar y no es culpa del plugin. Este es el primer log que hay que mirar en la Fase 6.
- `KindleScribe:init` llama a `self.screen:_MTK_ToggleFastMode(true)` ([device.lua:1848](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/kindle/device.lua#L1848)) *antes* de `Kindle.init(self)`.

**Historia de la regresión, verificada.** KOReader v2026.03 rompió el stylus del Scribe mientras el dedo seguía funcionando ([issue #15164](https://github.com/koreader/koreader/issues/15164), cerrado 2026-07-12). La causa fue [PR #14908](https://github.com/koreader/koreader/pull/14908), fusionado el 2026-03-08, cuyo diff completo consiste en **añadir `C.INPUT_TABLET`** —el digitalizador Wacom crudo, sin escalar— a `match_mask`, junto al ya presente `INPUT_SCALED_TABLET`. Abrir ambos produjo eventos en conflicto. [PR #15675](https://github.com/koreader/koreader/pull/15675) revirtió ese cambio y se fusionó el 2026-07-12, antes del tag v2026.07.

Consecuencia práctica que el plan original no explotaba: **la máscara de v2026.07.x es idéntica a la de v2025.10**, es decir, a la que ya funcionaba. Verificado descargando `frontend/device/kindle/device.lua` de v2025.10, v2026.03, v2026.07, v2026.07.1 y v2026.07.2 y comparando la línea `local match_mask`. Esto es evidencia positiva de que el Scribe sí entrega eventos de lápiz en la línea base elegida.

### 4.4 Rotación

> ✅ VERIFIED: `routeStylusEvents()` corre antes de `gesture_detector:feedEvent` en el mismo handler de `SYN_REPORT`, y `adjustGesCoordinate` usa `self.screen:getTouchRotation()` ([gesturedetector.lua:1437](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/gesturedetector.lua#L1437)). `getTouchRotation` está definido en [koreader-base ffi/framebuffer.lua:122](https://github.com/koreader/koreader-base/blob/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/framebuffer.lua#L122) y su comentario dice explícitamente que el frontend puede sobrescribirlo; PocketBook lo hace ([pocketbook/device.lua:181](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/pocketbook/device.lua#L181)). Cambiar `toScreen` a `getTouchRotation` es correcto.

> ✅ VERIFIED: **las cuatro fórmulas actuales de `Capture.toScreen` son correctas.** Comparadas una a una con `GestureDetector:translateCoordinates` ([gesturedetector.lua:1396-1421](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/gesturedetector.lua#L1396)) y con los valores de `fb.DEVICE_ROTATED_*` (0/1/2/3, [framebuffer.lua:78-81](https://github.com/koreader/koreader-base/blob/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/framebuffer.lua#L78)):
>
> | modo | KOReader | FingerInk |
> | --- | --- | --- |
> | 1 CW | `(width - y), (x)` | `screen:getWidth() - y, x` |
> | 2 UD | `(width - x), (height - y)` | `screen:getWidth() - x, screen:getHeight() - y` |
> | 3 CCW | `(y), (height - x)` | `y, screen:getHeight() - x` |
>
> `getWidth()`/`getHeight()` devuelven las dimensiones **post-rotación**, y ambos lados las consultan en el mismo frame, así que coinciden por construcción.

> 🆕 ADDED: el fallback a `getRotationMode` es defensivo, no funcional. `getTouchRotation` existe también en el `koreader-base` del runtime local v2025.08 (`base/ffi/framebuffer.lua:122`), así que no hay ningún runtime realista donde el fallback se ejerza. Mantenerlo cuesta una línea y evita un `nil call` si alguien inyecta un stub de Screen incompleto en los tests — pero el test que ejercita el fallback debe existir precisamente porque en producción nunca se ejecuta.

### 4.5 Refresh

> ✅ VERIFIED: `fb:refreshFast` → `refreshFastImp` → `mech_refresh(false, self.waveform_fast, ...)` ([framebuffer_mxcfb.lua:804-806](https://github.com/koreader/koreader-base/blob/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/framebuffer_mxcfb.lua#L804)). Para MTK — que es lo que es el Scribe — `waveform_fast = C.MTK_WAVEFORM_MODE_DU` ([framebuffer_mxcfb.lua:897](https://github.com/koreader/koreader-base/blob/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/framebuffer_mxcfb.lua#L897)), y `_MTK_ToggleFastMode` existe en L656.

Esto respalda conservar inicialmente el `Screen:refreshFast` regional actual. Cambiar entrada y política de refresh en el mismo paso dificultaría atribuir problemas de latencia o ghosting.

### 4.6 Temporización

> ✅ VERIFIED: `UIManager:scheduleIn(seconds, action, ...)` no tiene sentencia `return` ([uimanager.lua:335-340](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/ui/uimanager.lua#L335)). `UIManager:unschedule(action)` recorre `_task_queue` comparando `task.action == action` y devuelve un booleano ([uimanager.lua:440-449](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/ui/uimanager.lua#L440)).

Si la fase posterior incorpora throttling, debe guardar una función estable y pasar esa misma referencia a ambas llamadas. No copiar el patrón de DrawNotes que guarda el retorno de `scheduleIn`.

> 🆕 ADDED: **no usar `UIManager:debounce` para el flush de tinta.** Existe en [uimanager.lua:386-423](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/ui/uimanager.lua#L386) y es tentador, pero es un debounce *trailing* portado de underscore.js: con `immediate = false` la acción no corre hasta que el flujo de entrada se calla durante `seconds` — es decir, no aparecería tinta hasta levantar el lápiz. Con `immediate = true` corre en el flanco de subida y luego se traga todo lo demás durante la ventana. Ninguno de los dos modos produce una cadencia periódica de flush. Lo que la Fase 7 necesita es un **throttle**, que KOReader no ofrece; hay que escribirlo (§7, Fase 7).

## 5. Arquitectura decidida

### 5.1 Modos persistidos

Añadir `fingerink_input_mode` a `G_reader_settings` con estos valores:

| Valor | Resolución |
| --- | --- |
| `auto` | `stylus` cuando existen ambos métodos de callback **y** `Device.input.wacom_protocol == true`; `finger` en otro caso |
| `stylus` | Requiere sólo la API; si no existe o está ocupada, no activa dibujo y muestra una notificación |
| `finger` | Usa exactamente la captura actual |

> ⚠️ REVISED: `wacom_protocol` es un flag muy estrecho: `grep -rn "wacom_protocol" koreader-2026.07.2/` sólo lo encuentra activado en `kindle/device.lua` (los tres Scribe) y `remarkable/device.lua:276`. **Kobo no lo activa nunca.** Los Kobo con stylus (Elipsa, Sage, Libra Colour) reportan la herramienta por `ABS_MT_TOOL_TYPE` ([input.lua:1067](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L1067)), lo que hace que `slot.tool == TOOL_TYPE_PEN` y que `routeStylusEvents` dispare — pero `auto` los manda a `finger`. Es deliberado: sin hardware para validarlos, un `auto` agresivo rompería a los usuarios de Kobo sin stylus del mismo panel. La ruta manual (`stylus` explícito, sin requisito de `wacom_protocol`) existe para ellos.

> ❌ REMOVED: `Device:isSDL()` como segundo disparador de `auto`. La auditoría lo propuso razonando desde `stylus_tool_protocol = self.wacom_protocol or is_sdl` ([input.lua:756](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L756)); la premisa es cierta pero insuficiente. Verificado durante la implementación en [koreader-base ffi/SDL3.lua](https://github.com/koreader/koreader-base/blob/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/SDL3.lua): los eventos `SDL_EVENT_PEN_*` sí se traducen a `SDL_PEN_SLOT = 4` con `TOOL_TYPE_PEN`/`TOOL_TYPE_ERASER` (L361-L440), pero el **ratón** entra por `genTouchDownEvent` (L473-L480) en el slot 0 o 1 y **no emite `ABS_MT_TOOL_TYPE` en absoluto**. En el emulador, con `auto` → `stylus`, el ratón nunca llegaría al callback y el filtro residual se lo tragaría: el plugin abriría sin poder dibujar. Servir el caso raro (tableta gráfica conectada) rompiendo el común (ratón) es el intercambio equivocado, y el modo `stylus` explícito ya cubre la tableta.

**Por qué `auto` no puede simplemente elegir `stylus` siempre que exista la API.** El backend stylus instala el filtro residual, que se traga *todo* el táctil fuera de la barra. En un Paperwhite eso dejaría al usuario sin ninguna forma de dibujar: el callback nunca dispara y el dedo está suprimido. `auto` debe fallar hacia `finger`, que es el modo utilizable en ausencia de lápiz.

**Kobo Elipsa/Sage y similares.** Con esta regla siguen cayendo en `finger` bajo `auto`. Es deliberado: no hay hardware para validarlos y un `auto` demasiado agresivo rompería a usuarios de Kobo sin stylus del mismo modelo de panel. La ruta manual (`stylus` explícito) existe precisamente para ellos y **no** exige `wacom_protocol`. Documentarlo en el README como no soportado pero disponible.

El valor predeterminado será `auto`. Esto no altera el Paperwhite porque allí `wacom_protocol` no está activo. En un Scribe antiguo sin callback, `auto` cae a la ruta heredada; debe documentarse que esa ruta no ofrece rechazo de palma ni garantiza el lápiz.

No cambiar de modo mientras `drawing == true`. Los items de radio del menú estarán deshabilitados mientras se dibuja. Esto evita abortar y reinstalar captura dentro de una secuencia de contacto.

### 5.2 Flujo de entrada

```text
setDrawing(true)
  |
  +-- modo efectivo finger
  |     `-- wrapper feedEvent actual
  |           +-- 1 contacto -> dibuja
  |           `-- 2+ contactos -> pasa gestos a KOReader
  |
  `-- modo efectivo stylus
        +-- registerStylusCallback          [corre 1º, dentro de routeStylusEvents]
        |     +-- PEN/ERASER fuera de UI -> dibuja/borra y devuelve true
        |     `-- barra o diálogo -> devuelve false
        |
        `-- wrapper feedEvent residual      [corre 2º, mismo SYN_REPORT]
              +-- dedo/palma fuera de UI -> llama al detector y vacía sus gestos
              `-- contacto iniciado en barra o diálogo -> deja pasar
```

> 🆕 ADDED: **el orden dentro de un frame es una garantía dura, no una casualidad.** Las cinco variantes de `handleTouchEv` tienen la misma forma: `routeStylusEvents()` y acto seguido `gesture_detector:feedEvent(self.MTSlots)`, dentro del mismo `EV_SYN:SYN_REPORT` ([input.lua:1085-1091](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L1085) y equivalentes en 1127, 1193, 1254, 1304). Es decir, dentro de un frame `onStylusEvent` **siempre** corre antes que `onStylusTouchFrame`, y cuando el filtro residual ve el frame el slot dominado del lápiz ya no está. Esa garantía es exactamente lo que permite la regla “el filtro residual nunca aborta `self.stroke`”: cuando lo ejecuta, la decisión del lápiz para ese frame ya está tomada.

El wrapper residual es necesario. Registrar sólo el callback de stylus eliminaría el lápiz del flujo de gestos, pero los contactos de palma seguirían llegando al lector y podrían cambiar de página.

### 5.3 Política de palma

En backend `stylus`, todos los contactos táctiles fuera de la barra o un diálogo se consumen mientras `Draw` está activo. No intentar distinguir dedo de palma.

Consecuencia deliberada: los gestos táctiles de una y varias manos no navegan durante la escritura. Para navegar, el usuario pulsa `Stop`. Mantener los gestos de dos dedos sería incompatible con un rechazo de palma predecible. Esto supersede en parte a ADR-3, que debe anotarse.

> 🆕 ADDED: **limitación conocida — la decisión de emisión es por frame, no por slot.** Los gestos que devuelve `feedEvent` llevan `ges`, `pos` y `time` pero **no** el número de slot (ver las construcciones en [gesturedetector.lua:539-548](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/gesturedetector.lua#L539) y L604-614). Por tanto el wrapper sólo puede emitir o descartar el array entero. Si en el mismo frame coinciden una secuencia de lápiz en passthrough (porque empezó sobre la barra) y una palma apoyada fuera de ella, emitir para el lápiz también deja salir el gesto de la palma.
>
> **Decisión: se acepta.** La ventana es estrecha (requiere apoyar la palma exactamente mientras se pulsa un botón de la barra con el lápiz) y la alternativa es peor de mantener. Debe cubrirse con un test (§8) y aparecer en el README.
>
> **Contingencia, sólo si la Fase 6 demuestra que la barra se vuelve inutilizable:** filtrar el array devuelto por geometría en vez de emitirlo entero, conservando únicamente los gestos cuyo `pos` cae dentro de la barra. Es viable, pero exige recordar que **`ges.pos` está sin rotar** en ese punto: `adjustGesCoordinate` corre *después*, ya en `Input:handleTouchEv`, así que habría que pasar `pos` por `Capture.toScreen` antes de compararlo con `bar.dimen`. Eso va en un commit aparte, nunca en el mismo que la captura.

### 5.4 Propiedad segura de recursos globales

Antes de mutar nada, `Capture:installStylus` debe comprobar:

1. `Device.input` existe.
2. `registerStylusCallback` y `unregisterStylusCallback` son funciones.
3. `gesture_detector.feedEvent` existe, porque se necesita para filtrar palma.
4. `input.stylus_callback == nil` o ya es exactamente el callback propio.

> ✅ VERIFIED: la comprobación 4 es segura. `stylus_callback` no figura entre los campos por defecto de la clase `Input` ([input.lua:180-195](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L180)), así que `input.stylus_callback` es `nil` hasta que alguien registra, sin riesgo de leer un valor heredado de la metatabla de clase.

Si existe un callback ajeno, devolver `false, "stylus_callback_busy"`. No sobrescribirlo y no caer silenciosamente a dedo cuando el usuario eligió `stylus`.

Al retirar captura:

- marcar primero los handlers propios como inactivos para que cualquier wrapper que quede encadenado sea passthrough;
- llamar a `unregisterStylusCallback()` sólo si `input.stylus_callback` sigue siendo exactamente el callback propio;
- restaurar `feedEvent` sólo si el valor actual sigue siendo exactamente el wrapper propio;
- si otro código reemplazó cualquiera de los dos, registrar un warning y no sobrescribirlo;
- limpiar todas las referencias internas aun cuando ya no se posea el recurso.

La misma comprobación de identidad debe mejorar la retirada del backend `finger`; el código actual (`ink_capture.lua:38-43`) restaura incondicionalmente el original.

### 5.5 Máquina de estado stylus

Añadir a `FingerInk`:

```lua
self.input_mode = "auto" | "stylus" | "finger"
self.input_backend = nil | "stylus" | "finger"
self.stylus_active = false        -- hay contacto de lápiz en curso
self.stylus_passthrough = false   -- la secuencia en curso va a la UI
```

No reutilizar `n_contacts` para el lápiz. La palma se procesa después de que KOReader haya retirado el slot dominado del lápiz, por lo que mezclar ambos contadores recrearía el bug que se intenta eliminar.

> ⚠️ REVISED: las seis reglas se reescriben para que sean **por transición** y **idempotentes**, según el ciclo de vida de §4.2. Las reglas originales asumían que cada frame trae información nueva; con tablas persistentes eso no se cumple.

Reglas de `FingerInk:onStylusEvent(slot)`. La primera línea copia escalares:

```lua
local id, x, y, tool = slot.id, slot.x, slot.y, slot.tool
```

1. **`id == nil`** → consumir el frame (`true`) sin tocar el trazo. Es hover previo al primer tracking id.
2. **`id >= 0` y `not self.stylus_active`** — flanco de bajada. Marcar `stylus_active = true` y **latchar** `stylus_passthrough` de una vez para toda la secuencia, evaluando:
   - `self:dialogOnTop()`;
   - si `x` e `y` existen, si el primer punto cae dentro de `bar.dimen` tras `Capture.toScreen`.

   Si no hay `x`/`y` en el frame de bajada, no latchar passthrough por geometría todavía; diferir esa parte al primer frame con coordenadas, pero **no** dibujar antes de haberla evaluado.
3. **Passthrough latchado** → devolver `false` durante toda la secuencia, incluido el lift.
4. **`id >= 0`, no passthrough, con `x`/`y`** → transformar coordenadas y llamar a la ruta compartida de punto con `tool`.
5. **Herramienta.** `tool == Capture.TOOL_ERASER` fuerza borrado. Cualquier otro valor —incluido `TOOL_TYPE_FINGER`, que aparece al salir de proximidad (§4.2), y `TOOL_TYPE_HIGHLIGHTER`— usa la herramienta manual actual. El highlighter no recibe semántica especial en este PR.
6. **`id < 0`** — flanco de subida, **idempotente**: si `stylus_active` es falso, no hacer nada más que devolver el mismo booleano que devolvió el resto de la secuencia. Si es verdadero: finalizar el trazo cuando se estaba consumiendo, poner `stylus_active = false`, y devolver `true`; si era passthrough, resetear y devolver `false`.

La función debe devolver siempre un booleano porque ese valor gobierna si KOReader retira el slot antes del detector. (`routeStylusEvents` hace `if dominated then`, así que `nil` también valdría como falso, pero un booleano explícito es lo que hace legibles los tests.)

> 🆕 ADDED: **invariante de latchado, y por qué es obligatorio.** La decisión de dominar se toma en el flanco de bajada y no puede cambiar hasta el lift. No es estilo, es corrección, y se deriva de [gesturedetector.lua:228-249 y 402-429](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/gesturedetector.lua#L228):
>
> - **`true` → `false` a media secuencia.** El pen slot vuelve a `MTSlots` sin que GestureDetector haya visto nunca su bajada. `feedEvent` no encuentra `Contact` para el slot, crea uno nuevo, y `Contact:initialState` lo marca `down = true` con `initial_tev` copiado de la posición *actual*. Al levantar sale un **tap espurio** en mitad del trazo.
> - **`false` → `true` a media secuencia.** El `Contact` que ya existe nunca ve su lift. Queda en `active_contacts` con su `pending_hold_timer` vivo: dispara un `hold` fantasma y bloquea el slot hasta el siguiente `dropContacts()`. `GestureDetector:dropContact` sólo se ejecuta al ver `id == -1`.
>
> Ambos fallos son intermitentes y difíciles de atribuir en hardware. El test correspondiente es obligatorio (§8).

### 5.6 Filtro táctil residual

Crear `FingerInk:onStylusTouchFrame(slots)`. Puede reutilizar `contacts`, `n_contacts` y `passthrough` sólo para contactos residuales, pero nunca debe llamar a `onContactPoint`.

Reglas:

- si `stylus_passthrough` está activo, devolver `true` para que la secuencia de lápiz destinada a la UI llegue al detector (con la limitación documentada en §5.3);
- un contacto que comienza dentro de la barra activa passthrough hasta que todos los contactos residuales se levanten;
- si hay diálogo encima del lector, activar passthrough para la secuencia;
- cualquier otro dedo/palma devuelve `false`, tanto con uno como con varios contactos;
- mantener el patrón `passthrough or was_passthrough` en el frame de lift para que los taps permitidos se completen;
- nunca abortar `self.stroke` al detectar dedos durante una secuencia de lápiz;
- **`#slots == 0` es un frame válido y frecuente** —ocurre siempre que el lápiz era el único contacto y fue dominado— y no debe interpretarse como “todos los contactos se levantaron”. Iterar sobre el array y no tocar estado si está vacío es suficiente; el código actual de `onTouchFrame` ya se comporta así.

### 5.7 Coordenadas y herramienta compartida

Cambiar `Capture.toScreen` a:

```lua
local mode = screen.getTouchRotation
    and screen:getTouchRotation()
    or screen:getRotationMode()
```

Mantener las fórmulas existentes —verificadas contra `translateCoordinates` en §4.4— y añadir tests para las cuatro rotaciones más uno que ejercite el fallback con un stub sin `getTouchRotation`.

Extender `onContactPoint` con un parámetro opcional `tool`. La condición de borrado será conceptualmente:

```lua
local physical_eraser = tool == Capture.TOOL_ERASER
if physical_eraser or self.eraser then
    self:eraseAt(x, y)
else
    -- start/add stroke actual
end
```

No guardar `tool` en el stroke. El formato persistido permanece `{n, w, x1, y1, ...}`.

> 🆕 ADDED: `onContactPoint` es la única ruta compartida entre los dos backends y su firma cambia. El backend `finger` debe seguir llamándola **sin** `tool`, de modo que `tool == nil` y `physical_eraser` sea falso. Un test de regresión debe fijar eso explícitamente, porque es el punto exacto donde una refactorización descuidada rompería el Paperwhite.

### 5.8 Refresh y persistencia en la primera entrega

Conservar sin cambios:

- rasterización DDA;
- pintura directa en `Screen.bb`;
- un `refreshFast` o `refreshPartial` por segmento;
- guardado mediante `onSaveSettings`;
- sidecar `fingerink_strokes`.

La primera prueba física debe establecer la línea base. Sólo abrir la fase de tuning si aparece uno de estos síntomas:

- backlog visible entre punta y tinta;
- trazos con huecos que no provengan del hit test;
- freeze o errores de ioctl/refresh;
- ghosting inaceptable antes del siguiente cambio de página;
- crecimiento de sidecar que afecte apertura o cambio de página.

### 5.9 Contención de errores y auto-desarme

> 🆕 ADDED: esta sección no existía y cubre el peor modo de fallo del diseño. Sin ella, un `nil index` en `onStylusEvent` no produce una tinta ausente: produce un KOReader caído con el hook todavía instalado.

**Por qué es necesario.** No hay ninguna protección entre el handler del plugin y el bucle principal de eventos:

- `routeStylusEvents` invoca `self.stylus_callback(self, slot)` sin `pcall` ([input.lua:506](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L506));
- `Input:waitEvent` invoca `self:handleTouchEv(event)` sin `pcall` ([input.lua:1691](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L1691)); el único `pcall` cercano protege la llamada C `input.waitForEvent` (L1614), no el despacho posterior;
- ni `UIManager:handleInput` ni `reader.lua` envuelven esa ruta.

Un error propagado desde el plugin se convierte en traceback de KOReader. Y como el error escapa antes de llegar a `setDrawing(false)`, el wrapper de `feedEvent` y el callback siguen registrados: la sesión queda con la entrada capturada por un plugin en estado inconsistente.

**Diseño requerido.** Los dos handlers instalados por `Capture` deben ser envoltorios protegidos, no las funciones del plugin directamente:

```lua
-- patrón, no implementación
local function guard(self, fn, fail_value)
    return function(...)
        local ok, res = pcall(fn, ...)
        if ok then return res end
        logger.err("FingerInk: input handler failed:", res)
        self:disarm()          -- retira captura por identidad, idempotente
        return fail_value      -- callback: false. wrapper residual: true.
    end
end
```

Reglas concretas:

1. **Valor de retorno seguro tras fallo.** El callback de stylus devuelve `false` (no dominar: el evento sigue su curso normal). El wrapper residual devuelve `true` (emitir: los gestos llegan al lector). En ambos casos el fallo degrada hacia “KOReader se comporta como si el plugin no estuviera”, nunca hacia “la entrada desaparece”.
2. **Auto-desarme.** El primer error retira toda la captura por identidad (§5.4), pone `drawing = false`, aborta el trazo en vuelo y actualiza la barra. No reintentar.
3. **Notificar una sola vez.** Una `Notification` al desarmarse, con un texto accionable (“Finger Ink: drawing stopped after an input error”). Nunca una por frame.
4. **Reentrada.** `disarm()` puede invocarse desde dentro del propio wrapper que está desmontando. Debe ser idempotente y no debe asumir que `self.bar` existe.
5. **El `pcall` no envuelve `original(gd_self, slots)`.** Llamar al `feedEvent` original es responsabilidad de KOReader y un error allí no es del plugin; protegerlo enmascararía bugs de core. Sólo se protege la lógica propia.

El coste es un `pcall` por frame de entrada. En LuaJIT eso es despreciable frente al ioctl de refresh que ya se hace por segmento.

### 5.10 Suspensión, reanudación y reset de estado

> 🆕 ADDED: el plan original mencionaba suspensión sólo en las matrices de test, sin describir qué hace KOReader por debajo ni por qué el diseño actual es suficiente.

`Device:onPowerEvent` acaba llamando a `Input:inhibitInput(true)`, que ([input.lua:1731-1771](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L1731)):

- guarda `handleTouchEv` en `_abs_ev_handler` y lo sustituye por `voidEv` — mientras dure la inhibición **no se llama a `routeStylusEvents` ni a `feedEvent`**, así que ni el callback ni el wrapper reciben nada;
- llama a `Input:resetState()`, que hace `gesture_detector:dropContacts()` y **reconstruye `self.ev_slots` desde cero** ([input.lua:690-704](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L690)), dejando sólo el finger slot.

Consecuencias para el plugin:

1. Si el usuario suspende con el lápiz apoyado, **el lift nunca llega**. `stylus_active` quedaría `true` para siempre. Por eso `onSuspend` → `setDrawing(false)` es obligatorio, y `setDrawing(false)` debe resetear el estado stylus además del de contactos.
2. Tras reanudar, la tabla del pen slot es **nueva**. Cualquier referencia guardada apunta a un objeto muerto — otra razón para no retener la tabla del slot (§4.2).
3. No hace falta `onResume`: al reanudar, `drawing` ya es `false` y la captura está retirada. El usuario vuelve a pulsar `Draw`. Documentar esa decisión en el README para que no se lea como un bug.

## 6. Cambios por archivo

### 6.1 `fingerink.koplugin/ink_capture.lua`

Reemplazar la interfaz monolítica por una explícita, manteniendo el módulo singleton:

```lua
Capture.TOOL_FINGER      -- leídos de Device.input.TOOL_TYPE_*, con literal de fallback
Capture.TOOL_PEN
Capture.TOOL_ERASER
Capture.TOOL_HIGHLIGHTER

Capture:supportsStylus()
Capture:isStylusSlot(slot, input)
Capture:installFinger(frame_handler)
Capture:installStylus(stylus_handler, residual_frame_handler, on_error)
Capture:remove()
Capture.toScreen(x, y)
```

Detalles obligatorios:

- `installFinger` conserva la llamada al detector original y vacía el array devuelto cuando `frame_handler` no permite emitir.
- `installStylus` registra el callback y además instala el mismo tipo de wrapper para el residual táctil.
- **Ambos instaladores envuelven los handlers recibidos con la guarda de §5.9** y usan `on_error` para avisar a `main.lua`. `Capture` no conoce a `FingerInk`; la política de desarme la pone quien instala.
- Guardar `input`, `gesture_detector`, `original_feed`, `feed_wrapper`, `stylus_callback`, `backend`, `active`.
- Validar todo antes de la primera mutación.
- Devolver `true, backend` o `false, reason`.
- No lanzar errores por API ausente; convertirlos en reasons que `main.lua` pueda presentar.
- `remove` debe ser idempotente y comprobar identidad antes de restaurar (§5.4).
- Las constantes se resuelven **una vez, al instalar**, no en el momento de carga del módulo: `Device.input` puede no estar completamente inicializado cuando el plugin se requiere.

### 6.2 `fingerink.koplugin/main.lua`

Cambios concretos:

1. Leer `fingerink_input_mode`, default `auto`.
2. Inicializar estado stylus (`input_backend`, `stylus_active`, `stylus_passthrough`).
3. Añadir `resolveInputBackend()`:
   - `finger` siempre devuelve `finger`;
   - `stylus` devuelve error si falta la API o está ocupada, **sin** exigir `wacom_protocol`;
   - `auto` elige `stylus` con API y (`wacom_protocol` o `isSDL()`).
4. Refactorizar `setDrawing(true)`:
   - resolver backend;
   - instalarlo;
   - asignar `drawing = true` sólo después de una instalación completa;
   - traducir reasons a notification y log.
5. Refactorizar `setDrawing(false)` y `teardown()` para abortar el trazo, resetear los dos estados y retirar captura una vez. `teardown` debe hacer lo mismo que `setDrawing(false)`, que hoy no hace (§3).
6. Añadir `onStylusEvent`, `onStylusTouchFrame`, `resetStylusState`, `disarmInput`.
7. Añadir parámetro `tool` a `onContactPoint`, con `nil` equivalente al comportamiento actual.
8. Añadir `inputModeItem(text, value)` y submenú `Input mode` con tres radios.
9. Deshabilitar cambio de modo mientras `drawing` esté activo.
10. Mantener todos los nombres de Dispatcher existentes.

Mensajes de error mínimos:

- `no_stylus_api`: “Stylus input requires KOReader v2026.07 or newer”.
- `stylus_callback_busy`: “Another plugin is already using stylus input”.
- `no_gesture_detector`: conservar el mensaje actual de imposibilidad de capturar touch.
- `handler_error` (§5.9): “Finger Ink: drawing stopped after an input error”.

No mostrar notificaciones por cada frame ni loguear coordenadas de todos los puntos. Como diagnóstico, loguear únicamente: backend seleccionado y por qué, transición tool/contact down, lift, conflicto de ownership, retirada de ownership y desarme por error.

### 6.3 `fingerink.koplugin/_meta.lua`

Cambiar la descripción para indicar dibujo con dedo o stylus. No renombrar el plugin ni el directorio.

### 6.4 Runner de tests

> ⚠️ REVISED: cambia la ubicación. Un `test.lua` en la raíz del repositorio **no lo ejecuta ni lo comprueba** `koreader_qa.sh` (§3), de modo que el plan original tenía una brecha entre lo que §14 declara verificado y lo que la herramienta verifica de hecho.

Estructura:

- **`fingerink.koplugin/tests/run.lua`** — la suite real. Es lo que ejecuta `koreader_qa.sh test` (`(cd "$PLUGIN_DIR" && luajit tests/run.lua)`), con el directorio de trabajo en la carpeta del plugin. Al vivir bajo `$PLUGIN_DIR`, además entra en el barrido de sintaxis de LuaJIT.
- **`test.lua`** en la raíz — shim de una línea que carga el anterior, para que el comando documentado en el README siga funcionando desde la raíz del repositorio.

El runner debe resolver `package.path` sin depender del directorio de trabajo, porque se invoca desde dos sitios distintos. Derivarlo del propio script (`arg[0]`) en lugar de asumir `./` o `fingerink.koplugin/`.

Resto del patrón, tomado del test histórico `ddefe627:test.lua`:

- stubs mediante `package.preload`;
- cargar los módulos reales del plugin;
- runner pequeño con `check`, contador de fallos y exit code distinto de cero;
- no depender de una sesión KOReader.

No copiar los tests PDF de aquella rama.

**Nota de coste:** `tests/` viaja al dispositivo dentro del `.koplugin`. Son unos pocos KB y KOReader no carga nada fuera de `main.lua`/`_meta.lua`, así que es inocuo. Si el autor prefiere no empaquetarlo, la alternativa es dejar la suite sólo en la raíz y renunciar a la integración con la skill de QA — en cuyo caso §10 y §14 deben dejar de mencionar `koreader_qa.sh test` como si cubriera la suite.

### 6.5 Documentación

- `README.md`: compatibilidad, **versión mínima v2026.07**, modos, palma estricta, goma condicionada a lo reportado por KOReader, la limitación de §5.3, la ausencia deliberada de `onResume` (§5.10) y los tests reales.
- `requirements.md`: preservar Paperwhite y añadir Scribe; mover palm rejection fuera de “out of scope” sólo para backend stylus.
- `spec.md`: convertir la captura única en dual y documentar estado/handover, incluido el invariante de latchado (§5.5) y la garantía de orden intra-frame (§5.2).
- `decisions.md`:
  - añadir **ADR-11 “callback de stylus + filtro residual de touch”**, registrando que un callback sin filtro no rechaza palma;
  - añadir **ADR-12 “handlers de entrada protegidos y auto-desarme”** (§5.9), porque es una decisión arquitectónica con coste (un `pcall` por frame) y consecuencias (degradación a passthrough), no un detalle de implementación;
  - marcar **ADR-1 como superseded por ADR-11** y corregir su afirmación de que la API no existe, acotándola a v2026.03;
  - marcar **ADR-3 como superseded-in-part** para el backend stylus.

### 6.6 Archivos que no se deben tocar

- `fingerink.koplugin/ink_render.lua`;
- `fingerink.koplugin/ink_store.lua`;
- `fingerink.koplugin/ink_bar.lua`, salvo que un test revele una regresión real;
- `demo.mp4`;
- el checkout `/Users/christianstenger/koreader/koreader` y sus plugins instalados;
- cualquier archivo de KOReader core;
- la rama `upstream/claude/pdf-ink-annotations`.

## 7. Orden de implementación

### Fase 0 — Congelar baseline

1. Confirmar `git status --short` vacío.
2. Crear `codex/kindle-scribe-stylus` desde `main`/`300169f`.
3. Ejecutar preflight y sintaxis con la skill de QA.
4. Registrar que el runtime local es v2025.08 y sólo cubre el fallback, no la API de v2026.07.

Criterio de salida: baseline reproducible y sin modificar el checkout de KOReader.

### Fase 1 — Crear tests que fallen

Crear primero `fingerink.koplugin/tests/run.lua` con stubs para `Device.input`, GestureDetector, Screen, UIManager, widgets y settings. Añadir los casos de la sección 8. Al menos los tests de callback y los de contención de errores deben fallar contra el código actual antes de implementar.

Criterio de salida: `koreader_qa.sh test` ejecuta la suite (no imprime `SKIP`), los tests heredados de dedo siguen verdes y los tests stylus están rojos por ausencia de API interna del plugin.

### Fase 2 — Backend dual en `ink_capture.lua`

1. Añadir constantes resueltas desde `Device.input` y helpers.
2. Renombrar la instalación actual a `installFinger` sin cambiar su semántica.
3. Implementar validación atómica de `installStylus`.
4. Instalar callback y filtro residual, ambos bajo la guarda de §5.9.
5. Implementar retirada por identidad e idempotencia.
6. Cambiar transformación a `getTouchRotation` con fallback.

Criterio de salida: todos los tests unitarios del módulo Capture verdes, incluido conflicto de ownership y desarme por error.

### Fase 3 — Estado y UX en `main.lua`

1. Añadir setting y resolución de backend.
2. Conectar callbacks desde `setDrawing`.
3. Implementar la máquina stylus con latchado e idempotencia.
4. Implementar el filtro de palma.
5. Integrar goma física.
6. Corregir `teardown` (§3).
7. Añadir submenú de modo.
8. Añadir logs de transición, no logs por punto.

Criterio de salida: matriz completa de entrada verde y ninguna regresión en la barra.

### Fase 4 — Documentación y metadatos

Actualizar los archivos documentales/meta, incluidos ADR-11, ADR-12 y las supersesiones. El README no debe afirmar cobertura física hasta completarse la Fase 6.

Criterio de salida: documentación coincide con el código, versión mínima y límites reales.

### Fase 5 — QA local

1. Ejecutar unit tests con el LuaJIT del runtime KOReader y **confirmar en la salida que la suite corrió**, no sólo que el comando salió con 0.
2. Ejecutar compilación de los Lua del plugin.
3. Lanzar sesión aislada, abrir un PDF y verificar carga de ReaderUI.
4. Probar el backend finger en el emulador.
5. Probar la ruta stylus mediante stubs; el SDL/runtime local v2025.08 no tiene la API y no demuestra Wacom real.

Criterio de salida: sin traceback, `Plugin loaded fingerink`, `RD loaded plugin fingerink`, barra operativa y dibujo con dedo conservado.

### Fase 6 — Gate obligatorio en Kindle Scribe

Instalar en un Scribe con KOReader v2026.07 o posterior. Deshabilitar Pencil, `stylus-annotations` y otros plugins de stylus durante la primera ronda.

**Primer paso, antes de tocar el lápiz:** buscar en el log `We failed to auto-detect the proper input devices`. Si aparece, KOReader cayó al fallback de `touch_dev` y no abrió el digitalizador (§4.3); ningún trabajo del plugin puede arreglar eso y hay que reportarlo como problema de entorno, no de FingerInk.

No declarar completada la compatibilidad Scribe antes de pasar la matriz física de la sección 9.

### Fase 7 — Tuning condicionado

Sólo si la Fase 6 demuestra un problema de refresh:

1. Acumular un bounding box numérico de segmentos pendientes.
2. Programar una sola acción estable cada 8–16 ms; no reprogramar por punto. **Es un throttle, no un debounce**: `UIManager:debounce` no sirve aquí (§4.6).
3. Guardar la función, no el retorno de `scheduleIn`; cancelar con `UIManager:unschedule(esa_misma_función)`.
4. Hacer flush inmediato en lift, Stop, suspensión, desarme por error y teardown.
5. Comparar 0, 8 y 16 ms en hardware y elegir por evidencia.

Esta fase debe ir en commit separado y poder revertirse sin retirar soporte de stylus.

## 8. Matriz de tests automatizados

### `ink_capture.lua`

| Caso | Resultado esperado |
| --- | --- |
| API de stylus ausente | `supportsStylus() == false`; instalación explícita falla sin mutar nada |
| Callback ya ocupado | reason `stylus_callback_busy`; callback ajeno intacto |
| Instalación stylus válida | registra exactamente un callback y un wrapper residual |
| Callback devuelve true | el valor `true` llega a KOReader para dominar el slot |
| Callback devuelve false | el slot puede continuar al detector |
| Residual devuelve false | original `feedEvent` se invoca y su array de gestos queda vacío |
| Residual devuelve true | array original se conserva |
| `remove` dos veces | no error ni segunda mutación |
| Callback reemplazado después | `remove` no borra el callback nuevo |
| Wrapper reemplazado después | `remove` no restaura sobre el wrapper nuevo; wrapper propio queda inactivo |
| Cuatro rotaciones | mismas fórmulas que `GestureDetector:translateCoordinates` |
| `getTouchRotation` disponible | se usa antes que `getRotationMode` |
| Stub de Screen **sin** `getTouchRotation` | cae a `getRotationMode` sin error |
| Constantes tomadas de `Device.input` | `TOOL_ERASER` refleja `input.TOOL_TYPE_ERASER` si existe |
| Constantes con `input` sin exports | `TOOL_ERASER == 2` por fallback |
| **Handler stylus lanza error** | no propaga; devuelve `false`; captura retirada; `on_error` invocado una vez |
| **Handler residual lanza error** | no propaga; devuelve `true`; captura retirada; `on_error` invocado una vez |
| **`disarm` reentrante desde el handler** | idempotente, sin error, sin segunda notificación |

### `main.lua`

| Caso | Resultado esperado |
| --- | --- |
| Auto + Wacom + API | backend `stylus` |
| Auto sin Wacom, no SDL | backend `finger` |
| Auto + SDL + API | backend `finger` (el ratón del emulador debe poder dibujar) |
| Stylus explícito + SDL | backend `stylus` (opt-in para tableta gráfica) |
| Stylus explícito sin API | dibujo permanece apagado y muestra error |
| Stylus explícito, API presente, sin Wacom | backend `stylus` (no exige `wacom_protocol`) |
| Pen down/move/lift | un trazo guardado, eventos dominados |
| Frame stylus con `id=nil` | no inicia ni termina stroke, devuelve `true` |
| **`id < 0` repetido tras un lift** | sólo un `endStroke`; frames siguientes no crean ni cierran nada |
| **Frame de hover con `x`/`y` pegajosos e `id < 0`** | no dibuja ningún punto |
| **Pen slot con `tool == TOOL_TYPE_FINGER` e `id < 0`** | tratado como lift, no como punto de tinta |
| **Passthrough latchado: primer punto en barra, luego fuera** | devuelve `false` durante toda la secuencia, incluido el lift; ninguna tinta |
| **Dominación latchada: primer punto fuera, luego en barra** | devuelve `true` durante toda la secuencia; trazo truncado en el borde |
| Lápiz sobre barra | passthrough completo, ninguna tinta |
| Lápiz arrastrado a barra | termina en borde y consume resto hasta lift |
| Goma física | elimina el trazo alcanzado aunque `self.eraser == false` |
| `tool == HIGHLIGHTER` | se comporta como pen, usa la herramienta manual |
| Pen + dedo fuera de barra | pen continúa; dedo no aborta ni emite gesto |
| **Frame residual vacío (`#slots == 0`)** | no altera estado de contactos ni cierra trazos |
| Un dedo fuera de barra | no tinta, no gesto |
| Dos dedos fuera de barra | no tinta, no gesto |
| Dedo sobre barra | tap permitido hasta lift |
| **Lápiz en passthrough + palma simultánea** | limitación conocida: se emite el frame entero. El test fija el comportamiento actual para que un cambio futuro sea deliberado |
| Diálogo en top | dedo y lápiz se entregan a KOReader/UI |
| Stop/suspend/close | stroke abortado y captura retirada; estado stylus y de contactos reseteados |
| **`teardown` con trazo en vuelo** | aborta el trazo y resetea contactos, igual que `setDrawing(false)` |
| `onContactPoint` sin `tool` (ruta finger) | comportamiento idéntico al actual |
| Backend finger, un contacto | comportamiento actual: dibuja |
| Backend finger, dos contactos | comportamiento actual: aborta y passthrough |
| Cambio de modo con `drawing == true` | item deshabilitado; el setting no cambia |

### Regresiones auxiliares

- rasterización horizontal, vertical y diagonal;
- store add/pop/remove/hit;
- toolbar: botones, borde, lector debajo, menú debajo, toast y hardware keys;
- `drawing == true` implica siempre `bar ~= nil`;
- datos guardados antes del cambio se pueden cargar sin migración.

> 🆕 ADDED: los stubs deben reproducir el ciclo de vida real de los slots (§4.2) — una tabla persistente por número de slot, reutilizada entre frames, con `id`/`x`/`y` que sobreviven al lift. Un stub que fabrique una tabla nueva por frame dejaría verdes exactamente los tests que existen para atrapar el bug de `id` pegajoso.

## 9. Matriz de prueba física en Scribe

Ejecutar sobre un PDF fijo, primero en orientación normal y después tras rotación soportada:

1. Dibujar diez líneas lentas y diez rápidas con la punta.
2. Apoyar la palma antes de tocar con la punta.
3. Apoyar la palma después de iniciar el trazo.
4. Añadir uno y varios dedos durante un trazo.
5. Confirmar que no cambia de página, no abre menú y no aborta la línea.
6. Usar la goma posterior; confirmar que borra trazos completos y que la punta vuelve a dibujar.
7. **Botón lateral: expectativa falsable.** El código predice que en un dispositivo no-SDL `BTN_STYLUS` activa `stylus_eraser_active` ([input.lua:747-751](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L747)) y que `routeStylusEvents` reescribe entonces `tool` de `PEN` a `ERASER` mientras se mantiene pulsado ([input.lua:494-499](https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L494)); `BTN_STYLUS2` haría lo propio con `HIGHLIGHTER`. **Resultado esperado: mantener el botón lateral borra.** Si no ocurre nada, la conclusión es que el kernel del Scribe no emite `BTN_STYLUS` — anotarlo y no intentar compensarlo en el plugin.
8. Pulsar la barra con dedo y con lápiz.
9. Arrastrar el lápiz hacia la barra y confirmar truncado en el borde.
10. **Empezar un trazo sobre la barra y arrastrarlo fuera**: no debe aparecer tinta en ningún momento (verifica el latchado de §5.5).
11. Abrir/cerrar menú o diálogo mientras Draw está activo.
12. Pulsar Stop y comprobar que todos los gestos normales vuelven inmediatamente.
13. Suspender durante y después de un trazo; reanudar sin hook atascado y sin gesto fantasma en el primer toque.
14. Cerrar y volver a abrir el documento; comprobar persistencia.
15. Mantener escritura continua durante 60 segundos y revisar huecos, lag, ghosting y `crash.log`.
16. Repetir con “Fast refresh” apagado para separar input de waveform.
17. **Con el lápiz levantado pero cerca del panel (hover), esperar 10 s**: no debe crearse ni cerrarse ningún trazo, ni aparecer puntos sueltos (verifica idempotencia de `id < 0` y coordenadas pegajosas).

> ⚠️ REVISED: el punto 7 pasa de “registrar qué reporta” a una predicción comprobable, ahora que el comportamiento está leído en el código. El punto 10 y el 17 son nuevos y cubren los dos fallos de máquina de estado que los tests sintéticos sólo pueden simular.

Criterios de aceptación física:

- cero crashes o tracebacks de FingerInk;
- cero cambios de página causados por palma en modo stylus;
- un dedo no crea tinta;
- la palma no termina el stroke del lápiz;
- Stop restaura lectura normal sin reiniciar KOReader;
- punta y goma producen la herramienta esperada cuando KOReader las reporta;
- el hover prolongado no produce artefactos;
- no hay pérdida de trazos terminados tras cierre/suspensión normal;
- el retraso o ghosting observado queda documentado antes de decidir batching.

## 10. Comandos de validación

Desde la raíz del repositorio:

```sh
git status --short

KOREADER_QA=/Users/christianstenger/.claude/skills/koreader-simulator-qa/scripts/koreader_qa.sh
KOREADER_RUNTIME=/Users/christianstenger/koreader/koreader/koreader-emulator-arm64-apple-darwin25.1.0-debug/koreader

(cd fingerink.koplugin && "$KOREADER_QA" preflight)
(cd fingerink.koplugin && "$KOREADER_QA" test)     # debe correr tests/run.lua, no imprimir SKIP
"$KOREADER_RUNTIME/luajit" test.lua                 # shim de raíz, misma suite
lua test.lua                                        # cualquier Lua 5.1+, sin LuaJIT

# Contrasta los stubs de la suite contra el Device real del runtime instalado.
# UNCHECKABLE no es un pase: significa que este runtime no tiene esa API.
PROBE="$PWD/fingerink.koplugin/tests/conformance.lua"
(cd "$KOREADER_RUNTIME" && ./luajit "$PROBE")
```

Para una sesión visual aislada:

```sh
KOREADER_SCREEN_WIDTH=1860 \
KOREADER_SCREEN_HEIGHT=2480 \
KOREADER_SCREEN_DPI=300 \
KOREADER_PLUGIN_DIR="$PWD/fingerink.koplugin" \
"$KOREADER_QA" launch hidpi
```

Abrir un PDF desde FileManager y exigir en el log:

```text
Plugin loaded fingerink
RD loaded plugin fingerink at plugins/fingerink.koplugin
```

Notas:

- **`"$KOREADER_QA" test` sólo ejecuta `$PLUGIN_DIR/tests/run.lua`.** Si imprime `SKIP no tests/run.lua found`, la suite no corrió: eso es un fallo de la Fase 5, no un pase;
- el runtime local es v2025.08 y **no tiene** `registerStylusCallback`; el test sintético cubre el contrato de v2026.07, pero no sustituye un runtime o dispositivo actual;
- el plugin es `is_doc_only`; un smoke que se queda en FileManager no prueba que `main.lua` de ReaderUI se haya cargado;
- la ventana SDL puede escalar dimensiones en macOS; no usar su tamaño aparente como prueba exacta de geometría Scribe;
- no usar el estado KOReader habitual; la skill crea un `KO_HOME` aislado por ejecución.

## 11. Secuencia de commits sugerida

1. `test: add executable FingerInk input regression harness`
2. `feat: add owned stylus capture backend with touch suppression`
3. `feat: guard input handlers and disarm capture on error`
4. `feat: add Scribe input modes and physical eraser handling`
5. `fix: abort in-flight stroke and reset contacts on teardown`
6. `docs: document Scribe compatibility and validation limits`
7. Sólo si el hardware lo justifica: `perf: throttle live ink refreshes on stylus input`

Cada commit debe dejar la suite verde. No introducir cambios de refresh en el mismo commit que la captura.

> ⚠️ REVISED: se separan la contención de errores (#3) y la corrección de `teardown` (#5) en commits propios. El primero es la mitigación de un fallo de clase crash y debe poder revisarse y revertirse por separado; el segundo es un arreglo de pérdida de datos independiente de la funcionalidad de stylus, y mezclarlo con ella haría imposible portarlo a `main` si el resto del PR se retrasa.

## 12. Riesgos y mitigaciones

| Riesgo | Mitigación |
| --- | --- |
| **Error de Lua en un handler tumba KOReader** | `pcall` en ambos handlers, retorno seguro, auto-desarme, notificación única (§5.9) |
| Otro plugin usa el único callback | Detectar `input.stylus_callback`, rechazar activación y no sobrescribir |
| Otro plugin reemplaza hooks después | Retirada por identidad; wrapper propio inactivo si ya no puede desmontarse |
| `id` pegajoso repite lifts o pinta en hover | Reglas por transición e idempotentes; nunca deducir contacto de `x`/`y` (§4.2) |
| `tool == FINGER` en el pen slot pinta al salir de proximidad | Sólo `id` gobierna inicio/fin de trazo; `tool` sólo elige tinta o borrado |
| Decisión de dominación cambia a media secuencia | Latchado en el flanco de bajada; tests en ambos sentidos (§5.5) |
| Palma sigue llegando al lector | Wrapper residual que consume touch además del callback de pen |
| Palma simultánea con lápiz en passthrough | Limitación documentada, test que fija el comportamiento, contingencia geométrica (§5.3) |
| Barra queda inaccesible | Passthrough geométrico de la secuencia iniciada en la barra, con tests de dedo y lápiz |
| Menú queda bloqueado | `dialogOnTop` gobierna tanto stylus como touch residual |
| Regresión de Paperwhite | Backend finger separado, `tool == nil` equivalente al comportamiento actual, matriz heredada completa |
| Coordenadas incorrectas al rotar | Usar `getTouchRotation` y probar cuatro modos; fórmulas ya verificadas contra core |
| Kobo con stylus no detectado por `auto` | Modo `stylus` manual sin requisito de `wacom_protocol`; documentado como no soportado |
| v2026.03 rompe stylus Scribe | Documentar mínimo v2026.07; no parchear core |
| KOReader cae al fallback de `touch_dev` y no abre el digitalizador | Buscar `We failed to auto-detect` en el log antes de culpar al plugin (§4.3) |
| Suspensión con lápiz apoyado deja `stylus_active` colgado | `onSuspend` → `setDrawing(false)`; nunca retener tablas de slot (§5.10) |
| Latencia/ghosting desconocidos | Mantener baseline, medir hardware y aislar tuning en commit posterior |
| Sidecar crece con alta tasa Wacom | Medir primero; no cambiar esquema ni simplificar puntos en el PR de input |
| README promete tests inexistentes | Runner real en `tests/run.lua`, ejecutado y **observado** por la skill de QA |

## 13. Condiciones de parada

Detener la implementación y reportar evidencia si ocurre cualquiera:

- v2026.07 o posterior en el Scribe no produce slots PEN/ERASER en el callback;
- **no llega ningún evento de lápiz y el log muestra que KOReader cayó al fallback de `touch_dev`** — el digitalizador no fue clasificado como `INPUT_SCALED_TABLET` y por tanto no se abrió; es un problema de detección de FBInk, no del plugin;
- el callback está ocupado y no puede deshabilitarse el plugin propietario;
- la goma no es distinguible de la punta en los eventos reales;
- el filtro residual impide a la barra completar taps en hardware;
- aparece un requisito de modificar KOReader core;
- el tuning exige presión/tilt o APIs que el callback no expone.

> ⚠️ REVISED: la condición original “el dispositivo entrega coordenadas sin escalar pese a `INPUT_SCALED_TABLET`” se sustituye. Ese modo de fallo no existe: `INPUT_SCALED_TABLET` es un criterio de *selección* en `fbink_input_scan`, no una transformación aplicada después. Un digitalizador sin escalar se clasifica como `INPUT_TABLET`, que no está en la máscara de v2026.07.x, y simplemente no se abre (§4.3).

En esos casos, conservar logs de transición (`tool`, `id`, slot, backend y versión KOReader), pero no registrar cada coordenada indefinidamente ni incluir rutas de archivo, títulos ni ningún dato de los libros del usuario. Si se adjunta `crash.log`, revisarlo antes de compartirlo.

## 14. Definición de terminado

La funcionalidad está terminada sólo cuando:

- `fingerink.koplugin/tests/run.lua` existe, **se observa ejecutándose** bajo `koreader_qa.sh test` (no `SKIP`) y todas sus comprobaciones pasan con el LuaJIT de KOReader;
- el shim `test.lua` de la raíz ejecuta la misma suite;
- los Lua pasan la validación de sintaxis;
- ReaderUI carga el plugin en una sesión aislada sin traceback;
- Paperwhite/finger conserva el comportamiento anterior;
- Scribe/stylus pasa la matriz física mínima, incluidos los puntos 10 y 17;
- un error inyectado en un handler desarma el plugin sin tumbar KOReader;
- no se ha modificado KOReader core ni el formato persistido;
- README, requirements, spec, ADR-11, ADR-12, las supersesiones de ADR-1 y ADR-3, y la metadata describen el comportamiento implementado;
- la PR declara explícitamente qué versión/modelo físico se probó y qué aspectos siguen sin cobertura.

## 15. Registro de validación documental

Todas las entradas de esta sección se re-verificaron durante la auditoría del 2026-08-23 contra el árbol descargado del tag y contra la API de GitHub.

```text
Topic: Contrato de Input:registerStylusCallback
Why validation was needed: Es una API nueva y determina la arquitectura de captura.
Source: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L461-L515
What was verified: callback(Input, slot); slot = {slot,id,x,y,tool,timev}; retorno truthy retira el
  slot de MTSlots antes de feedEvent; unregister pone el callback a nil; routeStylusEvents se llama
  inmediatamente antes de gesture_detector:feedEvent en las cinco variantes de handleTouchEv
  (L1085, L1127, L1193, L1254, L1304); is_stylus casa también por numero de slot (pen_slot),
  no solo por tool.
Version / availability constraints: Presente desde v2026.07. input.lua es byte-identico en
  v2026.07, v2026.07.1 y v2026.07.2 (verificado por diff).
Impact on the plan: Backend stylus sin parche de core; ownership singleton obligatorio;
  version minima corregida a v2026.07.
Confidence: High.

Topic: Visibilidad de las constantes TOOL_TYPE_*
Why validation was needed: El plan original ordenaba declarar equivalentes locales.
Source: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L1831-L1834
Corroboration: https://github.com/koreader/koreader/blob/v2026.07.2/spec/unit/input_spec.lua#L160-L249
What was verified: Input.TOOL_TYPE_FINGER/PEN/ERASER/HIGHLIGHTER se asignan al modulo al final
  del archivo y la suite oficial de KOReader los consume por ese nombre.
Impact on the plan: Leer de Device.input.TOOL_TYPE_* con literal solo como fallback.
Confidence: High. CORRIGE el plan original.

Topic: Ciclo de vida de los datos de slot
Why validation was needed: Las reglas del callback dependen de si id/x/y son frescos por frame.
Source: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L1381-L1450
Corroboration: comentario dentro de GestureDetector:feedEvent, gesturedetector.lua L232-L241.
What was verified: ev_slots es persistente por slot; initMtSlot no limpia campos; newFrame solo
  vacia MTSlots y active_slots; MTSlots guarda referencias a ev_slots.
Impact on the plan: Reglas por transicion e idempotentes; prohibido retener la tabla del slot;
  prohibido deducir contacto de la presencia de x/y.
Confidence: High. AMPLIA el plan original.

Topic: tool == TOOL_TYPE_FINGER en el pen slot
Why validation was needed: Determina si tool puede gobernar el dibujo.
Source: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L757-L767
Corroboration: https://github.com/koreader/koreader/blob/v2026.07.2/spec/unit/input_spec.lua#L239-L252
What was verified: con BTN_TOOL_PEN/RUBBER a 0, KOReader escribe TOOL_TYPE_FINGER en el pen slot;
  el test oficial lo assertea.
Impact on the plan: Solo las transiciones de id inician/terminan trazos.
Confidence: High. CORRIGE el plan original.

Topic: Ausencia de proteccion frente a errores
Why validation was needed: Determina el peor modo de fallo del diseño.
Source: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L506 y #L1691
What was verified: stylus_callback se invoca sin pcall; handleTouchEv se invoca sin pcall; el unico
  pcall cercano (L1614) cubre la llamada C waitForEvent, no el despacho; ni UIManager:handleInput
  ni reader.lua envuelven esa ruta.
Impact on the plan: Nueva seccion 5.9, nuevo ADR-12, nuevos tests, commit propio.
Confidence: High. AÑADE al plan original.

Topic: Latchado de la decision de dominacion
Why validation was needed: El plan lo exigia sin justificarlo.
Source: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/gesturedetector.lua#L228-L249
  y #L402-L429, #L187-L213
What was verified: feedEvent crea un Contact la primera vez que ve un slot; initialState marca
  down=true copiando el tev actual como initial_tev; dropContact solo ocurre al ver id == -1 y es
  quien limpia pending_hold_timer.
Impact on the plan: Invariante explicito con dos tests direccionales y dos pruebas fisicas.
Confidence: High. AMPLIA el plan original.

Topic: Configuracion especifica de Kindle Scribe
Why validation was needed: El plan depende de que KOReader abra y normalice el digitalizador.
Source: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/kindle/device.lua
What was verified: KindleScribe (L1168), KindleScribe3 (L1186), KindleScribeColorSoft (L1218):
  isMTK, 300 dpi, touch_dev=/dev/input/touch; wacom_protocol=true en L1888/L1951/L2014; ninguno
  sobrescribe handleTouchEv; match_mask en L545 incluye INPUT_SCALED_TABLET y NO INPUT_TABLET;
  touch_dev solo se usa en el fallback de L563 cuando fbink_input_scan falla.
Impact on the plan: Auto selecciona stylus mediante wacom_protocol; primer check de la Fase 6 es
  el log de auto-deteccion; condicion de parada reescrita.
Confidence: High para codigo, Medium para comportamiento fisico.

Topic: Alcance real de wacom_protocol
Why validation was needed: Es el discriminante de la regla auto.
Source: grep sobre el arbol completo del tag v2026.07.2.
What was verified: solo lo activan kindle/device.lua (los tres Scribe) y remarkable/device.lua:276.
  Kobo nunca. Los Kobo con stylus reportan la herramienta via ABS_MT_TOOL_TYPE (input.lua L1067).
  stylus_tool_protocol = wacom_protocol or is_sdl (input.lua L756).
Impact on the plan: auto ampliado a isSDL(); stylus explicito no exige wacom_protocol; Kobo
  documentado como no soportado pero accesible.
Confidence: High. CORRIGE el plan original.

Topic: Regresion Scribe de v2026.03 y su revert
Why validation was needed: El README actual declara esa version, pero no es base segura para stylus.
Source: https://github.com/koreader/koreader/issues/15164 (cerrado 2026-07-12)
Cause: https://github.com/koreader/koreader/pull/14908 (fusionado 2026-03-08)
Resolution: https://github.com/koreader/koreader/pull/15675 (fusionado 2026-07-12)
What was verified: el diff completo de #14908 consiste en añadir C.INPUT_TABLET al match_mask de
  Kindle; #15675 lo revierte; la match_mask de v2026.07.x es identica a la de v2025.10.
Impact on the plan: Minimo v2026.07; y evidencia positiva de que la mascara restaurada es la que
  ya funcionaba antes de la regresion.
Confidence: High.

Topic: Transformacion de coordenadas
Why validation was needed: El callback ocurre antes del ajuste de GestureDetector.
Source: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/gesturedetector.lua#L1396-L1440
Framebuffer source: https://github.com/koreader/koreader-base/blob/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/framebuffer.lua#L78-L125
What was verified: adjustGesCoordinate usa getTouchRotation; las cuatro formulas de
  translateCoordinates coinciden una a una con Capture.toScreen; DEVICE_ROTATED_* = 0/1/2/3;
  PocketBook sobrescribe getTouchRotation (pocketbook/device.lua:181); getTouchRotation ya existe
  en el base del runtime local v2025.08.
Impact on the plan: Cambiar toScreen a getTouchRotation; conservar las formulas; el fallback es
  defensivo y necesita test propio porque en produccion no se ejerce.
Confidence: High.

Topic: Refresh e-ink en Kindle/Scribe
Why validation was needed: La tinta actual hace una actualizacion por segmento.
Source: https://github.com/koreader/koreader-base/blob/6e4bc81af4e04f78d81677a323a780a71b29702a/ffi/framebuffer_mxcfb.lua
What was verified: refreshFast -> refreshFastImp -> mech_refresh(false, waveform_fast) (L804);
  para isMTK waveform_fast = MTK_WAVEFORM_MODE_DU (L897); _MTK_ToggleFastMode existe (L656) y
  KindleScribe:init lo activa antes de Kindle.init.
Impact on the plan: Conservar refresh actual en el primer PR; tuning despues del gate fisico.
Confidence: High para seleccion de codigo, Low para percepcion fisica sin dispositivo.

Topic: Temporizacion, cancelacion y debounce
Why validation was needed: El analisis previo sugeria debounce/throttling.
Source: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/ui/uimanager.lua#L335-L449
What was verified: scheduleIn no devuelve handle; unschedule compara task.action == action y
  devuelve booleano; UIManager:debounce (L386) existe pero es un debounce trailing portado de
  underscore.js, inadecuado para tinta en vivo.
Impact on the plan: Accion estable si se abre la fase de batching; prohibicion explicita de
  UIManager:debounce; no copiar el patron de DrawNotes.
Confidence: High. AMPLIA el plan original.

Topic: Suspension e inhibicion de entrada
Why validation was needed: La matriz fisica prueba suspend/resume sin describir el mecanismo.
Source: https://github.com/koreader/koreader/blob/v2026.07.2/frontend/device/input.lua#L1731-L1771 y #L690-L704
What was verified: inhibitInput(true) sustituye handleTouchEv por voidEv y llama a resetState();
  resetState hace dropContacts() y reconstruye ev_slots desde cero.
Impact on the plan: Nueva seccion 5.10; justifica que no haga falta onResume; refuerza la
  prohibicion de retener tablas de slot.
Confidence: High. AÑADE al plan original.

Topic: Lecciones de Pencil y de otros propietarios del callback
Why validation was needed: Es una implementacion cercana con punta/goma.
Source: https://raw.githubusercontent.com/mysticknits/pencil.koplugin/main/README.md
What was verified: pen tip, eraser end, highlighter, debug de input, persistencia por documento;
  solo Kobo; las instrucciones de instalacion exigen reemplazar /frontend/device/input.lua.
Additional: nada en el core de v2026.07.2 registra un stylus callback, asi que stylus_callback_busy
  solo puede venir de terceros; decisions.md ADR-1 nombra tambien stylus-annotations.koplugin.
Impact on the plan: Adoptar semantica de tool y logs de transicion; rechazar parche de core;
  desactivar ambos plugins en la primera ronda fisica.
Confidence: High para lo documentado por el proyecto.

Topic: Limites del emulador local y de la skill de QA
Why validation was needed: La definicion de terminado requiere separar integracion de hardware.
Source: ~/.claude/skills/koreader-simulator-qa/SKILL.md y scripts/koreader_qa.sh
What was verified: run_tests() solo ejecuta $PLUGIN_DIR/tests/run.lua (L153-157) y su barrido de
  sintaxis recorre find "$PLUGIN_DIR" -name '*.lua' (L150); entorno KO_HOME aislado por ejecucion;
  la skill prohibe explicitamente reclamar cobertura de dispositivo real.
Version / availability constraints: Runtime local v2025.08-100-g1d66e440b, anterior al callback.
Impact on the plan: Runner movido a fingerink.koplugin/tests/run.lua con shim en la raiz; §10 y
  §14 exigen observar que la suite corrio.
Confidence: High. CORRIGE el plan original.
```

## 16. Desviaciones respecto al análisis previo

- Se mantiene el backend dual propuesto, pero el backend stylus también instala un filtro residual de touch. Sin él no existe rechazo de palma real.
- Ambos handlers se instalan bajo `pcall` con auto-desarme. Es la diferencia entre “la tinta deja de funcionar” y “KOReader se cae con la entrada secuestrada”.
- El refresh agrupado y el guardado con debounce no entran en el primer PR. La evidencia confirma APIs para hacerlo, pero no que el Scribe lo necesite; se dejan detrás de medición física para reducir variables y riesgo.
- `getTouchRotation` reemplaza a `getRotationMode` como fuente primaria porque coincide con GestureDetector. Las fórmulas de transformación no cambian: ya eran correctas.
- No se presupone convivencia con otros plugins de stylus: la API es singleton y la activación falla de forma segura si está ocupada.
- La versión mínima de stylus se fija en **v2026.07**, aunque el modo finger continúe funcionando en versiones anteriores.
- Las constantes de herramienta se leen de `Device.input`, no se declaran a ciegas.
- La regla `auto` incorpora `isSDL()` y se documenta que los Kobo con stylus requieren selección manual.
- Se corrigen de paso dos defectos preexistentes: la restauración incondicional en `Capture:remove` y la pérdida del trazo en vuelo en `teardown`.
