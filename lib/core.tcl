encoding system utf-8
set SMEGGDROP_ROOT [file dirname [info script]]

# make "package require" work
#set ::auto_path {/usr/share/tcltk/tcl8.5 /usr/lib /usr/local/lib/tcltk /usr/local/share/tcltk /usr/lib/tcltk /usr/share/tcltk}

lappend auto_path $SMEGGDROP_ROOT/core/vendor/http

# safe interpreter
#source $SMEGGDROP_ROOT/core/http_local.tcl
source $SMEGGDROP_ROOT/core/safe_interp.tcl
