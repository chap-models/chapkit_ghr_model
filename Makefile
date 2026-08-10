.PHONY: help build run run-ghcr lint test-unit test-local test-api test-contract serve-test stop-test clean

IMAGE ?= chapkit-ghr-model:latest
GHCR_IMAGE ?= ghcr.io/chap-models/chapkit_ghr_model:latest
TEST_PORT ?= 8128
TEST_URL ?= http://localhost:$(TEST_PORT)

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build          Build docker image ($(IMAGE))"
	@echo "  run            Build and run the service on :8000"
	@echo "  run-ghcr       Pull and run the prebuilt GHCR image on :8000"
	@echo "  test-unit      Unit checks for the pure helpers in scripts/lib.R"
	@echo "  test-local     Run train.R + predict.R directly against example_data"
	@echo "  serve-test     Start a detached test service on :$(TEST_PORT)"
	@echo "  test-contract  chapkit's own end-to-end contract test (synthetic data)"
	@echo "  test-api       Train + predict as real jobs over the API, real geo data"
	@echo "  stop-test      Stop the detached test service"
	@echo "  lint           Run ruff format check + lint"
	@echo "  clean          Remove local image and test outputs"

build:
	@echo ">>> Building $(IMAGE)"
	@docker build --platform linux/amd64 -t $(IMAGE) .

run: build
	@echo ">>> Running $(IMAGE) on :8000"
	@docker run --rm --platform linux/amd64 -p 8000:8000 --name chapkit-ghr-model $(IMAGE)

run-ghcr:
	@echo ">>> Running $(GHCR_IMAGE) on :8000"
	@docker run --rm --pull always --platform linux/amd64 -p 8000:8000 --name chapkit-ghr-model $(GHCR_IMAGE)

test-unit: build
	@echo ">>> Unit checks for scripts/lib.R"
	@docker run --rm --platform linux/amd64 -v $(PWD):/work $(IMAGE) Rscript tools/test_lib.R

# Exercises the scripts through the same contract chapkit uses (config.yml in
# the working directory, CSV in, CSV out) without starting the service. Runs from
# a writable workspace copy the way the real service does, because /work is
# root-owned and the service runs as the non-root 'app' user -- it cannot write
# config.yml or model.rds into /work.
test-local: build
	@echo ">>> Running train + predict against example_data"
	@docker run --rm --platform linux/amd64 \
		-v $(PWD)/example_data:/work/example_data:ro \
		-v $(PWD)/test_out:/work/test_out \
		$(IMAGE) bash -c "\
			w=\$$(mktemp -d) && cp -r scripts \$$w/scripts && \
			cp example_data/config.yml \$$w/config.yml && cd \$$w && \
			Rscript scripts/train.R --data /work/example_data/training_data.csv --geo /work/example_data/geo.json && \
			Rscript scripts/predict.R \
				--historic /work/example_data/training_data.csv \
				--future /work/example_data/future_data.csv \
				--geo /work/example_data/geo.json \
				--output /work/test_out/predictions.csv"

# Detached service the two API-level test targets run against.
serve-test: build
	@docker rm -f chapkit-ghr-model-test >/dev/null 2>&1 || true
	@docker run -d --platform linux/amd64 -p $(TEST_PORT):8000 \
		--add-host host.docker.internal:host-gateway \
		--name chapkit-ghr-model-test $(IMAGE) >/dev/null
	@echo ">>> Waiting for $(TEST_URL)/health"
	@for i in $$(seq 1 40); do \
		if curl -fsS $(TEST_URL)/health >/dev/null 2>&1; then echo "    healthy"; exit 0; fi; \
		sleep 3; \
	done; echo "    service did not become healthy"; exit 1

# chapkit's own contract test. Drives config/train/predict with synthetic data
# and verifies the prediction shape. Runs without geo, which also exercises the
# no-geometry fallback (spatial random effect disabled).
test-contract: serve-test
	@docker run --rm --platform linux/amd64 --add-host host.docker.internal:host-gateway \
		--entrypoint chapkit $(IMAGE) test \
		--url http://host.docker.internal:$(TEST_PORT) \
		--rows 400 --predict-rows 200 --timeout 1200 --verbose
	@$(MAKE) stop-test

# Real train + predict jobs over the API using the dengue_MS fixture and its
# geometry, so the spatial effect is actually exercised.
test-api: serve-test
	@python3 tools/api_smoke.py $(TEST_URL)
	@$(MAKE) stop-test

stop-test:
	@docker rm -f chapkit-ghr-model-test >/dev/null 2>&1 || true

lint:
	@echo ">>> Ruff format check"
	@uv run ruff format --check .
	@echo ">>> Ruff lint"
	@uv run ruff check .

clean:
	@docker rmi -f $(IMAGE) 2>/dev/null || true
	@rm -rf test_out

.DEFAULT_GOAL := help
