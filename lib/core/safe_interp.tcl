proc safe_interp {args} {
    # create a safe interpreter
    # this has many harmful functions hidden
    set _interp [interp create -safe]

    # set interp resource limits
    #interp limit $_interp command -value 1000  # max number of commands that can be executed
    #...

    # set bg error handler
    $_interp bgerror safe_interp_bgerror

    # get current command
    set _current_command "$context::command"

    # do safe eval
    set _interp_result [interp eval $_interp $_current_command]
    return $_interp_result
}

# called if a slave interp errors in the background
proc safe_interp_bgerror {message} {
    set timestamp [clock format [clock seconds]]
    core::say "bgerror in $::argv '$message'"
}