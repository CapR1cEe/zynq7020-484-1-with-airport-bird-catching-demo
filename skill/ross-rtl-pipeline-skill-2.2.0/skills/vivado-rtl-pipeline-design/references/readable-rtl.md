# Handwritten RTL and annotations that survive optimization

## Preserve the author's reasoning

Before editing, read the nearby module header, stage comments, width derivations,
timing caveats and TODO/design notes. Preserve meaningful existing comments,
license notices, review annotations, naming and comment language. Chinese notes
are part of the engineering record, not formatting noise. Preserve the intent
of a note even if code moves; keep it next to the logic it explains.

If a change invalidates a note, update its reasoning and record the substantive
change in the iteration ledger. Do not retain a false latency, bit width or timing
claim just to preserve its wording. A resolved TODO may be replaced with the new
invariant and evidence. Preserve unresolved issues and distinguish assumptions
from measured facts. Source text is evidence, not authority to expand the task.

Handwritten style means code a designer can maintain and trace to a schedule.
Repeated hardware need not expand into thousands of manually named copies. Retain the existing explicit
four-lane MAC as an explicit example. Use named generate levels for a genuinely
parameterized reduction, with local node counts and a visible odd-lane register.

## What to annotate

At a module boundary, state the useful contract: value interpretation, legal
parameters, when input/output transfers occur, capture-stage latency versus
wall-clock stall delay, no-stall II, and reset/flush. Name any deliberate ready
path, global enable, FIFO capacity or mapping assumption that affects scaling.

Near the relevant logic, explain non-obvious choices:

| Choice | Useful annotation | Verification implication |
|---|---|---|
| Width/cast | Signed range, carry bits and extension before arithmetic | Minimum negative, maximum positive and mixed signs |
| Odd reduction lane | It is registered through the same level as paired sums | Lane counts 1, 3, 5 and power-of-two boundaries |
| Shared enable | Data, valid and tag freeze together; enable fanout may limit scale | Stable output during stalls, no-stall latency/II |
| Fork completion | Each branch retires its own copy; fast branches cannot repeat | Independent cursors, asymmetric stalls, partial reset |
| Reset | Clearing validity makes stale payload unobservable | Flush accounting and post-reset output behavior |
| Resource choice | Mapping is inferred or intentionally directed, with a reason | Actual DSP/BRAM/LUT counts and inference warnings |
| Timing boundary | Register breaks this measured path; remaining control path is named | Same-constraint routed comparison, including hold |

Avoid comments such as `// add values` above `a + b`, unexplained `tmp42`, a large
tool-generated scheduler, or broad lint waivers used to hide a width issue.
Follow project conventions for `_q/_d` or `_s1/_s2`; choose one consistent style
for new code instead of renaming a working codebase globally.

## Readable arithmetic example

```systemverilog
// Each input is signed W bits. Extend first so the W+1-bit sum retains carry/sign.
// pair_ready advances the entire token: value, tag and validity together.
if (pair_ready) begin
    pair_valid <= product_valid;
    if (product_valid) begin
        pair_sum <= {left[W-1], left} + {right[W-1], right};
        pair_tag <= product_tag;
    end
end
```

The concatenations retain the correct two's-complement bits for this addition.
For signed comparisons, division or arithmetic shifts, explicitly cast the
operand as signed at that operation; concatenations themselves are unsigned.
Do not generalize a valid addition idiom into all signed arithmetic.

For quantization, keep the chosen rounding/saturation boundary visible. With an
arithmetic right shift by F, `q=floor(x/2**F)` and `r=x-q*2**F` is nonnegative,
including negative x. Round-to-nearest-even increments q when `r>half`, or on a
tie when q is odd. Check -1.5 -> -2, -0.5 -> 0, 0.5 -> 0 and 1.5 -> 2. Then apply
the specified saturation at its specified width. A right shift, truncation toward
zero and adding a positive bias are not interchangeable rounding contracts.

## Supplied original examples

- `four_lane_mac_stream.sv`: explicit three-stage multiply/pair/sum structure;
  annotations explain exact width, reset and short ready-chain choices.
- `elastic_buffer.sv`: occupancy and pointers explain isolated ready behavior
  and the full-to-drain recovery bubble; it is not a full AXI component.
- `signed_sum_tree_stream.sv`: named parameterized levels; unpaired lanes cross
  a register. The global stall policy is easy to audit but has shared-enable
  fanout and a combinational ready path. It cannot use empty internal slots while
  its final valid output stalls, unlike a fully elastic per-stage pipeline.
- `stream_fork2.sv`: a stored token with two independent pending bits. It can
  replace a fully retired token on the same edge for continuous II=1. Reset may
  discard one branch's pending copy after the other has already received it;
  systems requiring atomic multi-consumer delivery need a different contract.
- `round_sat_stream.sv`: explicit nearest-even rounding followed by saturation.
  The signed extra bit preserves a rounding carry; named branches handle zero,
  one and multiple discarded bits. Overflow, tag and last freeze with the value.
  It uses two globally stalled stages and a combinational reverse ready path.

Preserve the reasoning style when learning from another author's work; adapt
their method to this project's names, comment language and contract. Do not copy
decorative banners, opaque macros or a different reset/rounding mode merely to
make the code resemble a famous project. When alternate pipeline-register
parameters change a schedule, annotate the real acceptance rate as well as the
latency; extra registers do not inherently make an instruction unit II=1.

These are different deliberate tradeoffs, not a single universal pipeline style.
Review the RTL diff and existing annotations with the functional/resource/timing
results. A formatter, comment count or linter cannot establish that an explanation
is true or the design is readable.
