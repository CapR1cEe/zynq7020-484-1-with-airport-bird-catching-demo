# Public-source research and scoped comparison

Reviewed 2026-10-31. These are inspected revisions, not claims about the latest
release or a reproduction of published performance. Public source was read for
architecture/protocol decisions. No third-party RTL is bundled. The standalone
distribution's `validation/research_sources.json` records downloaded-file hashes.
The RTL examples and scoreboards in this skill are original.

The 2.1.0 update adds [four further source studies](case-studies-2026-11-01.md)
and a [handwritten RTL/annotation guide](readable-rtl.md). The dated observations
below retain their original baseline rather than pretending to be new measurements.

The 2.2.0 update adds [four community case studies](community-case-studies.md),
including individual and university designs, and an original tested rounding/
saturation example. Affiliation is not a quality gate; the inspected evidence
and the adopted technique's assumptions determine what can be claimed.

## verilog-axis: elasticity and long pipelines

- Source: `alexforencich/verilog-axis`, commit
  `48ff7a7e2ef782cf778d47910cf85835c64b1bce`.
- Read: [axis_register.v](https://github.com/alexforencich/verilog-axis/blob/48ff7a7e2ef782cf778d47910cf85835c64b1bce/rtl/axis_register.v),
  [axis_pipeline_fifo.v](https://github.com/alexforencich/verilog-axis/blob/48ff7a7e2ef782cf778d47910cf85835c64b1bce/rtl/axis_pipeline_fifo.v),
  README and COPYING. License: MIT.
- Observation: registered-ready operation uses output and temporary storage;
  payload and sidebands move together. Pipeline/FIFO separation reserves space
  before a downstream stop reaches every producer.
- Adaptation: choose short elastic chains or isolated-ready buffers explicitly;
  derive capacity from unpreventable arrivals; scoreboard data and metadata.
- Limit: its FIFO-depth formula belongs to that architecture, not every pipeline.
  It is not a CDC solution. The bundled occupancy/pointer buffer is not a copied
  AXI register slice.

## verilog-divider: cuts follow arithmetic depth

- Source: `risclite/verilog-divider`, commit
  `e73dec16750b45bd9e01d82848251e564a4d5354`.
- Read: [divfunc.v](https://github.com/risclite/verilog-divider/blob/e73dec16750b45bd9e01d82848251e564a4d5354/divfunc.v)
  and README. The RTL header declares Apache-2.0; root LICENSE fetch returned 404.
- Observation: compare/subtract iterations grow in width; `STAGE_LIST` selects
  register cuts. Dividend, divisor, quotient and valid state cross cuts together.
- Adaptation: balance actual operation width/depth rather than equal iteration
  counts per stage. Carry all partial state and token identity.
- Limit: there is no downstream ready; delayed ack is not an elastic handshake.
  README DE2-115 timing is not a Vivado or different-device Fmax. Signed and
  zero-divisor behavior require their own contract.

## FINN: folding, bandwidth, and bottleneck balancing

- Source: `Xilinx/finn`, commit
  `38c42bf95abbdad493db0b0f5053060074698908`.
- Read: [set_folding.py](https://github.com/Xilinx/finn/blob/38c42bf95abbdad493db0b0f5053060074698908/src/finn/transformation/fpgadataflow/set_folding.py)
  and LICENSE.txt. License: BSD-3-Clause.
- Observation: PE/SIMD choices obey divisibility/operator constraints; weight-stream
  width limits SIMD growth and producer/consumer configurations must match. A
  bounded second pass can balance against the observed cycle bottleneck.
- Adaptation: compare finite legal parallelism/reuse candidates, account for
  bandwidth, optimize the bottleneck before expanding every stage. Reject
  necessary-bound failures before expensive implementation.
- Limit: this is not a generic RTL mapper. Do not silently relax requested
  throughput. Passing an analytical bound still needs scheduling and measurement.

## PipeCNN: overlap, feedback, and numeric boundaries

- Source: `doonny/PipeCNN`, commit
  `392692b86747096e4324098deb38d8e93159809e`.
- Read: [conv_pipe.cl](https://github.com/doonny/PipeCNN/blob/392692b86747096e4324098deb38d8e93159809e/project_intel/device/conv_pipe.cl),
  [coreConv.cpp](https://github.com/doonny/PipeCNN/blob/392692b86747096e4324098deb38d8e93159809e/project_xilinx/device/coreConv.cpp)
  and README. Inspected source headers declare Apache-2.0.
- Observation: channel-connected memory/compute and ping-pong windows require
  preload, padding and tails. Pipelined partial accumulations distribute feedback
  and reduce at a defined numeric boundary.
- Adaptation: write ownership/access schedules for load/compute/store overlap;
  include prologue, drain and non-multiple tails. Independent accumulation contexts
  are legal only when final reduction preserves the numeric contract.
- Limit: compiler-specific HLS/OpenCL choices do not transfer verbatim to RTL.
  Preserve rounding/bias/clipping; floating-point reassociation can change results.
  This research did not reproduce PipeCNN's performance.

## ZipCPU: resource reuse and proof boundaries

- Source: `ZipCPU/zipcpu`, commit
  `42606d2d6ef55df313772232977621b2d72f0159`.
- Read: [slowmpy.v](https://github.com/ZipCPU/zipcpu/blob/42606d2d6ef55df313772232977621b2d72f0159/rtl/core/slowmpy.v).
  License: GPL-3.0-or-later in the header. No implementation is redistributed.
- Observation: multi-cycle multiplication trades throughput/latency for area,
  with busy/done and auxiliary-data alignment. Its formal section distinguishes
  signaling checks from complete multiplication arithmetic proof.
- Adaptation: consider time sharing when II permits it; state what each test or
  proof establishes instead of upgrading protocol checks to numeric proof.
- Limit: a reused multiplier and an II=1 pipeline serve different contracts;
  comparing their clock rates alone is misleading.

## Comparison with inspected official ROSS skills

Baseline: local AMD ROSS `2026.9.1`. This is document/artifact coverage, not a
controlled performance benchmark, nor a claim about the complete official suite.

| Need | Official coverage inspected | Community addition for handwritten RTL |
|---|---|---|
| Clock, II, latency and resources together | `hls-pipeline`: C/C++ regions, pragma feasibility, II and style | Explicit RTL contract, legal candidates, stage table and resource/bandwidth ledger |
| Decompose pipelines | `hls-pipe-decomp`: linear C++ dataflow and forwarding; its completion criteria leave II/timing verification to the user | Arithmetic/feedback/elastic boundaries plus independent tests and implementation iteration |
| Timing diagnosis | `vivado-timing-methodology-checks`: specialized checks/resolution with its own version requirements | Connect measured root causes to architecture changes while preserving contract and evidence |
| Executable artifacts | These entrypoints serve specialized workflows | Resource-bound helper, original signed MAC and buffer, stall/reset benches, report collector |
| Evidence scope | Specialized skills retain their domain authority | Analytical/simulation/synthesis/routed/board distinctions and a system-performance case study |

Keep the official lint, simulation, HLS and methodology skills available. This
skill joins an end-to-end RTL task; it does not replace their specialized depth.
Measured superiority would need the same model/tool/part, specifications, budgets
and seeds across repeated baseline/candidate tasks, comparing correctness, timing,
resources, latency/II, failures and human effort. That controlled comparison has
not been run for this package.

## Device-specific references

Use release/family-matched primary documentation:
[UG949](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology),
[UG906](https://docs.amd.com/r/en-US/ug906-vivado-design-analysis),
[UG901](https://docs.amd.com/r/en-US/ug901-vivado-synthesis),
[UG479](https://docs.amd.com/v/u/en-US/ug479_7Series_DSP48E1),
[UG579](https://docs.amd.com/r/en-US/ug579-ultrascale-dsp).
These are reference destinations. A portal's JavaScript shell is not evidence
that its substantive document was read; use installed documentation/search for
exact command options and device rules.
