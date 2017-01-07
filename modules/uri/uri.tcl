# uri.tcl --
#
#	URI parsing and fetch
#
# Copyright (c) 2000 Zveno Pty Ltd
# Copyright (c) 2006 Pierre DAVID <Pierre.David@crc.u-strasbg.fr>
# Copyright (c) 2006 Andreas Kupries <andreas_kupries@users.sourceforge.net>
# Copyright (c) 2017 Keith Nash <kjnash@users.sourceforge.net>
# Steve Ball, http://www.zveno.com/
# Derived from urls.tcl by Andreas Kupries
#
# TODO:
#	Handle www-url-encoding details
#
# CVS: $Id: uri.tcl,v 1.36 2011/03/23 04:39:54 andreas_kupries Exp $

package require Tcl 8.2

namespace eval ::uri {

    namespace export split join
    namespace export resolve isrelative
    namespace export geturl
    namespace export canonicalize
    namespace export register

    variable file:counter 0

    # --------------------------------------------------------------------------
    # These variables are used by uri::register and are a repository of
    # scheme-related pattern information that may be accessed by external code.
    # None is used by the other commands of this package.
    # --------------------------------------------------------------------------
    variable schemes       {}
    variable schemePattern ""
    variable url           ""
    variable url2part
    array set url2part     {}

    # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    # basic regular expressions used in URL syntax.

    namespace eval basic {
	# ----------------------------------------------------------------------
	# These variables are used to construct the variables used by commands.
	# ----------------------------------------------------------------------
	variable	digit		{[0-9]}
	variable	hex		{[0-9A-Fa-f]}
	variable	alphaDigit	{[A-Za-z0-9]}
	variable	alphaDigitMinus	{[A-Za-z0-9-]}
	variable	escape		"%${hex}${hex}"
	variable	digits		"${digit}+"

	variable	toplabel	\
		"(${alphaDigit}${alphaDigitMinus}*${alphaDigit}\\.?|${alphaDigit}\\.?)"
	variable	domainlabel	\
		"(${alphaDigit}${alphaDigitMinus}*${alphaDigit}|${alphaDigit})"

	variable	hostname	\
		"((${domainlabel}\\.)*${toplabel})"
	variable	hostnumber4	\
		"(?:${digits}\\.${digits}\\.${digits}\\.${digits})"
	variable	hostnumber6	{(?:\[[^]]*\])}
	variable	hostnumber	"(${hostnumber4}|${hostnumber6})"

	variable	usrCharN	{[a-zA-Z0-9$_.+!*'(,);?&=-]}
	variable	usrChar		"(${usrCharN}|${escape})"

	# ----------------------------------------------------------------------
	# >>> THESE VARIABLES ARE THE ONLY ONES USED BY COMMANDS <<<
	# ----------------------------------------------------------------------

	variable	hostspec	"${hostname}|${hostnumber}"
	variable	port		"${digit}*"
	variable	user		"${usrChar}*"
	variable	password	$user

	# ----------------------------------------------------------------------
	# This variable (and escape, hostname, hostnumber, port, user, password
	# from above) are used to construct the variables in the block below.
	# ----------------------------------------------------------------------

	variable	xCharN		{[a-zA-Z0-9$_.+!*'(,);/?:@&=-]}

	# ----------------------------------------------------------------------
	# These variables (and "escape") are used in the patterns defined in the
	# calls to uri::register at the end of the file.  They are not used by
	# any commands.
	# ----------------------------------------------------------------------

	variable	xChar		"(${xCharN}|${escape})"
	variable	host		"(${hostname}|${hostnumber})"
	variable	hostOrPort	"${host}(:${port})?"
	variable	login		"(${user}(:${password})?@)?${hostOrPort}"
	variable	alpha		{[a-zA-Z]}

	# ----------------------------------------------------------------------
	# These variables are not used by anything in this file.
	# ----------------------------------------------------------------------

	variable	loAlpha		{[a-z]}
	variable	hiAlpha		{[A-Z]}
	variable	safe		{[$_.+-]}
	variable	extra		{[!*'(,)]}
	# danger in next pattern, order important for []
	variable	national	{[][|\}\{\^~`]}
	variable	punctuation	{[<>#%"]}	;#" fake emacs hilit
	variable	reserved	{[;/?:@&=]}

	# next is <national | punctuation>
	variable	unsafe		{[][<>"#%\{\}|\\^~`]} ;#" emacs hilit

	#	unreserved	= alpha | digit | safe | extra
	#	xchar		= unreserved | reserved | escape

	variable	unreserved	{[a-zA-Z0-9$_.+!*'(,)-]}
	variable	uChar		"(${unreserved}|${escape})"

    } ;# basic {}
}

# ::uri::register --
#
#	Register a scheme (and aliases) in the package. The command
#	creates a namespace below "::uri" with the same name as the
#	scheme and executes the script declaring the pattern variables
#	for this scheme in the new namespace. At last it updates the
#	uri variables keeping track of overall scheme information.
#
#	The script has to declare at least the variable "schemepart",
#	the pattern for an url of the registered scheme after the
#	scheme declaration. Not declaring this variable is an error.
#
#	Registration provides a number of pattern variables for use by external
#	code.  It is unconnected to the commands provided by the uri package.
#	See the warnings near the end of this file where uri::register is
#	called.
#
# Arguments:
#	schemeList	Name of the scheme to register, plus aliases
#       script		Script declaring the scheme patterns
#
# Results:
#	None.

proc ::uri::register {schemeList script} {
    variable schemes
    variable schemePattern
    variable url
    variable url2part

    # Check scheme and its aliases for existence.
    foreach scheme $schemeList {
	if {[lsearch -exact $schemes $scheme] >= 0} {
	    return -code error \
		    "trying to register scheme (\"$scheme\") which is already known"
	}
    }

    # Get the main scheme
    set scheme  [lindex $schemeList 0]

    if {[catch {namespace eval $scheme $script} msg]} {
	catch {namespace delete $scheme}
	return -code error \
	    "error while evaluating scheme script: $msg"
    }

    if {![info exists ${scheme}::schemepart]} {
	namespace delete $scheme
	return -code error \
	    "Variable \"schemepart\" is missing."
    }

    # Now we can extend the variables which keep track of the registered schemes.

    eval [linsert $schemeList 0 lappend schemes]
    set schemePattern	"([::join $schemes |]):"

    foreach s $schemeList {
	# FRINK: nocheck
	set url2part($s) "${s}:[set ${scheme}::schemepart]"
	# FRINK: nocheck
	append url "(${s}:[set ${scheme}::schemepart])|"
    }
    set url [string trimright $url |]
    return
}

# ::uri::split --
#
#	Splits the given <a url> into its constituents.
#
# Arguments:
#	url	the URL to split
#
# Results:
#	Tcl list containing constituents, suitable for 'array set'.

proc ::uri::split {url {defaultscheme http}} {

    set url [string trim $url]
    set scheme {}

    # RFC 3986 Sec 3.1: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
    regexp -- {^([A-Za-z][A-Za-z0-9+.-]*):} $url dummy scheme

    if {$scheme == {}} {
	set scheme $defaultscheme
	switch -- $scheme {
	    http - https - ftp {
		# x/y     -> //x/y    PREPEND //
		# /x/y    -> ///x/y   PREPEND //
		# //x/y   -> //x/y
		# ///x/y  -> ///x/y
		# ////x/y -> ////x/y
		if {[string range $url 0 1] != "//"} {
		    set url //$url
		}
	    }
	}
    }

    # ease maintenance: dynamic dispatch, able to handle all schemes
    # added in future!

    if {[::info procs Split[string totitle $scheme]] == {}} {
	error "unknown scheme '$scheme' in '$url'"
    }

    regsub -- "^${scheme}:" $url {} url

    set       parts(scheme) [string tolower $scheme]
    array set parts [Split[string totitle $scheme] $url]

    # should decode all encoded characters!

    return [array get parts]
}

proc ::uri::SplitFtp {url} {
    # @c Splits the given ftp-<a url> into its constituents.
    # @a url: The url to split, without! scheme specification.
    # @r List containing the constituents, suitable for 'array set'.

    # general syntax:
    # //<user>:<password>@<host>:<port>/<cwd1>/.../<cwdN>/<name>;type=<typecode>
    #
    # additional rules:
    #
    # <user>:<password> are optional, detectable by presence of @.
    # <password> is optional too.
    #
    # "//" [ <user> [":" <password> ] "@"] <host> [":" <port>] "/"
    #	<cwd1> "/" ..."/" <cwdN> "/" <name> [";type=" <typecode>]

    upvar \#0 [namespace current]::ftp::typepart ftptype

    array set parts {user {} pwd {} host {} port {} path {} type {}}

    # slash off possible type specification

    if {[regexp -indices -- "${ftptype}$" $url dummy ftype]} {

	set from	[lindex $ftype 0]
	set to		[lindex $ftype 1]

	set parts(type)	[string range   $url $from $to]

	set from	[lindex $dummy 0]
	set url		[string replace $url $from end]
    }

    # Handle user, password, host and port

    if {[string match "//*" $url]} {
	set url [string range $url 2 end]

	array set parts [GetUPHP url]
    }

    set parts(path) [string trimleft $url /]

    return [array get parts]
}

proc ::uri::JoinFtp args {
    set uphp [eval [linsert $args 0 ComposeUPHP {}]]

    array set components {
	path {} type {}
    }
    array set components $args

    set type {}
    if {[string length $components(type)]} {
	set type \;type=$components(type)
    }

    return ftp://${uphp}/[string trimleft $components(path) /]$type
}

proc ::uri::SplitHttps {url} {
    return [SplitHttp $url]
}

proc ::uri::SplitHttp {url} {
    # @c Splits the given http-<a url> into its constituents.
    # @a url: The url to split, without! scheme specification.
    # @r List containing the constituents, suitable for 'array set'.

    # general syntax:
    # //<host>:<port>/<path>?<searchpart>
    #
    #   where <host> and <port> are as described in Section 3.1. If :<port>
    #   is omitted, the port defaults to 80.  No user name or password is
    #   allowed.  <path> is an HTTP selector, and <searchpart> is a query
    #   string. The <path> is optional, as is the <searchpart> and its
    #   preceding "?". If neither <path> nor <searchpart> is present, the "/"
    #   may also be omitted.
    #
    #   Within the <path> and <searchpart> components, "/", ";", "?" are
    #   reserved.  The "/" character may be used within HTTP to designate a
    #   hierarchical structure.
    #
    # path == <cwd1> "/" ..."/" <cwdN> "/" <name> ["#" <fragment>]

    array set parts {host {} port {} path {} query {} fragment {}}

    set fragmentPattern "#(.*)\$"

    # slash off possible fragment.

    # NOTE: This must be done before the query, because a fragment can
    # follow a query, and slashing off the query first will take the
    # fragment with it. Bug #3235340.

    if {[regexp -indices -- $fragmentPattern $url match fragment]} {
	set from [lindex $fragment 0]
	set to   [lindex $fragment 1]

	set parts(fragment) [string range $url $from $to]

	set url [string replace $url [lindex $match 0] end]
    }

    # slash off possible query. the 'search' regexp, while official,
    # is not good enough. We have apparently lots of urls in the wild
    # which contain unquoted urls with queries in a query. The RE
    # finds the embedded query, not the actual one. Using string first
    # now instead of a RE

    if {[set pos [string first ? $url]] >= 0} {
	incr pos
	set parts(query) [string range   $url $pos end]
	incr pos -1
	set url          [string replace $url $pos end]
    }

    if {[string match "//*" $url]} {
	set url [string range $url 2 end]

	array set parts [GetUPHP url]
    }

    set parts(path) [string trimleft $url /]

    return [array get parts]
}

proc ::uri::JoinHttp {args} {
    return [eval [linsert $args 0 ::uri::JoinHttpInner http 80]]
}

proc ::uri::JoinHttps {args} {
    return [eval [linsert $args 0 ::uri::JoinHttpInner https 443]]
}

proc ::uri::JoinHttpInner {scheme defport args} {
    set uphp [eval [linsert $args 0 ComposeUPHP $defport]]

    array set components {path {} query {} fragment {}}
    array set components $args

    set query {}
    if {[string length $components(query)]} {
	set query ?$components(query)
    }

    regsub -- {^/} $components(path) {} components(path)

    if { $components(fragment) != "" } {
	set components(fragment) "#$components(fragment)"
    } else {
	set components(fragment) ""
    }

    return $scheme://$uphp/$components(path)$query$components(fragment)
}

proc ::uri::SplitFile {url} {
    # @c Splits the given file-<a url> into its constituents.
    # @a url: The url to split, without! scheme specification.
    # @r List containing the constituents, suitable for 'array set'.

    upvar #0 [namespace current]::basic::hostspec	hostspec

    if {[string match "//*" $url]} {
	set url [string range $url 2 end]

	set hostPattern "^($hostspec)"

	switch -exact -- $::tcl_platform(platform) {
	    windows {
		# Catch drive letter
		append hostPattern :?
	    }
	    default {
		# Proceed as usual
	    }
	}

	if {[regexp -indices -- $hostPattern $url match host]} {
	    set fh	[lindex $host 0]
	    set th	[lindex $host 1]

	    set parts(host)	[string range $url $fh $th]

	    set  matchEnd   [lindex $match 1]
	    incr matchEnd

	    set url	[string range $url $matchEnd end]
	}
    }

    set parts(path) $url

    return [array get parts]
}

proc ::uri::JoinFile args {
    array set components {
	host {} port {} path {}
    }
    array set components $args

    switch -exact -- $::tcl_platform(platform) {
	windows {
	    if {[string length $components(host)]} {
		return file://$components(host):$components(path)
	    } else {
		return file://$components(path)
	    }
	}
	default {
	    set components(path) [string trimleft $components(path) /]
	    return file://$components(host)/$components(path)
	}
    }
}

proc ::uri::SplitMailto {url} {
    # @c Splits the given mailto-<a url> into its constituents.
    # @a url: The url to split, without! scheme specification.
    # @r List containing the constituents, suitable for 'array set'.

    if {[string match "*@*" $url]} {
	set url [::split $url @]
	return [list user [lindex $url 0] host [lindex $url 1]]
    } else {
	return [list user $url]
    }
}

proc ::uri::JoinMailto args {
    array set components {
	user {} host {}
    }
    array set components $args

    return mailto:$components(user)@$components(host)
}

proc ::uri::SplitNews {url} {
    if { [string first @ $url] >= 0 } {
	return [list message-id $url]
    } else {
	return [list newsgroup-name $url]
    }
}

proc ::uri::JoinNews args {
    array set components {
	message-id {} newsgroup-name {}
    }
    array set components $args
    return news:$components(message-id)$components(newsgroup-name)
}

proc ::uri::SplitLdaps {url} {
    ::uri::SplitLdap $url
}

proc ::uri::SplitLdap {url} {
    # @c Splits the given Ldap-<a url> into its constituents.
    # @a url: The url to split, without! scheme specification.
    # @r List containing the constituents, suitable for 'array set'.

    # general syntax:
    # //<host>:<port>/<dn>?<attrs>?<scope>?<filter>?<extensions>
    #
    #   where <host> and <port> are as described in Section 5 of RFC 1738.
    #   No user name or password is allowed.
    #   If omitted, the port defaults to 389 for ldap, 636 for ldaps
    #   <dn> is the base DN for the search
    #   <attrs> is a comma separated list of attributes description
    #   <scope> is either "base", "one" or "sub".
    #   <filter> is a RFC 2254 filter specification
    #   <extensions> are documented in RFC 2255
    #

    array set parts {host {} port {} dn {} attrs {} scope {} filter {} extensions {}}

    #          host        port           dn          attrs       scope               filter     extns
    set re {//((?:[^:?/]+)|(?:\[[^\]]*\]))(?::([0-9]+))?(?:/([^?]+)(?:\?([^?]*)(?:\?(base|one|sub)?(?:\?([^?]*)(?:\?(.*))?)?)?)?)?}

    if {! [regexp $re $url match parts(host) parts(port) \
		parts(dn) parts(attrs) parts(scope) parts(filter) \
		parts(extensions)]} then {
	return -code error "unable to match URL \"$url\""
    }

    set parts(attrs) [::split $parts(attrs) ","]

    return [array get parts]
}

proc ::uri::JoinLdap {args} {
    return [eval [linsert $args 0 ::uri::JoinLdapInner ldap 389]]
}

proc ::uri::JoinLdaps {args} {
    return [eval [linsert $args 0 ::uri::JoinLdapInner ldaps 636]]
}

proc ::uri::JoinLdapInner {scheme defport args} {
    array set components {host {} port {} dn {} attrs {} scope {} filter {} extensions {}}
    set       components(port) $defport
    array set components $args

    set port {}
    if {[string length $components(port)] && $components(port) != $defport} {
	set port :$components(port)
    }

    set url "$scheme://$components(host)$port"

    set components(attrs) [::join $components(attrs) ","]

    set s ""
    foreach c {dn attrs scope filter extensions} {
	if {[string equal $c "dn"]} then {
	    append s "/"
	} else {
	    append s "?"
	}
	if {! [string equal $components($c) ""]} then {
	    append url "${s}$components($c)"
	    set s ""
	}
    }

    return $url
}

proc ::uri::ComposeUPHP {defport args} {
    # user:pwd@host:port

    array set components {
	user {} pwd {} host {} port {}
    }
    set       components(port) $defport
    array set components $args

    set userPwd {}
    if {[string length $components(user)] || [string length $components(pwd)]} {
	set userPwd $components(user)[expr {[string length $components(pwd)] ? ":$components(pwd)" : {}}]@
    }

    set port {}
    if {[string length $components(port)] && $components(port) != $defport} {
	set port :$components(port)
    }

    return ${userPwd}$components(host)${port}
}

proc ::uri::GetUPHP {urlvar} {
    # @c Parse user, password host and port out of the url stored in
    # @c variable <a urlvar>.
    # @d Side effect: The extracted information is removed from the given url.
    # @r List containing the extracted information in a format suitable for
    # @r 'array set'.
    # @a urlvar: Name of the variable containing the url to parse.

    upvar \#0 [namespace current]::basic::user		user
    upvar \#0 [namespace current]::basic::password	password
    upvar \#0 [namespace current]::basic::hostspec	hostspec
    upvar \#0 [namespace current]::basic::port		port

    upvar $urlvar url
    set url_save $url

    array set parts {user {} pwd {} host {} port {}}

    # syntax
    # "//" [ <user> [":" <password> ] "@"] <host> [":" <port>] "/"
    # "//" already cut off by caller

    set upPattern "^(${user})(:(${password}))?@"

    if {[regexp -indices -- $upPattern $url match theUser c d thePassword]} {
	set fu	[lindex $theUser 0]
	set tu	[lindex $theUser 1]

	set fp	[lindex $thePassword 0]
	set tp	[lindex $thePassword 1]

	set parts(user)	[string range $url $fu $tu]
	set parts(pwd)	[string range $url $fp $tp]

	set  matchEnd   [lindex $match 1]
	incr matchEnd

	set url	[string range $url $matchEnd end]
    }

    set hpPattern "^($hostspec)(:($port))?"

    if {[regexp -indices -- $hpPattern $url match theHost c d e f g h thePort]} {
	set fh	[lindex $theHost 0]
	set th	[lindex $theHost 1]

	set fp	[lindex $thePort 0]
	set tp	[lindex $thePort 1]

	set parts(host)	[string range $url $fh $th]
	set parts(port)	[string range $url $fp $tp]

	set  matchEnd   [lindex $match 1]
	incr matchEnd

	set url	[string range $url $matchEnd end]
    }
    
    if {![string match /* $url] && $url ne {}} {
	error [list {invalid url} $url $url_save]
    }

    return [array get parts]
}

# ::uri::resolve --
#
#	Resolve an arbitrary URL, given a base URL
#
# This code depends on the ability of uri::split to process relative URIs.
# N.B. http(s): and ftp: path does not begin with "/" and may be empty.
# The file: path (unix) always begins "/", even if a host is specified.
#
# RFC 3986 Sec. 5.2 defines how URI relative resolution should proceed.
# This command is a "strict parser" in the sense of Sec. 5.2.2: it does not
# allow a relative URI such as "http:foo/bar.html".  See also the last example
# in Sec. 5.4.2 and uri-rfc2396.test test uri-rfc2396-11.19.
#
# Arguments:
#	base	base URL (absolute)
#	url	arbitrary URL
#
# Results:
#	Returns a URL

proc ::uri::resolve {base url} {
    if {[isrelative $url]} {
	set canon 1
	array set baseparts [split $base]

	switch -- $baseparts(scheme) {
	    http -
	    https -
	    ftp -
	    file {
		set changed 0
		array set relparts [split $baseparts(scheme):$url]
		if {[array names relparts path] != {path}} {
		    set relparts(path) {}
		}
		if { [string match /* $url] } {
		    set baseparts(path) $relparts(path)
		    catch {
			if {$relparts(host) != ""} {
			    # RFC 3986 section 4.2 and 5.2.2.
			    # url has no scheme, but has authority
			    # ("UPHP" or User,Password,Host,Port). Use that
			    # authority. Do not transfer credentials or port
			    # number from the base authority.
			    set baseparts(host) $relparts(host)
			    set baseparts(user) {}
			    set baseparts(pwd)  {}
			    set baseparts(port) {}
			    set baseparts(user) $relparts(user)
			    set baseparts(pwd)  $relparts(pwd)
			    set baseparts(port) $relparts(port)
			}
		    }
		    set changed 1
		} elseif {    [string match */ $baseparts(path)]
			   && ([string length $relparts(path)] > 0)
		} {
		    set baseparts(path) "$baseparts(path)$relparts(path)"
		    set changed 1
		} elseif { [string length $relparts(path)] > 0 } {
		    set path [lreplace [::split $baseparts(path) /] end end]
		    set baseparts(path) "[::join $path /]/$relparts(path)"
		    set changed 1
		} else {
		    # Do not overwrite baseparts(path).  In this case,
		    # RFC 3986 Sec. 5.2.2 does not demand canonicalization.
		    # FIXME check whether it assumes the base URI is already canonical.
		    set canon 0
		}
	    }
	    default {
		return -code error "unable to resolve relative URL \"$url\""
	    }
	}

	# query and fragment are defined for http, https; not for file, ftp
	# FIXME check the RFCs re fragment: it is useful in HTML documents when
	# accessed by file or ftp.
	switch -- $baseparts(scheme) {
	    http -
	    https {
		if {[array names relparts query] != {query}} {
		    set relparts(query) {}
		}
		if {[array names relparts fragment] != {fragment}} {
		    set relparts(fragment) {}
		}

		if {$changed || ($relparts(query) != {})} {
		    set baseparts(query) $relparts(query)
		    set changed 1
		} else {
		    # Keep base query.
		    # FIXME error if url has empty query "?".
		}

		# RFC 3986 section 5.2.2 requires that the base fragment
		# is always discarded.
		set baseparts(fragment) $relparts(fragment)
		# FIXME (in split/join) empty fragment "#".
	    }
	    ftp -
	    file -
	    default {
	    }
	}
	set url [eval [linsert [array get baseparts] 0 join]]
	if {$canon} {
	    # RFC 3986 section 5.2.2 requires us to canonicalize the path.
	    set url [canonicalize $url]
	} else {
	}
	return $url
    } else {
	# RFC 3986 section 5.2.2 requires us to canonicalize the path.
	set url [canonicalize $url]
	return $url
    }
}

# ::uri::isrelative --
#
#	Determines whether a URL is absolute or relative
#
# Arguments:
#	url	URL to check
#
# Results:
#	Returns 1 if the URL is relative, 0 otherwise

proc ::uri::isrelative url {
    return [expr {![regexp -- {^[A-Za-z][A-Za-z0-9+.-]*:} $url]}]
}

# ::uri::geturl --
#
#	Fetch the data from an arbitrary URL.
#
#	This package provides a handler for the file:
#	scheme, since this conflicts with the file command.
#
# Arguments:
#	url	address of data resource
#	args	configuration options
#
# Results:
#	Depends on scheme

proc ::uri::geturl {url args} {
    array set urlparts [split $url]

    switch -- $urlparts(scheme) {
	file {
        return [eval [linsert $args 0 file_geturl $url]]
	}
	default {
	    # Load a geturl package for the scheme first and only if
	    # that fails the scheme package itself. This prevents
	    # cyclic dependencies between packages.
	    if {[catch {package require $urlparts(scheme)::geturl}]} {
		package require $urlparts(scheme)
	    }
        return [eval [linsert $args 0 $urlparts(scheme)::geturl $url]]
	}
    }
}

# ::uri::file_geturl --
#
#	geturl implementation for file: scheme
#
# TODO:
#	This is an initial, basic implementation.
#	Eventually want to support all options for geturl.
#
# Arguments:
#	url	URL to fetch
#	args	configuration options
#
# Results:
#	Returns data from file

proc ::uri::file_geturl {url args} {
    variable file:counter

    set var [namespace current]::file[incr file:counter]
    upvar #0 $var state
    array set state {data {}}

    array set parts [split $url]

    set ch [open $parts(path)]
    # Could determine text/binary from file extension,
    # except on Macintosh
    # fconfigure $ch -translation binary
    set state(data) [read $ch]
    close $ch

    return $var
}

# ::uri::join --
#
#	Format a URL
#
# Arguments:
#	args	components, key-value format
#
# Results:
#	A URL

proc ::uri::join args {
    array set components $args

    return [eval [linsert $args 0 Join[string totitle $components(scheme)]]]
}

# ::uri::canonicalize --
#
#	Canonicalize a URL
#
# Acknowledgements:
#	Andreas Kupries <andreas_kupries@users.sourceforge.net>
#	Keith Nash <kjnash@users.sourceforge.net>
#
# Arguments:
#	uri	URI (which contains a path component)
#
# Results:
#	The canonical form of the URI

proc ::uri::canonicalize uri {

    # Make uri canonical with respect to dots (path changing commands)
    #
    # Remove single dots (.)  => pwd not changing
    # Remove double dots (..) => gobble previous segment of path
    #
    # Fixes for this command:
    #
    # * Ignore any url which cannot be split into components by this
    #   module. Just assume that such urls do not have a path to
    #   canonicalize.
    #
    # * Ignore any url which could be split into components, but does
    #   not have a path component.
    #
    # In the text above 'ignore' means
    # 'return the url unchanged to the caller'.

    if {[catch {array set u [::uri::split $uri]}]} {
	return $uri
    }
    if {![info exists u(path)]} {
	return $uri
    }

    set oldList [::split $u(path) /]

    if {[lindex $oldList 0] == {}} {
	set lead 1
    } else {
	set lead 0
    }

    set end [llength $oldList]
    incr end -1

    # i - index of element seg in oldList
    # j - index of last element written to newList
    set i 0
    set j -1
    set newList {}
    foreach seg $oldList {
	if {($seg == {}) && ($i != 0) && ($i != $end)} {
	    # Throw away this empty segment.
	    # This merges adjacent "/".
	    # If the first or last segment is empty, it is handled at "else".
	} elseif {($seg == {.}) && ($i == $end)} {
	    # Replace "." with {} to keep a trailing "/" in path.
	    lappend newList {}
	    incr j
	} elseif {$seg == {.}} {
	    # Throw away this "." segment.
	} elseif {($seg == {..}) && ($j > $lead - 1) && ($i == $end)} {
	    # Remove the element previously added to newList, and
	    # replace it with {} to keep a trailing "/" in path.
	    set newList [lreplace $newList $j $j {}]
	} elseif {($seg == {..}) && ($j > $lead - 1)} {
	    # Remove the element previously added to newList.
	    set newList [lreplace $newList $j $j]
	    incr j -1
	} elseif {($seg == {..}) && ($i == $end)} {
	    # Can't go any deeper in newList, but this path needs a
	    # leading "/".
	    lappend newList {}
	    incr j
	} elseif {$seg == {..}} {
	    # Can't go any deeper in newList.
	} else {
	    # A "normal" path segment!
	    lappend newList $seg
	    incr j
	}

	incr i
    }

    set u(path) [::join $newList /]
    set uri [eval [linsert [array get u] 0 ::uri::join]]

    return $uri
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# regular expressions covering various url schemes

# Currently known URL schemes:
#
# (RFC 1738)
# ------------------------------------------------
# scheme	basic syntax of scheme specific part
# ------------------------------------------------
# ftp		//<user>:<password>@<host>:<port>/<cwd1>/.../<cwdN>/<name>;type=<typecode>
#    		//<user>:<password>@<host>:<port>/fpath;type=<typecode>
#
# http		//<host>:<port>/<hpath>?<searchpart>
#
# gopher	//<host>:<port>/<gophertype><selector>
#				<gophertype><selector>%09<search>
#		<gophertype><selector>%09<search>%09<gopher+_string>
#
# mailto	<rfc822-addr-spec>
# news		<newsgroup-name>
#		<message-id>
# nntp		//<host>:<port>/<newsgroup-name>/<article-number>
# telnet	//<user>:<password>@<host>:<port>/
# wais		//<host>:<port>/<database>
#		//<host>:<port>/<database>?<search>
#		//<host>:<port>/<database>/<wtype>/<wpath>
# file		//<host>/<fpath>
# prospero	//<host>:<port>/<hsoname>;<field>=<value>
# ------------------------------------------------
#
# (RFC 2111)
# ------------------------------------------------
# scheme	basic syntax of scheme specific part
# ------------------------------------------------
# mid	message-id
#		message-id/content-id
# cid	content-id
# ------------------------------------------------
#
# (RFC 2255)
# ------------------------------------------------
# scheme	basic syntax of scheme specific part
# ------------------------------------------------
# ldap		//<host>:<port>/<dn>?<attrs>?<scope>?<filter>?<extensions>
# ------------------------------------------------


# ------------------------------------------------------------------------------
#     IMPORTANT WARNINGS
# ------------------------------------------------------------------------------
# (1) THE PATTERNS DEFINED BELOW (with one exception) ARE NOT USED FOR PARSING
#     URLS BY ANY OF THIS PACKAGE'S COMMANDS.
# (2) THAT EXCEPTION IS THE VARIABLE ::uri::ftp::typepart
# (3) AS LONG AS THAT VARIABLE IS ASSIGNED THE CORRECT VALUE, ALL THE
#     uri::register CALLS CAN BE DELETED WITHOUT AFFECTING THE uri::* COMMANDS.
# (2) REGISTRATION OF A SCHEME DOES NOT IMPLEMENT COMMANDS FOR THAT SCHEME.
# (3) REGISTRATION OF A SCHEME IS NOT NECESSARY TO IMPLEMENT COMMANDS FOR THAT
#     SCHEME.
#     Instead:
# (4) THE PATTERNS ARE FOR REFERENCE, AND CAN BE ACCESSED VIA THESE NAMESPACE
#     VARIABLES, OR IN SOME CASES VIA VARIABLES MAINTAINED BY uri::register.
# (5) THE VARIABLES schemepart AND url ARE MENTIONED IN THE DOCUMENTATION.
# (6) UNDOCUMENTED VARIABLES MIGHT BE ACCESSED BY THIRD-PARTY CODE.
# (7) THEREFORE EVERYTHING IS RETAINED FOR BACKWARD COMPATIBILITY.
# ------------------------------------------------------------------------------

# FTP
uri::register ftp {
    # Please read the warnings above.
    variable escape [set [namespace parent [namespace current]]::basic::escape]
    variable login  [set [namespace parent [namespace current]]::basic::login]

    variable	charN	{[a-zA-Z0-9$_.+!*'(,)?:@&=-]}
    variable	char	"(${charN}|${escape})"
    variable	segment	"${char}*"
    variable	path	"${segment}(/${segment})*"

    variable	type		{[AaDdIi]}
    variable	typepart	";type=(${type})"
    # Used elsewhere: typepart

    variable	schemepart	\
		    "//${login}(/${path}(${typepart})?)?"

    variable	url		"ftp:${schemepart}"
}

# FILE
uri::register file {
    # Please read the warnings above.
    variable	host [set [namespace parent [namespace current]]::basic::host]
    variable	path [set [namespace parent [namespace current]]::ftp::path]

    variable	schemepart	"//(${host}|localhost)?/${path}"
    variable	url		"file:${schemepart}"
}

# HTTP
uri::register http {
    # Please read the warnings above.
    variable	escape \
        [set [namespace parent [namespace current]]::basic::escape]
    variable	hostOrPort	\
        [set [namespace parent [namespace current]]::basic::hostOrPort]

    variable	charN		{[a-zA-Z0-9$_.+!*'(,);:@&=-]}
    variable	char		"($charN|${escape})"
    variable	segment		"${char}*"

    variable	path		"${segment}(/${segment})*"
    variable	search		$segment
    variable	schemepart	\
	    "//${hostOrPort}(/${path}(\\?${search})?)?"

    variable	url		"http:${schemepart}"
}

# GOPHER
uri::register gopher {
    # Please read the warnings above.
    variable	xChar \
        [set [namespace parent [namespace current]]::basic::xChar]
    variable	hostOrPort \
        [set [namespace parent [namespace current]]::basic::hostOrPort]
    variable	search \
        [set [namespace parent [namespace current]]::http::search]

    variable	type		$xChar
    variable	selector	"$xChar*"
    variable	string		$selector
    variable	schemepart	\
	    "//${hostOrPort}(/(${type}(${selector}(%09${search}(%09${string})?)?)?)?)?"
    variable	url		"gopher:${schemepart}"
}

# MAILTO
uri::register mailto {
    # Please read the warnings above.
    variable xChar [set [namespace parent [namespace current]]::basic::xChar]
    variable host  [set [namespace parent [namespace current]]::basic::host]

    variable schemepart	"$xChar+(@${host})?"
    variable url	"mailto:${schemepart}"
}

# NEWS
uri::register news {
    # Please read the warnings above.
    variable escape [set [namespace parent [namespace current]]::basic::escape]
    variable alpha  [set [namespace parent [namespace current]]::basic::alpha]
    variable host   [set [namespace parent [namespace current]]::basic::host]

    variable	aCharN		{[a-zA-Z0-9$_.+!*'(,);/?:&=-]}
    variable	aChar		"($aCharN|${escape})"
    variable	gChar		{[a-zA-Z0-9$_.+-]}
    variable	newsgroup-name	"${alpha}${gChar}*"
    variable	message-id	"${aChar}+@${host}"
    variable	schemepart	"\\*|${newsgroup-name}|${message-id}"
    variable	url		"news:${schemepart}"
}

# WAIS
uri::register wais {
    # Please read the warnings above.
    variable	uChar \
        [set [namespace parent [namespace current]]::basic::xChar]
    variable	hostOrPort \
        [set [namespace parent [namespace current]]::basic::hostOrPort]
    variable	search \
        [set [namespace parent [namespace current]]::http::search]

    variable	db		"${uChar}*"
    variable	type		"${uChar}*"
    variable	path		"${uChar}*"

    variable	database	"//${hostOrPort}/${db}"
    variable	index		"//${hostOrPort}/${db}\\?${search}"
    variable	doc		"//${hostOrPort}/${db}/${type}/${path}"

    #variable	schemepart	"${doc}|${index}|${database}"

    variable	schemepart \
	    "//${hostOrPort}/${db}((\\?${search})|(/${type}/${path}))?"

    variable	url		"wais:${schemepart}"
}

# PROSPERO
uri::register prospero {
    # Please read the warnings above.
    variable	escape \
        [set [namespace parent [namespace current]]::basic::escape]
    variable	hostOrPort \
        [set [namespace parent [namespace current]]::basic::hostOrPort]
    variable	path \
        [set [namespace parent [namespace current]]::ftp::path]

    variable	charN		{[a-zA-Z0-9$_.+!*'(,)?:@&-]}
    variable	char		"(${charN}|$escape)"

    variable	fieldname	"${char}*"
    variable	fieldvalue	"${char}*"
    variable	fieldspec	";${fieldname}=${fieldvalue}"

    variable	schemepart	"//${hostOrPort}/${path}(${fieldspec})*"
    variable	url		"prospero:$schemepart"
}

# LDAP
uri::register ldap {
    # Please read the warnings above.
    variable	hostOrPort \
        [set [namespace parent [namespace current]]::basic::hostOrPort]

    # very crude parsing
    variable	dn		{[^?]*}
    variable	attrs		{[^?]*}
    variable	scope		"base|one|sub"
    variable	filter		{[^?]*}
    # extensions are not handled yet

    variable	schemepart	"//${hostOrPort}(/${dn}(\?${attrs}(\?(${scope})(\?${filter})?)?)?)?"
    variable	url		"ldap:$schemepart"
}

package provide uri 1.2.7
