# ==============================================================================
# PDFtrack - Makefile de Gestión de Infraestructura y Despliegue
# ==============================================================================
# Automatiza el ciclo de vida completo de los contenedores, healthchecks,
# escalamiento y ejecución de pruebas de estrés (Twelve-Factor XII).
# ==============================================================================

.DEFAULT_GOAL := help

# Cargar variables de entorno desde .env si existe
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

PUBLIC_PORT ?= 80

# Comandos base de Compose (Docker Compose v2)
COMPOSE_BASE := docker compose -f docker-compose.yml
COMPOSE_DEV  := $(COMPOSE_BASE) -f docker-compose.build.yml
COMPOSE_PROD := $(COMPOSE_BASE)
COMPOSE_5R   := $(COMPOSE_BASE) -f docker-compose.5-replicas.yml

.PHONY: help build up up-prod up-5replicas down down-clean logs logs-extractor logs-documents ps health stress-k6 stress-vegeta stress-all clean

help: ## Lista todos los targets disponibles con su descripción
	@echo "=============================================================================="
	@echo " PDFtrack - Comandos de Despliegue y Orquestación"
	@echo "=============================================================================="
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo "=============================================================================="

build: ## Buildea todas las imágenes localmente desde repositorios hermanos
	@echo "==> Compilando imágenes Docker locales (modo dev)..."
	$(COMPOSE_DEV) build

up: ## Levanta el sistema completo en modo dev (build local, 1 réplica)
	@echo "==> Levantando PDFtrack en modo desarrollo (build local, 1 réplica)..."
	$(COMPOSE_DEV) up -d --build

up-prod: ## Levanta el sistema usando imágenes publicadas (modo producción)
	@echo "==> Levantando PDFtrack en modo producción (imágenes publicadas)..."
	$(COMPOSE_PROD) up -d

up-5replicas: ## Levanta el sistema con 5 réplicas del extractor (build local)
	@echo "==> Levantando PDFtrack con 5 réplicas del extractor..."
	$(COMPOSE_DEV) -f docker-compose.5-replicas.yml up -d --build

down: ## Baja todos los servicios preservando volúmenes de datos
	@echo "==> Deteniendo y eliminando contenedores (preservando volúmenes)..."
	$(COMPOSE_BASE) down

down-clean: ## Baja todos los servicios y elimina volúmenes de datos e imágenes
	@echo "==> Deteniendo contenedores, eliminando redes, volúmenes e imágenes..."
	$(COMPOSE_BASE) down -v --rmi all --remove-orphans

logs: ## Muestra logs de todos los servicios en tiempo real
	$(COMPOSE_BASE) logs -f

logs-extractor: ## Muestra logs en tiempo real solo del servicio extractor
	$(COMPOSE_BASE) logs -f extractor

logs-documents: ## Muestra logs en tiempo real solo del servicio documents
	$(COMPOSE_BASE) logs -f documents

ps: ## Muestra el estado y healthcheck de todos los contenedores
	$(COMPOSE_BASE) ps

health: ## Ejecuta pruebas de salud contra /health/live y /api/health/live
	@echo "==> Verificando salud del sistema a través del proxy inverso (puerto $(PUBLIC_PORT))..."
	@echo -n "  [Extractor /health/live]: "
	@curl -s -f -w "HTTP %{http_code} (OK)\n" http://localhost:$(PUBLIC_PORT)/health/live || (echo "FALLÓ" && exit 1)
	@echo -n "  [Documents /api/health/live]: "
	@curl -s -f -w "HTTP %{http_code} (OK)\n" http://localhost:$(PUBLIC_PORT)/api/health/live || (echo "FALLÓ" && exit 1)
	@echo ">> Sistema en estado HEALTHY y listo para recibir tráfico."

stress-k6: ## Ejecuta el test spike de k6 contra http://localhost:${PUBLIC_PORT}
	@echo "==> Iniciando prueba de estrés k6 (spike test modelo cerrado)..."
	@mkdir -p tests/stress/results
	@if command -v k6 >/dev/null 2>&1; then \
		TARGET_URL="http://localhost:$(PUBLIC_PORT)/extract" PDF_DIR="./tests/stress/pdfs" k6 run tests/stress/k6_spike.js; \
	else \
		docker run --rm -i --network host \
			-v "$$(pwd):/workspace" \
			-w /workspace \
			-e TARGET_URL="http://localhost:$(PUBLIC_PORT)/extract" \
			-e PDF_DIR="./tests/stress/pdfs" \
			grafana/k6 run tests/stress/k6_spike.js; \
	fi

stress-vegeta: ## Ejecuta el test de carga fija de 50 req/s con Vegeta
	@echo "==> Iniciando prueba de carga constante con Vegeta (modelo abierto)..."
	@mkdir -p tests/stress/results
	@chmod +x ./tests/stress/run_vegeta.sh 2>/dev/null || true
	@PUBLIC_PORT=$(PUBLIC_PORT) ./tests/stress/run_vegeta.sh

stress-all: stress-k6 stress-vegeta ## Ejecuta k6 y luego Vegeta secuencialmente
	@echo "==> Benchmark completo finalizado con éxito."

clean: ## Elimina imágenes locales de pdftrack y dangling
	@echo "==> Limpiando imágenes locales de pdftrack..."
	@docker rmi -f $$(docker images 'pdftrack-*' -q) 2>/dev/null || true
	@docker image prune -f
