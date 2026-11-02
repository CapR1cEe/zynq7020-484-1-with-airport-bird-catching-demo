# Verification and ROSS/Vivado operation

## Find the available execution path

Discover the client's actual tool schemas. Names can be prefixed by the host;
do not invent arguments or require a particular server registration name.

1. If Vivado MCP is available, list sessions first. Reuse the intended live
   session; verify the loaded project/design, part and tool version before any
   mutation. Starting a new general session is appropriate only when needed.
2. Execute commands sequentially within one session. Wait for a running command
   to complete using the actual status mechanism before executing another one.
   Independent report reads/session listing may be parallelized if supported.
3. If MCP is absent, use an installed Vivado CLI or existing reports. With neither,
   deliver RTL/planning/simulation evidence and state that mapped resources and
   implementation frequency remain unmeasured. MCP connectivity alone does not
   prove Vivado or a suitable device/license is installed.

Typical operations are session listing, start/connect/status, Tcl execution and
log retrieval. Treat these as capabilities, not a fixed API declaration. Never
stop someone else's session or open a different project over unsaved work.
Do not package the user's EXE/VSIX, machine paths, credentials or MCP secrets.

## Run the shipped examples

From the skill directory (Python 3.10+; standard library only):

```text
python scripts/resource_plan.py assets/design-contract.example.json --output plan.json
python scripts/run_examples.py --mode lint --build-dir <outside-the-skill-directory>
python scripts/run_examples.py --mode simulate --backend verilator --build-dir <directory>
python scripts/run_examples.py --mode simulate --backend iverilog --build-dir <directory>
python scripts/run_examples.py --mode simulate --backend xsim --vivado-bin <Vivado-installation>/bin --build-dir <directory>
```

Select a single bench with `--example mac|elastic|tree|fork|round`; the MAC bench
supports `--mac-width 2..15`. The tree bench supports `--tree-inputs 1..32` and
`--tree-width 2..15`. These are bench limits, not claims of complete coverage.
Simulation and Verilator/Icarus lint apply those selected parameters; XSim's lint
mode only parses the RTL. Only claim configurations actually executed.

The rounding bench accepts `--round-in-width 2..12`, `--round-out-width 2..input-width`
and `--round-fraction-bits 0..input-width-1` (defaults 8, 4, 3). It exhaustively
enumerates every input bit pattern for the selected configuration, checks against
a sign/magnitude integer oracle, then adds stalls/reset/metadata checks. This is
an exhaustive numeric input set for that configuration inside bounded simulation,
not a proof for all control traces or arbitrary widths.

The runner uses argument lists, explicit top modules, bounded command timeouts and
separate build directories. It reports missing tools as failures; lint is not
simulation. Verilator binary simulation also needs its supported C++ toolchain
and make. Use a consistent MSYS2/UCRT shell/PATH on Windows; mixed compiler,
linker, make and standard libraries can fail after lint succeeds. Preserve the
actual failure log instead of claiming the tests passed.

The MAC bench uses a wider independent arithmetic model and scoreboards accepted
inputs; the elastic bench stores expected tokens separately from DUT storage.
Both drive at falling edges and sample pre-update signals on rising edges. They
cover continuous traffic, source bubbles, long/deterministic random stalls,
reset with accepted tokens pending, data/tag/last alignment as applicable, and
assert that a stalled output cannot withdraw valid. Their no-stall checks use
**capture stages**: a token accepted at edge n is observed transferable at edge
n+L for an L-stage module. Continuous II=1 is measured explicitly.

The tree uses a flat wide reference sum, including signed extrema and an odd
unpaired lane. The fork has an independent cursor for each output, asymmetric
long/random stalls, explicit continuous II=1 checks, and reset after only one
branch has received a copy. Reset accounting is per branch; delivered copies
cannot be revoked. Stalled data/tag/last and valid are checked together.

These benches cover the supplied configurations, not every legal parameter or
arbitrary protocol environment. Add width configurations and application-specific
numeric/reset/packet cases when adapting a module. Formal proofs and equivalence
are useful where supported; bounded simulation is not a formal proof.

When a formal run is used, record the actual mode/result, parameters, reset/input
assumptions, properties, engine, bound/induction scope and covers. A cover reaching
stall/recovery does not establish no-loss safety. At integration, establish each
block's input assumptions from its producer instead of constraining away failures.
Compare different-latency implementations by accepted transaction identity and
completion, rather than comparing outputs on unrelated cycles. See the
[community formal and multiplier cases](community-case-studies.md).

## Collect implementation reports

After opening the intended synthesized or routed design in Vivado:

```tcl
source {/path/to/skills/vivado-rtl-pipeline-design/scripts/collect_reports.tcl}
ross_collect_reports {/path/to/results/revision-name}
```

Review `report_index.tsv`, then the reports themselves. The collector fails early
outside Vivado/without an open design and records optional report failures. The
script does not create clocks, synthesize, implement, program hardware or alter
constraints. Preserve the baseline's project flow and apply a new run only when
needed by the requested design task.

Use `python scripts/assess_timing.py <timing_summary.rpt> --context ooc` to extract
min/max summary metrics and missing-constraint checks. Exit 1 means a measured
violation, 2 means incomplete evidence; 0 means only that this supported report
summary passed and further review remains. The helper always sets `signoff=false`.
`--context integrated` is a caller assertion, not verification of a board/XDC.
Unknown layouts or absent hold/pulse/check_timing data remain incomplete.

For a dedicated scratch characterization, `scripts/characterize_tree.tcl` runs
the original tree inside a registered source/sink wrapper using a full top-level
clock network. Invoke it in a separate batch process with arguments `SKILL_DIR
OUTPUT_DIR PART MHZ`. It does synthesize/place/route; inspect the script's explicit
uncertainty/output-delay assumptions first. The wrapper's automatic IO placement
is not a board pin plan. This is a different benchmark context from an OOC core:
do not claim it repairs an earlier OOC failure or signs off the user's system.

## Record evidence without upgrading its status

Use `assets/evidence.example.json` as an editable report shape. Keep absent metrics
null with a reason and report path; do not use zero to mean not measured. Retain
functional result, measured no-stall II and stage count, peak buffered tokens,
synthesis resources and routed timing separately. An analytical resource count,
requested MHz, simulation clock period or another project's Fmax is not a measured
hardware result. Record an iteration's changed hypothesis and its actual outcome.
