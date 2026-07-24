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

namespace eval commands {
    proc words {} { core::words }
}
