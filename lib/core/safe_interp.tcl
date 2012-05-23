namespace eval SInterp {
    # This name space is meant to hide state
    # keep a persistent interpreter until something messes up?
    
    variable safe_interp_is_safe 0
    variable our_last_safe_interp 0
}

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

        # set interp resource limits
        #interp limit $_interp command -value 1000  # max number of commands that can be executed
        #...

        set safe_interp_is_safe 1
    }
    return $our_last_safe_interp
}

proc safe_interp_eval {command} {
    global SInterp::safe_interp_is_safe
    set _interp [get_safe_interp]
    set safe_interp_is_safe 0
    interp limit $_interp command -value 1000
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
    #set _interp_result [interp eval $_interp $_current_command]
    set _interp_result [safe_interp_eval $_current_command]

    return $_interp_result
}

# called if a slave interp errors in the background
proc safe_interp_bgerror {message} {
    set timestamp [clock format [clock seconds]]
    core::say "bgerror in $::argv '$message'"
}
