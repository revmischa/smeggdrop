# http compat for saved procs, same interface as the tclcurl-era http.tcl:
#   http get $url            -> [list code {header value ...} body]
#   http post $url $body ?k v ...?
#   http head $url           -> {header value ...}
# backed by the host's guarded fetcher (core::http), which enforces the
# scheme/address policy and per-eval limits.

namespace eval httpx {
  proc get url {
    core::http GET $url
  }

  proc post {url body args} {
    if {[llength $args]} {
      # legacy form: post url k v ?k v ...? url-encodes pairs ($body is
      # the first key, like http::formatQuery did)
      set pairs [linsert $args 0 $body]
      set enc [list]
      foreach {k v} $pairs {
        lappend enc "[core::urlencode $k]=[core::urlencode $v]"
      }
      set body [join $enc &]
    }
    core::http POST $url $body
  }

  proc head url {
    lindex [core::http HEAD $url] 1
  }
}

namespace eval commands {
  meta_proc http -namespace httpx head get post
}
