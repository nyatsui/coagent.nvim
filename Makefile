.PHONY: test test-file deps clean

NVIM ?= nvim

# Run the whole suite (mock LLM only, no network access to Copilot).
test: deps
	$(NVIM) --headless --clean -u scripts/test.lua

# Run a single spec or directory: make test-file F=tests/controller_spec.lua
test-file: deps
	TEST_PATH=$(F) $(NVIM) --headless --clean -u scripts/test.lua

deps:
	@test -d .dependencies/plenary.nvim || git clone --depth=1 https://github.com/nvim-lua/plenary.nvim .dependencies/plenary.nvim
	@test -d .dependencies/CopilotChat.nvim || git clone --depth=1 https://github.com/CopilotC-Nvim/CopilotChat.nvim .dependencies/CopilotChat.nvim

clean:
	rm -rf .dependencies
