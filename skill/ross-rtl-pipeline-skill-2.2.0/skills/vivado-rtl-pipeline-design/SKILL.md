---
name: vivado-rtl-pipeline-design
description: >-
  Design or refactor readable Verilog/SystemVerilog for FPGA clock, throughput,
  latency, and resource targets. Select parallelism, memory banking and elastic
  pipeline boundaries; verify bit-exact behavior and iterate using Vivado timing
  reports. Use for hand-written RTL architecture and timing closure, including
  arithmetic, DSP, streaming, and memory datapaths. Complements ROSS diagnostics;
  use HLS skills for C/C++ kernels.
license: MIT
metadata:
  version: "2.2.0"
---

# Vivado RTL Pipeline Design

Turn a functional specification into readable RTL and a measured implementation.
Treat frequency as a constrained implementation result, not a promise attached to
code. This community skill works standalone or alongside official ROSS skills.

## 1. Establish the contract

Inspect the existing top, reference model, part/speed grade, tool version, clocks,
XDC, interfaces, and baseline reports. Preserve the user's chosen semantics and
interfaces. Record target MHz and period, accepted-token rate or II, permitted
latency, burst shape, backpressure, reset/flush, sideband fields, arithmetic
ranges/signedness/rounding/saturation, and resource caps. Start from an existing
project's contract instead of inventing a replacement.

Use [assets/design-contract.example.json](assets/design-contract.example.json) as
an editable planning example, not a device or clock default. Ask only when a
missing decision materially changes behavior. Distinguish assumptions, analytical
bounds, synthesis measurements, routed measurements, and board measurements.

## 2. Choose an architecture before expanding RTL

Compare plausible parallel, time-shared, and pipelined schedules against the same
contract. Read [references/pipeline-patterns.md](references/pipeline-patterns.md)
when selecting arithmetic, elastic, feedback, or memory structures.

Produce two small design artifacts:

- A resource/bandwidth ledger: operations per token, operator initiation interval,
  parallel instances, recurrence distance, DSP width/mapping assumptions, memory
  capacity **and concurrent ports/banks**, LUT/FF/control cost, and margins.
- A stage table: operation, exact input/output widths, register boundary, control
  enable, carried metadata, no-stall latency, II, and buffering capacity.

Use `assets/stage-table.example.csv` and `assets/iteration-ledger.example.csv` as
starting formats; replace their illustrative rows with the actual design.

`scripts/resource_plan.py` calculates necessary throughput bounds from explicit
inputs. A passing bound is not a scheduling or timing proof. Measure mapping in
synthesis: an RTL multiplication is not necessarily one DSP, a pipeline's latency
is not its II, and a dual-port RAM does not supply arbitrary read/write bandwidth.

Do not infer pipeline depth from MHz alone. Balance actual carry/mux/memory/control
paths. Include address generation, feedback, reset/enable fanout and routing. Add
registers only at legal semantic boundaries, with operand and metadata alignment.
If the contract is infeasible, show the binding bound and relevant tradeoffs;
retain the best feasible design rather than silently lowering the goal.

When a public design can inform a choice, include individual, community and
academic sources as well as vendor examples. Use
[references/community-case-studies.md](references/community-case-studies.md) for
source selection and applicable cases. Inspect implementation and verification
evidence at a fixed revision; adopt a technique with its contract and limits.

## 3. Write readable, bit-exact, stall-safe RTL

Preserve the project's handwritten style and existing useful annotations. Keep
module/stage names, numeric explanations, handshake invariants, license notices
and measurement caveats through refactors. Update an annotation when its premise
changes; explain the change instead of silently deleting it. Read
[references/readable-rtl.md](references/readable-rtl.md) when writing or refactoring
RTL. Prefer visible stage registers and named structural generate blocks over
opaque generated temporaries. Comments should explain why a width, enable or
boundary is correct, not merely paraphrase assignments. Match the project's
comment language and conventions; retain Chinese annotations where present.

Use descriptive names, local width parameters, explicit signed types, deliberate
extensions/casts, and comments explaining numeric intent or hardware cost. Keep
long reductions balanced; split carries only with exact carry/sign preservation.
Preserve quantization and overflow rules at the same semantic boundary. A delayed
feedback accumulator may need interleaved contexts; adding registers to a
recurrence alone changes its behavior or II.

A token transfers on `valid && ready`. Hold `valid` and all payload/sideband fields
stable until accepted. Advance data and metadata under the same enable. Break a
critical combinational ready chain with an elastic/skid/FIFO structure; registering
ready alone loses in-flight beats. Size storage from stop latency and burst/schedule
imbalance, not a universal FIFO depth. The supplied examples distinguish short
combinational ready chains from registered-backpressure structures.

Reset protocol state and define whether reset flushes in-flight tokens. Avoid
resetting wide payloads when invalid payloads are unobservable and the contract
allows it. Use proper clock resources and CDC structures; an elastic single-clock
buffer is not a CDC FIFO. Do not apply KEEP/DONT_TOUCH/packing attributes without
a specific inference or implementation reason.

## 4. Verify, measure, and iterate

Read [references/verification-and-mcp.md](references/verification-and-mcp.md) for
ROSS tool discovery, example execution, and evidence recording. Read
[references/timing-closure.md](references/timing-closure.md) when timing is measured
or fails. Work in this evidence order:

1. Elaborate/lint; inspect width, latch, reset, memory and mapping warnings.
2. Run an independent self-checking reference: signed extrema, boundaries, continuous
   traffic, bubbles, long/random stalls, metadata, and reset with tokens in flight.
   Check no loss/duplication/reordering, stable stalled output (including valid),
   and explicit no-stall latency/II. Use formal/equivalence where suitable and available.
   Record formal assumptions/configuration and nontrivial traffic covers; distinguish
   bounded checks from proofs. Align transactions when comparing different latencies.
3. Synthesize; reconcile measured resources with the ledger and inspect inferred
   memories/DSPs. Reject resource/behavior regressions before expensive routing.
4. Route on the requested part with intended clocks/IO/uncertainty. Check setup,
   hold, pulse width, unconstrained paths, clock relationships, CDC, DRC and methodology.
   Inspect actual start/end points, logic delay and net delay, not just WNS.

For each iteration record the baseline, one evidence-backed hypothesis, focused
change, tool/constraint identity, functional result, latency/II, resources and
routed timing. Compare like for like. Keep the best feasible revision and stop
when targets pass, available resources/authorized runtime are exhausted, or further
changes lack evidence. Do not launch an indefinite search because an earlier
iteration failed. Explain the remaining bottleneck and unmeasured fields.

Never achieve an apparent pass by relaxing requested frequency, deleting legitimate
uncertainty, inventing false/multicycle paths, suppressing violations, or ignoring
unconstrained endpoints. A setup pass alone is not signoff. Fmax extrapolation from
one slack value is an estimate; a higher clock needs its own constrained route.

## 5. Deliver evidence at the right level

Deliver changed RTL, contract, stage table, resource plan versus measurement,
self-checking tests, reports and a compact iteration record. Use
[assets/evidence.example.json](assets/evidence.example.json) to distinguish measured
values from `null`/not run. Report board/system timing separately from local RTL
throughput, with the workload and timing boundaries.

Include the annotated RTL diff and explain any changed comment premises. Retain
the known limits alongside improvements; a new scoped benchmark cannot turn an
older failing whole-design report into a pass.

Optional official ROSS routing: `vivado-rtl-lint`, `vivado-rtl-elaboration-analysis`,
`vivado-simulate-rtl`, `vivado-timing-methodology-checks`; for C/C++ use `hls-architect`,
`hls-pipeline`, `hls-ii-diagnose`, `hls-optimize`. Inspect available skills/tools before
calling them; use ordinary CLI/report analysis if they are absent. Their specialized
rules do not replace this RTL design contract.

## References and examples

- [references/research-notes.md](references/research-notes.md): pinned public source
  observations, adaptations, licenses, limits, and comparison with official skills.
- [references/case-studies-2026-11-01.md](references/case-studies-2026-11-01.md):
  additional handshake, arithmetic, rounding, and verification source studies.
- [references/community-case-studies.md](references/community-case-studies.md):
  community skid/formal, CPU multiplier, fixed-point and multiport-memory cases;
  how source quality and verification limits change the recommended design.
- [references/architecture-and-timing.md](references/architecture-and-timing.md):
  TinyYOLO case study; retain its measurement boundaries, not its device/clock defaults.
- [assets/rtl](assets/rtl): original reusable examples; [assets/tb](assets/tb):
  independent scoreboards. Run `python scripts/run_examples.py --help` from this
  skill directory for lint/simulation commands.
