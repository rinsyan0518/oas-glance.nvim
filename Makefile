RUN := scripts/docker-run.sh

.PHONY: image clean-image test test-file update-screenshots lint format format-check typecheck doc doc-check check try

image clean-image test update-screenshots lint format format-check typecheck doc doc-check check:
	@$(RUN) $@

export FILE

test-file:
	@$(RUN) test-file "$$FILE"

try:
	@$(RUN) try "$$FILE"
