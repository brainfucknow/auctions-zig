# Code Coverage for auctions-zig

This project includes comprehensive test coverage across all auction types and serialization logic.

## Test Structure

The project has 6 test suites:

1. **Main/Domain Tests** (`src/main.zig`) - Core domain logic
2. **Persistence Tests** (`src/persistence_test.zig`) - Event persistence
3. **API Tests** (`src/api_test.zig`) - HTTP API endpoints
4. **Blind Auction State Tests** (`src/blind_auction_state_test.zig`) - Sealed bid auctions
5. **English Auction State Tests** (`src/english_auction_state_test.zig`) - Open ascending auctions
6. **Serialization Tests** (`src/english_auction_serialization_test.zig`) - JSON ser/de

## Running Tests

```bash
zig build test
```

## Code Coverage with kcov (Recommended)

Zig 0.15.2 doesn't have built-in code coverage, but you can use **kcov** for Linux:

### Install kcov

```bash
# Ubuntu/Debian
sudo apt-get install kcov

# Fedora
sudo dnf install kcov

# Arch
sudo pacman -S kcov
```

### Generate Coverage

```bash
# Run tests with kcov
kcov --exclude-pattern=/snap/,/usr/ coverage zig build test

# View HTML report
xdg-open coverage/index.html
```

## Code Coverage with LLVM Tools

Alternatively, use LLVM's coverage tools:

### 1. Build with coverage instrumentation

```bash
# Build tests with coverage flags
zig build test \
  -Doptimize=Debug \
  --summary all \
  -fprofile-arcs \
  -ftest-coverage
```

### 2. Generate coverage report

```bash
# Run tests to generate .gcda files
zig build test

# Generate report with lcov
lcov --capture --directory . --output-file coverage.info
genhtml coverage.info --output-directory coverage-html

# View report
xdg-open coverage-html/index.html
```

## Manual Coverage Analysis

You can also analyze test coverage manually:

### Source Files Coverage

All core source files have test coverage:

- ✅ `src/models.zig` - Tested via all test suites
- ✅ `src/domain.zig` - Domain tests + English/Blind auction tests
- ✅ `src/api.zig` - API tests
- ✅ `src/persistence.zig` - Persistence tests
- ✅ `src/jwt.zig` - API tests (JWT parsing)

### Feature Coverage

**English Auctions (Timed Ascending)**
- ✅ Bid validation (min raise, reserve price)
- ✅ State transitions (awaiting → ongoing → ended)
- ✅ Winner determination
- ✅ Time-based expiry
- ✅ Error handling (late bids, low bids, etc.)
- ✅ Serialization/deserialization

**Blind Auctions (Sealed Bid)**
- ✅ Hidden bids during ongoing phase
- ✅ Bid revelation on close
- ✅ Winner determination (highest bid)
- ✅ Multiple bids per user allowed
- ✅ State transitions
- ✅ Reserve price handling

**API Coverage**
- ✅ Auction creation
- ✅ Bid submission
- ✅ Auction listing
- ✅ Individual auction retrieval
- ✅ JWT authentication
- ✅ Error responses

**Persistence Coverage**
- ✅ Event serialization
- ✅ Event deserialization
- ✅ File I/O
- ✅ Event replay

## Test Count

Run `zig build test --summary all` to see detailed test counts:

- **Total:** 56+ tests
- **English Auction State:** 13 tests
- **Blind Auction State:** 5 tests
- **English Serialization:** 8 tests
- **API:** 8 tests
- **Persistence:** Tests for event storage/retrieval
- **Domain/Models:** Type and validation tests

## CI/CD Integration

For GitHub Actions or other CI:

```yaml
- name: Run tests with coverage
  run: |
    zig build test
    # Optional: Add kcov integration
    kcov --exclude-pattern=/snap/,/usr/ coverage zig build test

- name: Upload coverage
  uses: codecov/codecov-action@v3
  with:
    files: ./coverage/cobertura.xml
```

## Notes

- Zig 0.15.2 removed the built-in `code_coverage` flag that existed in earlier versions
- Future Zig versions may reintroduce first-class coverage support
- kcov provides the best Linux coverage experience currently
- Test coverage is comprehensive across all auction types and serialization formats
