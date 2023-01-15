#!/bin/bash
# $1 = test to run
# $1 = executable to test
# $2 = input files directory
# $3 = output directory
# $4 = reference comparison directory

bash -c "$1 ../altairdsk ../test_files ../test_output ../test_disks" 
