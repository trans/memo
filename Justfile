# IPCK - Intelligent Project Construction Kit

# Default task
default: check

# Install dependencies
install:
  shards install

# Update dependencies
update:
  shards update

# Check syntax (fast, no codegen)
check:
  crystal build --no-codegen src/ipck.cr

# Build the binary
build:
  crystal build src/cli.cr -o bin/ipck

# Build release binary
release:
  crystal build --release src/cli.cr -o bin/ipck

# Run the REPL
run:
  crystal run src/cli.cr

# Run all tests
test:
  crystal spec

# Run specific test file
test-file FILE:
  crystal spec {{FILE}}

# Run tests with verbose output
test-verbose:
  crystal spec --verbose

# Generate API documentation
doc: doc-api

doc-api:
  crystal docs -o docs/api

# Open docs in browser
doc-open: doc
  xdg-open docs/api/index.html 2>/dev/null || open docs/api/index.html

# Format code
fmt:
  crystal tool format src spec

# Format check (no changes)
fmt-check:
  crystal tool format --check src spec

# Clean build artifacts
clean:
  rm -rf docs/api lib .crystal .shards bin/ipck

# Full rebuild
rebuild: clean install check

# Watch for changes and run check (requires entr)
watch:
  find src -name '*.cr' | entr -c just check

# Watch and run tests (requires entr)
watch-test:
  find src spec -name '*.cr' | entr -c just test

# Show lines of code
loc:
  @find src -name '*.cr' | xargs wc -l | tail -1

# List all tasks
list:
  @just --list
