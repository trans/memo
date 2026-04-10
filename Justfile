# MEMO - Memory for Agents and Humans

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
  crystal build --no-codegen src/memo.cr

# Build the binary
build:
  crystal build bin/memo.cr -o bin/memo

# Build the Arcana bus service
build-arcana:
  crystal build bin/memo-arcana.cr -o bin/memo-arcana

# Build release binary
release:
  crystal build --release bin/memo.cr -o bin/memo

# Build release Arcana bus service
release-arcana:
  crystal build --release bin/memo-arcana.cr -o bin/memo-arcana

# Run the REPL
run:
  crystal run bin/memo.cr

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

# Bump version: just bump 0.10.0
bump VERSION:
  sed -i 's/^version: .*/version: {{VERSION}}/' shard.yml
  sed -i 's/VERSION = ".*"/VERSION = "{{VERSION}}"/' src/memo.cr
  sed -i 's/^pkgver=.*/pkgver={{VERSION}}/' pkg/PKGBUILD
  sed -i '1s/([^)]*)/({{VERSION}}-1)/' pkg/debian/changelog
  @echo "Bumped to {{VERSION}}"
  @grep 'version:' shard.yml | head -1
  @grep 'VERSION' src/memo.cr

# List all tasks
list:
  @just --list
