#!/bin/bash
# $1 = executable to test
# $2 = input files directory
# $3 = output directory
# $4 = reference comparison directory

$1 -F $3/8in1.dsk &&
$1 -F $3/8in2.dsk -T FDD_8IN &&
$1 -F $3/hdd.dsk -T HDD_5MB &&
cmp $3/8in1.dsk $4/fmt_8in.dsk &&
cmp $3/8in2.dsk $4/fmt_8in.dsk &&
cmp $3/hdd.dsk $4/fmt_hhd5mb.dsk
