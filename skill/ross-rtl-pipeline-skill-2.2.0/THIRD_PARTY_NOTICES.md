# Attribution and research boundaries

This is a community ROSS-compatible addition, not an AMD official release.
The directory/frontmatter/plugin layout follows AMD ROSS conventions; the AMD MIT
notice is retained in LICENSE. New skill text, helpers, RTL and benches are MIT.

The following projects were read as engineering references. Their source code is
not redistributed in this package; pinned links and observations are in
[research notes](skills/vivado-rtl-pipeline-design/references/research-notes.md).

| Project | Observed license |
|---|---|
| alexforencich/verilog-axis | MIT, COPYING |
| risclite/verilog-divider | Apache-2.0 in divfunc.v header; root LICENSE unavailable |
| Xilinx/finn | BSD-3-Clause, LICENSE.txt |
| doonny/PipeCNN | Apache-2.0 in inspected source headers |
| ZipCPU/zipcpu slowmpy.v | GPL-3.0-or-later; method observations only, no code copied |

No Vivado/ROSS EXE, VSIX, device database, private TinyYOLO model or firmware is
included. Vivado-generated reports retain their tool copyright headers. Report
paths and host identifiers are redacted; numeric results are unchanged.

## Further research in 2.1.0

| Project | Observed license |
|---|---|
| pulp-platform/common_cells | Solderpad Hardware License 0.51 |
| lowRISC/ibex | Apache-2.0 |
| hdl-modules/hdl-modules | BSD-3-Clause |
| alexforencich/verilog-axi | MIT |

These implementations/test sources were inspected, not redistributed. The new
reduction, buffered fork, benchmarks and tests are original community additions.
Pinned links, observations, applicability and limits are in
[the additional source studies](skills/vivado-rtl-pipeline-design/references/case-studies-2026-11-01.md).

## Community research in 2.2.0

| Project | License observed from the actual source/notice |
|---|---|
| ZipCPU/wb2axip skidbuffer.v | Apache-2.0 in the inspected file header |
| YosysHQ/picorv32 | ISC, COPYING |
| WangXuan95/FPGA-FixedPoint | GPL-3.0, LICENSE; method observations only |
| AmeerAbdelhadi/Multiported-RAM | BSD-3-Clause, UBC notice in LICENSE |

The source implementations, testbenches and paper are not redistributed. New RTL
and its independent tests are original MIT additions. Source provenance includes
download hashes; it is not evidence of running upstream regressions or proofs.
See [the community source studies](skills/vivado-rtl-pipeline-design/references/community-case-studies.md).
