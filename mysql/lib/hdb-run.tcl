# One timed TPROC-C run: rampup + measured duration.
#
# When PMH_PACE_MS > 0 every virtual user is paced to start one transaction
# every PMH_PACE_MS milliseconds, which caps the load at a known rate instead
# of running flat out. The pacing code is injected into the stock HammerDB
# driver script, so everything else (transaction mix, result calculation)
# stays standard.
source [file join [file dirname [info script]] hdb-common.tcl]

set vu       [pmh_env PMH_VU 64]
set rampup   [pmh_env PMH_RAMPUP 1]
set duration [pmh_env PMH_DURATION 60]
set pace_ms  [pmh_env PMH_PACE_MS 0]

diset tpcc mysql_driver       timed
diset tpcc mysql_rampup       $rampup
diset tpcc mysql_duration     $duration
diset tpcc mysql_allwarehouse [pmh_env PMH_ALLWAREHOUSE false]
diset tpcc mysql_timeprofile  false
diset tpcc mysql_keyandthink  false
diset tpcc mysql_total_iterations 10000000000

loadscript

if { $pace_ms > 0 } {
    set script $_ED(package)
    # 1. pacing interval option
    set n [regsub {(set prepare "[a-z]+"[^\n]*\n)} $script "\\1set PACE_MS $pace_ms ;# Parma Ham pacing interval per virtual user\n" script]
    # 2. check for abort on every iteration so paced VUs stop promptly
    incr n [regsub {set abchk_mx 1024;} $script {set abchk_mx 1;} script]
    # 3. sleep until this VU's next scheduled transaction start. The schedule
    #    starts at a random offset (spreads VUs out) and is allowed to fall
    #    at most 10 intervals behind, so a stall never causes a long burst.
    set pace {
            if {![info exists pmh_next]} { set pmh_next [expr {[clock milliseconds] + rand()*$PACE_MS}] }
            set pmh_now [clock milliseconds]
            if {$pmh_next > $pmh_now} { after [expr {int($pmh_next - $pmh_now)}] } elseif {$pmh_now - $pmh_next > 10*$PACE_MS} { set pmh_next [expr {$pmh_now - 10*$PACE_MS}] }
            set pmh_next [expr {$pmh_next + $PACE_MS}]
            set choice [ RandomNumber 1 23 ]}
    incr n [regsub {\n\s*set choice \[ RandomNumber 1 23 \]} $script "\n$pace" script]
    if { $n != 3 } {
        puts "PARMAHAM_ERROR: could not inject pacing into the HammerDB driver ($n of 3 patches applied)"
        exit 1
    }
    set _ED(package) $script
    puts "PARMAHAM: pacing each virtual user to one transaction every $pace_ms ms"
}

vuset logtotemp 0
vuset unique 0
vuset showoutput 1
vuset vu $vu
vucreate
set runout [vurun]
vudestroy
# vurun returns "Benchmark Run jobid=<id>"
regexp {jobid=([0-9A-F]+)} $runout -> jobid

# The caller parses the "TEST RESULT : System achieved N NOPM from M MySQL TPM"
# line that the monitor virtual user prints.
# The HammerDB job database would otherwise grow forever on a permanent run
if { [info exists jobid] } { catch { jobs $jobid delete } }
exit
