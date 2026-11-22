# PDFtrack - Infraestructura, Orquestación y Despliegue (`pdftrack-deploy`)

[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-v2-blue.svg)](https://docs.docker.com/compose/)
[![Traefik](https://img.shields.io/badge/Reverse%20Proxy-Traefik%20v3-00B2B2.svg)](https://traefik.io/)
[![Twelve-Factor App](https://img.shields.io/badge/Architecture-Twelve--Factor-success.svg)](https://12factor.net/)
[![Grafana k6](https://img.shields.io/badge/Stress%20Test-Grafana%20k6-7D67FF.svg)](https://k6.io/)
[![Vegeta](https://img.shields.io/badge/Load%20Test-Vegeta-red.svg)](https://github.com/tsenart/vegeta)

Repositorio central de infraestructura, orquestación multicontenedor y pruebas de estrés del sistema **PDFtrack**. Este es el **único** repositorio del ecosistema que conoce la topología completa de servicios, definiendo las políticas de red, volúmenes de datos, healthchecks, límites estrictos de hardware y harnesses de benchmarking bajo modelos de carga abiertos y cerrados.

---

## 1. Arquitectura del Sistema y Topología de Red

El sistema opera como una arquitectura de microservicios distribuidos desacoplados. Todo el tráfico externo ingresa obligatoriamente a través del proxy inverso **Traefik v3**, el cual realiza enrutamiento determinista por path, balanceo dinámico con estrategia `p2c` (Power of Two Random Choices) y protección contra sobrecargas mediante buffering de cuerpos en memoria/disco.

```
                            [ Cliente / Pruebas de Carga ]
                                          │
                                          │ HTTP :80 (Host)
                                          ▼
                         ┌─────────────────────────────────┐
                         │      pdftrack-proxy             │
                         │      (Traefik v3)               │
                         │  • File Provider                │
                         │  • Sin docker.sock              │
                         │  • Buffering (55 MiB)           │
                         │  • Strategy: p2c                │
                         │  • Dynamic DNS Round-Robin      │
                         └────────────────┬────────────────┘
                                          │
              Red Interna Bridge Aislada  │ (pdftrack-net)
              Puertos cerrados al Host    │
         ┌────────────────────────────────┴────────────────────────────────┐
         │                                                                 │
         ▼ (Path: /extract, /health/*, /docs)                              ▼ (PathPrefix: /api)
┌─────────────────────────────────┐                       ┌─────────────────────────────────┐
│     pdftrack-extractor          │                       │      pdftrack-documents         │
│  (FastAPI + PyMuPDF)            │                       │  (FastAPI + Beanie ODM)         │
│  • Stateless / Workers aislados │                       │  • Gestión de documentos        │
│  • Escalamiento (1 a N réplicas)│                       │  • Consultas y paginado         │
│  • Backpressure HTTP 429/503    │                       │  • Puerto interno: 8001         │
│  • Puerto interno: 8000         │                       └────────────────┬────────────────┘
└─────────────────────────────────┘                                        │
                                                                           │ MONGODB_URL
                                                                           ▼ :27017
                                                          ┌─────────────────────────────────┐
                                                          │          mongodb:7.0            │
                                                          │  • Base de datos NoSQL          │
                                                          │  • Volumen: mongodb-data        │
                                                          │  • Puerto interno: 27017        │
                                                          └─────────────────────────────────┘
```

### Topología de Puertos

| Servicio | Puerto en Host | Puerto Contenedor | Acceso Externo | Propósito |
| :--- | :---: | :---: | :---: | :--- |
| `proxy` | **`${PUBLIC_PORT:-80}`** | `${PUBLIC_PORT:-80}` | **SÍ (Punto Único)** | Puerta de entrada HTTP pública |
| `proxy` | *Ninguno* | `8082` | NO (Solo interno) | Healthcheck interno de Traefik (`/ping`) |
| `extractor` | *Ninguno* | `8000` | NO (Solo proxy) | Microservicio de extracción síncrona |
| `documents` | *Ninguno* | `8001` | NO (Solo proxy) | Microservicio CRUD y metadatos |
| `mongodb` | *Ninguno* | `27017` | NO (Solo interno) | Almacenamiento persistente BSON/JSON |

---

## 2. Prerrequisitos del Entorno

* **Docker Engine** >= 24.0.0
* **Docker Compose** v2 (comando integrado `docker compose`)
* **GNU Make** (opcional pero recomendado; disponible nativamente en Linux/macOS y mediante Git Bash o WSL en Windows)
* **cURL** (para verificación de healthchecks)

---

## 3. Inicio Rápido (Quickstart)

Para inicializar y levantar el stack completo en modo desarrollo local con un único comando:

```bash
cp .env.example .env && make up
```

Una vez levantado, verifique el estado operativo de los componentes con:

```bash
make health
```

---

## 4. Endpoints Expuestos por el Proxy Inverso

Todas las solicitudes deben dirigirse a `http://localhost:${PUBLIC_PORT:-80}`. Traefik distribuye internamente el tráfico según la prioridad y las reglas de coincidencia:

| Método | Path | Prioridad | Upstream | Descripción |
| :--- | :--- | :---: | :---: | :--- |
| `POST` | `/extract` | **100** | `extractor-svc` | Extracción síncrona de texto y metadatos de PDF (Multipart o Binary). Protegido por middleware de buffering (máx. 55 MiB). |
| `GET` | `/health/live` | **100** | `extractor-svc` | Liveness probe del extractor (HTTP 200). |
| `GET` | `/health/ready` | **100** | `extractor-svc` | Readiness probe del extractor (HTTP 200). |
| `GET` | `/openapi.json` | **100** | `extractor-svc` | Especificación OpenAPI 3.1 del extractor. |
| `GET` | `/docs` | **90** | `extractor-svc` | Swagger UI interactiva del extractor. |
| `POST` | `/api/documents` | **80** | `documents-svc` | Indexación de documento con extracción delegada y persistencia en MongoDB. |
| `GET` | `/api/documents` | **80** | `documents-svc` | Listado paginado de documentos almacenados (`?skip=0&limit=20`). |
| `GET` | `/api/documents/{id}`| **80** | `documents-svc` | Detalle, metadatos y contenido de un documento por su ID. |
| `DELETE`| `/api/documents/{id}`| **80** | `documents-svc` | Eliminación lógica/física de un documento. |
| `GET` | `/api/health/live` | **80** | `documents-svc` | Liveness probe del servicio de gestión documental. |
| `GET` | `/api/health/ready`| **80** | `documents-svc` | Readiness probe de documentos (valida ping activo contra MongoDB). |
| `ANY` | `/*` (Fallback) | **1** | `extractor-svc` | Router fallback para compatibilidad con clientes legados. |

---

## 5. Modos de Despliegue

### A. Desarrollo Local (Build desde código fuente hermano)
Construye las imágenes en caliente tomando los contextos de los repositorios hermanos mediante `docker-compose.build.yml`:

```bash
make up
# Equivalente nativo:
# docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

### B. Producción (Imágenes Publicadas / Registros)
Consume imágenes ya compiladas y tageadas en registros de contenedores (Docker Hub, GHCR), sin necesidad de código fuente en el host:

```bash
make up-prod
# Equivalente nativo:
# docker compose -f docker-compose.yml up -d
```

### C. Escalamiento a 5 Réplicas del Extractor (Benchmarking)
Aplica la capa override `docker-compose.5-replicas.yml` para desplegar 5 instancias del microservicio `extractor`. Traefik v3 balancea automáticamente el tráfico vía DNS dinámico de Docker y estrategia `p2c` sin reiniciar el proxy:

```bash
make up-5replicas
# Equivalente nativo:
# docker compose -f docker-compose.yml -f docker-compose.build.yml -f docker-compose.5-replicas.yml up -d --build
```

---

## 6. Pruebas de Estrés y Benchmarking de Rendimiento

El sistema incluye dos suites de pruebas de carga en `tests/stress/` para evaluar la resiliencia, el encolamiento y el backpressure ante ráfagas extremas.

### A. Prueba Spike con Grafana k6 (Modelo Cerrado de Carga)

El modelo cerrado fija el número de usuarios virtuales (**100 VUs**) y evalúa cómo el tiempo de respuesta del servidor desacelera la generación de nuevas solicitudes.

* **Perfil de Carga**:
  * 0 a 100 VUs en 10 s (rampa de aceleración agresiva)
  * 100 VUs constantes durante 20 s (meseta de saturación máxima)
  * 100 a 0 VUs en 10 s (rampa de drenado controlado)
  * **Duración total**: 40 segundos
* **Mecanismo**: Cada VU rota secuencialmente los 4 PDFs oficiales y despacha peticiones `POST /extract` en formato `multipart/form-data`.
* **Clasificación de Respuestas**:
  1. **Exitosas (HTTP 200)**: Procesamiento completado en tiempo y forma.
  2. **Rechazos Controlados (HTTP 429 / 503)**: Backpressure planificado cuando los workers o la cola del extractor están al límite de capacidad.
  3. **Fallos Inesperados (HTTP 500, 502, 504 o fallas TCP)**: Errores no controlados que violan el contrato del sistema.

Ejecutar mediante:
```bash
make stress-k6
```

### B. Prueba de Carga Constante con Vegeta (Modelo Abierto de Carga)

El modelo abierto simula el arribo de clientes independientes a una tasa estricta y constante (**50 req/s**), independientemente de cuán saturado esté el backend.

* **Configuración**:
  * Tasa de ataque: **50 peticiones/segundo constantes**
  * Duración: **30 segundos**
  * Peticiones generadas: **1500 peticiones en total**
  * Timeout por petición: **30 segundos**
  * Formato: Envío directo del payload binario `application/pdf`.

Ejecutar mediante:
```bash
make stress-vegeta
```

Para correr ambas pruebas secuencialmente:
```bash
make stress-all
```

---

## 7. Interpretación de Resultados vs. Valores de Referencia de la Cátedra

Los resultados deben compararse directamente con las líneas de base provistas por la cátedra para evaluar la optimización de la arquitectura:

| Herramienta | Métrica Clave | Umbral Cátedra (Baseline) | Comportamiento Esperado en PDFtrack |
| :--- | :--- | :--- | :--- |
| **Grafana k6** | **Throughput Global** | **> 25.35 req/s** | Debe superar el baseline gracias a Traefik v3 y `maxIdleConnsPerHost: 2`. |
| **Grafana k6** | **Fallos Inesperados** | **0% (count == 0)** | **Cero tolerancia** a códigos 500/502. Todo rechazo debe ser HTTP 429/503. |
| **Grafana k6** | **Latencia p(95)** | **< 30.00 s** | Todas las peticiones procesadas deben resolverse antes del timeout de 30s. |
| **Vegeta** | **Throughput Efectivo** | **> 16.65 req/s** | Capacidad efectiva sostenida sin colapsar las colas de procesamiento. |
| **Vegeta** | **Tasa de Éxito** | **> 66.53%** | Porcentaje de respuestas 200 OK bajo una tasa de arribo agresiva de 50 req/s. |

> **Nota Teórica (Modelo Abierto vs. Modelo Cerrado)**:  
> En el **modelo cerrado (k6)**, las 100 VUs esperan a que el servidor responda antes de emitir la siguiente solicitud; por lo tanto, el backpressure (rechazos 429 rápidos) permite mantener una alta tasa de rotación sin agotar memoria.  
> En el **modelo abierto (Vegeta)**, las peticiones llegan inexorablemente cada 20 ms. Con 1 sola réplica, la capacidad de servicio se satura y se disparan los rechazos controlados. Al escalar a **5 réplicas** (`make up-5replicas`), la tasa de éxito efectiva escala drásticamente superando con amplio margen el 66.53%.

---

## 8. Tabla de Variables de Entorno (Factor III)

La configuración del sistema se gobierna en su totalidad a través de variables de entorno inyectadas en tiempo de despliegue:

| Variable | Tipo | Default | Servicio | Descripción y Efecto |
| :--- | :---: | :---: | :---: | :--- |
| `PUBLIC_PORT` | int | `80` | `proxy` | Puerto TCP del host donde Traefik v3 escucha solicitudes entrantes. |
| `INTERNAL_PING_PORT` | int | `8082` | `proxy` | Puerto interno exclusivo para el endpoint `/ping` de Traefik. |
| `EXTRACTOR_HOST` | string | `extractor` | `proxy` | Nombre de servicio/DNS interno del contenedor extractor. |
| `EXTRACTOR_PORT` | int | `8000` | `proxy` | Puerto TCP interno del microservicio extractor. |
| `DOCUMENTS_HOST` | string | `documents` | `proxy` | Nombre de servicio/DNS interno del contenedor documents. |
| `DOCUMENTS_PORT` | int | `8001` | `proxy` | Puerto TCP interno del microservicio documents. |
| `MAX_REQUEST_BODY_BYTES` | int | `57671680` | `proxy` | Límite máximo de payload aceptado por Traefik (55 MiB en bytes). Peticiones mayores reciben HTTP 413. |
| `MEM_REQUEST_BODY_BYTES` | int | `2097152` | `proxy` | Límite en RAM (2 MiB) antes de que Traefik vuelque el buffer del body a disco temporal para evitar OOM. |
| `PROXY_READ_TIMEOUT` | string | `35s` | `proxy` | Timeout de lectura de respuesta del upstream (mayor a los 30s del extractor). |
| `PROXY_CONNECT_TIMEOUT` | string | `5s` | `proxy` | Timeout para establecer handshake TCP con los microservicios. |
| `PROXY_SEND_TIMEOUT` | string | `35s` | `proxy` | Timeout para enviar el cuerpo de la petición hacia el upstream. |
| `PROXY_GRACE_TIMEOUT` | string | `30s` | `proxy` | Período de gracia ante SIGTERM para drenar conexiones activas. |
| `TRAEFIK_LOG_LEVEL` | string | `WARN` | `proxy` | Verbosidad de logs de Traefik (`DEBUG`, `INFO`, `WARN`, `ERROR`). |
| `PORT` | int | `8000` | `extractor` | Puerto HTTP donde corre el servidor ASGI (Uvicorn) del extractor. |
| `EXTRACTION_WORKERS` | int | `1` | `extractor` | Cantidad de procesos/hilos concurrentes de extracción PDF por réplica. |
| `EXTRACTION_QUEUE_SIZE` | int | `1` | `extractor` | Capacidad máxima de la cola interna de espera antes de aplicar backpressure. |
| `QUEUE_WAIT_TIMEOUT_SECONDS`| float | `0` | `extractor` | Segundos de espera en cola antes de retornar 429 Too Many Requests (0 = rechazo inmediato si la cola está llena). |
| `EXTRACTION_TIMEOUT_SECONDS`| int | `30` | `extractor` | Tiempo límite por operación de parsing antes de cancelar con timeout. |
| `MAX_PDF_SIZE_MB` | int | `50` | `extractor` | Tamaño máximo en MB permitido para los archivos PDF. |
| `MONGODB_URL` | string | `mongodb://mongodb:27017` | `documents` | Cadena de conexión hacia el clúster interno de MongoDB. |
| `MONGODB_DB_NAME` | string | `pdftrack` | `documents` | Nombre de la base de datos documental. |
| `MONGODB_COLLECTION_NAME`| string | `documents` | `documents` | Nombre de la colección BSON de almacenamiento. |
| `DEFAULT_PAGE_LIMIT` | int | `20` | `documents` | Cantidad por defecto de documentos devueltos en peticiones paginadas. |
| `MAX_PAGE_LIMIT` | int | `100` | `documents` | Límite máximo configurable para paginado. |
| `MONGO_INITDB_DATABASE` | string | `pdftrack` | `mongodb` | Base de datos inicial creada automáticamente al inicializar Mongo. |
| `LOG_LEVEL` | string | `INFO` | Todos | Nivel de logging estándar de la aplicación. |

---

## 9. Cumplimiento de los Principios The Twelve-Factor App

| Principio | Cumplimiento en `pdftrack-deploy` |
| :--- | :--- |
| **I. Un código base con seguimiento de versiones** | Este repositorio gestiona exclusivamente infraestructura declarativa como código (IaC), orquestación y testing de integración sin contener lógica de negocio de las aplicaciones. |
| **III. Configuraciones en el entorno** | Toda la parametrización de red, timeouts, límites y backpressure se inyecta desde `.env.example`. El archivo `.env` está estrictamente ignorado en `.gitignore`. |
| **V. Separación de fases: Construcción, Publicación, Ejecución** | El archivo base `docker-compose.yml` opera únicamente en fase de ejecución consumiendo imágenes ya publicadas. La fase de compilación local está desacoplada en el override explícito `docker-compose.build.yml`. |
| **VII. Asignación de puertos** | Cada microservicio expone su propio puerto internamente mediante variables (`PORT`, `DOCUMENTS_PORT`). El proxy Traefik unifica la entrada en el puerto 80. |
| **VIII. Concurrencia** | El microservicio `extractor` es completamente stateless y puede escalarse horizontalmente (`docker-compose.5-replicas.yml`) sin fricción de estado. |
| **IX. Desechabilidad (Disposability)** | Inicio rápido y apagado elegante gestionado mediante directivas `stop_grace_period` (35s en extractor/proxy, 15s en documents) permitiendo drenar conexiones activas ante `SIGTERM`. |
| **X. Paridad en desarrollo y producción** | Se utiliza exactamente la misma definición de servicios y redes en desarrollo y producción; solo varía la fuente de la imagen (build local vs. imagen publicada). |
| **XII. Procesos de administración** | Las tareas de benchmark y diagnóstico (`k6_spike.js`, `run_vegeta.sh`, `make health`) son herramientas versionadas y ejecutadas en entornos homogéneos vía contenedores oficiales. |

---

## 10. Restricciones de Hardware y Límites de Recursos

Para garantizar previsibilidad y reproducibilidad durante los benchmarks, se aplican límites de CPU y memoria (`deploy.resources.limits`) estrictamente auditados:

```
┌──────────────┬─────────────┬──────────────┬────────────────────────┐
│ Servicio     │ Límite CPU  │ Límite RAM   │ stop_grace_period      │
├──────────────┼─────────────┼──────────────┼────────────────────────┤
│ proxy        │ 0.25 CPU    │ 128 MiB      │ 35 segundos            │
│ extractor    │ 1.00 CPU    │ 768 MiB      │ 35 segundos (x réplica)│
│ documents    │ 0.50 CPU    │ 512 MiB      │ 15 segundos            │
│ mongodb      │ 0.50 CPU    │ 256 MiB      │ N/A (Docker default)   │
└──────────────┴─────────────┴──────────────┴────────────────────────┘

Consumo Global con 1 Réplica:   2.25 CPUs  |  1.664 GiB RAM
Consumo Global con 5 Réplicas:  6.25 CPUs  |  5.504 GiB RAM
```

---

## 11. Guía Paso a Paso: Flujo de Ejecución y Benchmarking

Siga exactamente esta secuencia para validar el entorno completo desde cero:

### Paso 1: Clonar los 4 repositorios hermanos y verificar la estructura
```bash
# Directorio raíz que contendrá los 4 proyectos
mkdir -p pdftrack-workspace && cd pdftrack-workspace

git clone https://github.com/Nacho-Acuna1/pdftrack-proxy.git
git clone https://github.com/Nacho-Acuna1/pdftrack-extractor.git
git clone https://github.com/Nacho-Acuna1/pdftrack-documents.git
git clone https://github.com/Nacho-Acuna1/pdftrack-deploy.git

# Verificar que los directorios están al mismo nivel
ls -la
# Salida esperada:
# pdftrack-proxy/
# pdftrack-extractor/
# pdftrack-documents/
# pdftrack-deploy/
```

### Paso 2: Primera ejecución completa
```bash
cd pdftrack-deploy

# Crear archivo de variables de entorno desde la plantilla oficial
cp .env.example .env

# Levantar el sistema en modo desarrollo (construye imágenes locales)
make up
```

### Paso 3: Verificar que el sistema está Healthy
```bash
make health
```
*Salida esperada:*
```text
==> Verificando salud del sistema a través del proxy inverso (puerto 80)...
  [Extractor /health/live]: HTTP 200 (OK)
  [Documents /api/health/live]: HTTP 200 (OK)
>> Sistema en estado HEALTHY y listo para recibir tráfico.
```

### Paso 4: Ejecutar el benchmark completo (1 réplica)
```bash
make stress-all
```
Esto ejecutará la prueba spike con k6 y posteriormente la prueba de carga continua con Vegeta, guardando los resultados en `tests/stress/results/`.

### Paso 5: Escalar a 5 réplicas y repetir el benchmark
```bash
# Escalar el extractor a 5 réplicas
make up-5replicas

# Verificar que los 5 contenedores del extractor están UP y saludables
make ps

# Re-ejecutar el benchmark completo
make stress-all
```

Al comparar los reportes generados en `tests/stress/results/`, observará el salto de rendimiento: la tasa de éxito de Vegeta pasará del baseline a valores cercanos al 100%, y el throughput de k6 superará ampliamente la meta de 25.35 req/s sin un solo fallo inesperado.
