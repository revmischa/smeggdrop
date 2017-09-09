namespace eval SInterp {
    # This name space is meant to hide state
    # keep a persistent interpreter until something messes up?
    
    variable safe_interp_is_safe 0
    variable our_last_safe_interp 0

    proc needs_state_reload {} {
        variable safe_interp_is_safe
        if { $safe_interp_is_safe == 1 } {
            return 0
        } else {
            return 1
        }
    }
}

# get current context vars
proc nick {} {return $context::nick}
proc channel {} {return $context::channel}
proc mask {} {return $context::mask}
proc command {} {return $context::command}

# I think this has to be in a namespace that we can't modify

proc get_safe_interp {args} {
    global SInterp::safe_interp_is_safe
    global SInterp::our_last_safe_interp
    if { $safe_interp_is_safe==1 } {
    } else {
        # CREATE singleton
        set our_last_safe_interp [interp create -safe]

        # set bg error handler
        interp bgerror $our_last_safe_interp safe_interp_bgerror

        foreach mod [list meta_proc meta cache dict] {
            $our_last_safe_interp invokehidden source "$::SMEGGDROP_ROOT/core/${mod}.tcl"
        }

        # export some procs to slave
        $our_last_safe_interp alias nick nick
        $our_last_safe_interp alias mask mask
        $our_last_safe_interp alias channel channel
        $our_last_safe_interp alias command command
        $our_last_safe_interp alias clock clock

        set safe_interp_is_safe 1
    }
    return $our_last_safe_interp
}

proc export_proc_to_slave {fullname} {
    [get_safe_interp] alias $fullname $fullname
}

proc safe_interp_eval {command} {
    global SInterp::safe_interp_is_safe
    set _interp [get_safe_interp]
    set safe_interp_is_safe 0
    #interp limit $_interp command -value 1000  # this would be nice, but it's not per-eval
    set _result [interp eval $_interp $command]
    set safe_interp_is_safe 1
    return $_result
}

proc safe_interp {args} {
    # create a safe interpreter
    # this has many harmful functions hidden
    set _interp [get_safe_interp]
    
    # get current command
    set _current_command "$context::command"

    # do safe eval
    set _interp_result [safe_interp_eval $_current_command]

    return $_interp_result
}

# called if a slave interp errors in the background
proc safe_interp_bgerror {message} {
    set timestamp [clock format [clock seconds]]
    core::say "bgerror in $::argv '$message'"
}
