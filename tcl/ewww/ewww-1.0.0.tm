package provide odfi::ewww 1.0.0
package require odfi::common
package require odfi::closures 3.0.0
package require odfi::files 2.0.0

### CODE Based on JohnBuckman http://wiki.tcl.tk/15244
###############################################################

package require uri
package require base64
package require ncgi
package require snit

namespace eval odfi::ewww {

    ################################################################################
    ## Classes
    ################################################################################
    odfi::common::resetNamespaceClasses [namespace current]

    lappend auto_path ./tls

    proc bgerror {msg} {
            odfi::common::logError "bgerror: $::errorInfo"

    }



    itcl::class Httpd {

        ## Base configs
        public variable port "80"
        public variable pki {}
        public variable userpwds {}
        public variable realm {Trivial Tcl Web V2.0}
        public variable handlers {}

        ## List of authorized users from userpwds
        variable authList {}

        variable listeningSocket

        ## \brief Started or not started
        public variable started false

        constructor {cPort args} {

            ## Default Configure
            ###############################
            if {[llength $args]>0} {
                configure $args
            }

            set port $cPort

            ## Process User passwords
            ###################
            foreach up $userpwds {
                lappend authList [base64::encode $up]
            }


        }

        destructor {
            catch {close $listeningSocket}
        }

        ## \brief Starts the Socket
        public method start args {

            ## If PKI Provided, try to start TLS
            #########################
            if {$pki ne {}} {

                ## Require TLS pckage and init certificates
                package require tls
                foreach {certfile keyfile} $pki {break}

                ## Init TLS and start socket
                tls::init -certfile $certfile -keyfile  $keyfile \
                    -ssl2 1 -ssl3 1 -tls1 0 -require 0 -request 0
                set listeningSocket [tls::socket -server [mymethod accept] $port]

            } else {

                ## No PKI provided, normal socket
                set listeningSocket [socket -server "${this} accept" $port]
                set started true

                ## Configure
                #chan configure $listeningSocket -encoding utf-8

            }
            odfi::log::info "Listening socket: $listeningSocket started on port $port ..."

        }

        ## \brief Closes the socket
        public method stop args {

            catch {close $listeningSocket}


        }

        ## \brief Accept connection for a client
        public method accept {sock ip port} {

            odfi::log::fine "Accepted connection from $ip"

            ## Configure
            #chan configure $sock -encoding utf-8
            #chan configure $sock -encoding utf-8 -translation crlf -blocking 1
            chan configure $sock -encoding utf-8 -translation binary -blocking 1
            #chan configure $sock -blocking 1

            if {[catch {

                ## Parse HTTP
                ##############
                gets $sock line
                set auth ""
                for {set c 0} {[gets $sock temp]>=0 && $temp ne "\r" && $temp ne ""} {incr c} {
                    regexp {Authorization: Basic ([^\r\n]+)} $temp -- auth
                    if {$c == 30} {error "Too many lines from $ip"}
                }
                if {[eof $sock]} {error "Connection closed from $ip"}

                ## Split HTTP line argument
                ################
                foreach {method uri version} $line {break}
                switch -exact $method {
                    GET {$this serve $sock $ip $uri $auth}
                    POST {$this serve $sock $ip $uri $auth}
                    default {error "Unsupported method '$method' from $ip"}
                }
            } msg resOptions]} {
                puts "Error: $msg [dict get $resOptions -errorinfo]"

		#close $sock
		#error $msg
            }
            close $sock
        }

        public method authenticate {sock ip auth} {
            if {[lsearch -exact $authList $auth]==-1} {
                respond $sock 401 Unauthorized "WWW-Authenticate: Basic realm=\"$realm\"\n"
                odfi::log::warn "Unauthorized from $ip"
                return 0
            } else {return 1}
        }


        ## \brief Serves a request by using handler list
        public method serve {sock ip uri auth} {

            ## Check authentication
            ##########
            if {[llength $authList] ne 0 && [$self authenticate $sock $ip $auth] ne 1} return

            ## Split request path
            array set request [uri::split $uri]



            ## Look for a handler for given path
            #############################
            set requestPath "/$request(path)"

           

            ## Clean all // -> /
            #set requestPath [string map {// /} $requestPath]
            set requestPath  [regsub -all {//+} $requestPath "/"]
            
            #set requestPathSplitted [odfi::list::filter [split $requestPath /] {
            #        expr [expr [string length $it] > 0 ? true : false]
            #}]
            #set requestPath [join $requestPathSplitted /]

            odfi::log::fine "Got request for URI: $uri , and path: $requestPath"

            ## Modify URI array
            array set request [list path $requestPath]

            ## Search for handler
            #set handler [lsearch -glob $handlers $request(path)]

            set handler ""
            switch -glob "$requestPath" $handlers

            if {$handler!=""} {
                
                set localRequestPath [string map [list [$handler cget -path] "/" // /] "$requestPath"]
                
                odfi::log::fine "Found handler for $requestPath ([$handler cget -path]) -> $localRequestPath : $handler"
                
                $handler serve $localRequestPath $this $sock $ip [array get request] $auth

            } else {

                odfi::log::warn "No handler found for $requestPath"
	        }

            #set handler [switch -glob $request(path) $handlers]
            #eval $handler
        }

        public method respond {sock code contentType body {head ""}} {


            #foreach enc [encoding names] {
            #    puts "Encoding: $enc"
            #}

                #set realBody [join $body]
                set encoded [encoding convertto utf-8 $body]
#
                #odfi::common::logFine "--- Responding with content: $body , length [string length $body]"

                #; charset=UTF-8

                puts $sock "HTTP/1.1 $code"
                puts $sock "Content-Type: $contentType"
                puts $sock "Connection: keep-alive"

                puts $sock "Content-length: [string length $encoded]"
                #puts $sock "Content-length: [string length $body]"

                puts $sock ""

                #puts $sock "$head"
                puts $sock "$encoded"
                #puts -nonewline $sock "HTTP/1.0 $code\nContent-Type: $contentType; \
                    charset=UTF-8\nConnection: keep-alive\nContent-length: [string bytelength $body]\n$head\n$encoded"
                flush $sock

        }

        ##################
        ## Getter Setters
        ##################

        ## \brief Returns true if started, false otherwise
        public method isStarted args {
            return $started
        }


        ##################
        ## Handling
        ##################

        public method addHandler  handler {

            ## Clean Handler path
            set handlerPath /[$handler getPath]
            set handlerPath [regsub -all {/+} $handlerPath /]

            ## If Ends with /, make it global for all subp aths
            if {[string match "*/" $handlerPath]} {
                set handlerPath ${handlerPath}*
            }

            #odfi::common::logInfo "Registered Handler at $handlerPath"

    		lappend handlers $handlerPath
    		lappend handlers [list set handler $handler]
                #set handlers [concat [$handler getPath] [list set handler $handler" $handlers]
               # lappend handlers $uri
               # lappend handlers $script

        }

    };
    # end of snit::type HTTPD


    ##########################
    ## Handlers
    ############################

    ## \brief Base Class Handler
    itcl::class AbstractHandler {

        ##\brief Base path against which this handler is matching
        public variable path

        ## \brief User provided closure
        public variable closure

        constructor {cPath cClosure} {

            set path    [regsub -all {//+} $cPath "/"]
            set closure $cClosure
        }

	   ## \brief Return path this handler
	   public method getPath args {
	        return $path
	   }

        ##\brief Common Method not designed for overwritting
        public method serve {localPath httpd sock ip uri auth} {
            odfi::closures::doClosure $closure
        }


    }


    ##\brief Handles a request, user code must return HTML
    ###################################
    itcl::class HtmlHandler {
            inherit AbstractHandler

        constructor {cPath cClosure} {AbstractHandler::constructor $cPath $cClosure} {


        }


        ##\brief Serves on doServe
        public method serve {httpd sock ip uri auth} {

            ## Eval Closure, must evaluate to an HTML string
            set html [eval $closure]

            $httpd respond $sock 200 "text/html" $html

        }



    }
    
    ##\brief Handles a request, Serves a simple file
    ###################################
    itcl::class FSHandler {
            inherit AbstractHandler

        public variable baseFolder

        constructor {cPath cBaseFolder cClosure} {AbstractHandler::constructor $cPath $cClosure} {
            set baseFolder $cBaseFolder

        }


        ##\brief Serves on doServe
        public method serve {localPath httpd sock ip uri auth} {

            ## Eval Closure, must evaluate to an HTML string
            odfi::log::fine "Service URI: $uri -> $localPath"
            
            ## Directory, try to find indexes
            set foundFile -1
            set targetRelativeFile $localPath
            if {[string match "*/" $localPath]} {
            
                ## Try extensions
                set targetRelativeFile $localPath/index.html 
                if {[file exists $baseFolder/$targetRelativeFile]} {
                    set foundFile $baseFolder/$targetRelativeFile
                }
                
            } else {
            
                ## Try to find file
                if {[file exists $baseFolder/$targetRelativeFile]} {
                    set foundFile $baseFolder/$targetRelativeFile
                }
            }
            
           
            
            if {$foundFile==-1} {
            
                $httpd respond $sock 404 "text/plain" "Not Found: $targetRelativeFile"
            
            } else {
                
                ## Get File Content
                set content [odfi::files::readFileContent $foundFile]
                
                ## determine mime type
                set mimeType "text/plain"
                switch -glob [file tail $foundFile] {
                    "*.html" {
                        set mimeType "text/html"
                    }
                    "*.css" {
                        set mimeType "text/css"
                    }
                    "*.js" {
                        set mimeType "text/javascript"
                    }
                    "*.ico" {
                        set mimeType "image/icon"
                    }
                    default {
                        $httpd respond $sock 503 "text/plain" "Cannot Determine MIME Type of $foundFile"
                        error "Cannot Determine MIME Type of $foundFile"
                    }
                }
                
                ## Return
                $httpd respond $sock 200 $mimeType $content
                
            }
           

        }



    }

    ##\brief Handles a request, and tries to map to some user provided closures
    ###################################
    itcl::class APIHandler {
            inherit AbstractHandler

        public variable closures {}

	## \brief base constructor
        constructor {cPath closuresMap} {AbstractHandler::constructor $cPath {}} {

            ## Add Each subpath <-> closure entry to the closures list
           foreach {subpath functionClosure} $closuresMap {

               lappend closures [regsub -all {//+} "*/$subpath" /]
               lappend closures [list set functionClosure $functionClosure]

           }

        }

        ##\brief Common Method not designed for overwritting
        public method serve {localPath httpd sock ip uri auth} {
            
            
            puts "Looking for closure in APIHandler for function $localPath"
            foreach {subpath closure} $closures {
                puts "-- available: $subpath"
            }
                
                
        	## Find Maping between request path and functions
          	array set request [uri::split $uri]
        	set functionClosure ""
          	switch -glob $localPath $closures
        
    	
          	if {$functionClosure!=""} {

              	## Evaluate Closure
        		puts "Found closure in APIHandler for function $request(path)"
        
        		set res [eval $functionClosure]
        
        		## Result must be type + content
        		set contentType [lindex $res 0]
        		set content [lindex $res 1]
        
        		$httpd respond $sock 200 $contentType $content
        
          	}
        }

    }




}
