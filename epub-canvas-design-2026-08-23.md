# FingerInk: lienzo anclado a una posición del libro — diseño

Fecha: 2026-08-23
Feature ID: `FI-CANVAS-001`
Base: rama `codex/kindle-scribe-stylus`, tras la remediación `FI-SCRIBE-STYLUS-002`
Documentos previos: [`kindle-scribe-stylus-dev-plan-2026-08-23.md`](kindle-scribe-stylus-dev-plan-2026-08-23.md),
[`kindle-scribe-stylus-remediation-plan-2026-08-23.md`](kindle-scribe-stylus-remediation-plan-2026-08-23.md)

**Objetivo:** poder abrir una hoja en blanco anclada a una posición del libro,
dibujar libremente en ella, y redimensionarla arrastrando — de modo que el texto
siga visible mientras tomas notas a mano.

---

## 0. Decisiones ya tomadas

Las cuatro salieron de la conversación de diseño y están cerradas. Cambiar
cualquiera invalida partes del resto del documento.

| Decisión | Elegido | Descartado, y por qué |
| --- | --- | --- |
| Qué se dibuja en EPUB | **Un lienzo en blanco anclado a una posición** | Marcas sobre el texto: exige anclar cada trazo al texto de debajo y se rompe al recomponer (§1.1) |
| Forma de la UI | **Hoja inferior redimensionable** | Pantalla completa (menos flexible); página enfrentada (choca con pasar página) |
| Tamaño del lienzo | **Una pantalla fija; la hoja es una ventana** | Lienzo largo con scroll (gesto que compite con el lápiz); cuaderno multi-hoja (más estado, siguiente iteración) |
| Barra vs. lienzo | **La barra flota encima del lienzo** | Reservar la columna: ~15% de ancho perdido siempre |

## 1. Por qué un lienzo resuelve lo que el texto no

### 1.1 El problema que evitamos

EPUB es reflowable. Una "página" no es una entidad estable: cambia con el
cuerpo de letra, los márgenes, el interlineado y la rotación. El formato actual
guarda trazos en **coordenadas de pantalla contra un número de página**, así que
en EPUB la tinta se queda donde estaba mientras el texto se va — es la
limitación que el README ya documenta y que ADR-5 dejó aplazada.

La vía "anclar la tinta al texto" es posible pero se degrada mal:

- subrayar una línea funciona;
- rodear una palabra funciona, pero el círculo no escala con la fuente;
- una raya cruzando un párrafo que pasa de 4 a 6 líneas queda en el sitio
  equivocado;
- un esquema en un hueco en blanco se ancla a la palabra más cercana, que puede
  estar lejos, y viaja con ella.

Anclar punto a punto no es salida: `getNearestWordFromPosition` por muestra a
frecuencia Wacom no es viable y además deformaría el trazo.

### 1.2 Lo que el lienzo cambia

Si los trazos viven en **coordenadas del lienzo**, el reflow no puede moverlos.
Lo único que debe sobrevivir a una recomposición es *dónde cuelga el lienzo*, y
eso es un solo xpointer — precisamente el caso para el que los xpointers
existen.

> 🗑️ **Pieza eliminada del diseño.** Una versión anterior de esta propuesta
> guardaba `getDocumentRenderingHash(true)` junto a la tinta para detectar
> cambios de layout y avisar de que la tinta era aproximada. Con el lienzo no
> hace falta: nada puede desplazar los trazos. El hash desaparece del diseño.

Y de paso el lienzo deja de ser una cosa de EPUB: anclado a una página, funciona
igual en PDF.

## 2. Anclaje

**Reflowable** (`ui.rolling`): `ancla = ui.document:getXPointer()`, que devuelve
el xpointer del principio de la vista actual. Es exactamente lo que
`ReaderRolling` guarda y restaura como posición de lectura
([readerrolling.lua:229](https://github.com/koreader/koreader/blob/v2026.07/frontend/apps/reader/modules/readerrolling.lua#L229)),
así que es tan estable como el propio "por dónde iba".

**Layout fijo** (`ui.paging`): no hay xpointers. El ancla es el número de
página, que en PDF sí es estable.

Para reencontrarlo mientras se lee: `document:isXPointerInCurrentPage(xp)`, que
está cacheada por render, dice si la marca debe aparecer en esta vista.

`getScreenPositionFromXPointer(xp)` está disponible si en el futuro se quiere
colocar la marca a la altura exacta del ancla en vez de en un sitio fijo del
margen. **No hace falta para v1.**

## 3. Datos

Clave **nueva** en el sidecar. `fingerink_strokes` no se toca: el dibujo directo
sobre página en PDF sigue funcionando exactamente igual, sin migración.

```lua
fingerink_canvases = {
    {
        anchor  = "/body/DocFragment[3]/body/p[7]/text().0",  -- nil en layout fijo
        page    = 41,      -- ancla en layout fijo; en EPUB, sólo informativo
        w       = 1860,    -- geometría de pantalla al crear el lienzo
        h       = 2480,
        strokes = { ... },  -- mismo formato de trazo que ink_store hoy
    },
}
```

`w`/`h` existen porque las coordenadas de trazo no significan nada sin saber
sobre qué geometría se dibujaron. Al renderizar en otra geometría (rotación,
otro dispositivo), **escalado uniforme por el ancho, anclado arriba-izquierda**:
uniforme para que la letra manuscrita no se deforme, por el ancho porque es la
dimensión que el usuario percibe como "la hoja".

## 4. Coordenadas y pintado

El lienzo mide siempre una pantalla: origen arriba-izquierda, tamaño `w`×`h`.

La hoja ocupa la franja inferior de la pantalla, de altura `sheet_h`, y muestra
**los `sheet_h` píxeles superiores del lienzo**. Maximizar destapa lo de abajo;
nada se mueve ni se escala al redimensionar.

```
lienzo (w × h)              hoja de altura sheet_h
(0,0) ┌──────────┐          pantalla_y = sheet_top + lienzo_y
      │  visible │ ┐
      │          │ │ sheet_h  lienzo_y = pantalla_y - sheet_top
      ├──────────┤ ┘
      │ tapado   │
      └──────────┘
```

La conversión es una traslación pura. No hay escalado en tiempo de dibujo, sólo
al cargar un lienzo hecho en otra geometría.

**Tinta en vivo:** igual que hoy — `Render.segment` sobre `Screen.bb` y
`refreshFast` sobre la caja del segmento — pero recortada al rectángulo de la
hoja. `refreshBox` ya recorta a la pantalla; pasa a recortar a la hoja.

**Repintado:** la hoja es un widget con su propio `paintTo`: fondo blanco, luego
los trazos trasladados y recortados.

## 5. Entrada

Con la hoja abierta:

| Dónde | Lápiz | Dedo |
| --- | --- | --- |
| Dentro de la hoja | dibuja en el lienzo | nada (rechazo de palma) |
| En el asa | arrastra para redimensionar | arrastra para redimensionar |
| Sobre la barra | pulsa botones | pulsa botones |
| Sobre el texto, arriba | nada | **lectura normal: pasar página, menú** |

El lápiz sobre el texto no hace nada **por decisión**, no por omisión: la
alternativa sería que siguiera entintando la página, y entonces habría dos
superficies de dibujo vivas a la vez en la misma pantalla, con reglas de
anclaje distintas y sin nada visible que las separe. Una superficie por vez.

La última fila es una mejora sobre el estado actual y conviene decirlo
explícitamente: hoy dibujar suprime **todo** el táctil y el único camino de
vuelta es Stop. Como aquí la superficie de dibujo está confinada a la hoja, no
hay motivo para suprimir nada fuera de ella.

En términos de ADR-13, `InkBar:suppresses` pasa de *"todo salvo la barra"* a
*"sólo dentro de la hoja, salvo el asa y la barra"*. Es la misma regla con otra
región, así que la forma de la decisión no cambia — sólo el predicado
geométrico.

**Arrastre.** Se copia el patrón de `MovableContainer`, y conviene ser exacto
sobre lo que ese patrón hace, porque no es lo que parece:

- se activa con **`hold_pan`**, no con `pan` a secas, para no chocar con el
  gesto de pasar página
  ([movablecontainer.lua:359](https://github.com/koreader/koreader/blob/v2026.07/frontend/ui/widget/container/movablecontainer.lua#L359));
- durante el arrastre **no repinta nada**. `onMovableHoldPan` sólo marca
  `_moving = true` y consume el evento; el movimiento y su único repintado
  ocurren en `onMovableHoldRelease`
  ([:373](https://github.com/koreader/koreader/blob/v2026.07/frontend/ui/widget/container/movablecontainer.lua#L373)),
  con un `setDirty("ui")` sobre la unión del rectángulo viejo y el nuevo
  ([:293](https://github.com/koreader/koreader/blob/v2026.07/frontend/ui/widget/container/movablecontainer.lua#L293)).

Es decir: KOReader **evita deliberadamente** el repintado continuo en e-ink.
Arrastras a ciegas y la ventana salta al soltar.

Para mover una ventana eso es aceptable. Para un asa de redimensionado es peor:
no ves qué altura vas a obtener. De ahí que las alturas con imán de §10 no sean
un adorno sino la compensación de esta limitación — con tres o cuatro paradas,
arrastrar a ciegas es perdonable. Un indicador fino durante el arrastre (una
línea de 2 px, región de refresco mínima) es la alternativa si en hardware
resulta insuficiente; se decide midiendo, no antes.

## 6. Pila de ventanas

`UIManager:show` inserta la ventana nueva por encima de la más alta no modal, y
`sendEvent` sólo ofrece la entrada a la más alta. Mostrar la hoja después de la
barra dejaría **la barra inalcanzable**, y eso rompe el requisito de seguridad
de ADR-13: "dibujar implica barra visible" dejó de ser una promesa de UX para
ser la condición que hace que la supresión sea posible.

Orden requerido, de abajo arriba:

```
ReaderUI  <  hoja del lienzo  <  barra
```

Es decir: al abrir la hoja hay que reinsertar la barra por encima. La barra
flota sobre el lienzo; dibujar debajo de ella trunca el trazo en el borde,
exactamente como ya ocurre hoy sobre la página — comportamiento conocido y ya
cubierto por tests.

**Invariante que debe quedar bajo test:** con la hoja abierta, la barra sigue
siendo el widget más alto.

## 7. Descubrimiento

Una marca discreta en el margen cuando el ancla de algún lienzo cae en la vista
actual (`isXPointerInCurrentPage`). Sin la marca los lienzos son invisibles y se
pierden.

Abrir la hoja con un lienzo anclado en la vista → abre ese. Sin lienzo aquí →
crea uno nuevo anclado al principio de la vista.

v1 asume **un lienzo por posición**: si hubiera varios anclados en la misma
vista se abre el primero. Varios por posición exige la lista de navegación, que
está fuera de alcance (§9).

## 8. Archivos

| Archivo | Estado | Responsabilidad |
| --- | --- | --- |
| `fingerink.koplugin/ink_canvas.lua` | **Crear** | El widget de la hoja: geometría, asa, arrastre, `paintTo` del lienzo |
| `fingerink.koplugin/ink_anchor.lua` | **Crear** | Ancla: crear desde la vista actual, comprobar si cae en la vista, reflowable vs. fijo |
| `fingerink.koplugin/ink_store.lua` | Modificar | Guardar y cargar `fingerink_canvases` junto a los trazos de página |
| `fingerink.koplugin/main.lua` | Modificar | Abrir/cerrar la hoja, enrutar el lápiz al lienzo, marca de margen, orden de pila |
| `fingerink.koplugin/ink_bar.lua` | Modificar | `suppresses` consulta la región de la hoja; botón para abrir el lienzo |
| `fingerink.koplugin/tests/` | Modificar | Cobertura de todo lo anterior |
| `README.md`, `spec.md`, `decisions.md` | Modificar | ADR-14; documentar el lienzo y sus límites |

`ink_render.lua` no se toca: el lienzo usa el mismo rasterizador.

## 9. Alcance de v1

**Dentro:** crear y abrir el lienzo de esta posición; arrastrar para
redimensionar; marca de margen; persistencia en el sidecar; el lápiz dibuja en
el lienzo y el dedo conserva la navegación fuera de la hoja.

**Fuera, y por qué:**

- **Lista de lienzos para navegar entre ellos.** Necesaria de verdad, pero no
  bloquea nada de lo anterior y merece su propia iteración.
- **Exportar.** Fuera de alcance igual que en el PR de entrada.
- **Dibujar encima del texto en EPUB.** Es el problema de §1.1; el lienzo lo
  esquiva deliberadamente.
- **Escalar la tinta con el cuerpo de letra.** Sólo tendría sentido si la tinta
  estuviera anclada al texto.
- **Cuaderno multi-hoja.** Descartado para v1 en la decisión de §0.

## 10. Riesgos

| Riesgo | Mitigación |
| --- | --- |
| El arrastre se siente mal en e-ink | KOReader no da respuesta visual durante el arrastre (§5): alturas con imán en 0 / 40 / 70 / 100% para que arrastrar a ciegas sea perdonable. Indicador fino durante el arrastre sólo si el hardware demuestra que hace falta |
| La barra queda debajo de la hoja y la supresión deja de tener salida | Orden de pila explícito (§6) con test de invariante |
| El asa queda suprimida por el rechazo de palma y no se puede arrastrar | La región del asa entra en el predicado de `suppresses` junto con la barra; test |
| La tinta en vivo se sale de la hoja | `refreshBox` recorta a la hoja, no a la pantalla |
| Un lienzo hecho en otra rotación se ve mal | `w`/`h` guardados y escalado uniforme por el ancho |
| El ancla apunta a contenido borrado o a otro libro | `isXPointerInDocument(xp)` antes de usarlo; si falla, el lienzo se conserva pero sin marca |
| El sidecar crece | Mismo formato de trazo que hoy; medir antes de cambiar nada |

## 11. Preguntas abiertas

- **¿Alturas con imán o arrastre continuo?** Propongo imán a 40 / 70 / 100% con
  arrastre libre entre medias. Decidible al implementar, no antes.
- **¿Un lienzo por posición, o varios?** v1 asume uno. Varios exige la lista de
  navegación, que ya está fuera de alcance.

## 12. Registro de verificación

Todo lo que este documento afirma sobre KOReader se comprobó leyendo el tag
**v2026.07**, descargado, no de memoria.

| Afirmación | Fuente |
| --- | --- |
| `getXPointer()` devuelve la posición de lectura actual | `readerrolling.lua:229`, `:531`, `:666` — es lo que se guarda y restaura |
| `isXPointerInCurrentPage` y `getScreenPositionFromXPointer` existen y están cacheadas por render | `credocument.lua:1406`, `:908`; lista de `cache_by_tag` en `:1926-1930` |
| `getNearestWordAndBoxFromPosition` devuelve xpointers y funciona fuera de una palabra | `credocument.lua:719` |
| Los view modules pintan los últimos, tras contenido, highlights y footer | `readerview.lua:257` |
| `UIManager:sendEvent` sólo ofrece la entrada a la ventana no-toast más alta | `uimanager.lua:884-910` |
| `MovableContainer` arrastra con `hold_pan` y **no repinta hasta soltar** | `movablecontainer.lua:359` (el pan sólo marca estado), `:373` (el movimiento ocurre al soltar), `:293` (refresco único de la unión). **Corregido:** una lectura anterior de este diseño afirmaba repintado en cada paso; es falso |
| `ui.paging` / `ui.rolling` distinguen layout fijo de reflowable | `readerview.lua:194`, `:206` |
| `getDocumentRenderingHash(true)` es la huella de layout que usa ReaderRolling | `readerrolling.lua:92`, `:1034` — verificada, y **descartada** por innecesaria (§1.2) |
