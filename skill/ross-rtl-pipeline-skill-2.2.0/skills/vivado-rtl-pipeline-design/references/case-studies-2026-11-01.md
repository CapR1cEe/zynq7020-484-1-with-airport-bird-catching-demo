# Additional primary-source cases: 2026-11-01

These extend [the earlier five cases](research-notes.md). The source files below
were downloaded at pinned commits and their implementation/test logic inspected.
That supports the observations below; it does not mean every upstream test or
published performance result was reproduced. The package adds original examples
and its own independent tests instead of redistributing third-party RTL.

## PULP common_cells: fork ownership and flush contracts

Commit `e73baaec2ca665cd80c3c384e9258e35242b829c`, Solderpad Hardware License 0.51.

Read [cc_stream_fork.sv](https://github.com/pulp-platform/common_cells/blob/e73baaec2ca665cd80c3c384e9258e35242b829c/src/cc_stream_fork.sv),
[cc_stream_fifo.sv](https://github.com/pulp-platform/common_cells/blob/e73baaec2ca665cd80c3c384e9258e35242b829c/src/cc_stream_fifo.sv),
[cc_spill_register.sv](https://github.com/pulp-platform/common_cells/blob/e73baaec2ca665cd80c3c384e9258e35242b829c/src/cc_spill_register.sv),
and [cc_spill_register_flushable.sv](https://github.com/pulp-platform/common_cells/blob/e73baaec2ca665cd80c3c384e9258e35242b829c/src/cc_spill_register_flushable.sv),
with README and LICENSE. Older unprefixed paths are now deprecated wrappers;
the successful downloads use the actual `cc_` implementations.

The fork's source comment promises exactly one handshake per output for each
input, without requiring simultaneous branch handshakes. It tracks each output's
completion. This is a control-only, unbuffered fork: an output may consume before
the input handshake finally completes, relying on the source to hold its token.

The spill implementation distinguishes synchronous clear from flush, includes
two storage registers, and explicitly asserts that flush and valid must not be
asserted together. Its optional bypass removes isolation. Reset/flush/bypass are
observable protocol choices, not harmless implementation options.

**Adopt:** annotate ownership and per-branch completion, define flush behavior,
and reserve actual storage for delayed stopping. The original `stream_fork2.sv`
stores an input before presenting copies and has independent pending bits. Its
input-acceptance timing differs from the control-only upstream source.

**Limit:** the original example intentionally retains a combinational ready path.
It does not inherit the upstream spill block's timing isolation. The inspected
FIFO wrapper delegates to other primitives; reading a wrapper is not a full FIFO
correctness proof. No upstream PULP regression was run here.

## hdl-modules: explain timing choices and test each consumer

Commit `2bdb03032345a72b2cff17d2ab5ab6af422b636b`, BSD-3-Clause in `license.txt`.

Read [handshake_pipeline.vhd](https://github.com/hdl-modules/hdl-modules/blob/2bdb03032345a72b2cff17d2ab5ab6af422b636b/modules/common/src/handshake_pipeline.vhd),
[handshake_splitter.vhd](https://github.com/hdl-modules/hdl-modules/blob/2bdb03032345a72b2cff17d2ab5ab6af422b636b/modules/common/src/handshake_splitter.vhd),
its [testbench](https://github.com/hdl-modules/hdl-modules/blob/2bdb03032345a72b2cff17d2ab5ab6af422b636b/modules/common/test/tb_handshake_splitter.vhd),
[truncate_round_signed.vhd](https://github.com/hdl-modules/hdl-modules/blob/2bdb03032345a72b2cff17d2ab5ab6af422b636b/modules/math/src/truncate_round_signed.vhd)
and its [testbench](https://github.com/hdl-modules/hdl-modules/blob/2bdb03032345a72b2cff17d2ab5ab6af422b636b/modules/math/test/tb_truncate_round_signed.vhd),
with readme and license. VHDL concepts transfer; syntax/reset conventions do not.

The pipeline comments separately identify full-throughput skid storage,
data-registered/control-combinational operation, and reduced-throughput choices.
The splitter records sticky completion per destination. Its tests use independent
consumer queues, randomized stalls and a separate full-throughput case.

The rounding module documents tie-to-even versus tie-to-positive-infinity,
overflow and optional saturation, with optional registers carrying valid and
overflow together. Its tests separately exercise rounding modes and reference
data; reading the test also reveals configuration limits rather than proving all
mode combinations are covered.

**Adopt:** comments should state why a mode costs area or throughput; test output
branches independently, and test claimed II directly. Carry rounding-overflow
and validity through each optional register. Include negative ties and saturation
edges in the numeric contract, as described in [readable-rtl.md](readable-rtl.md).

**Limit:** the rounding block is fixed-rate valid-only, not a ready/valid block.
Do not add backpressure by delaying valid alone. Its source's resource comparison
is an upstream observation, not a measured win on our device. VUnit/OSVVM tests
were inspected, not run in this environment.

## Ibex: readable partial products and deliberate time sharing

Commit `f4515520c0045bb8ef1e72d46ed82499a6ac5f18`, Apache-2.0.

Read the multiplier sections and shared arithmetic/control interfaces of
[ibex_multdiv_fast.sv](https://github.com/lowRISC/ibex/blob/f4515520c0045bb8ef1e72d46ed82499a6ac5f18/rtl/ibex_multdiv_fast.sv),
plus README/LICENSE. Inspection focused on multiplier variants, signed partial
products, accumulation widths, result hold and state enables; it was not a
complete divider/CPU or formal-verification audit.

Its comments distinguish three 17-bit multipliers for the single-cycle MUL
variant from a single reused 17-bit multiplier with named partial-product states
for the fast variant. MUL and high-half MULH have different schedules. A comment
explains exactly why a particular high bit can be discarded; result hold prevents
state progression until the consumer accepts. The readable algebra/states connect
resource reuse, signedness and latency in one place.

**Adopt:** retain partial-product derivations and truncation proofs in comments,
use semantic state names, and identify the shared operator in the resource ledger.
Do not call a three-cycle shared multiplier an II=1 pipeline. Hold all relevant
state and follow the system's operand-stability contract.

**Limit:** this block relies on CPU decoder, ALU and intermediate-value interfaces;
it is not a drop-in independent ready/valid multiplier. Do not import its state
machine without those contracts or claim its configuration closes a new FPGA
frequency. No Ibex CPU regression was run for this package.

## verilog-axi: address/response cuts and verification boundaries

Commit `516bd5dadc3365b7f9e225d2af8fe0b8d804fe53`, MIT.

Read [axi_register_rd.v](https://github.com/alexforencich/verilog-axi/blob/516bd5dadc3365b7f9e225d2af8fe0b8d804fe53/rtl/axi_register_rd.v)
and [test_axi_register.py](https://github.com/alexforencich/verilog-axi/blob/516bd5dadc3365b7f9e225d2af8fe0b8d804fe53/tb/axi_register/test_axi_register.py),
with README/COPYING. The inspected RTL covers the read address/response half;
the test source targets the combined AXI register component.

Bypass, simple buffer and skid buffer are distinct choices per channel. The skid
path reserves output/temporary state and transfers IDs, response codes, last and
user information with data. Its simple buffer explicitly inserts bubbles.
The tests independently inject source idle and sink backpressure, check data
and surrounding memory sentinels, and include burst-boundary-sensitive offsets.

**Adopt:** cut both forward and reverse timing deliberately, bundle every channel
field, and separate idle/bubble tests from backpressure tests. For memory designs,
test burst tails and untouched bytes as well as numerical payload.

**Limit:** a generic token buffer is not full AXI compliance. These tests were
inspected, not run; protocol integration still needs the complete component and
its dependencies. Registering the read address alone does not resolve every
response/ready path in a system.

## Changes justified by this round

- Preserve original annotations and handwritten structure; explain arithmetic,
  control ownership, resource assumptions and remaining timing paths locally.
- Add a signed reduction supporting odd counts and a buffered fork with per-branch
  progress. Their testbenches use a flat independent numeric model and independent
  branch cursors, not DUT-internal values.
- Exercise single-lane/odd/power-of-two tree configurations, asymmetric stalls and
  reset after partial delivery. Record actual results in the distribution's
  validation directory; source inspection alone is not a passing run.
