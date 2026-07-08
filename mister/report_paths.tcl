project_open Hyprduel
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 100 -detail path_only \
    -file paths_setup.txt
project_close
