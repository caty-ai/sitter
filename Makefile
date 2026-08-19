.PHONY: test lint

test:
	bash tests/run.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		echo "Running shellcheck (blocking, #17/B6)..."; \
		shellcheck sitter tests/*.sh tests/fixtures/*.sh scripts/*.sh examples/*.sh; \
	else \
		echo "shellcheck not installed; skipping lint"; exit 0; \
	fi
