package provide odfi::closures 2.0.0
package require odfi::common

## \brief Closures utilities namespace
namespace eval odfi::closures {

    ## \brief Executes command in args, into +1 exec level, and add result  as string  to eRes variable available in the +1 exec also
    proc push args {

        set tRes "[uplevel 1 $args]"

        #puts "Will push on result list: $tRes"

        uplevel 1 "lappend eRes {$tRes}"
        set newLength [uplevel {llength $eRes}]
        set upns [uplevel {namespace current}]
        #lappend eRes {$tRes}

        puts "Pushed on result list,which is now: $newLength , and in ns: $upns, frame: [uplevel info frame]"

    }

    ## Replace embbeded TCL between <% %> markors in data with evaluated tcl
    # <% standard eval %>
    # <%= evaluation result not outputed %>
    # @warning Closure base execution level is 1, not 0 (so not this function's level)
    # @return resulting stream
    proc embeddedTclStream {dataStream {caller ""} } {

        set resultChannel [chan create "write read" [::new odfi::common::StringChannel #auto]]

        #puts "In Closure embedded stream: $dataStream: [read $dataStream]"

        ## Stream in the data, and gather everything between <% ... %> an eval
        ################

        set token [read $dataStream 1]
        set gather false
        set script ""
        while {[string length $token]==1} {

            #puts "Doing token : $token"
            ## Gather / Eval
            ########################

            #### If <%, gather
            if {$gather == false && $token == "<" } {

                ## If % -> We can start
                set nextChar [read $dataStream 1]
                if {$nextChar=="%"} {
                    set gather true

                    ## Output Modifiers
                    #########################
                    set outputNoEval false

                    #### If the next character is '=', set no eval output mode
                    set modifier [read $dataStream 1]
                    if {$modifier== "=" } {

                        ## Don't use the eval output
                        set outputNoEval true

                    } else {

                        ## Not a modifier -> Output to script
                        set script "${script}$modifier"
                    }

                } else {

                    ## Not a start -> Output to result
                    puts -nonewline $resultChannel $token
                    #puts -nonewline $resultChannel $nextChar
                    set token $nextChar
                    continue
                }

            } elseif {$gather==true && $token == "%" } {

                #### If %>, eval
                set nextChar [read $dataStream 1]
                if {$nextChar==">"} {

                    set gather false

                    ## Prepare a Channel
                    ############################
                    set ::eout [chan create "write read" [::new odfi::common::StringChannel #auto]]
                    set eout $::eout
                    #puts "Eval closure: $script "

                    set execLevel 1




                    ## Eval Script
                    ###########################
                    set script [string trim $script]

                   # puts "Calling closure"
                    if {[catch {set evaled [string trim [odfi::closures::doClosure $script $execLevel]]} res resOptions]} {

                        ## This may be a variable, just output the content to eout
                        puts "Invalid command ($res), doing error, first char is [lindex [string trim $script] 0] "

                        error $res [dict get $resOptions -errorinfo]

                        #puts "- Error While evaluating script $script. $res"

                    }



                    ## If evaluation output is to be ignored, set to ""
                    ########
                    if {$outputNoEval==true} {
                        set evaled ""
                    }

                    ## Get Embedded output
                    ######################
                    flush $eout
                    set output [read $eout]
                    close $eout

                    ## Result
                    ######################

                    ## If the embedded output is not empty, use it instead of evaluation result
                    set evalResult $evaled
                    if {[string length $output]>0} {
                        set evalResult $output
                    }

                    ## Adjust output
                    # set evalResult [::textutil::adjust::adjust [::textutil::adjust::indent $evalResult "    " 0] -justify left]
                    #set evalResult [::textutil::adjust::indent $evalResult "    " 1]

                    #puts "Closure result: $evalResult"

                    ## Output to result string
                    puts -nonewline $resultChannel $evalResult

                    ## Reset script
                    set script ""

                } else {

                    ## Not an end -> Output to script
                    set script "${script}$token"
                    set script "${script}$nextChar"

                }

            } elseif {$gather==true} {

                #### If gather -> Gather characters for script
                set script "${script}$token"

            } else {

                #### If not gather, output to result
                puts -nonewline $resultChannel $token
            }

            ## Read next token
            #############
            set token [read $dataStream 1]
        }

        ## Output result
        #######################
        flush $resultChannel
        set result [read $resultChannel]
        close $resultChannel

        return $result

    }




    ## \brief Evaluates a closure and make magic for variables to be resolvable
    # Returns the result of the closure
    # The executed closure can call the special "push" method to add result to a result list.
    # If the result list is not empty after evaluation, its content is returned as result
    # @return The last executed command in the closure, or the result list if the push command has been used
    proc doClosure {closure {execLevel 0} {resolveLevel 0}} {

        #puts "Evaluating closure $closure"



        set closureString "$closure"

        ## Level:
        ## - This is a utility proc, so level 1 is the caller.
        ## - So call level provided by caller must then be +1 to hide this procedure level
        ###################
        set execLevel [expr $execLevel+1]

        ## Resolution:
        ##  - Resolve variables in caller asked level +1
        ##  - Execute in caller asked level
        ###################
        set resolveLevel [expr $execLevel+1]

        ## list of all upvaring to prepend to closure
        set requiredUpvars {}



        #puts "Search into [llength $closure]"

        #puts "Exploring closure **************************"

        #foreach scriptElement [split $closureString { }] {

            ## Search for all variables
            ############
            #puts "**** Exploring $scriptElement"
            set vars [regexp -all -inline {\$[a-zA-Z0-9:{}_]+\s*} $closureString]
            foreach var $vars {

                set var [string trim [string range $var 1 end]]
                set var [regsub -all {\{|\}} $var ""]

                #puts "Found variable : $var"

                ## Ignore variables that are an explicit namespaced reference
                ##############

                ### Ignore certain patterns
                ## Why it was there ? "it" {continue}
                set ignores {

                    "::*" {continue}
                    "this" {continue}


                }
                switch -- $var $ignores
                #if {[string match "::*" $var] || $var=="this"} {
                #    continue
                #}

                #puts "Not ignored variable : $var"

                ### If variable is global, also ignore
                #if {[catch [list set ::$var] res]==0} {
                #    continue
                #}


                ## Search for variable in:
                #############
                set local               false
                set callerExec          false
                set callerExecUp        false
                set searchResolveLevel  $resolveLevel
                #set searchResolveLevel  1

                ### 1: Closure level -> Do nothing
                set exp "set $var .+\$"
                set localSearchResults [regexp -all -inline -line $exp $closureString]
                if {[llength $localSearchResults]>0} {

                    ## This is only true, if in none of the set expressions, the variable is used right
                    ## Ex: set var "${var}_var" should lead to an upvar
                    set validLocal true
                    foreach localResult $localSearchResults {

                        #puts "Checking local variable $var validity against set expression: $localResult"

                        if {[regexp "set $var .*\\\$$var.*" $localResult]>0} {

                            #puts "Variable should be upvared"
                            set validLocal false
                            break
                        }

                    }


                    #puts "-- Variable $var is defined in local"
                    if {$validLocal==true} {
                        set local true
                        continue
                    } else {
                        set local false
                    }


                } else {

                    #puts "Explored /$exp/ in closure string /$closureString/"

                }

                ##### 2: Caller Level -> Do nothing
                if {[catch [list uplevel $execLevel set $var] res]} {

                    #puts "-- Variable $var not found in execlevel upvar ($execLevel)"

                } else {

                    #puts "-- Variable $var was found in execlevel upvar ($execLevel)"

                    set callerExec true
                    #set requiredUpvars [concat upvar [expr $execLevel] $var $var $requiredUpvars]
                    #lappend requiredUpvars "upvar $execLevel $var $var"
                }

                ### 3: Caller +1 level -> upvar
                 if {$callerExec==false} {

                    #puts "**** Start Search at uplevel [uplevel $resolveLevel info level]"

                    while {[catch "uplevel $searchResolveLevel info level"]==0} {

                        #puts "**** Search $var at uplevel $searchResolveLevel [uplevel $searchResolveLevel namespace current]"

                        ## Test
                        if {[catch [list uplevel $searchResolveLevel set $var] res]} {
                            ## not found
                        } else {
                            ## Found
                            #puts "********* Found $var at $searchResolveLevel"
                            set callerExecUp true
                            set requiredUpvars [concat upvar [expr $searchResolveLevel-$execLevel] $var $var ";" $requiredUpvars]
                            break
                        }

                        incr searchResolveLevel

                        ## Breaking because can'T search anywhere else
                        if {[expr [info level]-$searchResolveLevel]<0} {
                            break
                        }

                    }

                 }
                 ## EOF uplevels search


                ## Verify Compatibilities
                ##########################

                ## If More than one level has true defined, there is a conflict
                if {$local==true && [llength [lsearch -all -exact [list $callerExec $callerExecUp] true]]>1} {

                    error "Variable $var has been found defined in some up level, and local closure, there will probably be some conflicts:
                            - Found in closure $local
                            - Found in Closure Caller execution level $callerExec
                            - Found in Closure Caller execution level +1 $callerExecUp
                    "

                } elseif {[lsearch -exact [list $local $callerExec $callerExecUp] true]==-1} {
                    #odfi::common::logWarn "Variable $var seems not to be resolvable:
                    #        - Found in closure $local
                    #        - Found in Closure Caller execution level $callerExec
                    #        - Found in Closure Caller execution level +1 $callerExecUp
                    #"
                }

            }
        #}


        ## Evaluate closure
        #########################

        ## Prepare result creation
        ###########
        namespace   export push
        uplevel     $execLevel "set eRes {}"
        uplevel     $execLevel "namespace import [namespace current]::push"

        ## Try to detect possible errors in closure
        ###############

        ## If starts with a  , add a return because it is only a string
        if {[string index [string trim "$closure"] 0]=="\""} {

            puts "use subst to resolve closure as string"
            set closure [concat return $closure]
        }

        ## Run And catch error
        ##########
        set evaledRes [uplevel $execLevel [concat $requiredUpvars $closure ]]

            #error $res [dict get $resOptions -errorinfo]



        ## If eRes list is not empty, used it as result
        #############
        set upns [uplevel $execLevel {namespace current}]
        set eResLength [uplevel $execLevel {llength $eRes}]
        #puts "Closure evaluated, eRes is in namespace $upns, has length: $eResLength , frame: [uplevel $execLevel info frame] "
        #upvar $execLevel eRes eRes
        if {$eResLength>0} {
           # puts "Result for closure: $eRes"
            set evaledRes [uplevel $execLevel {concat $eRes}]
            #puts "Result for closure: $evaledRes"
        }

        return $evaledRes


    }

    ## \brief Calls doClosure, and join result using a character. " " per default
    proc doClosureToString {closure {execLevel 0} {resolveLevel 0}} {

        set result [odfi::closures::doClosure $closure [expr $execLevel+1] [expr $resolveLevel+1]]

        ## Take First result of list, if only one
        if {[llength $result]==0} {
            set result [lindex $result 0]
        }

        #return [join $result " "]

        return [regsub -all "(\}|\{)" $result ""]

    }


}
