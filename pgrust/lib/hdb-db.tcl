# HammerDB settings for pgrust: the same as PostgreSQL's (HammerDB's pg
# driver; pgrust speaks the PostgreSQL protocol).
source [file join [file dirname [info script]] .. .. postgresql lib hdb-db.tcl]
