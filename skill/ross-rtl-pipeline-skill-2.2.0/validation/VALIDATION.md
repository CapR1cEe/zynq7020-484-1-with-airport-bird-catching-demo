# Validation — 2026-11-01, skill 2.2.0

## New checks actually executed

- 12 Python tests: six resource-bound and six timing-evidence checks.
- Original rounding/saturation pipeline passes XSim 2025.2 and Verilator 5.048
  `-Wall` RTL lint for (input width, output width, fractional bits):
  (8,4,3), (2,2,0), (3,2,1), (8,4,0), (8,8,0), (9,3,8), (10,4,3), (12,6,5).
- Each configuration enumerates every input bit pattern before randomized traffic:
  6,412 numeric patterns across the eight configurations. The independent oracle
  uses magnitude division/remainder; RTL uses signed floor and guard/sticky/parity.
  These are finite simulation traces, not an exhaustive control-state/formal proof.
- Each case checks value, saturation overflow, tag and last, two capture stages,
  continuous II=1, long/random stalls, and reset while two accepted tokens remain.
  Default: 1,294 accepted, 1,292 delivered, 2 flushed, 185 stalled-output checks.
- Two deliberately wrong implementations are rejected: changing ties to round up,
  and clearing saturation overflow. Mutant runner receipts correctly say `failed`;
  the mutation checker passes only on the observed oracle mismatch.
- Existing four RTL files and four benches are byte-for-byte unchanged from 2.1.0.
  The new module keeps explicit stage boundaries and meaningful Chinese/English
  annotations. Retention does not automatically prove a comment's truth/readability.

Selected logs and receipts are in `community-2.2.0`. Final package extraction,
default-example rerun and archive integrity status are in [delivery_check.json](delivery_check.json).

## Source research and what was not run

The new [community case studies](../skills/vivado-rtl-pipeline-design/references/community-case-studies.md)
inspect four pinned repositories, making thirteen project sources in total.
Implementation/test sections and actual license notices were inspected; hashes
are in [research provenance](research_sources_community_2.2.0.json). Upstream
regressions, formal engines and published performance were not reproduced.
The multiport RAM case is a scoped wrapper/collision-test study, not a full audit
of the byte-enable dependencies or the paper. Third-party RTL is not shipped.

No synthesis, place/route, Fmax measurement, formal proof or board test was run
for the new rounding module. Its simulation period and passing II say nothing
about an implementation frequency or a DSP/BRAM/LUT/FF count.

## Prior measurements remain scoped and incomplete

[The retained 2.1.0 record](VALIDATION-2.1.0.md) and [baseline evidence](evidence-2.1.0.json)
preserve tree/fork matrix, original mutation checks and implementation reports.
For its 200 MHz xc7z020clg484-1 benchmark, entire-design WNS is -5.577 ns and WHS
is +0.024 ns. Internal register-to-register setup is +1.313 ns, but excludes IO.
External output setup failures and NSTD-1/UCIO-1 remain; no complete 200 MHz
system signoff is claimed. Earlier 2.0.0 OOC negative hold evidence is retained.
Those values were not rerouted or relabeled as a new 2.2.0 speed result.

## Reproduce

From the package root: `python -B validation/reproduce.py --build-dir
<EXTERNAL_BUILD_DIR> --vivado-bin <VIVADO_INSTALL>/bin --full-matrix`.
This runs the 12 Python tests, all five default benches, and optionally six tree
and seven rounding boundary configurations. Set up a supported toolchain first;
keep output outside the package. For lint choose `--mode lint --backend verilator
--verilator <EXECUTABLE>`. See [the operation guide](../skills/vivado-rtl-pipeline-design/references/verification-and-mcp.md).

`python -B validation/verify_package.py` checks hashes, paths and local links.
Optional `--archive <ZIP>` checks ZIP CRC/content against the unpacked package.
Machine paths are redacted in distributed logs; measurements and warnings remain.
