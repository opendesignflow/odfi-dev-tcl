package provide odfi::utests 1.0.0
package require odfi::language 1.0.0
package require odfi::log 1.0.0

namespace eval odfi::utests {

    odfi::language::Language default {


        :suite name {
            +exportToPublic
            +exportTo Suite 

            ## Test 
            :test name script {

                +method run args {
                    :apply ${:script}
                }
            }
        }


    }


    ## Runners
    ###########

    ## Run All available root suites 
    proc run args {

        ## Get All Root suites 
        #############
        set suites [odfi::flist::MutableList::fromList [odfi::nx::getAllNXObjectsOfType ::odfi::utests::Suite]]
        set suites [$suites filter {$it isRoot}]

        odfi::log::info "Found [$suites size] suite(s)"

        
        ## Run Suites 
        #####################
        $suites foreach {
            {suite i} => 

                odfi::log::info "Running suite [$suite name get]"

                ## Run tests 
                $suite shade odfi::utests::Test eachChild {

                    {test i} =>

                        odfi::log::info "Running test: [$test name get]"
                        $test run
                }

        }



        #runFile [info script]
    }

    proc runFile file {

        odfi::log::info "Running File $file"

    }

}