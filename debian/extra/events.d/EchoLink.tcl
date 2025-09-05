# /etc/svxlink/events.d/EchoLink.tcl
# EchoLink: POUZE předává události do backendu ::SVX (žádná vlastní paměť, žádné seznamy)
# - remote_connected CALL     -> ::SVX::set_connected CALL 1  (+ uloží ::SVX::EL_LAST)
# - remote_disconnected CALL  -> ::SVX::set_connected CALL 0  (+ smaže ::SVX::EL_LAST)
# - is_receiving STATE ?CALL? -> ::SVX::start_talk/stop_talk s TG (viz níže)
# Ostatní události neřešíme.

namespace eval EchoLink {
  # --- Debug wrappers (volitelné) ---
  proc _dbg {msg} {
    if {[info commands ::SVX::dbg] ne ""} { ::SVX::dbg "EL: $msg" } else { puts "SVX/EL DBG: $msg" }
  }
  proc _enter {ctx} { if {[info commands ::SVX::dbgEnter] ne ""} { ::SVX::dbgEnter $ctx } }
  proc _leave {ctx} { if {[info commands ::SVX::dbgLeave] ne ""} { ::SVX::dbgLeave $ctx } }

  # --- Aktivace/deaktivace modulu (jen log) ---
  proc activating_module {}   { _enter "EchoLink::activating_module";   _dbg "activating_module";   _leave "EchoLink::activating_module" }
  proc deactivating_module {} { _enter "EchoLink::deactivating_module"; _dbg "deactivating_module"; _leave "EchoLink::deactivating_module" }

  # --- Připojení/odpojení vzdálené stanice ---
  proc remote_connected {call} {
    _enter "EchoLink::remote_connected $call"
    if {[info commands ::SVX::set_connected] ne ""} {
      catch { ::SVX::set_connected $call 1 }
      catch { set ::SVX::EL_LAST $call }
      catch { ::SVX::write_status }
    } else { _dbg "backend set_connected missing" }
    _leave "EchoLink::remote_connected $call"
  }
  proc remote_disconnected {call} {
    _enter "EchoLink::remote_disconnected $call"
    if {[info commands ::SVX::set_connected] ne ""} {
      catch { ::SVX::set_connected $call 0 }
      catch { set ::SVX::EL_LAST "" }
      catch { ::SVX::write_status }
    } else { _dbg "backend set_connected missing" }
    _leave "EchoLink::remote_disconnected $call"
  }
  proc disconnected {call} { remote_disconnected $call }

# STATE: 1 = talk_start, 0 = talk_stop. CALL může být prázdné u některých buildů.
proc is_receiving {state {call ""}} {
  EchoLink::_enter "EchoLink::is_receiving $state $call"
  set tg [expr {[info exists ::SVX::CURRENT_TG] ? $::SVX::CURRENT_TG : 0}]
  if {$state} {
    # Preferuj sjednocené backend handlery (řeší status + historii)
    if {[info commands ::ReflectorLogic::talker_start] ne ""} {
      catch { ::ReflectorLogic::talker_start $call $tg }
    } elseif {[info commands ::SVX::start_talk] ne ""} {
      catch { ::SVX::start_talk $call $tg }
    }
  } else {
    if {[info commands ::ReflectorLogic::talker_stop] ne ""} {
      catch { ::ReflectorLogic::talker_stop $call $tg }
    } elseif {[info commands ::SVX::stop_talk] ne ""} {
      catch { ::SVX::stop_talk  $call $tg }
    }
  }
  EchoLink::_leave "EchoLink::is_receiving $state $call"
}

  # ZÁMĚRNĚ NEIMPLEMENTUJEME: client_list_changed, remote_greeting, info_received
}
