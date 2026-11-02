# Warning classification policy

Project RTL width, memory inference and obsolete-register warnings are repaired in source. Explicit audited diagnostics remain visible at INFO. No severity-wide suppression is used. Timing, DRC, CDC and truncation messages retain their original severity.

Vendor PS/reset outputs are intentionally unused. SmartConnect and XPM parameterized interfaces prune unused ports.

The generated SmartConnect clk_map aresetn_out has no consumer: parent net aresetn_net occurs only in its declaration and output connection. Functional M00_ARESETN and S00_ARESETN have reset synchronizer drivers.

Named project registers removed by synthesis are duplicates of common read addresses, data or replicated requant tags. Exact messages and IDs appear in scripts/message_policy.tcl. New diagnostics remain visible.

Additional audited messages: XPM src_clk is inactive in this selected CDC parameterization; SmartConnect sc_node zero-width sideband placeholders are unused. These five exact messages remain visible at INFO. Installed catalog warnings for unrelated FPGA families and an empty optional board-part property also remain visible at INFO; this design selects xc7z020clg484-1 directly and does not use a board preset. The rules name the exact installed catalog entries and paths; new catalog failures retain their original severity.

The two exact BD 41-1306 messages name HP0 RDISSUECAP1_EN and WRISSUECAP1_EN. These optional FIFO_CTRL pins are intentionally tied to reset_zero_dout; the actual S_AXI_HP0 AXI interface remains connected. Both notices remain visible at INFO.

Actual source/configuration fixes include removing the unsupported Tcl `if` from reset_power_activity.xdc (linear XDC commands now annotate the known operating reset nets), disabling automatic incremental synthesis without a reference checkpoint, and removing a redundant Tcl export that warned about already packaged local sources. The .xpr plus build_vivado.ps1/build_vivado.tcl are the supported project entry points. Reset activity is an estimation assumption, not a hardware constant or a timing exception.

Only current build phase logs and current synthesis/implementation run logs are counted by reports/warning_audit.json. Historical baseline diagnostics are not counted as final build messages. Timing/DRC/CDC severities are never reclassified by these rules.

The remaining exact Physopt 32-894 message names proc_sys_reset_0/peripheral_aresetn[0]. Inspection of the implemented checkpoint constraints identifies the vendor XPM_CDC_ASYNC_RST scoped `set_false_path -through ... src_arst` constraints. This is a timing-optimization limitation: physical optimization cannot replicate this reset net through the constrained hierarchy. Its original WARNING severity and all vendor reset/CDC exceptions are retained. It is counted separately with the remaining timing diagnostics, not reclassified to INFO. `reports/reset_constraint_audit.json` records the exact message and checkpoint constraint scopes; other Physopt messages are not exempted.

The implementation pre-opt hook `scripts/cleanup_unused_reset.tcl` removes only reset flip-flops with exactly one output driver, zero leaf sinks and no top-level port. It checks the primitive type, temporarily releases input-net protection to disconnect the unused cell, and restores surviving input-net protection. The normal implementation then performs optimization, placement and routing. The audited per-cell proof is `reports/reset_cleanup.tsv`; no DRC severity is changed.

The audit also inspects the final DRC, methodology, CDC, route-status and bus-skew reports. Report-only violations cannot be hidden by a clean console log.

The cleanup and timing-optimization hooks are registered in the project's utils_1 fileset, so normal Vivado archive operations include them. The current project-opening check requires utility-file membership. The final build resets the implementation and uses launch_runs -scripts_only to capture the registered hooks in the native run files. Because Windows Script Host is unavailable on this host, scripts/run_implementation_direct.ps1 executes the generated full implementation Tcl and writes process lifecycle markers only after checking the real tool exit code, fresh bitstream output and unchanged frozen sources. No run success or NEEDS_REFRESH property is forced. The process receipt is reports/native_implementation_process.json. Historical failed build and recovery scratch is omitted from the final release.

Implementation temporarily applies +0.250 ns setup uncertainty to drive optimization. Native intermediate reports can issue Timing 38-282 before the post-route hook restores this additional budget to exactly zero. These original Critical Warning messages remain visible and are recorded separately in reports/warning_audit.json. They are accepted as intermediate timing diagnostics only when they precede the recorded budget restoration and the same native run subsequently passes the final timing gate. Final report violations and any later Critical Warning remain audit failures.

Clock connectivity warnings have no exemption. The 2026-10-28 build resynthesizes the changed dot-product RTL and preserves three BUFGs, including a direct MMCM CLKOUT0 to PL BUFG connection. assert_clock_topology.tcl verifies primitive connectivity before implementation, after routing, before bitgen and when opening the relocated project. No clock DRC is suppressed or downgraded. Current final DRC and non-timing Warning counts must be zero.
