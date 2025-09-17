set script_path /usr/share/svxlink/events.tcl
source /usr/share/svxlink/events.tcl
# Set the path to the main events script
set script_path /usr/share/svxlink/events.tcl

# Source the main events script
source $script_path

# Source all additional event scripts from the events.d directory
foreach f [lsort [glob -nocomplain /etc/svxlink/events.d/*.tcl]] {
    sourceTcl $f
}
