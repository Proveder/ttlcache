.PHONY: test
test:
	@echo "executing unit-tests"
	go test -cover -race ./...

# Go files tracked by git, expanded lazily by the shell (gopls check needs explicit
# paths — it does not accept ./...). The xargs filter drops tracked-but-deleted
# files, which git ls-files still reports and gopls errors on. Falls back to
# find outside a git checkout.
#
# examples/ is excluded on purpose: examples/httpcache and examples/dbcache are
# each their own Go module (pinned to the upstream jellydator/ttlcache), so
# `go vet ./...` and `staticcheck ./...` already skip them. Feeding them to gopls
# would make the three stages disagree about what "the code" is, and would need
# a per-module dependency download in CI.
GO_FILES = $$( { git ls-files '*.go' 2>/dev/null | xargs -I{} sh -c '[ -f "{}" ] && echo "{}"' || find . -name '*.go' -not -path './vendor/*'; } | sed 's|^\./||' | grep -v '^examples/' )

# gopls' new(expr) modernizer (Go 1.26) fires on every single-arg helper that
# returns &param. Nothing in this module matches today, and this module stays on
# go 1.25 so the Go 1.26 modernizers do not fire here at all; the pattern is kept
# for parity with the other Go repos.
# Delete these two patterns to see the suggestions again.
GOPLS_EXCLUDE = 'can be simplified to new\(x\)|inlinable wrapper around new\(expr\)'

.PHONY: lint
lint: ## Static analysis: correctness (vet), simplifications (staticcheck), modernizations (gopls)
	@# Every stage runs even if an earlier one reports, so a single invocation shows
	@# the full picture; rc accumulates and the target fails at the end.
	@# Preflight: gopls pins GOTOOLCHAIN=local, so the *installed* go must satisfy
	@# go.work/go.mod on its own — GOTOOLCHAIN=auto silently rescues vet/staticcheck
	@# by downloading a newer toolchain, but gopls then fails with a buried version
	@# error. Surface it up front, with the remedy.
	@if ! chk="$$(GOTOOLCHAIN=local go list -m 2>&1 >/dev/null)"; then \
		echo "==> toolchain preflight failed:"; \
		printf '%s\n' "$$chk" | sed 's/^/  /'; \
		echo "  fix: update the installed Go (macOS: brew upgrade go), then re-run"; \
		exit 1; \
	fi
	@rc=0; \
	echo "==> go vet (correctness)"; \
	go vet ./... || rc=1; \
	echo "==> staticcheck (simplifications)"; \
	if command -v staticcheck >/dev/null 2>&1; then \
		staticcheck ./... || rc=1; \
	else \
		echo "  skipped: go install honnef.co/go/tools/cmd/staticcheck@latest"; rc=1; \
	fi; \
	echo "==> gopls (modernizations, unused params)"; \
	if command -v gopls >/dev/null 2>&1; then \
		if ! raw="$$(gopls check -severity=hint $(GO_FILES) 2>&1)"; then \
			echo "  gopls failed to run:"; echo "$$raw"; rc=1; \
		fi; \
		out="$$(printf '%s\n' "$$raw" | grep -Ev $(GOPLS_EXCLUDE) || true)"; \
		if [ -n "$$out" ]; then echo "$$out"; rc=1; fi; \
	else \
		echo "  skipped: go install golang.org/x/tools/gopls@latest"; rc=1; \
	fi; \
	if [ $$rc -eq 0 ]; then echo "lint: clean"; fi; \
	exit $$rc

.PHONY: audit
audit:
	@echo "go dependencies audit"
	go list -m all | nancy sleuth

.PHONY: audit-fix
audit-fix: ## Attempt to fix vulnerable dependencies automatically
	@echo "updating Go dependencies to latest patch versions"
	go get -u=patch ./...
	go mod tidy
	@echo "re-running dependency audit"
	go list -m all | nancy sleuth

.PHONY: test lint audit audit-fix
