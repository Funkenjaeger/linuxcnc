#!/bin/sh
# the next line restarts using emcsh \
exec /usr/bin/wish "$0" "$@"

###############################################################
# Description:  halconfig.tcl
#               This file, shows a running hal configuration
#               and has menu for modifying and tuning
#
#  Author: Raymond E Henry
#  License: GPL Version 2
#
#  Copyright (c) 2006 All rights reserved.
#
#  Last change:
# $Revision$
# $Author$
# $Date$
###############################################################

# Script accesses HAL through two modes halcmd show xxx for show
# and open halcmd -skf for building tree, watch, edit, and such 

# TODO
# add edit widget set
# add tune widget set
# flesh out the save and reload with modified .ini file.
# clean up and remove cruft!!!!!

#----------Testing of run environment----------
proc initializeConfig {} {
    global tcl_platform
    # four ordinal tests are used as this script starts
    # 1 -- ms, if yes quit - else
    # 2 -- bwidget, if no quit - else
    # 3 -- Is script running in place if no quit - else
    # 4 -- running emc2 or hal if yes run this - else
    # 4 -- question setupconfig.tcl? if yes -> go after setup
    #      if no -> start scripts/demo
    
    # 1 -- since this script isn't worth a pinch of spit unless running
    # alongside a emc2 I'll use this to kill it until we find a way
    # to use it across a network
    switch $tcl_platform(platform) {
        windows {
            tk_messageBox  -icon error -type ok -message "Nothing to do, 'cause you're not running a real-time operating system.  Halconfig works best when it is interacting with a real, running HAL.  When you get this running along with EMC2 then you've got something."
            exit
            destroy .
        }
            default {
            option add *ScrolledWindow.size 14
        }
    }
    
    # 2 -- BWidget package is used for the Tree widget
    # with bdi, apt-get install bwidget will work
    # If you don't find it with this package it is available in
    # the Axis display package
    set isbwidget ""
    set isbwidget [glob -directory /usr/lib -nocomplain \
        -types d bwidget* ]
    if {$isbwidget == ""} {
        tk_messageBox -icon error -type ok -message "Darn.  I didn't find the bwidget library in the usual place\n\n/usr/lib/bwidget-##.\n\nIf this is a linux box and you have the Axis display stuff loaded, it has an older copy of Bwidget that you could link to the location shown above."
        exit
        destroy .
    } else {
        package require BWidget
    }
    
    # 3 -- Are we where we ought to be.
    set thisdir [file tail [pwd]]
    if { $thisdir != "emc2"} {
         tk_messageBox -icon error -type ok -message "The configuration script needs to be run from the main EMC2 directory"
         exit
         destroy .
    }
    
    # 4 -- is a hal running?
    # first level of test is to see if module is in there.
    set temp ""
    set tempmod ""
    set temp [lsearch [exec /sbin/lsmod] hal_lib]
    if {$temp == -1} {
        noHal
    } else {
        # check status reply for "not" 
        set tempmod [exec scripts/realtime "status"]
        set isnot [string match *not* $tempmod]
        if {$tempmod == "-1"} {
            if {$isnot != 1} {
                noHal
            }
        }
    }
}

# proc allows user to choose some startup stuff if env is okay.
set demoisup no
proc noHal {} {
    global demoisup
    set demoisup no
    set thisanswer [tk_messageBox -type yesnocancel -message "It looks like HAL is not loaded.  If you'd like to go to the configuration and startup script press yes.  If you'd like to start a HAL demo press no. To stop this script, press cancel."]
    switch -- $thisanswer {
        yes {
            wm withdraw .
            [exec tcl/bin/setupconfig.tcl]
        }
        no {
           # this works to start a hal but halconfig doesn't live
            set tmp [exec sudo scripts/realtime load & ]
            set demoisup yes
            after 1000 
        }
        cancel {
            killHalConfig
        }
    }
}

# run the init test process
initializeConfig
#
#----------end of environment tests----------

# provide for some initial i18n -- needs lots of text work
package require msgcat
if ([info exists env(LANG)]) {
    msgcat::mclocale $env(LANG)
    msgcat::mcload "../../src/po"
}

#----------start toplevel----------
#
# including size and position

wm title . "HAL Configuration"
wm protocol . WM_DELETE_WINDOW tk_
set masterwidth 700
set masterheight 450
# set fixed size for configuration display and center
set xmax [winfo screenwidth .]
set ymax [winfo screenheight .]
set x [expr ($xmax - $masterwidth )  / 2 ]
set y [expr ($ymax - $masterheight )  / 2]
wm geometry . "${masterwidth}x${masterheight}+$x+$y"

# add a few default characteristics to the display
foreach class { Button Checkbutton Entry Label Listbox Menu Menubutton \
    Message Radiobutton Scale } {
    option add *$class.borderWidth 1  100
}

# trap mouse click on window manager delete and ask to save
wm protocol . WM_DELETE_WINDOW askKill
proc askKill {} {
    global configdir
    set tmp [tk_messageBox -icon error -type yesno \
        -message "Would you like to save your configuration before you exit?"]
    switch -- $tmp {
        yes {saveHAL $configdir ; killHalConfig}
        no {killHalConfig}
    }
}

# clean up a couple of possible problems during shutdown
proc killHalConfig {} {
    global demoisup fid
    if {$demoisup == "yes"} {
        set demoisup no
        set tmp [exec sudo scripts/realtime unload & ]
    }
    if {[info exists fid] && $fid != ""} {
        catch flush $fid
        catch close $fid
    }
    exit
    destroy .
}

#----------open channel to halcmd ----------
#
# These procs open a channel to halcmd, send commands and receive
# replies including % return and empty lines. They work like this;
# 1 -- openHALCMD creates the channel and sets var "fid" as its
# ident. It registers fid with the event handler for "read" events.
# 2 -- exHAL sets global var chanflag to rd, sends a proper command,
# and sets "vwait chanflag" in the event handler.  So exHAL waits
# when channel read is seen while getsHAL builds a global variable
# named returnstring.
# 3 -- At the end of read, halcmd sends % a couple times
# so getsHAL watches and changes chanflag to wr which causes
# exHAL to return the value of returnstring to whomever initiated
# the command by issuing something like "set myret [exHAL argv]."

proc openHALCMD {} {
    global fid
    set fid [open "|bin/halcmd -skf" "r+"]
    fconfigure $fid -buffering line -blocking on
    gets $fid
    fileevent $fid readable {getsHAL}
}

proc exHAL {argv} {
    global fid chanflag returnstring
    set chanflag rd
    puts $fid "${argv}"
#    puts "Proc exHAL, fid = '$fid', argv = '$argv'"
    vwait chanflag
    set tmp $returnstring
    set returnstring ""
    return $tmp
}

# getsHAL appends lines to returnstring until it receives a line with just a percent sign "%" on it
# Once the % is received, the global var chanflag is set to "wr"
set returnstring ""
proc getsHAL {} {
    global fid chanflag returnstring
    gets $fid tmp
    if {$tmp != "\%"} {
        append returnstring $tmp
    } else {
        set chanflag wr
    }
}

openHALCMD
#
#----------end of open halcmd----------

# workmodes are set from the menu
# possible workmodes include showhal modifyhal tunehal watchHAL ...
# only showhal does much special now.
set workmode showhal

##########
# Use a monofont to display properly
# Build the display areas to look like this

#########################################
#File  View  Settings             Help  #
#########################################
#  Tree         # Main                  #
#  Navigation   # Text display          #
#  (frame - $tf)# (frame - $df)         #
#  ($treew)     # (text - $disp)        #
#               # (displayThis {str})   #
#########################################
#  Command area                         #
#  (frame - $cf)                        #
#########################################

# The layout is fixed sized and uses the place manager to
# fix this layout.  It can be expanded by the user after startup.

set top [frame .main -bg white]
pack $top -padx 4 -pady 4 -fill both -expand yes

# fixme clean up the underlines so they are unique under each set
set menubar [menu $top.menubar -tearoff 0]
set filemenu [menu $menubar.file -tearoff 0]
    $menubar add cascade -label [msgcat::mc "File"] \
            -menu $filemenu -underline 0
        $filemenu add command -label [msgcat::mc "Run Hal"] \
            -command {} -underline 0 -state disabled
        $filemenu add command -label [msgcat::mc "Refresh"] \
            -command {refreshHAL} -underline 0
        $filemenu add command -label [msgcat::mc "Save"] \
            -command {saveHAL save} -underline 0 -state disabled
        $filemenu add command -label [msgcat::mc "Save As"] \
            -command {saveHAL saveas} -underline 0 -state disabled
        $filemenu add command -label [msgcat::mc "Save and Exit"] \
            -command {saveHAL saveandexit} -underline 1 -state disabled
        $filemenu add command -label [msgcat::mc "Exit"] \
            -command {killHalConfig} -underline 0
set viewmenu [menu $menubar.view -tearoff 0]
    $menubar add cascade -label [msgcat::mc "View"] \
            -menu $viewmenu -underline 0
        $viewmenu add command -label [msgcat::mc "Components"] \
            -command {workMode comp} -underline 1
        $viewmenu add command -label [msgcat::mc "Pins"] \
            -command {workMode pin} -underline 1
        $viewmenu add command -label [msgcat::mc "Parameters"] \
            -command {workMode param} -underline 1
        $viewmenu add command -label [msgcat::mc "Signals"] \
            -command {workMode sig} -underline 1
        $viewmenu add command -label [msgcat::mc "Functions"] \
            -command {workMode funct} -underline 1
        $viewmenu add command -label [msgcat::mc "Threads"] \
            -command {workMode thread} -underline 1
set settingsmenu [menu $menubar.settings -tearoff 0]
    $menubar add cascade -label [msgcat::mc "Settings"] \
            -menu $settingsmenu -underline 0
        $settingsmenu add radiobutton -label [msgcat::mc "Show"] \
            -variable workmode -value showhal -underline 0 \
            -command {workMode {zzz} }
        $settingsmenu add radiobutton -label [msgcat::mc "Watch"] \
            -variable workmode -value watchhal  -underline 0 \
            -command {workMode {zzz} }
        $settingsmenu add radiobutton -label [msgcat::mc "Modify"] \
            -variable workmode -value modifyhal  -underline 0 \
            -command {workMode {zzz} }
        $settingsmenu add radiobutton -label [msgcat::mc "Tune"] \
            -variable workmode -value tunehal  -underline 0 \
            -command {workMode {zzz} }
            
set helpmenu [menu $menubar.help -tearoff 0]
    $menubar add cascade -label [msgcat::mc "Help"] \
            -menu $helpmenu -underline 0
        $helpmenu add command -label [msgcat::mc "About"] \
            -command {showHelp about} -underline 0
        $helpmenu add command -label [msgcat::mc "Main"] \
            -command {showHelp main} -underline 0
        $helpmenu add command -label [msgcat::mc "Component"] \
            -command {showHelp component} -underline 0
        $helpmenu add command -label [msgcat::mc "Pin"] \
            -command {showHelp pin} -underline 0
        $helpmenu add command -label [msgcat::mc "Parameter"] \
            -command {showHelp parameter} -underline 0
        $helpmenu add command -label [msgcat::mc "Signal"] \
            -command {showHelp signal} -underline 0
        $helpmenu add command -label [msgcat::mc "Function"] \
            -command {showHelp function} -underline 0
        $helpmenu add command -label [msgcat::mc "Thread"] \
            -command {showHelp thread} -underline 0
. configure -menu $menubar

# build the tree area in the upper left
set tf [frame $top.maint]
set treew [Tree $tf.t  -width 10 -yscrollcommand "sSlide $tf" ]
set str $tf.sc
scrollbar $str -orient vert -command "$treew yview"
pack $str -side right -fill y
pack $treew -side right -fill both -expand yes

# This binding to treew returns the name of the node clicked
# so a call using it includes that one arg.
# no two nodes can have the same name even with different paths
# so this return will be unique to each pin, param, or signal
$treew bindText <Button-1> {workMode   }

# build text area upper right for display
set df [frame $top.maind ]
set disp [text $df.tx -bg grey93 -relief flat -width 40 -wrap word \
    -yscrollcommand "sSlide $df"]
set stt $df.sc
scrollbar $stt -orient vert -command "$disp yview"
pack $stt -side right -fill y
pack $disp -side right -fill both -expand yes

# slider processes
proc sSlide {f a b} {
    $f.sc set $a $b
}

# canvas area upper right for watch
set dc [frame $top.maincanvas ]
set cisp [canvas $dc.c -bg grey93 -yscrollcommand "sSlide $dc" ]
set stc $dc.sc
scrollbar $stc -orient vert -command "$cisp yview"
pack $stc -side right -fill y
pack $cisp -side right -fill both -expand yes


# create a small lower display area for editing work.
# might build several frames like cf for different modes
set cf [labelframe $top.mainc -text "Control" -bg gray96 ]
# set up a temporary entry widget and button for editing
set lab [label $cf.label -text "Enter a proper HAL command :"]
set com [entry $cf.entry -textvariable halcommand]
bind $com <KeyPress-Return> {exHAL $halcommand ; refreshHAL}
set ex [button $cf.execute -text Execute \
    -command {exHAL $halcommand ; refreshHAL} ]
pack $lab -side left -padx 5
pack $com -side left -fill x -expand yes
pack $ex -side left -padx 5

# use place manager for fixed locations of frames within top
place configure $tf -in $top -x 2 -y 2 -relheight .69 -relwidth .3
place configure $df -in $top -relx .31 -y 2 -relheight .69 -relwidth .69
place configure $cf -in $top -x 2 -rely .7 -relheight .29 -relwidth .99

#----------tree widget stuff----------
#
# the tree node name needs to be nearly
# equivalent to the hal element name but since no two
# nodes can be named the same, and pins and params often are
# we append the hal type to the front of it.
# so a param like pid.0.FF0
# is broken down into "pid 0 FF0"
# a node is made below param named param+pid
# below it a node named param+pid.0
# and below a leaf param+pid.0.FF0
#
# a global var -- treenodes -- holds the names of existing nodes
# nodenames are the text applied to the toplevel tree nodes
# they could be internationalized
set nodenames {Components Pins Parameters Signals Functions Threads}
# searchnames is the real name to be used to reference
set searchnames {comp pin param sig funct thread}
# add a few names to test and make subnodes to the signal node
# a linkpp signal is sorted by it's pin name so ignore here
set signodes {X Y Z A "Spindle"}


# refreshHAL is the starting point for building/rebuilding a tree.
# First empty tmpnodes, the list of all nodes that are open
# Look through tree for current list of open nodes
# Clean out the entire tree
# Call listHAL to read HAL for pin, param, sig names and build new tree
# Open old nodes if they still exist
set treenodes ""
proc refreshHAL {} {
    global treew treenodes
    set tmpnodes ""
    # look through tree for nodes that are displayed
    foreach node $treenodes {
        if {[$treew itemcget $node -open]} {
            lappend tmpnodes $node
        }
    }
    # clean out the old tree
    $treew delete [$treew nodes root]
    # reread hal and make new nodes
    listHAL
    # read opennodes and set tree state if they still exist
    foreach node $tmpnodes {
        if {[$treew exists $node]} {
            $treew opentree $node no
        }
    }
}

# listhal gets pin, param, and sig stuff
# and calls makeNodeX with list of stuff found.
proc listHAL {} {
    global searchnames nodenames
    set i 0
    foreach node $searchnames {
        writeNode "$i root $node [lindex $nodenames $i] 1"
        incr i
    }
    set pinstring [exHAL { list pin }]
    makeNodeP pin $pinstring
    set paramstring [exHAL { list param }]
    makeNodeP param $paramstring
    set sigstring [exHAL { list sig }]
    makeNodeSig $sigstring
}

proc makeNodeP {which pstring} {
    global treew 
    # make an array to hold position counts
    array set pcounts {1 1 2 1 3 1 4 1 5 1}
    # consider each listed element
    foreach p $pstring {
        set elementlist [split $p "." ]
        set lastnode [llength $elementlist]
        set i 1
        foreach element $elementlist {
            switch $i {
                1 {
                    set snode "$which+$element"
                    if {! [$treew exists "$snode"] } {
                        set leaf [expr $lastnode - 1]
                        set j [lindex [array get pcounts 1] end]
                        writeNode "$j $which $snode $element $leaf"
                        array set pcounts "1 [incr j] 2 1 3 1 4 1 5 1"
                        set j 0
                    }
                    set i 2
                }
                2 {
                    set ssnode "$snode.$element"
                    if {! [$treew exists "$ssnode"] } {
                        set leaf [expr $lastnode - 2]
                        set j [lindex [array get pcounts 2] end]
                        writeNode "$j $snode $ssnode $element $leaf"
                        array set pcounts "2 [incr j] 3 1 4 1 5 1"
                        set j 0
                    }
                    set i 3
                }
                3 {
                    set sssnode "$ssnode.$element"
                    if {! [$treew exists "$sssnode"] } {
                        set leaf [expr $lastnode - 3]
                        set j [lindex [array get pcounts 3] end]
                        writeNode "$j $ssnode $sssnode $element $leaf"
                        array set pcounts "3 [incr j] 4 1 5 1"
                        set j 0
                    }
                    set i 4
                }
                4 {
                    set ssssnode "$sssnode.$element"
                    if {! [$treew exists "$ssssnode"] } {
                        set leaf [expr $lastnode - 4]
                        set j [lindex [array get pcounts 4] end]
                        writeNode "$j $sssnode $ssssnode $element $leaf"
                        array set pcounts "4 [incr j] 5 1"
                        set j 0
                    }
                    set i 4
                }
                5 {
                    set sssssnode "$ssssnode.$element"]
                    if {! [$treew exists "$sssssnode"] } {
                        set leaf [expr $lastnode - 5]
                        set j [lindex [array get pcounts 5] end]
                        writeNode "$j $ssssnode $sssssnode $element $leaf"
                        array set pcounts "5 [incr j]"
                        set j 0
                    }
                }
              # end of node making switch
            }
           # end of element foreach
         }
        # end of param foreach
    }
    # empty the counts array in preparation for next proc call
    array unset pcounts {}
}

# signal node assumes more about HAL than pins or params.
# For this reason the variable signodes
# supplies a set of sig -> subnodes to build around
# then it finds dot separated sigs and builds a node with them
# these are most often made by linkpp sorts of commands
# finally it makes leaves under sig for remaining signals
proc makeNodeSig {sigstring} {
    global treew signodes
    # build sublists dotstring, each signode element, and remainder
    foreach nodename $signodes {
        set nodesig$nodename ""
    }
    set dotsig ""
    set remainder ""
    foreach tmp $sigstring {
        set i 0
        if {[string match *.* $tmp]} {
            lappend dotsig $tmp
            set i 1
        }
   
        foreach nodename $signodes {
            if {[string match *$nodename* $tmp]} {
                lappend nodesig$nodename $tmp
                set i 1
            }
        }
        if {$i == 0} {
            lappend remainder $tmp
        }
    }
    set i 0
    # build the signode named nodes and leaves
    foreach nodename $signodes {
        set tmpstring [set nodesig$nodename]
        if {$tmpstring != ""} {
            set snode "sig+$nodename"
            writeNode "$i sig $snode $nodename 1"
            incr i
            set j 0
            foreach tmp [set nodesig$nodename] {
                set ssnode sig+$tmp
                writeNode "$j $snode $ssnode $tmp 0"
                incr j
            }
        }
    }
    set j 0
    # build the linkpp based signals just below signode
    foreach tmp $dotsig {
        set tmplist [split $tmp "."]
        set tmpmain [lindex $tmplist 0]
        set tmpname [lindex $tmplist end] 
        set snode sig+$tmpmain
        if {! [$treew exists "$snode"] } {
            writeNode "$i sig $snode $tmpmain 1"
            incr i
        }
        set ssnode sig+$tmp
        writeNode "$j $snode $ssnode $tmp 0"
        incr j
    }
    # build the remaining leaves at the bottom of list
    foreach tmp $remainder {
        set snode sig+$tmp
        writeNode "$i sig $snode $tmp 0"
        incr i
    }

}

# writeNode handles tree node insertion for makeNodeX
# builds a global list -- treenodes -- but not leaves
proc writeNode {arg} {
    global treew treenodes
#    set treenodes ""
    scan $arg {%i %s %s %s %i} j base node name leaf
    $treew insert $j  $base  $node -text $name
    if {$leaf > 0} {
        lappend treenodes $node
    }
}

# Tree code above looks like crap but works fairly well
#
#----------end of tree building processes----------


# create empty arrays to hold modify mode elements
# array elements are created from what is clicked in tree
# each element of controlarray is a complete node name
array set controlarray {}

# all clicks on tree node names go into workMode
# process uses it's own halcmd show so that displayed
# info looks like what is in the Hal_Introduction.pdf
# action depends upon workmode which is not complete
# FIXME use scan rather than split and lindex

proc workMode {which} {
    global workmode 
    switch -- $workmode {
        showhal {
            swapDisplay display df
            showHAL $which
        }
        watchhal {
            swapDisplay display dc
            watchHAL $which
        }
        modifyhal {
            swapDisplay display df
            swapDisplay control cf
            modifyHAL $which
        }
        tunehal {
            swapDisplay display df
            swapDisplay control cf
            tuneHAL $which
        }
        default {
            swapDisplay display df
            displayThis "Something went way wrong with settings."
        }
    }
}

proc swapDisplay {where to} {
    global top df dc de cf
    switch -- $where {
    display {
        foreach olddisplay {dc df dc } {
            place forget [set $olddisplay]
        }
        place configure [set $to] -in $top -relx .31 -y 2 \
            -relheight .69 -relwidth .69
        }
    control {
    
        }
    }    
}

proc showHAL {which} {
    if {$which == "zzz"} {
        displayThis "Select a node to show."
        return
    }
    set thisnode $which
    set thislist [split $which "+"]
    set searchbase [lindex $thislist 0]
    set searchstring [lindex $thislist 1]
    set thisret [exec bin/halcmd show $searchbase $searchstring]
    displayThis $thisret
}

proc watchHAL {which} {
    global controlarray cisp
    if {$which == "zzz"} {
    # Put intro message here.
    }
    set asize [array size controlarray]
    array set controlarray "$asize $which"
    #setup canvas stuff here as this is temp to show something
    global cisp
    for {set i 0} {$i < 10} {incr i 1} {
        $cisp create oval 10 [expr $i * 20 + 5] 25 [expr $i * 20 + 20] \
        -fill firebrick4
    }

    set leftdef { -- -- -- -- -- -- -- -- -- -- -- -- }
    for {set i 0} {$i < 10} {incr i 1} {
        set label "[lindex $leftdef $i]"
        $cisp create text 40 [expr $i * 20 + 12] -text $label \
            -anchor w -tag labelz
    }
}

proc modifyHAL {which} {
    global controlarray
    set asize [array size controlarray]
    array set controlarray "$asize $which"
    puts [array get controlarray ]
    set thisret [exHAL "show $searchbase $searchstring"]
    displayAddThis $thisret
}

proc tuneHAL {which} {
    global tunearray
    displayThis "Move along.  Nothing to see here yet."
}

# proc switches the insert and removal of upper right text
# This also removes any modify array variables
proc displayThis {str} {
  global disp controlarray
  $disp delete 1.0 end
  $disp insert end $str
  array unset controlarray {}
#  updateControl
}

# fixme from here down.
# no delete of existing display with this
# fixme, header lines for this
proc displayAddThis {str} {
    global disp controlarray
    $disp insert end "\n$str"
#    updateControl
}

# start up the tree discovery stuff
refreshHAL

# strips extra stuff from halcmd -s show and updates
# next step here is to make the display show indicators
# FIXME preserve order of clicks
# FIXME this is damn slow so need long delay and speed
proc watchHALxx {} {
    global workmode controlarray k
    set arraynames [array names controlarray]
    set tmpstring ""
    foreach name $arraynames {
        set rawsplit [split [lindex [array get controlarray $name] end] +]
        scan $rawsplit {%s %s} showtype showthis
        set showtype [lindex $rawsplit 0]
        set showthis [lindex $rawsplit 1]
        switch -- $showtype {
            pin {-}
            param {
                set tmp [exHAL "show $showtype $showthis"]
                set pinname [lindex $tmp 4]
                set value [lindex $tmp 3]
                if {[lindex $tmp 1] == "float"} {set value [expr $value]}
                append tmpstring "$pinname $value" \n
            }
            sig {
                set tmp [exec bin/halcmd -s show $showtype $showthis]
                append tmpstring "[lindex $tmp 2 ] [lindex $tmp 1 ]" \n
            }
            default {
                append tmpstring "Not really anything to watch in $showtype" \n
            }
        }
    }
    displayThis $tmpstring
    if {$workmode == "watchHAL" } {
        after 5000 {watchHAL}
    }
}


#----------save config----------
#
# save will assume that restarting is from a comp and netlist
# we need to build these files and copy .ini for the new
proc saveHAL {which} {
    puts "This had the arg $which with it."
    switch -- $which {
        save {
            displayThis [exec bin/halcmd save "comp"]
        }
        saveas {}
        saveandexit {
            exit {destroy . }
        }
    }
}


#----------Help processes----------
#
proc showHelp {which} {
    global helpabout helpmain helpcomponent helppin helpparameter
    global helpsignal helpfunction helpthread
    switch -- $which {
        about {displayThis  $helpabout}
        main {displayThis  $helpmain}
        component {displayThis  $helpcomponent}
        pin {displayThis  $helppin}
        parameter {displayThis  $helpparameter}
        signal {displayThis  $helpsignal}
        function {displayThis  $helpfunction}
        thread {displayThis  $helpthread}
        default {I'm lost here in help land}
    }
}

# Help includes sections for each of these
# Components Pins Parameters Signals Functions Threads

set helpabout {
     Copyright Raymond E Henry. 2006
     License: GPL Version 2

     Halconfig is an EMC2 configuration tool.  It should be started from the emc2 directory and will require that you have started an instance of emc2 or work up a new configuration from scratch.

     This script is not for the faint hearted and carries no warranty or liability for its use to the extent allowed by law.}

set helpmain {
    You can show any part of a running hal by clicking on the node names in the tree in the upper left side of the display.  You can expand a node if it has a + in front and then click on these names to show their attributes as well.  Attributes are displayed in the same box you are reading now.

    The settings menu will provide the major way of moving from showing HAL attributes to modifying them or tuning them.  When working in modify mode, various control buttons are shown in the lower control frame.
}

set helpcomponent {
    This is the component display
}

set helppin {
    This is the pin help
}

set helpparameter {
    This is the parameter help
}

set helpsignal {
    This is the signal help
}

set helpfunction {
    This is the function help
}

set helpthread {
    This is the thread help
}

#
#----------end of help processes----------

