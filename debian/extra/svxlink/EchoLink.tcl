#!/usr/bin/env tclsh
# /etc/svxlink/events.d/EchoLink.tcl
# Role: předává EchoLink události do backendu ::SVX. Bez fallbacků. Chyby hlásí do svxlink.log.

namespace eval ::EchoLink {}

# --- log helpers -----------------------------------------------------------
proc ::EchoLink::_err {msg}  { puts stderr "EchoLink.tcl ERROR: $msg" }
proc ::EchoLink::_info {msg} { puts stderr "EchoLink.tcl INFO:  $msg" }

# --- connect/disconnect ----------------------------------------------------
proc ::EchoLink::remote_connected {call} {
  if {$call eq ""} { ::EchoLink::_err "remote_connected: empty CALL"; return }
  if {[info commands ::SVX::set_connected] eq ""} { ::EchoLink::_err "SVX::set_connected not available"; return }
  catch { ::SVX::set_connected $call 1 }
  catch { ::SVX::write_status }
}

proc ::EchoLink::remote_disconnected {call} {
  if {$call eq ""} { ::EchoLink::_err "remote_disconnected: empty CALL"; return }
  if {[info commands ::SVX::set_connected] eq ""} { ::EchoLink::_err "SVX::set_connected not available"; return }
  catch { ::SVX::set_connected $call 0 }
  catch { ::SVX::write_status }
}

proc ::EchoLink::disconnected {call} { ::EchoLink::remote_disconnected $call }

# --- RX activity -> talk start/stop ---------------------------------------
proc ::EchoLink::is_receiving {state {call ""}} {
  if {![string is integer -strict $state]} { ::EchoLink::_err "is_receiving: invalid state '$state'"; return }
  if {$call eq ""} { ::EchoLink::_err "is_receiving: empty CALL"; return }
  if {[info commands ::SVX::start_talk] eq "" || [info commands ::SVX::stop_talk] eq ""} {
    ::EchoLink::_err "SVX::start_talk/stop_talk not available"; return
  }
  set tg 0
  if {[info exists ::SVX::CURRENT_TG]} { set tg $::SVX::CURRENT_TG }
  if {$state} {
    catch { ::SVX::start_talk $call $tg }
  } else {
    catch { ::SVX::stop_talk  $call $tg }
  }
}

# --- Optional: list of connected clients ----------------------------------
if {[info procs ::EchoLink::client_list_changed] eq ""} {
  proc ::EchoLink::client_list_changed {clients} {
    if {[info procs ::SVX::sync_el_clients] eq ""} {
      ::EchoLink::_err "SVX::sync_el_clients not available"; return
    }
    catch { ::SVX::sync_el_clients $clients }
  }
}
