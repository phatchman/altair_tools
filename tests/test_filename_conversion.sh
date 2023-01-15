#!/bin/bash
# $1 = executable to test
# $2 = input files directory
# $3 = output directory
# $4 = reference comparison directory

output='Name     Ext   Length Used U At
M        COM   21509B  20K 0 W 
M1111111       21509B  20K 0 W 
M2222222       21509B  20K 0 W 
M3333333       21509B  20K 0 W 
M80            21509B  20K 0 W 
M80      CCC   21509B  20K 0 W 
M80      COM   21509B  20K 0 W 
M800     COM   21509B  20K 0 W 
M8000000 COM   21509B  20K 0 W 
M81            21509B  20K 0 W 
10 file(s), occupying 200K of 296K total capacity
44 directory entries and 96K bytes remain'

$1 -F $3/conv.dsk &&
$1 -p $3/conv.dsk ${2}/m\*.com &&
$1 -p $3/conv.dsk $2/m80. &&
$1 -p $3/conv.dsk $2/m81 &&
$1 -p $3/conv.dsk $2/m80.....com &&
$1 -p $3/conv.dsk $2/m800.c..o.m &&
$1 -p $3/conv.dsk $2/m80.cccom &&
$1 -p $3/conv.dsk $2/m8000000000.com &&
$1 -p $3/conv.dsk $2/m1111111 &&
$1 -p $3/conv.dsk $2/m2222222. &&
$1 -p $3/conv.dsk $2/m3333333.... &&
$1 $3/conv.dsk > $3/conv.dir &&
echo "$output" | diff $3/conv.dir -
