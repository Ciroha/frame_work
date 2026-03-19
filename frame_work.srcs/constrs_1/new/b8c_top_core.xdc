# ========================================
# Clock
# ========================================
create_clock -name clk -period 4.000 -waveform {0.000 2.000} [get_ports clk]

# ========================================
# Async reset
# ========================================
set_false_path -from [get_ports rst_n]

# ========================================
# Optional guardband
# Enable only after first clean implementation run
# ========================================
# set_clock_uncertainty -setup 0.050 [get_clocks clk]

# ========================================
# IO timing placeholders
# ========================================
# TODO: add set_input_delay after external timing is known
# TODO: add set_output_delay after external timing is known
