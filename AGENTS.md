# AGENTS.md

This repository requires test-driven development by default.

## Working Rules

1. Use TDD as the default workflow.
2. Before changing production code, first add or update a failing test that captures the expected behavior or reproduces the bug.
3. Only then implement the code change needed to make the test pass.
4. After the change, run the relevant test suite and report the exact verification that was executed.
5. For regressions, do not ship a fix without a regression test unless it is technically impossible.

## Test Expectations

1. For Flutter changes:
   - Prefer Dart unit tests for pure logic.
   - Add widget tests when UI behavior is involved and can be covered reliably.
   - For browser-only integrations that are hard to unit test, extract testable logic first, then add the smallest possible integration-facing verification.
2. For Django or Python backend changes:
   - Add or update automated tests in the relevant app test suite.
3. For WebSocket, media, STT, LiveKit, or other integration-heavy paths:
   - Do not rely on manual testing alone.
   - Add test coverage for the state machine, protocol handling, serialization, parsing, and failure paths.
   - If end-to-end automation is not practical, explicitly document what was covered by tests and what remains manual.

## Delivery Standard

1. "It works locally" is not sufficient.
2. A task is not complete until:
   - the code change is in place,
   - the relevant tests exist,
   - the relevant tests pass,
   - and the verification steps are reported clearly.

## Environment And Docs Sync

1. When adding, renaming, or removing environment variables in code, update `.env.example` in the same task.
2. If the variable is user-facing or needed for local/dev/prod setup, update the relevant docs in the same task.
3. Do not leave the repository in a state where code supports config that is missing from `.env.example`.

## Exceptions

1. If a test cannot be added before the fix, say so explicitly and explain why.
2. In that case, add the test immediately after the fix in the same task unless truly impossible.
