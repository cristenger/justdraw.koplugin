# Encargo de diseño: interfaz de cuadernos independientes para JustDraw

- Fecha: 2026-08-26
- Tipo de entrega: propuesta de producto e interfaz, sin implementación
- Plataforma principal: KOReader en Kindle Scribe y lectores e-ink similares con lápiz
- Documento de salida sugerido: `standalone-notebooks-ui-proposal-YYYY-MM-DD.md`

## 1. Instrucción principal para el agente de diseño

Actúa como diseñador sénior de producto e interacción especializado en interfaces para tinta electrónica y lápiz. Diseña la experiencia completa de los cuadernos independientes de JustDraw: entrada a la función, biblioteca, creación y administración de cuadernos, edición de páginas con lápiz, navegación, recuperación de errores y salida segura.

No estás diseñando una aplicación móvil convencional ni una réplica visual de Kindle Notes. La propuesta debe poder implementarse con los widgets, el ciclo de vida y el sistema de refresco de KOReader, y debe respetar el backend que ya existe en este repositorio. El resultado esperado es una especificación de diseño argumentada y verificable, no código de producción.

Antes de diseñar:

1. Lee los archivos del repositorio indicados en la sección 19.
2. Si está disponible, usa la skill `koreader-docs-research` para resolver de nuevo la última versión estable y el commit actual de desarrollo de KOReader. Contrasta ambos; no trates la copia local antigua como autoridad sobre APIs nuevas.
3. Usa una skill de diseño de interfaz si el entorno ofrece una adecuada para este trabajo, pero no permitas que patrones de iOS, Android o web sustituyan las convenciones de KOReader.
4. Comprueba en fuentes oficiales cualquier afirmación que dependa del stack de ventanas, propagación de eventos, widgets, refrescos de pantalla, FileManager o ReaderUI.
5. No modifiques código de JustDraw en esta tarea. Si el diseño necesita ampliar un contrato del backend, descríbelo como una brecha concreta y propón la API mínima necesaria.

No bloquees la propuesta por preguntas menores. Formula una recomendación principal, documenta los supuestos y separa con claridad qué forma parte del MVP y qué pertenece a una etapa posterior.

## 2. Resultado que debe conseguir la experiencia

El usuario debe poder tomar notas manuscritas sin abrir un libro:

- entrar a una biblioteca de cuadernos desde el explorador de archivos de KOReader o mientras lee un documento;
- crear un cuaderno con una primera página;
- abrirlo y escribir con el lápiz con la misma ruta de tinta ya probada en JustDraw;
- alternar entre lápiz y goma, deshacer el último trazo y cambiar de página;
- añadir páginas al final y borrar una página con confirmación;
- volver a la biblioteca sin perder tinta;
- comprender y recuperar fallos de carga, guardado o entrada;
- retomar el cuaderno y su última página confirmada después de cerrar, suspender o cambiar de host dentro de KOReader.

La propuesta debe dar prioridad a cuatro cualidades:

1. La tinta nunca debe parecer guardada cuando no lo está.
2. La palma y un toque accidental no deben activar controles destructivos ni cambiar de página durante un trazo.
3. La interacción habitual debe requerir pocos refrescos e-ink y pocos cambios de pantalla.
4. La biblioteca debe seguir siendo utilizable con miles de cuadernos y páginas.

## 3. Qué es JustDraw hoy

JustDraw es un plugin de KOReader escrito en Lua/LuaJIT. Actualmente tiene tres dominios claramente separados:

1. **Tinta directa sobre documentos de página fija, como PDF.** Dibuja en coordenadas de pantalla/página y conserva su comportamiento actual. Esta ruta no debe rediseñarse como parte de los cuadernos.
2. **Hojas acotadas dentro de EPUB y otros documentos reflowables.** Una hoja se ancla al texto mediante un xpointer y ofrece un área delimitada para dibujar. Tampoco debe convertirse en la interfaz de cuadernos.
3. **Cuadernos independientes.** El backend ya está implementado, probado y separado de cualquier libro. Todavía no tiene ventana, biblioteca visual ni entrada de menú visible.

La futura interfaz activa el tercer dominio. No debe reutilizar `ink_canvas_overlay.lua`: esa pieza representa una hoja superpuesta dentro de ReaderUI, con reglas propias de anclaje y tamaño. Un cuaderno es una experiencia de pantalla completa con navegación y ciclo de vida propios.

El plugin mantiene por ahora `is_doc_only = true`. Como parte de la futura implementación de UI habrá que cambiarlo a `false` y registrar una entrada en FileManager y ReaderUI. Esta activación no forma parte del presente encargo de diseño, pero la propuesta debe especificar cómo se ve y se comporta en ambos lugares.

## 4. Hardware, contexto de uso y límites físicos

El dispositivo prioritario es Kindle Scribe, con una pantalla aproximada de 1860 × 2480 píxeles en vertical, panel e-ink y digitalizador Wacom. El diseño también debe adaptarse a lectores de menor tamaño o resolución y a orientación horizontal.

Asume lo siguiente:

- La pantalla es monocroma. El color no puede ser el único portador de estado.
- Los refrescos completos son lentos y pueden parpadear; los rápidos sacrifican fidelidad y pueden dejar ghosting.
- No conviene usar animaciones, transiciones continuas, arrastre con feedback por frame ni barras que cambien de forma constantemente.
- Un lápiz puede tocar controles, pero la captura de tinta ocurre antes del reconocimiento normal de gestos. El widget no recibirá ese contacto si la región no fue declarada como passthrough.
- La palma debe tratarse de manera deliberada. En la ruta moderna de stylus, JustDraw distingue lápiz, goma y dedo; presión, inclinación, hover y proximidad no forman parte del contrato público actual usado por el plugin.
- La goma posterior se puede utilizar si KOReader la expone como herramienta de borrado.
- La latencia, el rechazo real de palma, el ghosting, las waveforms y el comportamiento del firmware sólo pueden aprobarse en un Scribe físico.
- KOReader también puede ejecutar la ruta de compatibilidad con dedo en hardware sin stylus moderno. La UI no debe quedar inutilizable en ese modo.

Diseña objetivos táctiles cómodos para dedo y lápiz. Usa escalado de KOReader (`Screen:scaleBySize`, constantes de `Size` y widgets existentes) en la futura implementación; no fijes controles a un número absoluto de píxeles tomado únicamente del Scribe.

## 5. Arquitectura que ya existe

La relación de componentes es ésta:

```text
Instancia JustDraw del host
├── ReaderUI existente
│   ├── tinta directa PDF, sin cambios
│   └── hojas EPUB, sin cambios
├── NotebookController
│   ├── NotebookRepository
│   │   └── settings/justdraw-notebooks.sqlite3
│   └── NotebookSession
│       └── InkSurfaceSession
│           ├── un InkCanvasCache/raster activo
│           ├── InkCanvasQueue durable
│           ├── codec de trazos por chunks
│           └── índice espacial para goma y reparación
└── InkInputController, singleton de proceso
    └── InkCapture, hook de entrada de bajo nivel
```

La futura UI debe quedar encima de este stack:

```text
NotebookWindow / NotebookLibrary
        │
        ▼
NotebookController y NotebookSession
        │
        ▼
Persistencia, raster y entrada existentes
```

Reglas de separación:

- La UI no abre SQLite ni conoce tablas, sentencias, WAL o chunks.
- La UI no registra callbacks Wacom ni llama directamente a `InkCapture`.
- La UI no pinta trazos reconstruyéndolos desde datos persistidos; presenta el raster activo que mantiene `InkSurfaceSession`.
- La UI no conserva un raster por página ni genera miniaturas a partir de tinta en la biblioteca.
- La UI puede solicitar operaciones al Controller o a la Session pública. Si una acción visual no tiene un método público suficiente, debe proponerse una fachada mínima en lugar de acceder a campos internos.
- Sólo puede existir una superficie activa y una lease de entrada en todo el proceso.

## 6. Modelo de datos y garantías funcionales

### 6.1 Cuadernos

Cada cuaderno expone metadata semejante a:

- `id`;
- `title`;
- `page_count`;
- `created_at`;
- `updated_at`;
- `current_page_id` cuando se consulta el cuaderno individual.

El título se recorta, es obligatorio y admite como máximo 255 bytes. La interfaz debe validar antes de enviar y debe explicar un nombre inválido sin mostrar códigos internos como `bad_title`.

La biblioteca está ordenada por actividad reciente (`updated_at`, después `id`) y usa paginación keyset. El tamaño por defecto es 50 y el máximo por consulta es 200. Cada fila contiene sólo metadata: listar cuadernos no carga páginas, trazos, chunks ni imágenes.

### 6.2 Páginas

Cada página tiene:

- `id` y `notebook_id`;
- una clave de orden interna monotónica;
- `logical_w` y `logical_h`;
- `template_kind`;
- fechas de creación y actualización.

En v1 las páginas sólo se añaden al final. No hay inserción en medio, reordenamiento, duplicado ni movimiento entre cuadernos. Borrar no renumera las claves internas. No se puede borrar la última página de un cuaderno.

Los identificadores conocidos de plantilla son `blank`, `ruled`, `grid` y `dots`, pero el backend actual **sólo los almacena**. No existe todavía un renderer de fondos rayados, cuadriculados o punteados. El diseño debe escoger una de estas dos direcciones y declararla:

- MVP estrictamente honesto: crear únicamente páginas blancas y posponer el selector de plantilla; o
- incluir el selector en la propuesta, pero marcar el renderer de plantillas como dependencia funcional nueva, con su presupuesto de repintado, escalado y borrado.

No presentes las plantillas como una capacidad ya terminada.

### 6.3 Tinta y durabilidad

- Sólo la página abierta tiene cache y raster en memoria.
- En una pantalla Scribe, un raster BB8 completo ocupa aproximadamente 4,6 MB antes de overhead.
- Los trazos se almacenan por chunks y cargan en lotes acotados.
- La cola agrupa escrituras con debounce y límites de cantidad/tamaño; no escribe por cada muestra del lápiz.
- La fecha de actividad se actualiza una vez por batch durable, no por punto o por segmento.
- Un error de COMMIT conserva raster y cola para reintentar, bloquea nueva edición y evita abandonar la página mediante el cierre normal.
- La página actual persistida sólo cambia después de que la página de destino haya terminado de cargar.
- Los borrados son lógicos y un purgador elimina datos en lotes pequeños posteriores. No existe papelera restaurable en v1.
- Una base creada por una versión futura se abre en modo sólo lectura. La navegación sigue disponible sin escribir estado.

## 7. Contratos disponibles para la futura UI

### 7.1 Entrada del plugin

`JustDraw:notebookController()` crea de forma perezosa el dominio de cuadernos; no abre la base hasta la primera operación que la necesita.

`JustDraw:configureNotebookInteraction(opts)` debe ejecutarse antes de abrir un cuaderno. La UI suministra:

- `viewport_provider` o geometría equivalente;
- `fit_rect` y `clip_rect` si no usa provider;
- alineación horizontal y vertical;
- callback de página lista;
- callbacks de cambio de estado y biblioteca;
- política de repintado mediante `on_dirty`;
- regiones o decisiones de passthrough para dedo y stylus;
- getters de modo de entrada, ancho de pluma y modo de goma si la UI los administra.

El Controller de producción exige un viewport válido. Abrir o rotar sin geometría visible se rechaza; el chrome nunca debe tratarse accidentalmente como papel.

### 7.2 `NotebookController`

Operaciones públicas existentes:

| Operación | Uso de UI |
|---|---|
| `listNotebooks(cursor, limit)` | Cargar una página de biblioteca sin blobs; el cursor siguiente se forma con `updated_at` e `id` de la última fila |
| `createNotebook(spec)` | Crear cuaderno y primera página en una transacción |
| `renameNotebook(id, title)` | Renombrar y actualizar la actividad |
| `deleteNotebook(id)` | Cerrar de forma durable si está abierto y escribir un tombstone |
| `openNotebook(id)` | Hacer preflight, handoff de entrada y abrir la última página confirmada |
| `activeSession()` | Obtener la única sesión abierta |
| `closeNotebook()` | Aplicar el gate de guardado antes de liberar la sesión |
| `retryLoad()` | Reintentar la carga fallida de la página activa |
| `retrySave()` | Reintentar cola o metadata pendiente |
| `retryInput()` | Reinstalar la captura después de un fallo explícito |
| `onSuspend()` / `onResume()` | Delegación de ciclo de vida |
| `onScreenResize(...)` | Flush, reconstrucción del raster y nueva captura con geometría válida |

Callbacks disponibles:

- `on_state_changed(state, controller)`;
- `on_library_changed(controller)`;
- `on_page_ready(page, session)` a través de la configuración.

### 7.3 `NotebookSession`

Operaciones públicas existentes:

- `notebook()`;
- `currentPage()`;
- `stateName()`;
- `goToPage(page_id)`;
- `goPrevious()`;
- `goNext()`;
- `appendPage(spec)`;
- `softDeleteCurrentPage()`;
- `flush()`;
- `retryLoad()`, `retrySave()` y `retryInput()`;
- `close()`;
- `onScreenResize()`, `onSuspend()` y `onResume()`.

Las operaciones de cambio de página, append, borrado y cierre se niegan si hay un contacto activo o si el guardado no puede completarse.

### 7.4 Brechas de fachada que el diseño debe evaluar

No inventes respuestas leyendo campos privados. Si la propuesta necesita alguna de las capacidades siguientes, inclúyela en una lista de ampliaciones mínimas del Controller/Session:

- estado derivado `writable/read_only` sin inspeccionar el repositorio;
- `has_previous` y `has_next` para representar límites sin ejecutar una navegación fallida;
- posición ordinal actual para mostrar «Página 3 de 57»; no puede deducirse de `sort_key` después de borrados;
- una fachada paginada `listPages` si se propone un selector de páginas;
- `undo()` y `can_undo` sin entrar directamente en `InkSurfaceSession` o su cache;
- estado de escritura pendiente o guardado si se diseña un indicador fiable de «Guardado»;
- un snapshot cohesivo de capacidades/estado para evitar que el widget combine datos tomados en ticks distintos;
- códigos de error de dominio estables y texto localizado, en vez de mostrar errores de SQLite.

La propuesta debe justificar cada adición. No conviertas esta lista en una API general por anticipado. Si una pantalla puede funcionar con menos contrato, prefiérelo.

## 8. Integración con los dos hosts de KOReader

### 8.1 FileManager

KOReader crea plugins no document-only en FileManager con una instancia que sólo dispone del host `ui`. Allí no existen `document`, `view`, `doc_settings` ni información de página del lector.

La entrada de cuadernos debe estar disponible sin abrir un libro. La propuesta tiene que definir:

- dónde aparece la acción dentro del menú de FileManager;
- si abre directamente la biblioteca o reabre el último cuaderno;
- qué ocurre al pulsar Back desde biblioteca y desde editor;
- cómo se conserva el estado al abandonar FileManager para abrir un libro.

No diseñes ninguna dependencia de ReaderUI para esta ruta.

### 8.2 ReaderUI

ReaderUI crea otra instancia del plugin con `dialog`, `view`, `ui` y `document`. Al abrir un cuaderno desde un libro:

1. se valida la base, la página inicial y el viewport;
2. una hoja EPUB abierta debe guardarse y cerrarse;
3. si el lector estaba en Draw directo, se detiene y libera su lease;
4. el cuaderno toma la única lease y abre su ventana;
5. si el preflight o el flush anterior falla, el cuaderno no debe aparecer como abierto.

Al cerrar el cuaderno no se reactiva automáticamente el modo Draw anterior del libro. El usuario vuelve al libro en un estado seguro y explícito.

La propuesta debe decidir si la acción de menú abre biblioteca o último cuaderno, pero debe usar la misma arquitectura visual que en FileManager. Evita dos productos distintos para cada host.

### 8.3 Cambio de host

FileManager y ReaderUI no comparten la misma instancia de `NotebookController`. El estado durable de última página vive en SQLite; la lease de entrada es singleton de proceso para impedir que una instancia vieja desregistre el callback de una nueva.

La UI no puede confiar en referencias en memoria para sobrevivir a FileManager → ReaderUI. Un flujo que implique abrir un documento mientras hay un cuaderno abierto debe cerrar primero el cuaderno mediante el Controller.

## 9. Forma de la ventana y stack de KOReader

El editor de cuaderno debe ser un widget de nivel superior, de pantalla completa, mostrado con `UIManager:show`. Debe cubrir el host subyacente y consumir los gestos que le corresponden. No debe ser una colección de overlays independientes con orden ambiguo.

El orden conceptual es:

```text
FileManager o ReaderUI
└── NotebookWindow de pantalla completa
    ├── chrome y controles
    ├── superficie visible de la página
    └── diálogos/modales mostrados por encima
```

La ventana debe mantener una referencia correcta como `show_parent` para que los subwidgets invaliden el widget superior real. `UIManager:setDirty` sólo marca un widget para repaint si dicho widget está en el stack de ventanas; usar un hijo arbitrario puede encolar un refresh sin volver a pintarlo.

El cierre voluntario debe seguir este orden:

```text
Usuario solicita salir
→ NotebookController:closeNotebook()
→ si el flush termina: UIManager:close(NotebookWindow, refresco adecuado)
→ si falla: mantener la ventana y mostrar recuperación de guardado
```

No cierres primero el widget. La API de KOReader no ofrece veto después de iniciar el cierre. Un cierre externo forzado del proceso sigue siendo un límite residual: JustDraw libera el callback y la base aunque el último COMMIT falle, después de informar el error.

## 10. Enrutado de lápiz, dedo y controles

### 10.1 Papel y chrome

La propuesta debe definir dos regiones geométricas estables:

- **Página/papel:** `fit_rect` determina escala y posición; `clip_rect` determina lo visible e interactuable.
- **Chrome:** barras, botones, indicadores y márgenes que no pertenecen al papel.

La opción más segura es reservar espacio fuera de `clip_rect` para los controles persistentes. Esto reduce colisiones entre tinta y UI y evita que el chrome se capture como papel.

Si un control o modal invade la página, su región debe formar parte de `stylus_passthrough`. Si aparece en mitad de un trazo, el adaptador repara la tinta provisional y suprime el lápiz hasta que se levanta; nunca debe entregar a un botón la segunda mitad de un contacto que comenzó dibujando.

### 10.2 Comportamiento recomendado por fuente

| Fuente | Sobre papel | Sobre chrome declarado | Fuera de la ventana |
|---|---|---|---|
| Lápiz | dibuja o borra | pasa al widget; no dibuja debajo | la ventana superior decide/consume |
| Goma física | borra | pasa al widget si la región es control | la ventana superior decide/consume |
| Dedo en modo stylus | se suprime por defecto para rechazo deliberado de palma | pasa a controles/navegación explícitos | no debe alcanzar por accidente al libro inferior |
| Dedo en modo finger | dibuja sobre papel | pasa a controles declarados | la ventana superior decide/consume |

El diseñador debe decidir y justificar si habrá zonas de navegación por toque dentro del editor. Si se usan, deben estar fuera del papel o ser regiones passthrough explícitas y suficientemente grandes. No dependas únicamente de swipes sobre la página: en modo stylus pueden confundirse con palma, y en modo finger la página es la superficie de dibujo.

### 10.3 Latch y seguridad durante un trazo

- El destino de un contacto queda fijado al inicio.
- Un botón que se desplaza debajo de una punta ya apoyada no debe apropiarse del contacto.
- Navegar, cerrar, rotar o borrar una página durante un contacto activo debe rechazarse o aplazarse hasta el lift.
- No muestres un diálogo destructivo a mitad de trazo. Primero termina/aborta el contacto de forma segura y actualiza las regiones de passthrough.
- No permitas que un lápiz toque visualmente un botón pero siga dibujando debajo.
- No permitas que un modal visible deje activa la página que tiene detrás.

La especificación debe incluir una matriz de gestos completa para lápiz, goma, dedo, Back/teclas físicas si existen, orientación y toques repetidos.

## 11. Restricciones de refresco e-ink

`UIManager:setDirty` encola repaint y refresh para el siguiente tick; no pinta ni bloquea de inmediato. KOReader distingue, entre otros:

- `full`: máxima fidelidad, con flash y alta latencia;
- `ui`: fidelidad media para contenido mixto y controles;
- `partial`: texto sobre fondo blanco, usado sobre todo en ReaderUI;
- `fast`: baja fidelidad para contenido monocromo y feedback breve;
- `a2`: aún más limitado y reservado a casos concretos;
- `flashui`/`flashpartial`: variantes con limpieza mediante flash.

La ruta de tinta probada refresca cada segmento con modo rápido. No introduzcas coalescing, animación o otra waveform como hecho consumado. Si propones cambiar la política, conviértelo en una hipótesis para medir en Scribe contra la ruta actual.

Para cada interacción del diseño, especifica:

- qué región se repinta;
- qué tipo de refresh se espera;
- si se necesita un flash al entrar/salir o tras varias actualizaciones rápidas;
- cómo se limpia el ghosting sin flashear por cada trazo;
- qué ocurre al mostrar/ocultar chrome, cambiar página, rotar, abrir un diálogo o volver a la biblioteca.

Principios obligatorios:

- no refrescar toda la pantalla al mover cada punto de lápiz;
- no repintar biblioteca o toolbar por cada batch de tinta guardado;
- no usar scroll o animaciones que requieran decenas de frames;
- preferir cambios discretos, listas por páginas y estados visuales estables;
- mantener el feedback de presión/tap simple: la inversión rápida puede usar `fast`, y el regreso de texto debe conservar nitidez;
- limitar cada dirty region a la zona que realmente cambió.

KOReader evita deliberadamente feedback continuo en piezas como `MovableContainer`: el movimiento se materializa al soltar. No bases un control esencial en arrastrar a ciegas. Para cambiar opciones discretas, usa botones, ciclos o selecciones explícitas.

## 12. Escala y rendimiento que el diseño debe preservar

El backend está preparado para una biblioteca grande, pero una UI puede anular esas garantías si pide demasiado.

### Biblioteca

- Carga como máximo una página de metadata cada vez.
- Usa el cursor de la última fila; no uses `OFFSET` ni cargues toda la colección para calcular posiciones.
- No generes miniaturas de tinta al listar.
- No abras páginas en segundo plano para obtener una previsualización.
- No mantengas una jerarquía visual por cada página de cada cuaderno.
- Si hay actualización por `on_library_changed`, conserva de manera comprensible la posición o vuelve al inicio de forma deliberada; no mezcles páginas de dos snapshots del cursor.

Con estas restricciones, una lista textual paginada es la dirección de menor riesgo. Si propones una cuadrícula de «portadas», las portadas sólo pueden construirse con metadata y gráficos baratos; no pueden ser thumbnails reales sin una fase nueva de arquitectura y persistencia.

### Editor

- Mantén un único raster de página.
- Al cambiar de página, muestra un estado de carga hasta el primer paint; no simules que la página anterior ya es la siguiente.
- No precargues raster ni puntos de páginas vecinas.
- Una página densa puede tardar en inicializar metadata/índice y cargar puntos por ticks. El diseño necesita un estado de carga no bloqueante y una salida recuperable.
- No añadas un filmstrip con miniaturas vivas.

### Escrituras y flash

- No fuerces `flush()` por cada trazo, tap o actualización de indicador.
- Sí aplica el gate durable antes de cambiar página, borrar, cerrar, suspender o ceder el input a otro dominio.
- El borrado visible no libera inmediatamente todo el espacio; el purgador trabaja en ticks. No añadas una barra de progreso de purga salvo que exista un requisito y una API pública.

## 13. Estados de la sesión y comportamiento esperado

`stateName()` devuelve `closed`, `loading`, `ready`, `load_failed`, `save_failed` o `input_failed`. El modo read-only es una capacidad adicional, no un nombre de estado actual. `contact_active` es un error transitorio de una acción, tampoco un estado estable.

La propuesta debe incluir como mínimo esta matriz, refinada con copy y jerarquía visual:

| Condición | Qué se muestra | Tinta | Navegación | Salir | Acción primaria |
|---|---|---|---|---|---|
| Sin cuaderno / biblioteca vacía | estado vacío y crear | no aplica | biblioteca | sí | Crear cuaderno |
| `loading` | chrome estable y página en carga | bloqueada | bloqueada | sólo si el cierre seguro lo permite | Esperar; opción de volver si procede |
| `ready`, writable | página y herramientas | sí | sí, con gate durable | sí, con gate durable | Escribir |
| `ready`, read-only | página y aviso persistente discreto | no | sí, sin escribir página actual | sí | Consultar/navegar |
| `load_failed` | superficie retenida o parcial más error persistente | no | bloqueada para esa transición | ofrecer salida segura sin ocultar el fallo | Reintentar carga |
| `save_failed` | raster y tinta no confirmada conservados, error prominente | no más tinta | bloqueada | no cerrar voluntariamente | Reintentar guardado |
| `input_failed` | página visible con herramientas de tinta inactivas | no | sí si la persistencia está sana | sí | Reintentar lápiz |
| `contact_active` al pedir otra acción | sin cambio de pantalla destructivo | continúa hasta lift/abort seguro | aplazar o rechazar | aplazar o rechazar | Levantar lápiz y repetir |

Requisitos de recuperación:

- No uses únicamente un toast para `save_failed`, `load_failed` o `input_failed`.
- El botón Retry debe permanecer alcanzable por dedo y lápiz.
- Un retry no debe cerrar la pantalla antes de saber el resultado.
- Durante `save_failed`, no ofrezcas acciones que hagan creer al usuario que la tinta ya es durable.
- Si el dispositivo queda read-only por schema futuro, explica que las notas se pueden consultar pero no modificar. Deshabilita creación, renombrado, borrado, append, goma, lápiz y undo.
- No muestres mensajes técnicos de SQLite como copy principal. Puede existir un detalle diagnóstico secundario si encaja con KOReader.

## 14. Flujos que deben diseñarse de principio a fin

### 14.1 Entrada desde FileManager

Diseña el recorrido desde la acción de menú hasta:

- biblioteca con datos;
- biblioteca vacía;
- error al abrir la base;
- reapertura del último cuaderno;
- salida de vuelta al explorador.

### 14.2 Entrada desde un libro

Incluye:

- acción desde el menú de ReaderUI;
- preflight visible sólo si tarda lo suficiente;
- cierre de una hoja EPUB abierta;
- caso en que esa hoja no puede guardarse y el cuaderno no abre;
- detención del Draw directo;
- vuelta al libro sin reactivar Draw automáticamente.

### 14.3 Crear un cuaderno

La creación necesita al menos:

- título válido;
- dimensiones lógicas o un preset de formato/orientación que produzca esas dimensiones;
- plantilla realista para el alcance elegido;
- confirmación y apertura de la primera página;
- tratamiento de título vacío, demasiado largo, read-only y error de escritura.

El usuario no debe introducir números de geometría. Recomienda presets simples y explica cómo se transforman a `logical_w/logical_h`. La geometría lógica debe permanecer estable al rotar; no uses los píxeles actuales de pantalla como identidad semántica de la página sin justificar cómo se conserva entre dispositivos.

### 14.4 Biblioteca

Diseña:

- jerarquía de cada fila usando únicamente título, número de páginas y actividad;
- paginación/carga de siguientes 50;
- foco o selección para lápiz, dedo y teclas;
- abrir;
- renombrar;
- borrar con confirmación clara;
- retorno desde el editor con metadata actualizada;
- errores de carga de una página de resultados sin perder lo ya visible;
- read-only global.

No incluyas búsqueda o filtros como MVP salvo que también identifiques el contrato backend y la estrategia indexada que requieren.

### 14.5 Editor

Diseña el chrome y la página para vertical y horizontal:

- volver a biblioteca o al host;
- título del cuaderno;
- indicación de página basada en datos que realmente existan;
- lápiz;
- goma lógica y goma física;
- undo;
- anterior/siguiente;
- añadir página al final;
- borrar página actual, sin permitir borrar la última;
- acceso a ajustes de entrada relevantes sin llenar la pantalla de controles;
- estado de carga/guardado/error;
- mostrar u ocultar chrome, si lo recomiendas, sin dejar una salida inalcanzable.

Explica cómo se evita que una palma toque navegación o borrado. No uses un swipe sobre toda la página como único medio de cambiar de página.

### 14.6 Cambiar, añadir y borrar página

Incluye secuencias separadas para:

- siguiente/anterior en límites;
- carga normal de destino;
- fallo de flush antes del cambio;
- fallo de carga del destino;
- append con herencia de dimensiones y plantilla;
- borrado de página intermedia;
- intento de borrar la última;
- intento durante un trazo activo.

### 14.7 Renombrar y borrar cuaderno

- Renombrar debe usar un diálogo compatible con teclado KOReader, aceptar traducciones largas y conservar el nombre si la escritura falla.
- Borrar exige confirmación inequívoca. La acción es un tombstone sin restauración visible en v1: el copy no debe prometer papelera ni recuperación.
- Borrar el cuaderno abierto obliga primero a un cierre durable. Si éste falla, no presentes el borrado como completado.

### 14.8 Suspender, reanudar y rotar

- Suspend libera la captura.
- Resume sólo recupera una captura sana; `input_failed` exige Retry explícito.
- Rotación hace flush, libera captura, recalcula transform, reconstruye raster y recaptura sólo al llegar a ready.
- Durante la reconstrucción no se puede dibujar ni activar accidentalmente el host inferior.

Define el estado visual y la política de refresco para estas transiciones.

## 15. Inventario mínimo de pantallas y componentes

La propuesta debe resolver, como mínimo:

1. Acción de entrada en menú de FileManager.
2. Acción de entrada en menú de ReaderUI.
3. Biblioteca vacía.
4. Biblioteca con resultados paginados.
5. Diálogo de creación.
6. Diálogo de renombrado.
7. Confirmación de borrado de cuaderno.
8. Editor de pantalla completa en vertical.
9. Editor de pantalla completa en horizontal.
10. Confirmación de borrado de página.
11. Loading inicial y loading entre páginas.
12. Load failed con Retry.
13. Save failed con Retry persistente.
14. Input failed con Retry del lápiz.
15. Modo read-only.
16. Error de biblioteca/base no disponible.

Mapea cada pieza a widgets o patrones nativos plausibles de KOReader. Entre los candidatos están `Menu`, `InputDialog` o `MultiInputDialog`, `ConfirmBox`, `InfoMessage`, `ButtonDialog`, `Button`, `FrameContainer`, `VerticalGroup`, `HorizontalGroup` e `InputContainer`. No es obligatorio usar todos. Si propones un widget nuevo, explica por qué los existentes no cubren el comportamiento.

Los mensajes transitorios pueden usar patrones equivalentes a `InfoMessage`, pero no sustituyen estados de error persistentes. Todas las cadenas visibles deberán pasar por `_()` en la implementación y admitir expansión de texto, RTL y Bidi.

## 16. Decisiones de diseño que debes tomar y justificar

No devuelvas varias alternativas sin recomendación. Elige una dirección principal para cada punto:

1. **Entrada:** abrir biblioteca o último cuaderno desde cada host.
2. **Biblioteca:** lista paginada frente a cuadrícula de portadas sin thumbnails.
3. **Creación:** presets de tamaño/orientación y alcance real de plantillas.
4. **Chrome del editor:** posición en vertical y horizontal; espacio reservado fuera del papel.
5. **Navegación de páginas:** botones, zonas de toque o combinación segura.
6. **Indicador de página:** qué mostrar mientras no exista posición ordinal pública.
7. **Modo de foco:** maximizar papel sin perder una salida o Retry alcanzable.
8. **Herramientas:** jerarquía de lápiz, goma, undo y acciones de página.
9. **Estado de guardado:** cuánto feedback mostrar sin provocar repaints ni afirmar algo que el backend no expone.
10. **Errores:** presentación persistente que no tape la tinta recuperable ni permita dibujar debajo.
11. **Passthrough:** regiones exactas y orden de actualización al mostrar chrome o modal.
12. **Accesibilidad e internacionalización:** targets, texto largo, contraste, teclado, RTL y usuarios zurdos.
13. **Preferencias:** si reutilizar modo de entrada/ancho/goma actuales del plugin o mantener ajustes específicos de cuaderno. Evita dos fuentes de verdad sin una razón explícita.

Incluye las razones funcionales, no sólo una preferencia estética.

## 17. Entregables obligatorios de la propuesta

El documento final del agente de diseño debe incluir:

1. **Resumen ejecutivo:** dirección recomendada y por qué encaja con e-ink, stylus y arquitectura.
2. **Supuestos y alcance:** MVP, dependencias y funciones pospuestas.
3. **Arquitectura de información:** mapa de biblioteca, editor, diálogos y retorno a los dos hosts.
4. **Flujos end-to-end:** todos los casos de la sección 14, incluidos fallos.
5. **Wireframes de baja fidelidad:** Scribe vertical y horizontal; añade una adaptación para una pantalla más pequeña. Pueden ser diagramas, SVG o imágenes, pero deben incluir medidas relativas y zonas de interacción.
6. **Especificación de componentes:** anatomía, estados, acciones, foco y widget KOReader sugerido.
7. **Matriz de input:** lápiz, goma, dedo, teclado/Back, contacto activo y modal.
8. **Matriz de estados:** loading, ready, read-only, load/save/input failed y transitorios.
9. **Presupuesto de refresco:** tipo y región esperada para cada interacción relevante.
10. **Copy principal:** etiquetas y mensajes de recuperación en español neutro; indica que en código serán localizables.
11. **Accesibilidad e i18n:** tamaño de targets, contraste, traducciones largas, RTL/Bidi y zurdos.
12. **Brechas de API:** método mínimo, consumidor, motivo y alternativa si no se añade.
13. **Plan de validación:** simulador KOReader, matrices estable/dev y gate físico Scribe.
14. **Fases de entrega:** MVP implementable, afinado posterior y funciones fuera de alcance.
15. **Registro de fuentes:** URLs oficiales y commits exactos usados.

Los wireframes no deben ocultar estados difíciles detrás de notas al margen. Muestra visualmente dónde vive Retry, qué queda deshabilitado y cómo se sale sin perder tinta.

## 18. No objetivos y límites duros

No diseñes como capacidad comprometida del MVP:

- exportación a PDF, PNG o formato Amazon;
- sincronización, nube o backup automático;
- integración con cuadernos nativos del Kindle;
- OCR o reconocimiento de escritura;
- búsqueda de tinta o texto dentro de cuadernos;
- presión, inclinación, hover o pinceles caligráficos dependientes de esas señales;
- miniaturas reales de páginas;
- precarga de páginas vecinas;
- reordenar, insertar entre páginas, duplicar o mover páginas;
- restaurar desde papelera;
- múltiples hojas visibles o múltiples rasters activos;
- edición simultánea desde dos hosts;
- migración entre hojas EPUB y cuadernos;
- animaciones o gestos complejos que requieran refresco continuo.

Puedes mencionarlos como extensiones futuras sólo si no condicionan la arquitectura del MVP.

## 19. Archivos del repositorio que debes leer

Fuentes principales:

- `README.md`, especialmente “Standalone notebooks”, entrada, límites y pruebas.
- `decisions.md`, especialmente ADR-6, ADR-8 a ADR-13 y ADR-18.
- `standalone-notebooks-dev-plan-2026-08-26.md`.
- `justdraw.koplugin/main.lua`.
- `justdraw.koplugin/ink_notebook_controller.lua`.
- `justdraw.koplugin/ink_notebook_session.lua`.
- `justdraw.koplugin/ink_notebook_repository.lua`.
- `justdraw.koplugin/ink_notebook_input.lua`.
- `justdraw.koplugin/ink_input_controller.lua`.
- `justdraw.koplugin/ink_surface_session.lua`.
- `justdraw.koplugin/ink_canvas_transform.lua`.
- `justdraw.koplugin/ink_canvas_cache.lua`.
- `justdraw.koplugin/ink_canvas_queue.lua`.

Pruebas que documentan contratos y edge cases:

- `justdraw.koplugin/tests/notebook_controller_spec.lua`.
- `justdraw.koplugin/tests/notebook_session_spec.lua`.
- `justdraw.koplugin/tests/notebook_repository_spec.lua`.
- `justdraw.koplugin/tests/notebook_input_spec.lua`.
- `justdraw.koplugin/tests/notebook_geometry_spec.lua`.
- `justdraw.koplugin/tests/notebook_host_spec.lua`.
- `justdraw.koplugin/tests/surface_session_spec.lua`.
- `justdraw.koplugin/tests/input_controller_spec.lua`.
- `justdraw.koplugin/tests/conformance.lua`.

Para patrones KOReader, estudia en las referencias estable y dev actuales:

- `frontend/ui/uimanager.lua`;
- `frontend/ui/widget/menu.lua`;
- `frontend/ui/widget/inputdialog.lua` y `multiinputdialog.lua`;
- `frontend/ui/widget/confirmbox.lua`;
- `frontend/ui/widget/infomessage.lua`;
- `frontend/ui/widget/buttondialog.lua`;
- `frontend/ui/widget/button.lua`;
- `frontend/ui/widget/container/movablecontainer.lua` sólo para comprender sus límites, no como patrón obligatorio;
- `frontend/apps/filemanager/filemanager.lua` y su menú;
- `frontend/apps/reader/readerui.lua` y su menú;
- plugins oficiales que presenten listas o ventanas de pantalla completa en ambos hosts.

## 20. Baseline documental y obligación de revalidar

La investigación del plan de backend, realizada el 2026-08-26, fijó estas referencias:

- KOReader estable: tag `v2026.07.1`, commit `9192014d8bd82a91dc1012473be0f238dedfdb54`.
- KOReader desarrollo: commit `5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8`.
- Runtime local disponible: `v2025.08-100-g1d66e440b`, demasiado antiguo para validar por sí solo la ruta moderna de stylus.

En la preparación de este brief no fue posible volver a consultar la API de GitHub por un fallo de red. Por tanto, esas referencias son baselines ya verificadas del proyecto, no una afirmación de que siguen siendo las últimas al ejecutar tu tarea. Resuélvelas de nuevo antes de cerrar la propuesta y cita commits inmutables.

Fuentes oficiales ya utilizadas por el plan:

- [Carga de plugins en FileManager, estable fijado](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/apps/filemanager/filemanager.lua#L417-L429)
- [Creación de plugins en ReaderUI, estable fijado](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/apps/reader/readerui.lua#L463-L476)
- [Transición de FileManager a ReaderUI](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/apps/filemanager/filemanager.lua#L819-L849)
- [UIManager: show, close y stack, estable fijado](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/uimanager.lua#L156-L225)
- [UIManager: propagación de eventos, estable fijado](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/ui/uimanager.lua#L884-L930)
- [API documentada de entrada de KOReader](https://koreader.rocks/doc/modules/device.input.html)
- [Implementación de `device/input.lua`, estable fijado](https://github.com/koreader/koreader/blob/9192014d8bd82a91dc1012473be0f238dedfdb54/frontend/device/input.lua)
- [UIManager en la referencia dev fijada](https://github.com/koreader/koreader/blob/5e45c4b5c7bc5d29dee5ce98b3e9c380905788d8/frontend/ui/uimanager.lua)

No uses snippets de resultados de búsqueda como evidencia final. Para cada comportamiento importante, lee la página o el archivo oficial real.

## 21. Estado de verificación del backend

Al redactar este encargo, el backend de cuadernos había superado:

- 1969 comprobaciones Lua, sin fallos;
- las mismas 1969 comprobaciones bajo LuaJIT de KOReader;
- 48 de 48 comprobaciones de sintaxis;
- preflight completo;
- 64 claims de conformidad con SQLite real y EPUB real, sin discrepancias;
- tres auditorías independientes de arquitectura, KOReader y persistencia.

Esto confirma los contratos de software cubiertos por las pruebas, no la ergonomía del editor. Permanecen pendientes:

- smoke exacto en KOReader estable y dev resueltos al momento del trabajo de UI;
- gate físico en Kindle Scribe;
- latencia y frecuencia de muestras reales;
- palma y goma posterior con firmware real;
- ghosting y waveforms;
- rotación, suspensión y reanudación físicas;
- página densa de 1000 o más trazos y secuencias largas de cambios de página.

La propuesta debe convertir estos pendientes en escenarios observables de validación, no en garantías.

## 22. Criterios de aceptación de la propuesta

La propuesta está lista para convertirse en plan de implementación sólo si:

- cubre FileManager y ReaderUI sin asumir que comparten instancia;
- usa una ventana superior de pantalla completa y define su cierre durable;
- separa papel y chrome mediante `fit_rect`/`clip_rect`;
- hace alcanzables todos los controles con lápiz y dedo sin tinta debajo;
- contempla palma, contacto activo y modales que aparecen durante una sesión;
- incluye estados persistentes de Retry para carga, guardado e input;
- trata read-only como capacidad distinta de `stateName()`;
- no promete plantillas dibujadas, thumbnails, búsqueda, exportación o reordenamiento sin declarar una fase nueva;
- conserva paginación keyset, metadata-only y un único raster;
- no exige cargar todas las páginas para mostrar biblioteca o posición;
- especifica refresco por interacción y evita animación/scroll continuo;
- no permite cerrar voluntariamente después de un fallo de guardado;
- identifica con precisión cualquier método público que falta;
- muestra wireframes verticales y horizontales con targets, errores y navegación reales;
- termina con una recomendación principal implementable, no sólo con una colección de opciones.

Si un requisito visual entra en conflicto con la durabilidad, la captura del lápiz o los límites e-ink, prioriza la seguridad de los datos y explica el ajuste de diseño.
