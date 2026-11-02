# Architecture patterns and necessary bounds

## Contents

Resource/recurrence bounds; reductions and DSPs; elastic interfaces; memories;
non-CNN examples; implementation contracts.

## Allocate work rather than count RTL operators

For each token, count operations of each independently provisioned operator group.
If a group performs O operations/token, has P equivalent instances, and each
instance can start one operation every J clocks, its average resource bound is
`II >= ceil(O * J / P)`. Operator latency L and operator initiation interval J
are different. A fully pipelined L-cycle multiplier can have J=1. Independent
resources use the maximum of their bounds; operations sharing the same instances
must be combined before applying the formula. Divisibility, dependencies, mux
cost and scheduling can make the achieved II worse.

For a loop-carried dependency with feedback latency L and dependence distance D,
`II >= ceil(L/D)`. Interleaving independent accumulators can raise D, but requires
enough distinct contexts and a correctly aligned read/modify/write schedule.
Reassociating floating-point addition can change results; preserve the numerical
contract or obtain authorization for a different one. Never treat pipeline
register insertion as permission to change the algorithm.

Memory/external link bounds use transferred words or bytes per token divided by
effective capacity per clock or second. Apply both directional and shared-port
bounds where appropriate. Account for cache reuse, burst efficiency, refresh,
read/write turnaround and competing clients. A capacity bound says nothing about
bank conflicts or the feasibility of the exact access schedule.

The planning helper evaluates explicit candidates and returns necessary bounds,
not an automatic technology mapper or scheduler. An estimated resource total is
partial unless all datapath, control, buffering and clock costs are included.

## Arithmetic pipelines

For N signed W-bit products, allow 2W product bits and, conservatively,
`2W + ceil(log2(N))` sum bits. For mixed widths, bias, unsigned data, or restricted
ranges, derive the actual extrema instead. Extend before addition, shifting or
negation; changing a result's width after a too-narrow expression does not recover
lost bits. Include the most-negative signed value in tests. Preserve the exact
location of rounding, clipping and saturation; avoid implementation-dependent
unsized constants.

- Reduction/FIR: balance a tree, align odd leftover operands and metadata, then
  select legal register cuts using measured delay. Choose direct/transposed forms
  using sample dependencies, DSP cascades, coefficient reuse and reset semantics.
- Wide adders: register carry segments only when throughput and carry/sign/tag
  alignment are preserved. Pipelining across a feedback recurrence needs a new
  schedule, not a cosmetic split.
- Divider: iterative reuse saves resources but usually has larger II. A fully
  unfolded restoring pipeline can accept one dividend/divisor pair per clock at
  substantial area cost. Register partial remainder, quotient, divisor and tag
  together. Define divide-by-zero, signed remainder and min-negative/-1 behavior.
- DSP mapping: verify device multiplier/accumulator widths and internal register
  use. Packed multiplies need a proof of cross-term/sign separation and correction;
  a successful small random sample is insufficient. Count measured primitives.

There is no portable rule that one stage equals a specified number of MHz.
Registers have setup, clock-to-Q, skew and routing cost; empty stages do not fix a
single indivisible operation or poor placement.

Keep a wide value until the specified quantization boundary. For nearest-even
rounding, negative half ties and a carry into the positive saturation limit need
separate checks. Rounding before saturation can differ from saturating a narrowed
intermediate first. The original `round_sat_stream.sv` makes rounding and saturation
two visible stages, and carries overflow as token metadata. Its global ready path
and stall policy are explicit, not a claim that every quantizer should use two stages.

## Elastic and fixed-rate interfaces

Choose the interface from the consumer's actual capabilities:

| Structure | Use | Cost and limitation |
|---|---|---|
| Fixed-rate register pipeline | Source/sink obey an explicit sample-enable contract | No inherent backpressure; stop/drain behavior must be defined |
| One-entry elastic stage | Short ready path, local stalls | `ready = !valid || downstream_ready` can create a long combinational chain |
| Two-entry elastic buffer | Break a downstream-ready to upstream-ready path | Extra slot absorbs a late stop; full-to-drain input recovery can cost a cycle |
| Pipeline plus output FIFO/credits | Long wires or many unstallable in-flight tokens | Reserve capacity for all unpreventable arrivals and control delay |
| Async FIFO | Actual asynchronous clock crossing | Requires CDC-specific pointers/reset handling; ordinary elastic buffers cannot substitute |

For a decoupled producer, reserve free slots for the maximum beats that can still
arrive after the stop decision. At R beats/clock and S clocks of feedback delay,
at least R*S slots of additional headroom may be required, plus any independent
untracked production. Determine off-by-one conventions from the actual event
schedule. A FIFO can absorb a finite burst mismatch; it cannot fix a permanently
slower consumer. Derive depth from cumulative production minus consumption over
the relevant interval and test the maximum occupancy/drain schedule.

Bundle `data`, `last`, byte enables, tag and error/status fields into the same
logical token. For a join, consume matching operands atomically or retain each
until its partner arrives. For a fork, track which branches accepted the token;
holding upstream valid while repeating transfers to a ready branch duplicates
data. Examine cycles in dataflow graphs for initial-token and deadlock needs.

The original `stream_fork2.sv` stores a token and tracks one pending bit per
branch. A reset may flush a still-pending branch after the other has accepted;
this is explicitly not atomic delivery to all consumers. Test each branch with
an independent cursor and force one branch to remain ready while the other stalls.
The original `signed_sum_tree_stream.sv` supports odd and single-lane reductions;
unpaired values traverse a register at each level. Its global enable simplifies
alignment but restricts bubble movement during stalls and may have high fanout.

`assets/rtl/elastic_buffer.sv` is an original two-entry, single-clock implementation
with no combinational path from `m_ready` to `s_ready`. It has one capture stage,
II=1 under continuous ready, and reset flushes both slots. It is not a complete
AXI component or a CDC block. `four_lane_mac_stream.sv` intentionally illustrates a
short three-stage combinational-ready pipeline; use buffering when that chain is
critical rather than assuming it scales indefinitely.

## Memory and system pipelines

Write a per-cycle access table before selecting BRAMs. Capacity, port count,
width/depth configuration and read-during-write behavior are independent checks.
Bank by the actual address pattern; consecutive-lane banking does not solve
strided modulo conflicts. Distinguish replication for extra read ports from
partitioning for independent addresses. Include synchronous read latency and
enable/tag alignment, including a stalled request whose response cannot stop.

Define collisions separately: same-cycle read/write, adjacent-cycle read-after-write,
simultaneous writes to one address, and byte-enable interactions. State whether
each is legal, forwarded, old-data, new-data, arbitrated, or excluded by contract.
Tests that exclude an unsupported collision do not establish a behavior for it.
Include forwarding comparators/muxes, replicated banks, feedback read ports and
their timing in the ledger. A multiport wrapper's logical bank count is not a
physical BRAM count. Read the
[community multiport-memory case](community-case-studies.md#abdelhadi-multiported-ram-ports-have-real-memory-and-bypass-cost)
when considering those architectures; vendor inference and all dependencies
still need verification on the actual device.

Line/window buffers reduce repeated stencil reads; ping-pong buffers overlap
load/compute/store only if port ownership and completion are explicit. Check
prologue, final-window drain, frame edges and non-multiple tile tails. More cache
helps only when miss/burst counters improve; extra capacity can worsen routing.

Measure useful throughput at the right boundary. A clock target, II=1 datapath and
large FIFO can coexist with poor application throughput due to bus stalls or
software. Carry TinyYOLO's counter-based diagnosis into other domains without
carrying over its part, dimensions, packing tricks or frequency as defaults.
