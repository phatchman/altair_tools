cmake_minimum_required(VERSION 3.10)
project(altairdsk)
add_executable(altairdsk altairdsk.c)
enable_testing()

set(TEST_DISKS_DIR test_disks)
set(TEST_FILE_DIR test_files)
set(OUTPUT_DIR test_output)

add_test(NAME CreateFormat
	COMMAND altairdsk -F ${OUTPUT_DIR}/formatted.dsk
	CONFIGURATIONS Debug Release ""
)

add_test(NAME CheckFormat
	COMMAND ${CMAKE_COMMAND} -E compare_files ${OUTPUT_DIR}/formatted.dsk ${TEST_DISKS_DIR}/formatted.dsk
	CONFIGURATIONS Debug Release ""
)

add_test(NAME CreateWrite
	COMMAND altairdsk -F ${OUTPUT_DIR}/write.dsk
	CONFIGURATIONS Debug Release ""
)

add_test(NAME PutTextFile1
	COMMAND altairdsk -p ${OUTPUT_DIR}/write.dsk && ${TEST_FILE_DIR}/ascii.txt
	CONFIGURATIONS Debug Release ""
)

add_test(NAME PutTextFile2
	COMMAND altairdsk -p ${OUTPUT_DIR}/write.dsk ${TEST_FILE_DIR}/ascii.txt ascii2.txt
	CONFIGURATIONS Debug Release ""
)

add_test(NAME PutTextFile3
	COMMAND altairdsk -p ${OUTPUT_DIR}/write.dsk ${TEST_FILE_DIR}/ascii.txt ascii3.txt
	CONFIGURATIONS Debug Release ""
)

add_test(NAME GetAsciiFiles
COMMAND altairdsk -d ${OUTPUT_DIR}/write.dsk > ${TEST_FILE_DIR}/ascii.txt ascii2.txt ascii3.txt
	CONFIGURATIONS Debug Release ""
)

add_test(NAME GetAsciiFiles
	COMMAND altairdsk -g ${OUTPUT_DIR}/write.dsk ${TEST_FILE_DIR}/ascii.txt ascii2.txt ascii3.txt
	CONFIGURATIONS Debug Release ""
)
