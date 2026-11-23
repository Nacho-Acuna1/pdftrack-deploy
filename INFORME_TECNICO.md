# Informe Técnico — PDFtrack

## 1. Arquitectura de la solución

PDFtrack implementa una arquitectura de microservicios distribuidos
en 4 repositorios independientes, cada uno con su propio ciclo de vida,
dependencias y Dockerfile:

```
Cliente HTTP
│
▼
Traefik v3 (pdftrack-proxy)
├── /extract ──► pdftrack-extractor (1-5 réplicas)
└── /api/* ──► pdftrack-documents
                 │
                 ▼
              MongoDB 7.0
```

### Repositorios
| Repositorio | Rol | Puerto interno |
|---|---|---|
| pdftrack-proxy | Reverse proxy y balanceador | 80 |
| pdftrack-extractor | Extracción PDF→Markdown | 8000 |
| pdftrack-documents | CRUD documental + MongoDB | 8001 |
| pdftrack-deploy | Orquestación e infraestructura | — |

## 2. Decisiones de diseño

### Separación en repositorios independientes (Factor I)
Cada microservicio vive en su propio repositorio con su propio
`pyproject.toml`, `uv.lock` y `Dockerfile`. Esto cumple estrictamente
con el Factor I de Twelve-Factor App y permite ciclos de vida,
versionado y despliegue independientes.

### Zero-Copy IPC con SharedMemory
El extractor usa `multiprocessing.shared_memory` para pasar los bytes
del PDF al worker sin serialización pickle. Esto elimina la duplicación
de buffers en RAM y los picos de CPU por serialización bajo alta
concurrencia.

### Backpressure determinista
`asyncio.Semaphore(EXTRACTION_WORKERS + EXTRACTION_QUEUE_SIZE)` limita
la concurrencia máxima por réplica. Las requests que superan la capacidad
reciben 503 inmediato sin acumularse en cola.

### Traefik v3 sin buffering en /extract
El middleware de buffering de Traefik fue deshabilitado específicamente
para la ruta `/extract`. Traefik reenvía el stream binario del PDF
directamente al upstream sin volcarlo a memoria ni a disco, eliminando
el cuello de botella de CPU bajo alta concurrencia.

### MongoDB como Backing Service (Factor IV)
El extractor es 100% stateless y no tiene dependencias de MongoDB.
Documents consume MongoDB via `MONGODB_URL` como recurso anexo
adosable, cumpliendo Factor IV.

## 3. Análisis de cuellos de botella identificados

### Cuello de botella 1 — Buffering de Traefik (crítico)
**Problema:** Traefik con `memRequestBodyBytes=2MB` volcaba PDFs de
hasta 8.9MB a disco bajo la restricción de 0.25 CPU. El CPU throttling
superó el 94%, bloqueando los goroutines de I/O y colapsando el sistema
antes de que las requests llegaran al extractor.

**Síntoma:** 1.78 req/s con 100% timeouts en Vegeta.

**Solución:** Deshabilitar el middleware de buffering en `/extract` y
aumentar CPU de Traefik a 0.50.

**Resultado:** 50.21 req/s en k6 (+98% sobre referencia de cátedra).

### Cuello de botella 2 — Serialización IPC (resuelto en diseño)
**Problema:** Enviar PDFs de 8.9MB al worker via pickle duplicaba ~18MB
en RAM por request y disparaba el garbage collector.

**Solución:** Zero-Copy con `multiprocessing.shared_memory`.

## 4. Comparativa de métricas antes y después

### Test Spike k6 (Modelo Cerrado — 100 VUs, 40s)

| Métrica | Referencia cátedra | Antes corrección | Después corrección |
|---|---|---|---|
| Throughput | 25.35 req/s | 1.78 req/s | 50.21 req/s |
| Tasa de error | 0% | 67.61% | 0.00% |
| Latencia p95 | 8.80 s | 30.00 s | 3.42 s |
| Latencia p50 | 1.88 s | 30.00 s | 1.12 s |
| Peticiones totales | 1037 | 71 | 2008 |

### Test Carga Fija Vegeta (Modelo Abierto — 50 req/s, 30s)

| Métrica | Referencia cátedra | Antes corrección | Después corrección |
|---|---|---|---|
| Throughput efectivo | 16.65 req/s | 0.00 req/s | 49.85 req/s |
| Tasa de éxito | 66.53% | 0.00% | 100.00% |
| Timeouts | 33.40% | 100% | 0.00% |
| Latencia p50 | 14.89 s | 30.00 s | 0.18 s |

## 5. Implementación de Twelve-Factor App

| Factor | Implementación |
|---|---|
| I. Base de código | Un repositorio por servicio. 4 repos independientes |
| II. Dependencias | `pyproject.toml` + `uv.lock` por servicio |
| III. Configuración | Variables de entorno via `pydantic-settings` y `envsubst` |
| IV. Backing services | MongoDB via `MONGODB_URL`, extractor sin dependencias de BD |
| V. Build/Release/Run | Dockerfile multi-stage, `docker-compose.build.yml` separado |
| VI. Procesos | Stateless. Sin archivos temporales ni estado compartido |
| VII. Port binding | `entrypoint.py` lee `PORT` del entorno en ambos servicios |
| VIII. Concurrencia | 1-5 réplicas del extractor, ProcessPool interno |
| IX. Desechabilidad | `stop_grace_period: 35s`, shutdown limpio del ProcessPool |
| X. Paridad dev/prod | Mismo compose, distintos valores de variables |
| XI. Logs | JSON estructurado a stdout en todos los servicios |
| XII. Administración | Scripts de stress versionados en `pdftrack-deploy` |

## 6. Topología de contenedores y recursos

| Contenedor | Rol | CPU | RAM | Réplicas |
|---|---|---|---|---|
| proxy | Traefik v3 | 0.50 | 128 MB | 1 |
| extractor | Extracción PDF | 1.0 | 768 MB | 1-5 |
| documents | CRUD MongoDB | 0.5 | 512 MB | 1 |
| mongodb | Base de datos | 0.5 | 256 MB | 1 |

## 7. Proceso de investigación y optimización

1. Análisis del monorepo original: identificación de violaciones de
   Factor I y II, dependencias mezcladas y acoplamiento duro a MongoDB.
2. Separación en 4 repositorios independientes con dependencias propias.
3. Implementación de Zero-Copy IPC con SharedMemory en el extractor.
4. Implementación de backpressure determinista con asyncio.Semaphore.
5. Ejecución de tests de estrés iniciales: resultados catastróficos
   (1.78 req/s, 100% timeouts).
6. Diagnóstico: cuello de botella en Traefik volcando PDFs a disco
   bajo restricción de 0.25 CPU.
7. Corrección: deshabilitar buffering en /extract + aumentar CPU a 0.50.
8. Resultado final: 50.21 req/s (+98% sobre cátedra), 0% timeouts.
