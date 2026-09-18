SHELL_FILES = bin/swapai lib/swapai.sh install.sh tests/test.sh tests/deployment.sh tests/fixtures/bin/*

.PHONY: test check shellcheck install

test:
	@set -e; \
	for interpreter in sh bash dash; do \
		if command -v "$$interpreter" >/dev/null 2>&1; then \
			printf 'Testing with %s\n' "$$interpreter"; \
			SWAPAI_TEST_SHELL="$$interpreter" "$$interpreter" ./tests/test.sh; \
		fi; \
	done

check:
	sh -n $(SHELL_FILES)
	sh tests/deployment.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		$(MAKE) shellcheck; \
	else \
		printf 'shellcheck not installed; syntax check completed\n'; \
	fi

shellcheck:
	shellcheck -x -P SCRIPTDIR $(SHELL_FILES)

install:
	./install.sh
