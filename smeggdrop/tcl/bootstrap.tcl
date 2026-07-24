# bootstrap for the python port: context accessors and small compat shims.
# sourced into the safe slave before saved state is loaded, so saved procs
# with the same names win.

proc nick {} {return $context::nick}
proc channel {} {return $context::channel}
proc mask {} {return $context::mask}
proc command {} {return $context::command}
proc nicks {} {return $context::nicks}

# some saved procs use [alias] to publish namespaced procs as global names
proc alias {name target} {
    interp alias {} $name {} $target
}

namespace eval commands {
    proc words {} { core::words }
}
