#!/usr/bin/env tclsh
# backend_csv.tcl — backend s CSV ulozistem a HTTP pull z reflektoru
# Komentare nepouzivaji slozene zavorky, aby nevadily TCL parseru v jinych kontextech

# --- Load guard -----------------------------------------------------------
if {![namespace exists ::ELB]} {namespace eval ::ELB {}}
if {[info exists ::ELB::__loaded] && $::ELB::__loaded} {return}
set ::ELB::__loaded 1

# --- Konfigurace ----------------------------------------------------------
namespace eval ::ELB {
    variable STATUS_CSV "/run/svxlink/status.csv"
    variable META_FILE "/run/svxlink/status.meta"
    variable HISTORY_LOG "/var/log/svxlink/history.csv"
    variable HISTORY_RUN "/run/svxlink/history.csv"
    variable MAX_ROWS 28
    variable LOCK_DIR "/run/lock"
    variable SSE_HOST "127.0.0.1"
    variable SSE_PORT 8091
    variable REFLECTOR_URL "http://127.0.0.1:8880/status"
    variable POLL_MS 60000
    variable LOCAL_LINK "OK1LBC-L"
    variable EL_ACTIVE_FILE "/run/svxlink/elb_el_active"
}

# --- Util ----------------------------------------------------------------
proc ::ELB::trace {msg} {
    # Logging disabled
    return
}
proc ::ELB::ensure_dir {p} {
    set d [file dirname $p]
    if {![file isdirectory $d]} {
        catch {file mkdir $d}
    }
}
proc ::ELB::fmt_ts {t} {clock format $t -format {%d.%m.%Y %H:%M:%S}}
proc ::ELB::sse {payload} {
    if {$payload eq ""} {return}
    variable SSE_HOST; variable SSE_PORT
    set err ""
    if {
        [catch {
            set s [socket $SSE_HOST $SSE_PORT]
            fconfigure $s -encoding utf-8 -translation lf -blocking 1
            puts $s $payload
            close $s
        } err]
    } {
        ::ELB::trace "SSE error: $err"
    } else {
        ::ELB::trace "SSE sent: $payload"
    }
}

# --- CSV I O -------------------------------------------------------------
proc ::ELB::csv_header {} {
    return "link;src;connected;talk_active;tg;last_change;last_talk_start;last_talk_stop;talk_last_duration"
}
proc ::ELB::read_status {} {
    variable STATUS_CSV
    if {![file exists $STATUS_CSV] || [file size $STATUS_CSV] == 0} {
        return [dict create]
    }
    if {[catch { set f [open $STATUS_CSV r] }]} { return [dict create] }
    fconfigure $f -encoding utf-8 -translation lf
    set nodes [dict create]
    set i 0
    while {[gets $f line] >= 0} {
        if {$line eq ""} { continue }
        if {$i == 0} { incr i; continue }  ;# skip header
        set c [split $line ";"]
        if {[llength $c] < 9} { continue }
        set link [lindex $c 0]
        dict set nodes $link src                [lindex $c 1]
        dict set nodes $link connected          [expr {[lindex $c 2] + 0}]
        dict set nodes $link talk_active        [expr {[lindex $c 3] + 0}]
        dict set nodes $link tg                 [expr {[lindex $c 4] + 0}]
        dict set nodes $link last_change        [expr {[lindex $c 5] + 0}]
        dict set nodes $link last_talk_start    [expr {[lindex $c 6] + 0}]
        dict set nodes $link last_talk_stop     [expr {[lindex $c 7] + 0}]
        dict set nodes $link talk_last_duration [expr {[lindex $c 8] + 0}]
    }
    close $f
    return $nodes
}

proc ::ELB::write_status {nodes {link ""} {do_sse 0}} {
    variable STATUS_CSV; variable META_FILE
    ::ELB::ensure_dir $STATUS_CSV
    set tmp "$STATUS_CSV.[pid].tmp"
    if {[catch { set f [open $tmp w] } err]} { ::ELB::trace "CSV open fail: $err"; return }
    fconfigure $f -encoding utf-8 -translation lf
    puts $f [::ELB::csv_header]
    foreach ln [lsort [dict keys $nodes]] {
        set nd [dict get $nodes $ln]
        puts $f [join [list \
            $ln \
            [expr {[dict exists $nd src] ? [dict get $nd src] : ""}] \
            [expr {[dict exists $nd connected] ? [dict get $nd connected] + 0 : 0}] \
            [expr {[dict exists $nd talk_active] ? [dict get $nd talk_active] + 0 : 0}] \
            [expr {[dict exists $nd tg] ? [dict get $nd tg] + 0 : 0}] \
            [expr {[dict exists $nd last_change] ? [dict get $nd last_change] + 0 : 0}] \
            [expr {[dict exists $nd last_talk_start] ? [dict get $nd last_talk_start] + 0 : 0}] \
            [expr {[dict exists $nd last_talk_stop] ? [dict get $nd last_talk_stop] + 0 : 0}] \
            [expr {[dict exists $nd talk_last_duration] ? [dict get $nd talk_last_duration] + 0 : 0}]] ";"]
    }
    close $f
    file rename -force $tmp $STATUS_CSV
    set now [clock seconds]
    set mf "$META_FILE.[pid].tmp"
    if {![catch { set m [open $mf w] }]} {
        fconfigure $m -encoding utf-8 -translation lf
        puts $m "ts=$now"
        puts $m "ts_h=[::ELB::fmt_ts $now]"
        close $m
        file rename -force $mf $META_FILE
    }
    catch { ::ELB::trace "WROTE status.csv bytes=[file size $STATUS_CSV]" }
    if {$do_sse && $link ne ""} { ::ELB::sse "status $link" }
}

# --- HTTP klient a parser ------------------------------------------------
proc ::ELB::http_get {url} {
    # Non-blocking HTTP/1.x GET s timeoutem a Content-Length
    if {![regexp {^http://([^/]+)(/.*)?$} $url -> host path]} {return ""}
    if {$path eq ""} {set path "/"}
    set p 80
    if {[regexp {^(.*):(\d+)$} $host -> h p]} {set host $h}

    set resp ""; set body ""; set have_hdr 0; set clen -1
    set deadline [expr {[clock milliseconds] + 3000}]

    if {
        [catch {
            set s [socket $host $p]
            fconfigure $s -encoding binary -translation crlf -blocking 0 -buffering none
            puts $s "GET $path HTTP/1.1\r"
            puts $s "Host: $host\r"
            puts $s "Connection: close\r"
            puts $s "Accept: application/json\r"
            puts $s "\r"
            flush $s
            while {[clock milliseconds] < $deadline} {
                set chunk [read $s]
                if {[string length $chunk] > 0} {append resp $chunk}
                if {!$have_hdr} {
                    set pos [string first "\r\n\r\n" $resp]
                    if {$pos < 0} {set pos [string first "\n\n" $resp]; set add 2} else {set add 4}
                    if {$pos >= 0} {
                        set body [string range $resp [expr {$pos + $add}] end]
                        set have_hdr 1
                        if {[regexp -nocase {Content-Length:\s*([0-9]+)} $resp -> n]} {set clen $n}
                        if {$clen >= 0 && [string length $body] >= $clen} {break}
                    }
                } else {
                    if {$clen >= 0 && [string length $body] >= $clen} {break}
                }
                if {[eof $s]} {break}
                after 10
            }
            catch {close $s}
        } err]
    } {
        ::ELB::trace "HTTP error: $err"
        return ""
    }

    if {!$have_hdr} {return $resp}
    if {$clen >= 0} {return [string range $body 0 [expr {$clen - 1}]]}
    return $body
}
proc ::ELB::http_fetch {url} {
    if {![catch {package require http}]} {
        set tok [::http::geturl $url -timeout 3000 \
            -headers {Accept application/json Connection close}]
        set code [::http::ncode $tok]
        set data [::http::data $tok]
        ::http::cleanup $tok
        if {$code >= 200 && $code < 300} {return $data}
        ::ELB::trace "HTTP status $code"
        return ""
    }
    return [::ELB::http_get $url]
}
# Fallback parser pro JSON z reflektoru, bez tcllib
set ::ELB::LB [format %c 123]
set ::ELB::RB [format %c 125]
proc ::ELB::parse_reflector_simple {json} {
    # najdi objekt "nodes": { ... }
    set idx [string first "\"nodes\"" $json]
    if {$idx < 0} {return [dict create]}
    set obr [string first $::ELB::LB $json $idx]
    if {$obr < 0} {return [dict create]}
    set depth 0; set inq 0; set esc 0; set end -1
    set N [string length $json]
    for {set i $obr} {$i < $N} {incr i} {
        set ch [string index $json $i]
        if {$esc} {set esc 0; continue}
        if {$ch eq "\\"} {if {$inq} {set esc 1}; continue}
        if {$ch eq "\""} {set inq [expr {!$inq}]; continue}
        if {!$inq} {
            if {$ch eq $::ELB::LB} {incr depth}
            if {$ch eq $::ELB::RB} {incr depth -1; if {$depth == 0} {set end $i; break}}
        }
    }
    if {$end < 0} {return [dict create]}
    set body [string range $json [expr {$obr + 1}] [expr {$end - 1}]]

    # sekvenční čtečka: "key" : { ... }
    set res [dict create]
    set L [string length $body]
    set i 0
    while {$i < $L} {
        # přeskoč WS a ,
        while {$i < $L} {
            set ch [string index $body $i]
            if {[string first $ch " \t\r\n,"] >= 0} {incr i; continue}
            break
        }
        if {$i >= $L} {break}
        if {[string index $body $i] ne "\""} {incr i; continue}

        # JSON string klíče
        incr i
        set key ""
        set esc 0
        while {$i < $L} {
            set ch [string index $body $i]
            if {$esc} {append key $ch; set esc 0; incr i; continue}
            if {$ch eq "\\"} {set esc 1; incr i; continue}
            if {$ch eq "\""} {incr i; break}
            append key $ch
            incr i
        }

        # dvojtečka a WS
        while {$i < $L && [string first [string index $body $i] " \t\r\n"] >= 0} {incr i}
        if {$i >= $L || [string index $body $i] ne ":"} {continue}
        incr i
        while {$i < $L && [string first [string index $body $i] " \t\r\n"] >= 0} {incr i}
        if {$i >= $L} {break}

        # očekávej objekt { ... }
        if {[string index $body $i] ne $::ELB::LB} {
            while {$i < $L} {
                set ch [string index $body $i]
                if {$ch eq "," || $ch eq $::ELB::RB} {break}
                incr i
            }
            continue
        }

        # najdi konec vnitřního objektu
        set j $i
        set depth 0; set inq 0; set esc 0
        while {$j < $L} {
            set ch [string index $body $j]
            if {$esc} {set esc 0; incr j; continue}
            if {$ch eq "\\"} {if {$inq} {set esc 1}; incr j; continue}
            if {$ch eq "\""} {set inq [expr {!$inq}]; incr j; continue}
            if {!$inq} {
                if {$ch eq $::ELB::LB} {incr depth}
                if {$ch eq $::ELB::RB} {incr depth -1; incr j; if {$depth == 0} {break}; continue}
            }
            incr j
        }
        if {$j <= $i} {incr i; continue}

        set obj [string range $body $i [expr {$j - 1}]]
        set t 0; set tg 0
        if {[regexp -nocase {"isTalker"\s*:\s*(true|false)} $obj -> b]} {
            set t [expr {$b eq "true" ? 1 : 0}]
        }
        if {[regexp {"tg"\s*:\s*([0-9]+)} $obj -> n]} {set tg $n}
        dict set res $key [list connected 1 talk_active $t tg $tg]
        ::ELB::trace "NODE=$key talk=$t tg=$tg"

        set i $j
    }
    return $res
}
proc ::ELB::pull_and_refresh {} { # entry
    ::ELB::trace "PULL enter"
    # debounce in-process
    if {![info exists ::ELB::_last_pull_ms]} {set ::ELB::_last_pull_ms 0}
    set __now [clock milliseconds]
    if {$__now - $::ELB::_last_pull_ms < 1500} {::ELB::trace "PULL debounced"; return}
    set ::ELB::_last_pull_ms $__now
    # cross-interpreter singleflight
    variable LOCK_DIR; catch {file mkdir $LOCK_DIR}
    set __lock "$LOCK_DIR/elb-pull.lock"
    if {[catch {set __fd [open $__lock {CREAT EXCL RDWR}]}]} {::ELB::trace "PULL busy"; return}
    catch {close $__fd}
    try {
        variable REFLECTOR_URL
        ::ELB::trace "PULL start url=$REFLECTOR_URL"
        set body [::ELB::http_fetch $REFLECTOR_URL]
        ::ELB::trace "PULL body bytes=[string length $body] head='[string range $body 0 120]'"
        if {$body eq ""} {::ELB::trace "PULL empty body"; return}
        set nodesDict {}
        if {[catch {set nodesDict [::ELB::parse_reflector_simple $body]} err]} {
            ::ELB::trace "PARSE error: $err"
            return
        }
        ::ELB::trace "PULL parsed [dict size $nodesDict] nodes=[join [lsort [dict keys $nodesDict]] ,]"
        if {[dict size $nodesDict] == 0} {return}
        set st [::ELB::read_status]
        set changed 0
        set seen [dict create]
        dict for {ln nd} $nodesDict {
            set c 1
            set t [dict get $nd talk_active]
            set tg [dict get $nd tg]
            if {![dict exists $st $ln]} {set st [::ELB::ensure_node $st $ln rl]}
            set curc [expr {
                [dict exists $st $ln] &&
                [dict exists [dict get $st $ln] connected]
                    ? [dict get $st $ln connected] : 0
            }]
            set curt [expr {
                [dict exists $st $ln] &&
                [dict exists [dict get $st $ln] talk_active]
                    ? [dict get $st $ln talk_active] : 0
            }]
            set curtg [expr {
                [dict exists $st $ln] &&
                [dict exists [dict get $st $ln] tg]
                    ? [dict get $st $ln tg] : 0
            }]
            if {$c != $curc || $t != $curt || $tg != $curtg} {
                set changed 1
                set now [clock seconds]
                set st [::ELB::ensure_node $st $ln rl]
                dict set st $ln src rl
                dict set st $ln connected $c
                dict set st $ln talk_active $t
                dict set st $ln tg $tg
                dict set st $ln last_change $now
            }
            dict set seen $ln 1
        }
        foreach ln [dict keys $st] {
            set nd [dict get $st $ln]
            if {![dict exists $nd src] || ![string equal -nocase [dict get $nd src] rl]} {continue}
            if {![dict exists $seen $ln]} {
                set curc [expr {[dict exists $nd connected] ? [dict get $nd connected] : 0}]
                set curt [expr {[dict exists $nd talk_active] ? [dict get $nd talk_active] : 0}]
                if {$curc || $curt} {
                    set changed 1
                    set now [clock seconds]
                    dict set st $ln connected 0
                    dict set st $ln talk_active 0
                    dict set st $ln last_change $now
                }
            }
        }
        if {$changed} {
            ::ELB::trace "REFRESH from http nodes=[dict size $nodesDict]"
            ::ELB::write_status $st
            ::ELB::sse refresh
        } else {
            ::ELB::trace "PULL no change"
        }
    } finally {
        catch {file delete -force $__lock}
    }
}
proc ::ELB::start_timer {} {
    if {$::ELB::POLL_MS <= 0} {return}
    ::ELB::trace "TIMER start period=$::ELB::POLL_MS"
    if {[info exists ::ELB::__timer]} {catch {after cancel $::ELB::__timer}}
    set ::ELB::__timer [after $::ELB::POLL_MS {
        ::ELB::trace "TIMER tick"
        ::ELB::pull_and_refresh
        ::ELB::start_timer
    }]
}


# --- EchoLink active-flag helpers ---------------------------------------
proc ::ELB::clear_el_active {} {
    variable EL_ACTIVE_FILE
    catch { file delete -force $EL_ACTIVE_FILE }
    ::ELB::trace "EL flag deleted"
}
proc ::ELB::set_el_active {call on} {
    variable EL_ACTIVE_FILE
    if {$on} {
        catch {
            set f [open $EL_ACTIVE_FILE w]
            fconfigure $f -encoding utf-8 -translation lf
            puts $f "active;$call;0"
            close $f
        }
        ::ELB::trace "EL flag set ACTIVE call=$call"
    } else {
        ::ELB::clear_el_active
    }
}
proc ::ELB::write_el_grace {call ms} { ::ELB::clear_el_active }
proc ::ELB::read_el_flag {} {
    variable EL_ACTIVE_FILE
    set nowms [clock milliseconds]
    set mode ""; set call ""; set expms 0; set active 0
    if {[file exists $EL_ACTIVE_FILE]} {
        if {![catch { set f [open $EL_ACTIVE_FILE r] }]} {
            set line [string trim [read $f]]
            close $f
            set parts [split $line ";"]
            if {[llength $parts] >= 1} { set mode [lindex $parts 0] }
            if {[llength $parts] >= 2} { set call [lindex $parts 1] }
            if {[llength $parts] >= 3 && [string is integer -strict [lindex $parts 2]]} {
                set expms [lindex $parts 2]
            }
        }
    }
    if {$mode eq "active"} { set active 1 }
    return [list $active $call $expms $nowms $mode]
}
proc ::ELB::is_el_active {} {
    lassign [::ELB::read_el_flag] active call expms nowms mode
    if {!$active && $mode ne ""} { ::ELB::clear_el_active }
    return $active
}
proc ::ELB::get_el_call {} {
    lassign [::ELB::read_el_flag] active call expms nowms mode
    return $call
}
# --- Stavove helpery -----------------------------------------------------
proc ::ELB::ensure_node {nodes link {src ""}} {
    if {$link eq ""} { return $nodes }
    if {![dict exists $nodes $link]} {
        set now [clock seconds]
        set nd [dict create \
            src $src \
            connected 0 \
            talk_active 0 \
            tg 0 \
            last_change $now \
            last_talk_start 0 \
            last_talk_stop 0 \
            talk_last_duration 0]
        dict set nodes $link $nd
    } else {
        if {$src ne ""} { dict set nodes $link src $src }
    }
    return $nodes
}

# --- Historie append + rotace -------------------------------------------
proc ::ELB::with_lock {name body} {
    variable LOCK_DIR; catch { file mkdir $LOCK_DIR }
    set lock "$LOCK_DIR/$name.lock"
    if {[catch { set fd [open $lock {CREAT EXCL RDWR}] }]} {
        uplevel 1 $body; return
    }
    catch { close $fd }
    set err ""
    try {
        uplevel 1 $body
    } on error {e} {
        set err $e
    } finally {
        catch { file delete -force $lock }
    }
    if {$err ne ""} { error $err }
}
proc ::ELB::append_history {dur tg link start stop} {
    variable HISTORY_LOG; variable HISTORY_RUN; variable MAX_ROWS
    set line [format "%s;%s;%d;%d" [::ELB::fmt_ts $stop] $link $dur $tg]
    catch {
        ::ELB::ensure_dir $HISTORY_LOG
        set f [open $HISTORY_LOG a]
        fconfigure $f -encoding utf-8 -translation lf
        puts $f $line
        close $f
    }
    ::ELB::with_lock svx-hist {
        set rows {}
        if {[file exists $HISTORY_RUN]} {
            if {![catch { set fr [open $HISTORY_RUN r] }]} {
                fconfigure $fr -encoding utf-8 -translation lf
                set rows [split [string trimright [read $fr] "
"] "
"]
                close $fr
            }
        }
        if {[llength $rows] == 1 && [lindex $rows 0] eq ""} { set rows {} }
        lappend rows $line
        set n [llength $rows]
        if {$n > $MAX_ROWS} { set rows [lrange $rows [expr {$n-$MAX_ROWS}] end] }
        ::ELB::ensure_dir $HISTORY_RUN
        set fw [open "$HISTORY_RUN.[pid].tmp" w]
        fconfigure $fw -encoding utf-8 -translation lf
        foreach r $rows { puts $fw $r }
        close $fw
        file rename -force "$HISTORY_RUN.[pid].tmp" $HISTORY_RUN
        catch { file attributes $HISTORY_RUN -permissions 0644 }
    }
    ::ELB::sse history
}

# --- Handlery talker a connect ------------------------------------------
proc ::ELB::on_talker_start {tg link {src ""}} {
    set nodes [::ELB::read_status]
    set nodes [::ELB::ensure_node $nodes $link $src]
    set now [clock seconds]
    dict set nodes $link connected 1
    dict set nodes $link talk_active 1
    dict set nodes $link tg [expr {$tg + 0}]
    dict set nodes $link last_talk_start $now
    dict set nodes $link last_change $now
    ::ELB::write_status $nodes $link 1
}
proc ::ELB::on_talker_stop {tg link {src ""}} {
    set nodes [::ELB::read_status]
    set nodes [::ELB::ensure_node $nodes $link $src]
    set now [clock seconds]
    set start 0
    if {[dict exists $nodes $link last_talk_start]} {
        set start [dict get $nodes $link last_talk_start]
    }
    # předchozí stav
    set prev [expr {[dict exists $nodes $link talk_active] ? [dict get $nodes $link talk_active] : 0}]
    # aktualizace
    set dur 0
    if {$start > 0} { set dur [expr {$now - $start}] }
    if {$dur < 0} { set dur 0 }
    dict set nodes $link talk_active 0
    dict set nodes $link tg [expr {$tg + 0}]
    dict set nodes $link last_talk_stop $now
    dict set nodes $link talk_last_duration $dur
    dict set nodes $link last_change $now
    # SSE jen při 1→0, historie taky
    ::ELB::write_status $nodes $link $prev
    if {$prev} { ::ELB::append_history $dur [expr {$tg + 0}] $link $start $now }
}
proc ::ELB::set_connected {call flag} {
    set nodes [::ELB::read_status]
    set nodes [::ELB::ensure_node $nodes $call el]
    set now [clock seconds]
    dict set nodes $call connected [expr {$flag ? 1 : 0}]
    dict set nodes $call last_change $now
    ::ELB::write_status $nodes $call 1
}

# --- Wrappery ReflectorLogic --------------------------------------------
if {![namespace exists ::ReflectorLogic]} { namespace eval ::ReflectorLogic {} }

if {[llength [info procs ::ReflectorLogic::talker_start]]} {
    rename ::ReflectorLogic::talker_start ::ReflectorLogic::__elb_prev_talker_start
}
proc ::ReflectorLogic::talker_start {tg link args} {
    if {[info exists ::ELB::LOCAL_LINK] && $link eq $::ELB::LOCAL_LINK &&
        [::ELB::is_el_active]} {
        ::ELB::trace "suppress RL local start due to EL $link el_call=[::ELB::get_el_call]"
    } else {
        ::ELB::on_talker_start $tg $link rl
    }
    if {[llength [info procs ::ReflectorLogic::__elb_prev_talker_start]]} {
        uplevel 1 ::ReflectorLogic::__elb_prev_talker_start $tg $link {*}$args
    }
}

if {[llength [info procs ::ReflectorLogic::talker_stop]]} {
    rename ::ReflectorLogic::talker_stop ::ReflectorLogic::__elb_prev_talker_stop
}
proc ::ReflectorLogic::talker_stop {tg link args} {
    # Vzdy zapis stop i pro lokalni linku; pripadne "zbytecny" zapis neva
    ::ELB::on_talker_stop $tg $link rl
    if {[llength [info procs ::ReflectorLogic::__elb_prev_talker_stop]]} {
        uplevel 1 ::ReflectorLogic::__elb_prev_talker_stop $tg $link {*}$args
    }
}

if {[llength [info procs ::ReflectorLogic::reflector_connection_status_update]]} {
    rename ::ReflectorLogic::reflector_connection_status_update ::ReflectorLogic::__elb_prev_rcu
}
proc ::ReflectorLogic::reflector_connection_status_update {state} {
    ::ELB::trace "RL.rcu state=$state"
    if {$state} {
        ::ELB::trace "RCU pull now"
        if {[catch { ::ELB::pull_and_refresh } err]} {
            ::ELB::trace "PULL error: $err"
        }
        ::ELB::trace "RCU start_timer POLL_MS=$::ELB::POLL_MS"
        ::ELB::start_timer
    } else {
        set st [::ELB::read_status]
        set changed 0
        foreach ln [dict keys $st] {
            set nd [dict get $st $ln]
            if {[dict exists $nd src] && [string equal -nocase [dict get $nd src] rl]} {
                if {[dict get $nd connected] || [dict get $nd talk_active]} {
                    dict set st $ln connected 0
                    dict set st $ln talk_active 0
                    set changed 1
                }
            }
        }
        if {$changed} { ::ELB::write_status $st; ::ELB::sse refresh }
    }
    if {[llength [info procs ::ReflectorLogic::__elb_prev_rcu]]} {
        uplevel 1 ::ReflectorLogic::__elb_prev_rcu $state
    }
}

# --- API volane z EchoLink.tcl ------------------------------------------
proc ::ELB::debug_pull {} { ::ELB::trace "DEBUG manual pull"; ::ELB::pull_and_refresh }

if {![namespace exists ::SVX]} { namespace eval ::SVX {} }
proc ::SVX::set_connected {call flag} {
    ::ELB::trace "EL.connect $call flag=$flag"
    ::ELB::set_connected $call $flag
    if {!$flag} { ::ELB::clear_el_active }
}
proc ::SVX::start_talk {call tg} {
    ::ELB::trace "SVX.start_talk call=$call tg=$tg"
    ::ELB::set_el_active $call 1
    ::ELB::on_talker_start $tg $call el
}
proc ::SVX::stop_talk {call tg} {
    ::ELB::trace "SVX.stop_talk call=$call tg=$tg"
    ::ELB::on_talker_stop $tg $call el
    # GRACE zruseno: cistime flag ihned
    ::ELB::clear_el_active
}
proc ::SVX::sync_el_clients {clients} {
    ::ELB::trace "EL.sync clients received"
}

# --- Init ---
::ELB::trace "LOADED pid=[pid]"
::ELB::trace "CONFIG LOCAL_LINK=$::ELB::LOCAL_LINK REFRESH_URL=$::ELB::REFLECTOR_URL"
::ELB::trace "CONFIG POLL_MS=$::ELB::POLL_MS"
# seed status.csv jen kdyz chybi nebo je prazdny
if {![file exists $::ELB::STATUS_CSV] || [file size $::ELB::STATUS_CSV] == 0} {
    ::ELB::write_status [::ELB::read_status]
}
# eof guard
