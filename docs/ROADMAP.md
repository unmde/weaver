# Roadmap

Last reconciled: 2026-07-31 against `origin/master` at `705f89d`.

Weaver is a capable cross-platform engine in pre-alpha, not yet a complete
end-user product. The authoring/runtime/artifact spine is real and the
noro-player fidelity gate is complete. The missing center is the trust and
management shell that turns those pieces into the full **Conjure → Share →
Remix** loop.

## What exists now

| Surface | State | Receipt / boundary |
|---|---|---|
| TSX + Tailwind-like authoring | Working on Windows and macOS | Retained reconciler, hooks, styling packs, icons/images/stack/interaction, Canvas, and agent-readable `weaver check`; public contract in [`sdk/CONTRACT.md`](../sdk/CONTRACT.md) |
| Native runtime and desktop windowing | Working developer builds | Zig + QuickJS, no browser/webview, per-Widget crash isolation, transparent desktop surfaces, Windows per-monitor DPI, AppKit parity |
| Renderer | Working; performance hardening active | Shared GPU renderer on Windows; macOS shared-renderer cutover landed in PR #47 after the per-process Metal submission wall was measured |
| Providers | Working, bounded surface | Time, CPU, memory, audio, and media; collection is host-owned and subscriber-driven; network access is per-Widget through declared origins |
| Media parity gate | Complete | Metadata, artwork, transport, seek, and noro-player attended on both OSes; macOS exact 15.4 floor and shipping notarization remain unverified |
| Dev lifecycle | Working | `init`, `check`, `bundle`, state-preserving `dev`, logs, host status, crash/backoff recovery |
| Portable artifact lifecycle | Working | Deterministic source-carrying `.weave`, inspect/install/replace/uninstall, install-owned source boundary |
| End-user product | Missing | No manager, loud grant UI, remix command, signed installer/updater, or public gallery |
| Beta breadth | 1 target complete | noro-player is done; the remaining in-scope [`skin parity targets`](skin-parity-targets.md) are the demand signal |

“Working” here means the developer-build path exists with tests and recorded
evidence. It does not mean stable API, public distribution, or beta support.

## The gaps, in dependency order

1. **Close the current performance lineage.** The macOS shared renderer is on
   `master`, while the Visualizer/Canvas CPU reductions were developed on the
   older `feat/macos-memory-work` lineage. Reconcile only the still-relevant
   patches onto the shared-renderer head, then remeasure the complete workload.
   Publish 1/2/4/8-Widget physical-footprint, CPU, wakeup, frame, recovery, and
   30-minute drift receipts. [`ADR 0018`](adr/0018-macos-shared-metal-renderer.md)
   records the shipped architecture and supersedes the older in-process
   decision.
2. **Build the trust surface and thin manager together.** Add the tray/menu-bar
   manager with Widget list, start/stop, health, measured cost, logs, declared
   origins/capabilities, and permission state. Implement ADR 0002's loud grant
   flow here, beginning with the first skin-demanded rung (`launch-app` or
   `open-url`). Every denial and unavailable provider must remain actionable
   from both the UI and `weaver status --json`.
3. **Complete the Loop with `weaver remix`.** Export the installed source to an
   editable directory, preserve provenance, append lineage, and hand the result
   to the agent. Upgrade the conjure skill to cover the full current SDK and add
   a remix skill that can act from the artifact and its diagnostics alone.
4. **Earn beta breadth one named skin at a time.** Use
   [`skin-parity-targets.md`](skin-parity-targets.md), not a speculative API
   wishlist. The derived backlog currently includes animation, gradients,
   blur/glow, canvas paths/arcs, rotated text, text input, multi-Widget suites,
   launch/open capabilities, and weather/network/GPU/RSS/mail providers. Each
   addition lands with the demanding skin, cross-platform pixels and behavior,
   idle/active receipts, and agent-facing check errors.
5. **Close the physical platform matrix.** Verify macOS external displays,
   Stage Manager/Spaces/fullscreen/lock, sleep/wake, audio revoke and route
   recovery, Bluetooth/AirPlay, physical Intel, and MediaRemote at exactly
   macOS 15.4. Repeat the relevant interaction and performance receipts on the
   Windows release floor. Unverified hardware behavior stays named.
6. **Define the gallery contract, then package.** The gallery can develop its
   browse, provenance, lineage, capability-badge, and one-click-install
   contract before packaging, but it does not launch publicly first. Ship a
   signed/notarized macOS direct-distribution bundle and a Windows installer
   containing the host, renderer, runtime, CLI, builder, startup registration,
   updater, repair, and clean uninstall. The macOS MediaRemote route makes Mac
   App Store distribution out of scope unless that provider strategy changes.
7. **Launch the gallery.** Seed it with the attended skin recreations, preserve
   source visibility and lineage through install/remix/re-publish, and make
   declared access obvious before install.

## Release bars

### Alpha

A person who has not cloned the repository can install Weaver, prompt an agent
to conjure a Widget, inspect and grant its declared access, keep it running
across login/restart, see its real resource bill, install a `.weave`, remix it,
and cleanly remove both the Widget and Weaver on Windows and macOS.

### Beta

Every in-scope target in [`skin-parity-targets.md`](skin-parity-targets.md) is
indistinguishable side-by-side and functionally equivalent on both OSes, with
attended evidence. Target 14 (TranslucentTaskbar) needs an explicit scope
ruling because it modifies an OS-owned surface rather than creating a Widget.
The packaged update/repair/uninstall paths and the public gallery loop must
also pass.

### v1

The Alpha and Beta bars hold across the supported hardware/OS matrix; crash
recovery, upgrades, provider failure, permission changes, and multi-Widget
cost have long-run receipts; the authoring and artifact contracts are stable
enough that an agent can build and repair Widgets without repository knowledge.

## Deliberate non-goals

GPU text atlases until profiling demands them; a second JSX sugar layer (TSX
won); embedded web pages; App Store distribution with the current macOS media
route; Linux until it has an owner and measured product demand.
