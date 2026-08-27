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
	$(MAKE) --no-print-directory crap || rc=1; \
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

# CRAP (Change Risk Anti-Patterns) = cyclomatic complexity² penalized by
# missing test coverage — ranks the functions most dangerous to change.
# The gate fails when any function scores ABOVE CRAP_THRESHOLD. Mocks
# packages are filtered out of the report entirely: test scaffolding
# carries zero coverage by design and would otherwise own its whole top.
# The threshold was set just above the repo's worst score when the gate
# was introduced — treat it as a RATCHET: lower it as the worst functions
# gain tests or shed complexity; never raise it.
CRAP_THRESHOLD ?= 15

.PHONY: crap
crap:
	@echo "==> crap4go (CRAP: complexity vs coverage, worst first; threshold $(CRAP_THRESHOLD))"; \
	out="$$(go run github.com/unclebob/crap4go/cmd/crap4go@latest)" || { printf '%s\n' "$$out"; exit 1; }; \
	report="$$(printf '%s\n' "$$out" | sed -n '/^CRAP Report/,$$p' | awk 'NR <= 4 || $$2 != "mocks"')"; \
	printf '%s\n' "$$report"; \
	if [ -n "$$GITHUB_STEP_SUMMARY" ]; then \
		{ echo '### CRAP report (threshold $(CRAP_THRESHOLD))'; echo '```'; printf '%s\n' "$$report"; echo '```'; } >> "$$GITHUB_STEP_SUMMARY"; \
	fi; \
	printf '%s\n' "$$report" | awk -v max=$(CRAP_THRESHOLD) ' \
		/^-+$$/ { in_r = 1; next } \
		in_r && NF >= 5 && ($$NF) + 0 > max { bad = 1; print "  over threshold: " $$0 } \
		END { exit bad }' \
	|| { echo "crap: FAILED (score above $(CRAP_THRESHOLD))"; exit 1; }; \
	echo "crap: clean"
