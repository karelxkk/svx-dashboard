if {![info exists script_path]} { set script_path /usr/share/svxlink }
source /usr/share/svxlink/events.tcl
set files [glob -nocomplain -types f -directory /etc/svxlink/events.d *.tcl]
if {[llength $files]} { foreach f [lsort $files] { source $f } }
