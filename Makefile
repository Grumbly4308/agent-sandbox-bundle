# The checks that need no container runtime. `./sandbox verify` on a real
# host is what tests the barriers themselves; docs/08-verification.md records it.

.PHONY: test lint

test:
	tests/run.sh

lint:
	tests/run.sh lint
