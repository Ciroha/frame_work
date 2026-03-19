open_project frame_work.xpr
update_compile_order -fileset sources_1

reset_run impl_1
launch_runs impl_1 -to_step route_design
wait_on_run impl_1

open_run impl_1
report_timing_summary -delay_type max -max_paths 10 -file timing_summary.rpt
report_timing -max_paths 10 -nworst 10 -file timing_worst.rpt
report_utilization -file utilization.rpt
report_drc -file drc.rpt
report_exceptions -file exceptions.rpt
report_clock_interaction -file clock_interaction.rpt

puts "IMPL_DIRECT_DONE"
close_project
exit
