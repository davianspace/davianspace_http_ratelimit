# Contributing to davianspace_http_ratelimit

Thank you for your interest in contributing! This document provides guidelines
and instructions for contributing to this project.

---

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Coding Standards](#coding-standards)
- [Testing Requirements](#testing-requirements)
- [Pull Request Process](#pull-request-process)
- [Commit Convention](#commit-convention)
- [Architecture Guidelines](#architecture-guidelines)
- [Adding a New Algorithm](#adding-a-new-algorithm)
- [Documentation](#documentation)
- [Reporting Issues](#reporting-issues)

---

## Code of Conduct

This project follows the [Contributor Covenant](https://www.contributor-covenant.org/)
code of conduct. By participating, you are expected to uphold this code.
Please report unacceptable behaviour to the maintainers.

---

## Getting Started

1. Fork the repository on GitHub.
2. Clone your fork locally.
3. Create a feature branch from `master`.
4. Make your changes following the guidelines below.
5. Run the full quality gate before pushing.
6. Open a pull request against `master`.

---

## Development Setup

### Prerequisites

- **Dart SDK** `>=3.0.0 <4.0.0`
- Git

### Setup

```bash
git clone https://github.com/<your-fork>/davianspace_http_ratelimit.git
cd davianspace_http_ratelimit
dart pub get
```

### Quality Gate

Run all checks before every commit:

```bash
# Static analysis (zero issues required)
dart analyze --fatal-infos

# Full test suite (all tests must pass)
dart test

# Format check
dart format --set-exit-if-changed .
```

All three commands must pass with zero errors before a PR will be reviewed.

---

## Coding Standards

### Language & Analysis

- **Strict mode enabled**: `strict-casts`, `strict-inference`, `strict-raw-types`
  via `analysis_options.yaml`. All code must compile cleanly under these settings.
- Use `final class` for concrete public types (no accidental subclassing of
  limiters or policy objects).
- Prefer `dart:async` primitives (`Completer`, `Timer`) over `Future.delayed`
  in limiter implementations.
- Never swallow errors silently; reject pending waiters with typed exceptions
  on `dispose()` or timeout.

### Naming

| Concept | Pattern | Example |
|---------|---------|---------|
| Limiter implementations | `<Algorithm>RateLimiter` | `TokenBucketRateLimiter` |
| Key extractors | `<Strategy>KeyExtractor` | `IpKeyExtractor` |
| Exceptions | `<Kind>Exception` | `RateLimitExceededException` |
| Repository interfaces | `<Entity>Repository` | `RateLimiterRepository` |
| Internal helpers | `_CamelCase` | `_Waiter` |

### Code Layout

Each public class must have:

1. A documentation comment explaining the algorithm/concept and its
   characteristics (property table for limiters, example usage).
2. An `@override` annotation on every overridden member.
3. A `// ─── Section ───` horizontal rule separating logical groups
   (constructor, public API, internal helpers).

### FIFO Fairness Invariant

All blocking `acquire()` implementations maintain a **FIFO waiter queue**.
`tryAcquire()` **must** return `false` whenever the waiter queue is non-empty.
This prevents non-blocking callers from stealing permits at the expense of
waiting callers. See `TokenBucketRateLimiter` and `LeakyBucketRateLimiter`
for reference implementations.

---

## Testing Requirements

### Coverage Expectations

Every limiter class must have tests covering:

| Category | Required tests |
|----------|----------------|
| Construction | Defaults, bounds, `AssertionError` on invalid args |
| `tryAcquire` | Success, rejection, FIFO fairness guard, post-dispose `StateError` |
| `acquire` immediate | Resolves synchronously when permits available |
| `acquire` blocking | Resolves asynchronously after refill/release |
| `acquire` timeout | `RateLimitExceededException` on expiry |
| Statistics | Counters, `queueDepth` |
| Dispose | Idempotent, pending waiters receive `StateError` |

### Fake Async

Use `package:fake_async` for any test that would otherwise require real
wall-clock delays. Real-time delays make the suite fragile and slow.

### Test File Location

```
test/
  limiters/     ← one file per limiter (e.g., token_bucket_rate_limiter_test.dart)
  handler/      ← http_rate_limit_handler_test.dart
  server/       ← server_rate_limiter_test.dart, rate_limit_key_extractor_test.dart
  backend/      ← in_memory_rate_limiter_repository_test.dart (if added)
```

---

## Pull Request Process

1. **One concern per PR** — keep changes focused (bug fix, new feature, docs).
2. Include tests for any new behaviour.
3. Update `CHANGELOG.md` under `[Unreleased]` following Keep a Changelog format.
4. Ensure the full quality gate passes locally before requesting review.
5. At least one maintainer approval is required before merge.
6. Do not bump the version in `pubspec.yaml`; that is done during release.

---

## Commit Convention

This project uses a simplified [Conventional Commits](https://www.conventionalcommits.org/)
format:

```
<type>(<scope>): <short description>

[optional body]
```

### Types

| Type | When to use |
|------|-------------|
| `feat` | New feature or behaviour |
| `fix` | Bug fix |
| `test` | Adding or updating tests only |
| `docs` | Documentation only |
| `refactor` | Code restructuring without behaviour change |
| `chore` | Build, tooling, dependency updates |
| `perf` | Performance improvement |

### Scopes

Use the class or module name: `token-bucket`, `server-rate-limiter`,
`handler`, `headers`, `backend`, `concurrency`, etc.

### Examples

```
feat(concurrency): add tryAcquire FIFO fairness guard
fix(token-bucket): deny tryAcquire when waiters are queued
test(leaky-bucket): cover multi-slot drain scenario
docs(readme): add composite key extractor example
```

---

## Architecture Guidelines

See [doc/architecture.md](doc/architecture.md) for a full description of the
layered architecture. Key invariants:

1. **Limiters are pure in-memory state machines** — no I/O, no HTTP.
2. **`RateLimiterRepository` abstracts storage** — swap `InMemoryRateLimiterRepository`
   for a Redis-backed implementation without changing anything else.
3. **`ServerRateLimiter` is framework-agnostic** — it accepts a plain
   `Map<String, String>` for headers and a `Uri`, not a framework request object.
4. **`HttpRateLimitHandler` bridges HTTP and limiting** — it owns the
   `acquire`/`release` lifecycle around each HTTP request.
5. **Dispose is idempotent** — all `dispose()` implementations guard with
   `_disposed` and are safe to call multiple times.

---

## Adding a New Algorithm

1. Create `lib/src/limiters/<name>_rate_limiter.dart`.
2. Extend `RateLimiter` and implement all abstract members.
3. Maintain the FIFO fairness invariant in `tryAcquire`.
4. Implement `dispose()` with idempotency.
5. Export the new class in `lib/davianspace_http_ratelimit.dart` under the
   `// ─── Limiters ───` section.
6. Add a test file at `test/limiters/<name>_rate_limiter_test.dart` covering
   all categories in the [Testing Requirements](#testing-requirements) table.
7. Document the algorithm in [doc/architecture.md](doc/architecture.md).
8. Add a usage example in [example/example.dart](example/example.dart).

---

## Documentation

- All public symbols must have Dart doc-comments (`///`).
- Doc-comments on limiter classes must include:
  - A one-paragraph description of the algorithm.
  - A characteristics table (burst support, queue support, time complexity).
  - An `## Example` code block.
- Update `README.md` when adding new public API surface.

---

## Reporting Issues

When filing a bug report, please include:

1. Dart SDK version (`dart --version`).
2. Package version.
3. Minimal reproduction (algorithm + trigger condition).
4. Observed vs. expected behaviour.
5. Stack trace if applicable.

Label the issue with one of: `bug`, `enhancement`, `question`, `algorithm`.
