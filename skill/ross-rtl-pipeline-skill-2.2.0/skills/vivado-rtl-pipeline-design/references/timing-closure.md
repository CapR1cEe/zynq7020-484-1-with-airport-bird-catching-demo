# Report-driven timing closure

## Baseline and comparison

Record part/speed grade, Vivado version, top, source revision/hashes, XDC hashes,
clocks/generated clocks, IO assumptions, uncertainty, run strategies and relevant
seeds. Keep these constant across a direct RTL comparison. Identify an intentional
flow or constraint change separately rather than attributing its effect to RTL.
Preserve a working revision before exploring alternatives.

Use explicit values for target period, required II and maximum latency. Test the
required frequency directly. `1000 / (period - WNS)` is at most a local estimate
under restrictive same-clock assumptions, not a generally valid achieved Fmax:
cross-clock timing, uncertainty, hold, route changes and clock insertion differ.

## Read the actual limiting path

For each important setup/hold path capture startpoint, endpoint, clock relationship,
path requirement, logic levels, cell delay, net delay, fanout and physical span.
Distinguish the failing path's data delay from its total required/arrival terms.
Group repeated paths by root cause to avoid optimizing a nonlimiting multiplier.

| Evidence | Candidate action | Verify after change |
|---|---|---|
| Carry/reduction depth dominates | Balance reduction; use legal DSP registers; split wide adds | Exact carry/sign/rounding, added latency, recurrence II |
| Wide mux/address decode dominates | Stage address/decode; choose banks; simplify selection | Access schedule, hazards, memory inference, tags |
| Ready/valid/enable/reset has high fanout | Localize control; insert elastic storage; avoid unnecessary payload resets | In-flight capacity, stall stability, reset flush, throughput |
| Routing/net delay dominates | Reduce span/replication pressure; localize consumers; reconsider excessive parallelism | Placement/congestion and routed paths; do not assume more registers fix wires |
| Memory port/feedback bottleneck | Bank/replicate/reorder or interleave independent contexts | Bound, collisions, recurrence semantics, realistic stall trace |
| DSP/BRAM inference changed unexpectedly | Inspect width, signedness, enables, reset and inference templates | Primitive counts and bit-exact behavior |
| Clock skew/CDC/constraint issue | Check clock topology and legitimate relationships; use proper CDC structures | Related clocks, CDC reports, generated clocks, no unsafe exceptions |
| Hold/pulse width fails despite setup pass | Inspect min-delay/clock/pulse constraints and implementation | Routed hold and pulse-width reports on intended corners |

Do not use logic fabric to gate a clock, place an arbitrary false path on data,
or add multicycle constraints merely because an operation takes several clocks.
A valid exception requires a functional/protocol justification and correctly
paired setup/hold treatment. Stop and explain an infeasible request instead of
changing its definition to produce a green report.

## Bounded search with a useful stopping point

Build a short candidate set from the current evidence: for example a balanced
tree, one extra legal register cut, and a smaller bank-local parallel array.
Run cheap functional/resource checks first. Keep an iteration ledger including
failures, latency/II and resource tradeoffs. Preserve the best feasible candidate;
the latest candidate is not automatically the best. Choose the next experiment
only when its expected benefit addresses the current limiting cause.

Stop after closure against the actual contract, when available run resources are
consumed, or when repeated reports show no supported next improvement. Give the
remaining limitation and useful tradeoffs. Do not promise unconstrained overclocking
or loop forever to satisfy a subjective comparison with another skill.

## Signoff evidence

Synthesis estimates support architecture decisions. Only routed evidence on the
specified part and constraints supports routed timing claims. Check setup WNS/TNS,
hold WHS/THS, pulse width WPWS/TPWS, unconstrained paths, clock interaction, CDC,
DRC and methodology; review any bus-skew constraints. Clarify report scope,
corners and waivers. An isolated out-of-context core result does not sign off the
integrated system or its IO/CDC paths.

`scripts/collect_reports.tcl` collects available reports from an **already open**
design; it neither routes nor changes constraints. Check its report index for
failed/unsupported commands. A generated file is not proof that its violations
were reviewed or passed. Board performance and application correctness need
separate measurement even after timing closure.

For quick extraction, `scripts/assess_timing.py` reports measured negative slack
or missing min/max/check_timing evidence. It never grants signoff. Review the
actual paths and report scope; a register-to-register subset excludes IO paths
and cannot overrule a failing whole-design report. A full-clock registered
benchmark also changes context relative to a bare OOC core: record it separately,
with its own source/constraint hashes and remaining IO/DRC assumptions.
