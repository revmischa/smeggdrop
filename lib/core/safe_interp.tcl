
proc get_safe_interp {args} {
    global safe_interp_is_safe
    global our_last_safe_interp
    if { $safe_interp_is_safe==1 } {
    } else {
        set our_last_safe_interp [interp create -safe]
        set safe_interp_is_safe 1
    }
    return $our_last_safe_interp        
}

proc safe_interp_eval {command} {
    set _interp [get_safe_interp]
    set _result [interp eval $_interp $command]
    return $_result
}


proc safe_interp {args} {
    # create a safe interpreter
    # this has many harmful functions hidden
    set _interp [get_safe_interp]

    # set interp resource limits
    #interp limit $_interp command -value 1000  # max number of commands that can be executed
    #...

    # set bg error handler
    $_interp bgerror safe_interp_bgerror

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
