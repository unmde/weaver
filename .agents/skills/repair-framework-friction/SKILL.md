---
name: repair-framework-friction
description: Repair a reproducible defect in Weaver-owned code discovered while running a supported Weaver workflow. Use after a minimized case reproduces on the current default branch. Do not use when the only failure is invalid widget code with an actionable diagnostic, documented unsupported behavior, an unresolved product decision, or a fix owned by another repository.
---

# Repair Weaver framework friction

Take one confirmed Weaver defect from a minimized reproduction to a reviewed
pull request. The discovering agent retains ownership of the task that exposed
the defect. If you are the delegated repair agent, own this repair through its
completion handoff instead of delegating it again.

## Confirm the handoff

Receive or reconstruct this evidence before editing framework code:

- the parent task and how the defect blocks or weakens it;
- the smallest widget or command that reproduces the failure;
- the exact command, complete output, and platform;
- the expected behavior and the contract, documentation, or existing behavior
  that establishes it;
- the result from a refreshed, clean default branch; and
- the original checkout's branch and dirty state.

Classify the failure first. Return it to the discovering agent when the widget is
invalid and Weaver already names the problem and recovery, the behavior is
documented as unsupported, or the failure comes only from local setup outside
Weaver's control. An opaque or internal error caused by invalid input is a
framework diagnostic defect; repair the diagnostic without accepting the input.
Ask for a decision when the contract is ambiguous or a fix would choose new
product behavior. Ask before changing a submodule, another repository, or an
external upstream.

## Own the repair

1. Create an isolated worktree and a dedicated branch from the refreshed default
   branch. Leave the discovering agent's checkout and widget changes untouched.
2. Make the minimized failure red outside the original widget. Prefer a focused
   regression test. When no test seam exists, use the smallest deterministic
   command that proves the same failure and retain its output as the receipt.
3. Trace the failure to its root cause and fix Weaver-owned code. Preserve the
   supported contract. If the framework rejected bad input but gave an opaque
   error, make the diagnostic name the failed operation, bad value or state,
   expected constraint, and recovery.
4. Prove the focused regression, the affected test suites, and the original
   minimized workflow against the repaired build. The repair is not proven until
   the original reproduction succeeds or returns the intended actionable error.
5. Inspect the complete diff, commit only the repair and its evidence, push the
   dedicated branch, and open or update one Weaver pull request. The pull request
   must carry the reproduction, root cause, fix, regression receipt, affected
   validation, and impact on the parent task.
6. Babysit the pull request's current head. Refresh its SHA, required checks,
   review-bot state, and unresolved threads after every push. Fix narrow
   actionable findings, answer false positives with evidence, and request review
   again when needed. Continue until required checks pass, automated reviewers
   have finished, and no actionable thread remains. A mergeable badge alone is
   not completion.

Do not merge the pull request. If permissions, infrastructure, or an unresolved
product decision prevents the loop from finishing, return the exact blocker and
the evidence already collected.

## Return the repair

Send the discovering agent a completion packet containing:

- the pull request URL and current head SHA;
- the minimized reproduction;
- the red-before and green-after regression receipt;
- the commands and results used for affected validation;
- the current checks, automated review, and unresolved-thread state; and
- any remaining boundary or follow-up.

The discovering agent reruns the original workflow against the repaired code.
Only that retest closes the framework-friction branch of the parent task.
