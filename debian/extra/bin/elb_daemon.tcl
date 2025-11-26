#!/usr/bin/env tclsh

# načti backend
source /etc/svxlink/events.d/99_backend_csv.tcl

# perioda v ms
set ::ELB::POLL_MS 5000

::ELB::trace "DAEMON start, POLL_MS=$::ELB::POLL_MS"

proc DaemonTick {} {
    ::ELB::trace "DAEMON tick"
    if {[catch { ::ELB::pull_and_refresh } err]} {
        ::ELB::trace "PULL error in DAEMON: $err"
    }
    after $::ELB::POLL_MS DaemonTick
}

DaemonTick
vwait forever
