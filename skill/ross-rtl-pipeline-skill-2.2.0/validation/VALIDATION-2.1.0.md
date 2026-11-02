# Validation - 2026-11-01, skill 2.1.0

## Behavioral checks actually executed

- Six resource-bound tests and six timing-evidence tests pass.
- XSim 2025.2 passes four default benches: MAC, buffer, signed tree and fork.
- Signed tree also passes (lanes,width) = (1,2), (2,15), (3,4), (8,12), (17,8),
  (32,15); default (5,8) covers a second odd topology. The reference is a flat,
  wide software sum. Tests cover extrema, tag/order, no-stall II and capture-stage
  latency, bubbles, long/random stalls and reset with pending tokens.
- Default tree: accepted 1051, delivered 1045, reset-flushed 6, stages 3, II=1.
- Fork: accepted 1033; each branch delivered 1032 and flushed one pending copy.
  Two resets occurred after partial delivery; 337 cycles exercised different
  branch progress. Per-branch cursors check data, tag, last, stability and ordering.
- Verilator 5.048 -Wall RTL lint passes all four defaults and the six tree variants.
- Deliberately zeroing the unpaired tree lane causes a numeric mismatch. Disabling
  fork branch retirement causes an unsolicited/duplicate-output failure. These
  are expected failing mutants; their runner receipts are correctly `failed`.
- Both pre-existing RTL files retain every original line comment. Ignoring added
  comments/whitespace, their RTL text is unchanged. This checks retention, not
  that every annotation is automatically true.

## Vivado characterization and its actual limits

Vivado 2025.2 synthesized, placed and routed an original registered-source/sink
benchmark around the five-input 8-bit tree on xc7z020clg484-1 at requested 200 MHz.
It has a full synthesized clock network, 0.15 ns uncertainty, output max/min delays
0.5/0 ns, automatic pin placement, and no assigned board IO standard.

| Report scope | Worst setup ns | Worst hold ns | Meaning |
|---|---:|---:|---|
| Entire benchmark, including output ports | -5.577 | +0.024 | Setup fails; not a timing pass |
| All internal register-to-register paths | +1.313 | +0.024 | This subset meets its 5 ns constraints; excludes IO |

Global pulse slack is +2.000 ns. Whole-design TNS is -59.755 ns with 11 failing
setup endpoints. The worst inspected internal setup path is startup-count control
to the sink reset, not an arithmetic add; reported net delay is about 75.4% of its
data delay. The output failures and NSTD-1/UCIO-1 critical warnings require an
actual board IO/clock context. ZPS7-1 also flags the missing integrated PS7.
Nothing was waived, no IO delay/frequency was relaxed, no bitstream was generated.

The top uses 56 LUT/130 FF; the tree hierarchy reports 52 LUT/83 FF; DSP/BRAM are
zero. Hierarchy counts can overlap after LUT combining. This is a distinct
characterization, not a repair or fair speed comparison against the earlier OOC
MAC/buffer benchmark. Their negative hold reports remain in `history-2.0.0`.

The timing helper rejects the real earlier +0.041 setup/-0.480 hold report and
the new full benchmark's negative setup. Its unit tests also reject missing
hold/pulse/constraint data, non-routed reports and rounded-zero failing counts.
A positive supported summary still returns `signoff=false` with reviews pending.

## Reproduce and inspect

From the package root, run `python -B validation/reproduce.py --build-dir
<EXTERNAL_BUILD_DIR> --vivado-bin <VIVADO_INSTALL>/bin --full-matrix` in a configured
environment. The script uses only Python's standard library and installed HDL
tools. See [the operation guide](../skills/vivado-rtl-pipeline-design/references/verification-and-mcp.md)
for individual backends and the explicit scratch Vivado characterization command.

Pinned source hashes, raw selected logs, report indices and report files are
included. Machine paths and host names are redacted in packaged copies only;
numeric results and warning contents remain. Build products, DCPs, downloaded
third-party RTL and proprietary tools/models are excluded. Upstream tests were
read, not run. These simulations are deterministic and not a formal proof.
