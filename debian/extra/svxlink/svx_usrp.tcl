# svx_usrp.tcl — UsrpLogic odděleně. Řádky ≤100 znaků.

# Tento soubor drží pouze obálky pro UsrpLogic události.
# Načti společně se svx_backend.tcl v events.tcl pomocí 'source'.

if {![namespace exists ::UsrpLogic]} {namespace eval ::UsrpLogic {}}


# Funkce: Wrapper pro UsrpLogic::transmission_start, zachová původní chování.
# Parametry: args (původní argumenty události)
if {[llength [info procs ::UsrpLogic::transmission_start]]} {
  rename ::UsrpLogic::transmission_start ::SVX::__orig_UL_tx_start
}
proc ::UsrpLogic::transmission_start {args} {
  if {[llength [info procs ::SVX::__orig_UL_tx_start]]} {
    ::SVX::__orig_UL_tx_start {*}$args
  }
  if {[llength [info procs ::SVX::usrp_tx_start]]} {
    ::SVX::usrp_tx_start {*}$args
  }
}


# Funkce: Wrapper pro UsrpLogic::transmission_stop, zachová původní chování.
# Parametry: args (původní argumenty události)
if {[llength [info procs ::UsrpLogic::transmission_stop]]} {
  rename ::UsrpLogic::transmission_stop ::SVX::__orig_UL_tx_stop
}
proc ::UsrpLogic::transmission_stop {args} {
  if {[llength [info procs ::SVX::__orig_UL_tx_stop]]} {
    ::SVX::__orig_UL_tx_stop {*}$args
  }
  if {[llength [info procs ::SVX::usrp_tx_stop]]} {
    ::SVX::usrp_tx_stop {*}$args
  }
}


# Funkce: Wrapper pro UsrpLogic::talker_start, zachová původní chování.
# Parametry: args (původní argumenty události)
if {[llength [info procs ::UsrpLogic::talker_start]]} {
  rename ::UsrpLogic::talker_start ::SVX::__orig_UL_talker_start
}
proc ::UsrpLogic::talker_start {args} {
  if {[llength [info procs ::SVX::__orig_UL_talker_start]]} {
    ::SVX::__orig_UL_talker_start {*}$args
  }
  if {[llength [info procs ::SVX::usrp_talker_start]]} {
    ::SVX::usrp_talker_start {*}$args
  }
}

# Funkce: Wrapper pro UsrpLogic::talker_stop, zachová původní chování.
# Parametry: args (původní argumenty události)
if {[llength [info procs ::UsrpLogic::talker_stop]]} {
  rename ::UsrpLogic::talker_stop ::SVX::__orig_UL_talker_stop
}
proc ::UsrpLogic::talker_stop {args} {
  if {[llength [info procs ::SVX::__orig_UL_talker_stop]]} {
    ::SVX::__orig_UL_talker_stop {*}$args
  }
  if {[llength [info procs ::SVX::usrp_talker_stop]]} {
    ::SVX::usrp_talker_stop {*}$args
  }
}
