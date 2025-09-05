# svx_backend.tcl — čistě událostní backend pro SvxLink/SvxReflector (/status jen při bootstrapu; bez *.node)
# Stav se drží v paměti (dict ::SVX::NODES) a zapisuje do RAM_DIR:
#   STATUS  = /dev/shm/svx/status.json
#   HISTORY = /dev/shm/svx/history.csv (posledních HISTORY_LIMIT záznamů)
# Minimalizace I/O a CPU: žádné periodické čtení HTTP /status, žádné *.node
# Ladění: DEBUG 0=OFF, 1=hlavní akce, 2=+trace vstupy/výstupy procedur.

namespace eval ::SVX {
  # re-source safe init
  variable DEBUG;             if {![info exists ::SVX::DEBUG]} { set DEBUG 2 }
  variable RAM_DIR;           if {![info exists ::SVX::RAM_DIR]} { set RAM_DIR "/dev/shm/svx" }
  variable STATUS;            if {![info exists ::SVX::STATUS]} { set STATUS  "$RAM_DIR/status.json" }
  variable HISTORY;           if {![info exists ::SVX::HISTORY]} { set HISTORY "$RAM_DIR/history.csv" }

  variable DISK_DIR;          if {![info exists ::SVX::DISK_DIR]} { set DISK_DIR "/var/log/svxlink" }
  variable DISK_FILE;         if {![info exists ::SVX::DISK_FILE]} { set DISK_FILE "$DISK_DIR/history.csv" }

  variable CALLSIGN;          if {![info exists ::SVX::CALLSIGN]} { set CALLSIGN "-" }
  variable NODES;             if {![info exists ::SVX::NODES]} { set NODES [dict create] }
  variable HISTORY_LIMIT;     if {![info exists ::SVX::HISTORY_LIMIT]} { set HISTORY_LIMIT 28 }
  variable CONNECT_TTL;       if {![info exists ::SVX::CONNECT_TTL]} { set CONNECT_TTL 0 }
  variable CURRENT_TG;        if {![info exists ::SVX::CURRENT_TG]} { set CURRENT_TG 0 }
  variable LOCAL_NODE;        if {![info exists ::SVX::LOCAL_NODE]} { set LOCAL_NODE "" }

  # EchoLink runtime stav
  variable EL_CLIENTS;        if {![info exists ::SVX::EL_CLIENTS]} { set EL_CLIENTS {} }
  variable EL_LAST;           if {![info exists ::SVX::EL_LAST]} { set EL_LAST "" }

  # Jednorázový bootstrap guard
  variable BOOT_DONE
  if {![info exists ::SVX::BOOT_DONE]} { set BOOT_DONE 0 }

proc ::SVX::maybe_bootstrap {why} {
  # POZOR: volat POUZE z ReflectorLogic::connected (jednorázově po navázání spojení s reflektorem)
  if {$::SVX::BOOT_DONE} { return }
  ::SVX::dbg "bootstrap once ($why)"
  set ::SVX::BOOT_DONE 1
  ::SVX::bootstrap_from_reflector
}


}

proc ::SVX::dbg {msg}       { if {$::SVX::DEBUG < 1} { return }; puts "SVX DBG: $msg" }
proc ::SVX::dbgEnter {{ctx ""}} { if {$::SVX::DEBUG < 2} { return }; if {$ctx eq ""} { set ctx "::SVX" }; puts "SVX DBG: -> $ctx" }
proc ::SVX::dbgLeave {{ctx ""}} { if {$::SVX::DEBUG < 2} { return }; if {$ctx eq ""} { set ctx "::SVX" }; puts "SVX DBG: <- $ctx" }

# deps (http+json jen pro jednorázový bootstrap a hydratační čtení)
# Přidej běžné systémové cesty pro tcllib, aby fungovalo `package require json/http` i uvnitř SvxLinku
foreach p { /usr/share/tcltk /usr/share/tcltk/tcllib /usr/share/tcl8.6 /usr/lib/tcl8.6 } {
  if {[file isdirectory $p] && [lsearch -exact $::auto_path $p] < 0} { lappend ::auto_path $p }
}
if {[catch {package require http} err]} { ::SVX::dbg "http not available: $err" }
if {[catch {package require json} err]} { ::SVX::dbg "json not available: $err" }

# infra ----------------------------------------------------------------
proc ::SVX::ensure_dirs {} {
  ::SVX::dbgEnter "ensure_dirs"
  if {![file isdirectory $::SVX::RAM_DIR]}  { catch { file mkdir $::SVX::RAM_DIR } }
  if {![file isdirectory $::SVX::DISK_DIR]} { catch { file mkdir $::SVX::DISK_DIR } }
  ::SVX::dbgLeave "ensure_dirs"
}

proc ::SVX::ensure_files {} {
  ::SVX::dbgEnter "ensure_files"
  ::SVX::ensure_dirs
  foreach p [list $::SVX::HISTORY $::SVX::DISK_FILE] {
    if {![file exists $p]} { catch { set f [open $p a]; close $f; file attributes $p -permissions 0664 } }
  }
  if {![file exists $::SVX::STATUS]} {
    set ts [clock seconds]
    set OC [format %c 123]; set CC [format %c 125]; set COL [format %c 58]; set CM [format %c 44]
    set json "$OC \"ts\"$COL $ts$CM \"callsign\"$COL \"-\"$CM \"nodes\"$COL $OC $CC $CC"
    ::SVX::__atomic_write $::SVX::STATUS $json
  }
  ::SVX::dbgLeave "ensure_files"
}

proc ::SVX::json_escape {s} {
  set BS [format %c 92]; set DQ [format %c 34]; set NL [format %c 10]; set CR [format %c 13]; set TB [format %c 9]
  set s [string map [list $BS "$BS$BS" $DQ "$BS$DQ" $NL "${BS}n" $CR "${BS}r" $TB "${BS}t"] $s]
  set out ""
  for {set i 0} {$i < [string length $s]} {incr i} { set ch [string index $s $i]; scan $ch %c code; if {$code >= 32} { append out $ch } }
  return $out
}
proc ::SVX::bool {b} { expr {$b?"true":"false"} }
proc ::SVX::num  {v} { expr {int($v)} }

# NODES helpers ---------------------------------------------------------
proc ::SVX::ensure_node_defaults {n} {
  foreach {k def} {
    isTalker 0 tg 0 last_seen 0 last_talk_start 0 last_talk_stop 0 talk_count 0
    connected 0 connected_since 0 disconnected_since 0 last_change 0 talk_active 0 talk_last_duration 0
  } { if {![dict exists $n $k]} { dict set n $k $def } }
  if {![dict exists $n monitored_tgs]} { dict set n monitored_tgs {} }
  return $n
}

proc ::SVX::touch_node {name {src ""}} {
  ::SVX::dbgEnter "touch_node $name"
  # jen zajistí existenci a doplní zdroj; žádné vedlejší efekty (žádný set_connected, žádný zápis)
  set n {}
  if {[dict exists $::SVX::NODES $name]} { set n [dict get $::SVX::NODES $name] }
  set n [::SVX::ensure_node_defaults $n]
  if {$src ne ""} { dict set n src $src }
  dict set ::SVX::NODES $name $n
  ::SVX::dbgLeave "touch_node $name"
}
# --- TTL & hydrate (no-op) -----------------------------------------
proc ::SVX::prune_ttl {} { if {$::SVX::DEBUG>1} { puts "SVX DBG: -> prune_ttl"; puts "SVX DBG: <- prune_ttl" } }
proc ::SVX::maybe_hydrate {} { return }

# --- Core mutators ---------------------------------------------------
# --- fetch + parse helpers (vložit nad/hned pod bootstrap) -------------------
proc ::SVX::__fetch_status {} {
  # 1) zkusit http::geturl
  if {[info commands http::geturl] ne ""} {
    if {![catch { set tok [http::geturl "http://127.0.0.1:8880/status" -timeout 2000] } err]} {
      set code [http::ncode $tok]; set body [http::data $tok]
      catch { http::cleanup $tok }
      if {$code == 200 && $body ne ""} { return $body }
      ::SVX::dbg "bootstrap http ncode=$code"
    } else { ::SVX::dbg "bootstrap http error: $err" }
  }
  # 2) fallback: curl / wget
  if {[file executable "/usr/bin/curl"]} {
    if {![catch { exec /usr/bin/curl -fsS --max-time 2 http://127.0.0.1:8880/status } body]} { return $body }
  }
  if {[file executable "/usr/bin/wget"]} {
    if {![catch { exec /usr/bin/wget -q -T 2 -O - http://127.0.0.1:8880/status } body]} { return $body }
  }
  return ""
}

proc ::SVX::__apply_status_json {body} {
  # plná cesta přes tcllib/json, jinak minimální parser (jen názvy uzlů)
  set hydrated 0
  if {[info commands ::json::json2dict] ne ""} {
    if {![catch { set jd [::json::json2dict $body] } jerr]} {
      if {[dict exists $jd nodes]} {
        set rnodes [dict get $jd nodes]
        foreach name [dict keys $rnodes] {
          set r [dict get $rnodes $name]
          ::SVX::touch_node $name "REF"
          ::SVX::set_connected $name 1
          if {[dict exists $r tg]}        { dict set ::SVX::NODES $name tg        [::SVX::num [dict get $r tg]] }
          if {[dict exists $r isTalker]}  { dict set ::SVX::NODES $name isTalker  [expr {[dict get $r isTalker]?1:0}] }
          if {[dict exists $r monitoredTGs]} { dict set ::SVX::NODES $name monitored_tgs [dict get $r monitoredTGs] }
          incr hydrated
        }
      }
    } else {
      ::SVX::dbg "bootstrap json parse error: $jerr"
    }
    return $hydrated
  }
  # fallback: vytáhni jen názvy uzlů
  foreach {m name} [regexp -inline -all {"([A-Za-z0-9_-]+)"\s*:\s*\{} $body] {
    ::SVX::touch_node $name "REF"
    ::SVX::set_connected $name 1
    incr hydrated
  }
  return $hydrated
}

# --- BOOTSTRAP (NAHRAĎ tímto celou původní proc) ----------------------------
proc ::SVX::bootstrap_from_reflector {} {
  ::SVX::dbgEnter "bootstrap_from_reflector(hydrate)"
  # 1) nuluje stávající stav (nepředpokládej připojené)
  set now [clock seconds]
  foreach k [dict keys $::SVX::NODES] {
    set n [::SVX::ensure_node_defaults [dict get $::SVX::NODES $k]]
    dict set n isTalker 0
    dict set n talk_active 0
    dict set n connected 0
    dict set n disconnected_since $now
    dict set n last_change $now
    dict set n last_seen $now
    dict set ::SVX::NODES $k $n
  }
  # 2) stáhni /status (http nebo curl/wget) a aplikuj
  set body [::SVX::__fetch_status]
  set hydrated 0
  if {$body ne ""} {
    set hydrated [::SVX::__apply_status_json $body]
  } else {
    ::SVX::dbg "bootstrap: could not fetch /status"
  }
  # 3) zapiš
  ::SVX::write_status_quick
  ::SVX::dbg "bootstrap hydrated=$hydrated"
  ::SVX::dbgLeave "bootstrap_from_reflector(hydrate)"
}


proc ::SVX::set_connected {name state} {
  ::SVX::dbgEnter "set_connected $name state=$state"
  ::SVX::touch_node $name
  set now [clock seconds]
  set n [dict get $::SVX::NODES $name]
  set st [expr {$state?1:0}]
  dict set n connected $st
  if {$st} {
    if {[dict get $n connected_since] == 0} { dict set n connected_since $now }
    dict set n disconnected_since 0
  } else {
    dict set n disconnected_since $now
    dict set n talk_active 0
    dict set n isTalker 0
  }
  dict set n last_change $now
  dict set n last_seen $now
  dict set ::SVX::NODES $name $n
  ::SVX::dbgLeave "set_connected $name state=$state"
}

proc ::SVX::start_talk {name tg} {
  ::SVX::dbgEnter "start_talk $name tg=$tg"
  ::SVX::touch_node $name
  set now [clock seconds]
  set n [dict get $::SVX::NODES $name]
  dict set n connected 1
  if {[dict get $n connected_since] == 0} { dict set n connected_since $now }
  dict set n disconnected_since 0
  if {$tg ne ""} { dict set n tg [expr {int($tg)}] }
  dict set n isTalker 1
  dict set n talk_active 1
  dict set n last_talk_start $now
  dict set n last_seen $now
  dict set ::SVX::NODES $name $n
  ::SVX::dbgLeave "start_talk $name tg=$tg"
}

proc ::SVX::stop_talk {name tg} {
  ::SVX::dbgEnter "stop_talk $name tg=$tg"
  if {![dict exists $::SVX::NODES $name]} { ::SVX::dbgLeave "stop_talk $name tg=$tg"; return }
  set now   [clock seconds]
  set n     [dict get $::SVX::NODES $name]
  set start [dict get $n last_talk_start]
  set dur 0
  if {$start > 0 && $now >= $start} { set dur [expr {$now - $start}] }
  dict set n isTalker 0
  dict set n talk_active 0
  dict set n last_talk_stop $now
  dict set n talk_last_duration $dur
  dict set n talk_count [expr {[dict get $n talk_count] + 1}]
  dict set n last_seen $now
  if {$tg ne ""} { dict set n tg [expr {int($tg)}] }
  dict set ::SVX::NODES $name $n
  if {$dur > 0} { ::SVX::append_history $name [expr {int($tg)}] $dur $start }
  ::SVX::dbgLeave "stop_talk $name tg=$tg"
}

# (removed older duplicate ::SVX::set_connected)

# STATUS I/O -----------------------------------------------------------
proc ::SVX::__atomic_write {path data} {
  ::SVX::ensure_dirs
  set dir [file dirname $path]
  set tmp [file join $dir ".__tmp__[pid]_[clock clicks]"]
  set f [open $tmp w]; fconfigure $f -translation binary -encoding utf-8
  puts -nonewline $f $data; close $f
  catch { file attributes $tmp -permissions 0664 }
  file rename -force $tmp $path
}
proc ::SVX::__read_lines {path} {
  if {![file exists $path]} { return {} }
  set f [open $path r]; fconfigure $f -translation binary -encoding utf-8
  set data [read $f]; close $f
  set NL [format %c 10]; set data [string trimright $data $NL]
  if {$data eq ""} { return {} }
  return [split $data $NL]
}
proc ::SVX::__write_lines_atomic {path lines} {
  set NL [format %c 10]
  if {[llength $lines]} {
    set data "[join $lines $NL]$NL"
  } else {
    set data ""
  }
  ::SVX::__atomic_write $path $data
}
proc ::SVX::__append_line {path line} {
  ::SVX::ensure_dirs
  if {[catch { set f [open $path a] }]} { return }
  fconfigure $f -translation binary -encoding utf-8
  puts $f $line; close $f
}

# Read current nodes from status.json (best-effort) to support multi-logic writers
proc ::SVX::__read_status_nodes {} {
  if {![file exists $::SVX::STATUS]} { return [dict create] }
  if {[catch { set f [open $::SVX::STATUS r] }]} { return [dict create] }
  fconfigure $f -translation binary -encoding utf-8
  set body [read $f]; close $f
  if {[info commands ::json::json2dict] eq ""} { return [dict create] }
  if {[catch { set jd [::json::json2dict $body] }]} { return [dict create] }
  if {![dict exists $jd nodes]} { return [dict create] }
  set out [dict create]
  set rnodes [dict get $jd nodes]
  foreach name [dict keys $rnodes] {
    set rn [dict get $rnodes $name]
    set dn [::SVX::ensure_node_defaults [dict create]]
    foreach k {isTalker tg last_seen last_talk_start last_talk_stop talk_count connected connected_since disconnected_since last_change talk_active talk_last_duration} {
      if {[dict exists $rn $k]} {
        set v [dict get $rn $k]
        if {$k in {isTalker connected talk_active}} { set v [expr {$v?1:0}] }
        dict set dn $k $v
      }
    }
    if {[dict exists $rn monitoredTGs]} { dict set dn monitored_tgs [dict get $rn monitoredTGs] }
    dict set out $name $dn
  }
  return $out
}

proc ::SVX::append_history {name tg dur {start_ts {}}} {
  ::SVX::dbgEnter "append_history $name tg=$tg dur=$dur"
  if {$start_ts eq ""} { set start_ts [clock seconds] }
  set line "[::SVX::num $start_ts];$name;[::SVX::num $tg];[::SVX::num $dur]"
  # 1x ensure_dirs stačí
  ::SVX::ensure_dirs
  if {[info exists ::SVX::DISK_FILE]} { catch { ::SVX::__append_line $::SVX::DISK_FILE $line } }
  # RAM historie: udrž posledních HISTORY_LIMIT
  set lines [::SVX::__read_lines $::SVX::HISTORY]
  set keep [expr {$::SVX::HISTORY_LIMIT - 1}]; if {$keep < 0} { set keep 0 }
  if {[llength $lines] >= $keep} { set tail [lrange $lines end-[expr {$keep-1}] end] } else { set tail $lines }
  set new [concat $tail [list $line]]
  ::SVX::__write_lines_atomic $::SVX::HISTORY $new
  ::SVX::dbg "history+1 (node=$name tg=$tg dur=$dur) size=[llength $new]"
  ::SVX::dbgLeave "append_history $name tg=$tg dur=$dur"
}

proc ::SVX::__build_and_write_status {nodes} {
  ::SVX::dbgEnter "write_status"
  # Merge with existing file to avoid clobbering nodes from other logic interpreters
  set existing [::SVX::__read_status_nodes]
  foreach name [dict keys $nodes] { dict set existing $name [dict get $nodes $name] }
  set nodes $existing
  set ts [clock seconds]
  set OC [format %c 123]; set CC [format %c 125]; set CM [format %c 44]; set COL [format %c 58]
  set LBR [format %c 91]; set RBR [format %c 93]
  set out "$OC \"ts\"$COL $ts$CM \"callsign\"$COL \"[::SVX::json_escape $::SVX::CALLSIGN]\"$CM \"nodes\"$COL $OC"
  set first 1
  foreach name [lsort [dict keys $nodes]] {
    set n [::SVX::ensure_node_defaults [dict get $nodes $name]]
    if {!$first} { append out $CM } { set first 0 }
    append out "\"[::SVX::json_escape $name]\"$COL$OC"
    append out "\"isTalker\"$COL"   [::SVX::bool [dict get $n isTalker]]
    append out $CM "\"tg\"$COL"        [::SVX::num  [dict get $n tg]]
    append out $CM "\"monitoredTGs\"$COL"; append out $LBR
    set __f 1; foreach __v [dict get $n monitored_tgs] { if {!$__f} { append out $CM } { set __f 0 }; append out [::SVX::num $__v] }
    append out $RBR
    append out $CM "\"last_seen\"$COL"  [::SVX::num  [dict get $n last_seen]]
    append out $CM "\"last_talk_start\"$COL" [::SVX::num [dict get $n last_talk_start]]
    append out $CM "\"last_talk_stop\"$COL"  [::SVX::num [dict get $n last_talk_stop]]
    append out $CM "\"talk_count\"$COL" [::SVX::num [dict get $n talk_count]]
    append out $CM "\"connected\"$COL" [::SVX::bool [dict get $n connected]]
    append out $CM "\"connected_since\"$COL" [::SVX::num [dict get $n connected_since]]
    append out $CM "\"disconnected_since\"$COL" [::SVX::num [dict get $n disconnected_since]]
    append out $CM "\"last_change\"$COL" [::SVX::num [dict get $n last_change]]
    append out $CM "\"talk_active\"$COL" [::SVX::bool [dict get $n talk_active]]
    append out $CM "\"talk_last_duration\"$COL" [::SVX::num [dict get $n talk_last_duration]]
    append out $CC
  }
  append out " $CC$CC"
  ::SVX::__atomic_write $::SVX::STATUS $out
  ::SVX::dbg "status.json updated nodes=[llength [dict keys $nodes]]"
  ::SVX::dbgLeave "write_status"
}
proc ::SVX::write_status_quick {} { ::SVX::__build_and_write_status $::SVX::NODES }
proc ::SVX::write_status {} { ::SVX::prune_ttl; ::SVX::write_status_quick }

# Události z logik -----------------------------------------------------
namespace eval ::ReflectorLogic {}
namespace eval ::UsrpLogic {}
namespace eval ::EchoLink {}

proc ::ReflectorLogic::connected {args} {
  ::SVX::dbgEnter "ReflectorLogic::connected"
  ::SVX::write_status
  ::SVX::dbgLeave "ReflectorLogic::connected"
}

proc ::ReflectorLogic::disconnected {args} { ::SVX::dbgEnter "ReflectorLogic::disconnected"; ::SVX::dbgLeave "ReflectorLogic::disconnected" }
proc ::ReflectorLogic::local_talker_start {args} { ::SVX::dbgEnter "ReflectorLogic::local_talker_start"; ::SVX::dbgLeave "ReflectorLogic::local_talker_start" }
proc ::ReflectorLogic::local_talker_stop  {args} { ::SVX::dbgEnter "ReflectorLogic::local_talker_stop";  ::SVX::dbgLeave "ReflectorLogic::local_talker_stop" }

proc ::ReflectorLogic::tg_selected {args} {
  set tg 0; set flag ""; if {[llength $args] >= 1} { set tg [lindex $args 0] }; if {[llength $args] >= 2} { set flag [lindex $args 1] }
  ::SVX::dbgEnter "ReflectorLogic::tg_selected tg=$tg flag=$flag"
  set ::SVX::CURRENT_TG [::SVX::num $tg]
  if {[info exists ::SVX::LOCAL_NODE] && $::SVX::LOCAL_NODE ne ""} {
    set node $::SVX::LOCAL_NODE
    ::SVX::touch_node $node
    dict set ::SVX::NODES $node tg [::SVX::num $tg]
    if {$tg != 0} {
      set mt [expr {[dict exists $::SVX::NODES $node monitored_tgs] ? [dict get $::SVX::NODES $node monitored_tgs] : {}}]
      if {[lsearch -exact $mt $tg] < 0} { lappend mt $tg }
      dict set ::SVX::NODES $node monitored_tgs $mt
    }
    dict set ::SVX::NODES $node last_seen [clock seconds]
  }
  ::SVX::write_status_quick
  ::SVX::dbg "tg_selected $tg"
  ::SVX::dbgLeave "ReflectorLogic::tg_selected"
}

proc ::ReflectorLogic::talker_start {args} {
  # Robust parsing: accept {tg call}, {call tg}, or {call}
  set tg 0; set call ""
  if {[llength $args] == 1} {
    set call [lindex $args 0]
  } elseif {[llength $args] >= 2} {
    set a0 [lindex $args 0]; set a1 [lindex $args 1]
    if {[string is integer -strict $a0]} { set tg $a0; set call $a1 } else { set call $a0; set tg $a1 }
  }
  if {$call eq ""} { ::SVX::dbg "talker_start: missing call (args=$args)"; return }
  ::SVX::dbgEnter "ReflectorLogic::talker_start call=$call tg=$tg"
  ::SVX::touch_node $call "RF"
  ::SVX::set_connected $call 1
  ::SVX::start_talk $call $tg
  ::SVX::write_status_quick
  ::SVX::dbgLeave "ReflectorLogic::talker_start"
}

proc ::ReflectorLogic::talker_stop {args} {
  # Robust parsing: accept {tg call}, {call tg}, or {call}
  set tg 0; set call ""
  if {[llength $args] == 1} {
    set call [lindex $args 0]
  } elseif {[llength $args] >= 2} {
    set a0 [lindex $args 0]; set a1 [lindex $args 1]
    if {[string is integer -strict $a0]} { set tg $a0; set call $a1 } else { set call $a0; set tg $a1 }
  }
  if {$call eq ""} { ::SVX::dbg "talker_stop: missing call (args=$args)"; return }
  ::SVX::dbgEnter "ReflectorLogic::talker_stop call=$call tg=$tg"
  ::SVX::stop_talk  $call $tg
  ::SVX::write_status_quick
  ::SVX::dbgLeave "ReflectorLogic::talker_stop"
}

proc ::ReflectorLogic::reflector_connection_status_update {state} {
  ::SVX::dbgEnter "ReflectorLogic::reflector_connection_status_update state=$state"
  ::SVX::maybe_bootstrap "reflector_connected"
  ::SVX::write_status
  ::SVX::dbgLeave "ReflectorLogic::reflector_connection_status_update state=$state"
}


proc ::UsrpLogic::connected {args} { return }
proc ::UsrpLogic::disconnected {args} { return }
proc ::UsrpLogic::transmission_start {args} { return }
proc ::UsrpLogic::transmission_stop  {args} { return }
proc ::UsrpLogic::talker_start {args} { return }
proc ::UsrpLogic::talker_stop  {args} { return }
