# TinyYOLO: retain the lessons and measurement boundaries

## Verified local release identity

The selected local release, dated **2026-10-25**, is build `0x47325502`, **96x96
input**, PL **240 MHz**, 24 MAC lanes, and all 24 convolution layers in PL on the
Zynq-7020 project. Status: `BOARD_VERIFIED_FPS_BELOW_TARGET`. This supersedes older
notes describing a 192x192 candidate as the final release.

Source documents reread for this package on 2026-10-31: `STATUS.md`,
`board_test_final.md`, and `24_layer_validation_final.md` in the local final-project
archive. This summarizes recorded evidence; no new board run was performed. The
standalone skill does not require or distribute the private model, firmware,
bitstream, board logs or training data.

| Recorded item | Selected-release evidence | Boundary |
|---|---|---|
| Complete camera detection | 120 frames; 2.678770231 FPS; 373.305627 ms/frame | Processing interval 44.796675209 s; startup 801.581173 ms separately; image-file saving excluded |
| Numeric validation | 150 step hashes and 72 convolution hashes matched independent host golden; eight production runs passed | Documented configuration and tested inputs, not labelled accuracy evaluation |
| Timing | Setup slack +0.007 ns; hold slack +0.015 ns | Archived selected-release evidence, not another build or constraints |
| DSP | 216/220 | Little remaining DSP capacity; LUT/FF headroom alone does not mean more MACs fit |
| Application goals | 5 FPS and 15 FPS not achieved | Respectively 200 and 66.667 ms/frame |
| Not qualified | Labelled mAP, long-duration thermal/power behavior, successful target tracking, physical pan/tilt acceptance | RTL/hash checks do not establish these |

The same comparison run measured 96x96 build 5502 at 2.671215 FPS and 192x192 build
5503 at 1.389626 FPS. The final 2.678770231 result came from a later selected-build
120-frame run after environment repair/reboot. These are separate measurements.
Different input sizes have no equal-accuracy comparison, so no equal-accuracy
speedup is claimed. Candidate 550a had setup slack -0.550 ns and was excluded
without board deployment.

An earlier asynchronous capture/tracking loop ran about 12.46 iterations/s while
complete detection ran about 2.52 FPS, with zero valid tracking updates. Do not
call that 12.46 detection FPS or successful tracking. Final mapped DMA input and
independent shared output still require conversion/resize and an output copy;
it is not end-to-end zero-copy. The best final cache result used CPU RAM lookup,
not an OCM performance measurement.

## Portable engineering lessons

1. **Preserve numeric and interface contracts.** Keep signedness, observable
   reduction order, rounding and saturation. DSP packing needs sign/cross-term
   reasoning and extrema tests; another workload may not satisfy its assumptions.
2. **Timing can be a control/wiring problem.** Historical iterations found long
   state/handshake paths at the memory interface. Read routed endpoints, fanout
   and net delay before optimizing arithmetic again.
3. **A register cut transforms a token.** Operands, partial sums, valid, tags,
   packet markers and enables advance together. Delayed ready needs storage for
   in-flight traffic. Test long stalls and reset while tokens are pending.
4. **Resource allocation includes memory and physical costs.** More parallel MACs
   require ports and bandwidth. A larger cache helps only when access/miss counters
   improve; it can worsen routing/timing despite fitting BRAM.
5. **Separate local from system throughput.** Measure PL cycles, memory waits,
   software conversion, transfer boundaries and complete frames separately. A
   higher clock or II=1 block does not guarantee better application latency.
6. **Software correctness is accelerator correctness.** The documented project
   repaired bounded kernel division, DMA input/output lifetime overlap, and
   ordering before acknowledgements. Correct arithmetic cannot fix stale DMA data,
   missing barriers or unsafe buffer reuse.
7. **Separate selected releases from rejected experiments.** Retain source/report
   hashes, constraints and measurement scope. Earlier frequency/accuracy proxies
   are not selected-release board evidence.

Historical carry splits, DSP partitions and cache sweeps motivated these methods.
Their original per-iteration reports were not reread for this package, so old
numeric details are not promoted to new benchmark results. Do not adopt this
case's device, dimensions, clock, packing or FPS as universal defaults.

## What the generic package preserves

Contract -> finite resource/schedule candidates -> readable, bit-exact RTL ->
independent backpressure/reset tests -> mapped resources -> routed diagnosis ->
system measurement. Public-source adaptations are in
[research-notes.md](research-notes.md). The supplied MAC/buffer validation is
recorded separately from this historical case.
