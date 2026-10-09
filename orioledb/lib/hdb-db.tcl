# HammerDB settings for OrioleDB: the same as PostgreSQL's (HammerDB's pg
# driver); the tables become OrioleDB tables through
# default_table_access_method.
source [file join [file dirname [info script]] .. .. postgresql lib hdb-db.tcl]
