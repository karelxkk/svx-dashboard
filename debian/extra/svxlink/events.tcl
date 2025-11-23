# /etc/svxlink/events.tcl
set script_path /usr/share/svxlink/events.tcl
source $script_path

# Source all additional event scripts from the events.d directory
foreach f [lsort [glob -nocomplain /etc/svxlink/events.d/*.tcl]] {
    sourceTcl $f
}

foreach f [lsort [glob -nocomplain /usr/share/svxlink/events.d/*.tcl]] {
    sourceTcl $f
}
foreach f [lsort [glob -nocomplain /usr/share/svxlink/events.d/local/*.tcl]] {
    sourceTcl $f
}
