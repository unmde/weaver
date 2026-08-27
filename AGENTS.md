i(Dara,me) want to write this to you(agent). weaver we are building this together.

weaver is a desktop widget platform: Rainmeter, but cross platform (macOS and Windows) and authored in tsx instead of a bespoke markup language. It has to match or beat Rainmeter on performance: these are desk widgets, so the memory and cpu profile is the product, not a nice-to-have.

This is meant to be a bold project. Going with the flow and using existing solutions will not get us where we want to be.

Quick glossary of relevant parties in this document:

you - the agent reading this document and working on weaver directly.
me/we/us - the humans contributing to weaver. This is the party talking to you as we build.
developers - these are our users. We are assuming they won't read code much, rather they will prompt their own agents to build things using this framework.
widget - this is what weaver creates and manages

And the words we use when we work:

landmine - a decision that costs nothing now and blows up later. by the time it detonates it's load-bearing. (i.e. an unmeasured limit, a silent catch)
receipt - the measurement behind a number. no receipt, no number.
tripwire - a limit placed past where any good widget goes, so only broken things touch it. good widgets never feel it exists.
simple - how cleanly the logic breaks down. each step follows from the last, no step doing two jobs.
obvious - the next reader never asks "why is this here?". measured by the reader. not always simple; sometimes obvious has more parts.

Here's some philosophical things to consider as we build and work together

## Boil the ocean
When planning, do not be afraid to suggest seemingly insane solutions. we effectively have to rethink and rebuild what it means to make a desk widget platform. The bar is an amazing developer experience without giving up any of the performance: tsx familiarity for developers/agents who know the web, with efficiency that beats the native incumbents.

## Every number needs a receipt
A limit without a measurement is a landmine. Before writing any number (a `max_nodes`, a byte cap, a timeout), measure the real thing first, then size it as a tripwire. Capacity is free until touched (reserve big, commit lazily, never zero an arena eagerly), so be generous. If a good widget hits a budget, the budget is wrong. Remeasure, update the receipt.

## DX is for humans and agents
Every surface we ship has two readers: a human debugging at 2am and an agent with nothing but the error text. Design for both. Apis should be guessable by anyone who knows tsx; errors and check output should carry enough that an agent can act without reading our code. An agent can fix "max_nodes=128, asked for 129". It cannot fix a blank window. The test for done: given only the message, could a fresh agent fix the widget? Given only the log, would a human know where to look? A no on either means not done.

## A limit developers can hit is a limit they must see
Every budget failure names the budget, the limit, and the ask: at `weaver check` if knowable there, loudly at runtime if not. A silent budget is worse than no budget.

## Fight for the "obvious" solution
Measure twice, cut once: understand the problem fully before building, because cleverness is what gets written when you haven't. The biggest simplicity win is refusing to solve problems we don't have. Good code is the most simple thing that delivers full functionality and performance, nothing traded away, nothing bolted on. Push back when you see a more obvious way.

## Some general rules
These are meant to steer us in the right direction. They are not hard-set, but we should default to following them. If you think one should be ignored, be very loud and clear about that and get approval from us before doing it.

## Framework friction is product work
When a supported Weaver workflow exposes a reproducible defect in Weaver-owned code, or returns an error that leaves a fresh agent unable to recover, keep the failing case and treat the defect as part of the current task. Minimize it and reproduce it against the current default branch before starting a repair. Keep widget code honest instead of hiding the defect with a local workaround. A change that chooses new product semantics, crosses into another repository or submodule, or turns an unsupported request into a feature needs approval first.

For a confirmed Weaver defect, follow [`.agents/skills/repair-framework-friction/SKILL.md`](.agents/skills/repair-framework-friction/SKILL.md). This is standing authorization to fix Weaver-owned code, create or update a dedicated branch and pull request, and babysit its current head until required checks pass and no actionable review thread remains. It does not authorize merging the pull request.

When delegation is available and the repair can be separated from the original task, dispatch that skill to one subagent in an isolated worktree. The discovering agent owns the diagnosis, minimized reproduction, and final retest. The repair agent owns the regression test, root-cause fix, branch, pull request, and review loop. The discovering agent must receive the repair evidence and rerun the original workflow before reporting its task complete. Run the same skill directly when delegation is unavailable or the work cannot be separated cleanly.
