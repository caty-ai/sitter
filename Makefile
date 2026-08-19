.PHONY: test lint

test:
	bash tests/run.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "Running shellcheck (non-blocking; blocking enforcement arrives with #17/B6)..."; \
		shellcheck sitter tests/*.sh tests/fixtures/*.sh scripts/*.sh examples/*.sh || true; \
		echo "shellcheck run complete (non-blocking; blocking enforcement arrives with #17/B6)"; \
	else \
		echo "shellcheck not installed; skipping lint (non-blocking; blocking enforcement arrives with #17/B6)"; \
	fi
