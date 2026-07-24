# bootstrap for the python port: context accessors and small compat shims.
# sourced into the safe slave before saved state is loaded, so saved procs
# with the same names win.

proc nick {} {return $context::nick}
proc channel {} {return $context::channel}
proc mask {} {return $context::mask}
proc command {} {return $context::command}
proc nicks {} {return $context::nicks}

# irc-era accessors a lot of saved procs rely on
proc names {} {return $context::nicks}

# recent channel chatter as {unix_ts nick mask text} rows
proc log {} {return $context::log}

# best-effort: the old hostmask proc looked nicks up in channel state,
# which chat platforms don't have; fall back to scanning recent chatter
proc hostmask {who} {
    foreach line [log] {
        lassign $line _ts _nick _mask _text
        if {[string equal -nocase $_nick $who]} {return $_mask}
    }
    return "$who!unknown@unknown"
}

# some saved procs use [alias] to publish namespaced procs as global names
proc alias {name target} {
    interp alias {} $name {} $target
}

# the old versioned interpreter exposed this; cache::fetch et al use it to
# evaluate a script at interpreter (global) level
proc interp_eval {script} {
    uplevel #0 $script
}

# [apply] means two different things in the saved state.
#
# Tcl 8.5 introduced a builtin taking a lambda: [apply {{x} {body}} arg].
# Saved procs like map/select/cseq use that. But smeggdrop also had its own
# [apply] meaning "run this command with this argument list":
# [apply {format %s-%s} {a b}], and procs like yield use *that*. Whichever
# one is installed, the other convention's callers break — which is what
# made cseq (and everything built on it) fail.
#
# The builtin is stashed as tcl_apply before any of this loads (see
# interp.py). Dispatch on the shape of the first argument: a lambda's first
# element is an argument list, so it does not name an existing command,
# while the classic form's does. The heuristic can be fooled, hence the
# fallback.
proc apply {cmd args} {
    if {([llength $cmd] == 2 || [llength $cmd] == 3)
            && ![llength [info commands [lindex $cmd 0]]]} {
        return [uplevel 1 [linsert $args 0 tcl_apply $cmd]]
    }
    # {*} so the classic form keeps concat's flattening: [apply {format %s-%s}
    # {a b}] must run "format %s-%s a b", not pass {a b} as one argument
    if {[catch {uplevel 1 [concat $cmd {*}$args]} result options]} {
        if {[llength $cmd] == 2 || [llength $cmd] == 3} {
            if {![catch {uplevel 1 [linsert $args 0 tcl_apply $cmd]} alternate]} {
                return $alternate
            }
        }
        return -options $options $result
    }
    return $result
}

namespace eval commands {
    proc words {} { core::words }
}
