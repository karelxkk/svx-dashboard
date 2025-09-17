# svx_serial.tcl — oddělení SimplexReflector/SerialLogic. Řádky ≤100 znaků.

# Tento soubor izoluje obálky pro SimplexReflector a SerialLogic.
# Uživatelé bez těchto logik nejsou dotčeni. Načítej přes 'source'.

if {![namespace exists ::SimplexReflector]} {namespace eval ::SimplexReflector {}}
if {![namespace exists ::SerialLogic]} {namespace eval ::SerialLogic {}}


# Funkce: Wrapper pro SimplexReflector::reflector_connection_status_update.
# Parametry: state (0/1). Výchozí chování zachová, jinak no‑op.
if {[llength [info procs ::SimplexReflector::reflector_connection_status_update]]} {
  rename ::SimplexReflector::reflector_connection_status_update ::SVX::__orig_SR_rcsu
}
proc ::SimplexReflector::reflector_connection_status_update {state} {
  if {[llength [info procs ::SVX::__orig_SR_rcsu]]} {
    ::SVX::__orig_SR_rcsu $state
  }
}


# Funkce: Wrapper pro SimplexReflector::talker_start. Není nutné mapovat do backendu.
# Parametry: args (původní argumenty události)
if {[llength [info procs ::SimplexReflector::talker_start]]} {
  rename ::SimplexReflector::talker_start ::SVX::__orig_SR_talker_start
}
proc ::SimplexReflector::talker_start {args} {
  if {[llength [info procs ::SVX::__orig_SR_talker_start]]} {
    ::SVX::__orig_SR_talker_start {*}$args
  }
}


# Funkce: Wrapper pro SimplexReflector::talker_stop. Není nutné mapovat do backendu.
# Parametry: args (původní argumenty události)
if {[llength [info procs ::SimplexReflector::talker_stop]]} {
  rename ::SimplexReflector::talker_stop ::SVX::__orig_SR_talker_stop
}
proc ::SimplexReflector::talker_stop {args} {
  if {[llength [info procs ::SVX::__orig_SR_talker_stop]]} {
    ::SVX::__orig_SR_talker_stop {*}$args
  }
}


# Funkce: Wrapper pro SerialLogic::transmission_start. Pouze řetězí.
# Parametry: args (původní argumenty události)
if {[llength [info procs ::SerialLogic::transmission_start]]} {
  rename ::SerialLogic::transmission_start ::SVX::__orig_SL_tx_start
}
proc ::SerialLogic::transmission_start {args} {
  if {[llength [info procs ::SVX::__orig_SL_tx_start]]} {
    ::SVX::__orig_SL_tx_start {*}$args
  }
}


# Funkce: Wrapper pro SerialLogic::transmission_stop. Pouze řetězí.
# Parametry: args (původní argumenty události)
if {[llength [info procs ::SerialLogic::transmission_stop]]} {
  rename ::SerialLogic::transmission_stop ::SVX::__orig_SL_tx_stop
}
proc ::SerialLogic::transmission_stop {args} {
  if {[llength [info procs ::SVX::__orig_SL_tx_stop]]} {
    ::SVX::__orig_SL_tx_stop {*}$args
  }
}

# --- SimplexLogic minute tick silencer + SelCall shim -----------------------

# Tichý režim pro SimplexLogic a doplnění chybějícího SelCall shim.
# Uživatel bez Simplex/Serial není ovlivněn.

if {![namespace exists ::SimplexLogic]} {namespace eval ::SimplexLogic {}}
if {![namespace exists ::SelCall]} {namespace eval ::SelCall {}}

# Funkce: SelCall shim volaný některými stock skripty každou minutu.
# Parametry: args (ignorováno)
if {![llength [info procs ::SelCall::checkPeriodicIdentify]]} {
  proc ::SelCall::checkPeriodicIdentify {args} {}
}

# Funkce: SimplexLogic::every_minute — potlačí periodické volání.
# Parametry: žádné
if {[llength [info procs ::SimplexLogic::every_minute]]} {
  rename ::SimplexLogic::every_minute ::SVX::__orig_SX_every_minute
}
proc ::SimplexLogic::every_minute {} {}
