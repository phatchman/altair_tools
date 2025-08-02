/*
 *****************************************************************************
 * ALTAIR Disk Tools 
 *
 * Manipulate Altair CPM Disk Images
 * 
 *****************************************************************************
*/
/*
 * MIT License
 *
 * Copyright (c) 2023 Paul Hatchman
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <libgen.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <stdarg.h>
#include <ctype.h>
#include <limits.h>

#if !defined(_WIN32)
#define O_BINARY 0
#endif

#define MAX_SECT_SIZE	256		/* Maximum size of a disk sector read */
#define MAX_DIRS		1024 	/* Maximum size of directory table */
								/* Current max is HDD_5MB_1024 format with 1024 entries */
#define MAX_ALLOCS		2048 	/* Maximum size of allocation table */
								/* Current max is 8MB FDC+ type with 2046 allocs */
#define DIR_ENTRY_LEN	32		/* Length of a single directory entry (extent)*/
#define ALLOCS_PER_EXT	16		/* Number of allocations in a directory entry (extent) */
#define RECORD_MAX		128		/* Max records per directory entry (extent) */

#define FILENAME_LEN 	8	
#define TYPE_LEN	 	3
#define FULL_FILENAME_LEN (FILENAME_LEN+TYPE_LEN+2)
#define MAX_USER		15
#define DELETED_FLAG	0xe5

/* Configuration for MITS 8" controller which writes to the raw sector */
struct disk_offsets {
	int start_track;		/* starting track which this offset applies */
	int end_track;			/* ending track */
	int off_data;			/* offset of the data portion */
	int off_track_nr;		/* offset of track number */
	int off_sect_nr;		/* offset of sector number */
	int	off_stop;			/* offset of stop byte */
	int off_zero;			/* offset of zero byte */
	int off_csum;			/* offset of checksum */
	int csum_method;		/* Checksum method. Only supports methods 0 and 1 for Altair 8" */
};

/* Disk format Parameters */
struct disk_type {
	const char* type;		/* String type name */
	int sector_len;			/* length of sector in bytes (must be 128) */
	int sector_data_len;	/* length of data part of sector in bytes. Note only supports 128 */
	int num_tracks;			/* Total tracks */
	int reserved_tracks;	/* Number of tracks reserved by the OS */
	int sectors_per_track;	/* Number of sectors per track */
	int block_size;			/* Size of Block / Allocation */
	int num_directories;	/* maximum number of directories / extents supported */
	int directory_allocs;	/* number of allocations reserved for directory entries */
	int image_size;			/* size of disk image (for auto-detection) */
	int skew_table_size;	/* number of entries in skew table */
	int *skew_table;		/* Pointer to the sector skew table */
	int (*skew_function)(int,int);		/* logical to physical sector skew conversion */
	void (*format_function)(int);		/* pointer to formatting function */
	struct disk_offsets offsets[2];		/* Raw sector offsets for MITS 8" controller */
};

/* On-disk representation of a directory entry */
typedef struct raw_dir_entry
{
	uint8_t		user;					/* User (0-15). 0xE5 = Deleted */
	char 		filename[FILENAME_LEN];	
	char 		type[TYPE_LEN];
	uint8_t		extent_l;				/* Extent number low 0-31 */
	uint8_t		reserved;
	uint8_t		extent_h;				/* Extent number high 32x */
	uint8_t		num_records;			/* Number of sectors used for this directory entry */
	uint8_t 	allocation[ALLOCS_PER_EXT];	/* List of allocations used for the file */
} raw_dir_entry;

/* Sanitised version of a directory entry */
typedef struct cpm_dir_entry 
{
	int				index;				/* Zero based directory number */
	uint8_t			valid;				/* Valid if used for a file */
	raw_dir_entry	raw_entry;			/* On-disk representation */
	int				extent_nr;			
	int				user;				
	char			filename[FILENAME_LEN+1];
	char			type[TYPE_LEN+1];
	char			attribs[3];			/* R - Read-Only, W - Read-Write, S - System */
	char			full_filename[FILENAME_LEN+TYPE_LEN+2]; /* filename.ext format */
	int				num_records;		
	int				num_allocs;
	int				allocation[ALLOCS_PER_EXT];		/* Only 8 of the 16 are used. As the 2-byte allocs 
													 * in the raw_entry are converted to a single value */
	struct cpm_dir_entry*	next_entry; /* pointer to next directory entry if multiple */
}	cpm_dir_entry;

cpm_dir_entry	dir_table[MAX_DIRS];			/* Directory entires in order read from "disk" */
cpm_dir_entry*	sorted_dir_table[MAX_DIRS];		/* Pointers to entries sorted by 
												 * valid, filename+type, user, extent_nr */
uint8_t			alloc_table[MAX_ALLOCS];		/* Allocation table. 0 = Unused, 1 = Used */

struct disk_type *disk_type;					/* Pointer to the disk image type */

void format_disk(int fd);
void mits8in_format_disk(int fd);

/* Skew table. Converts logical sectors to on-disk sectors */
/* MITS Floppy has it's own skew routine, and needs a 1-based skew table */
int mits_skew_table[] = {
	1,9,17,25,3,11,19,27,05,13,21,29,7,15,23,31,
	2,10,18,26,4,12,20,28,06,14,22,30,8,16,24,32
};


int mits8in_skew_function(int track, int logical_sector)
{
	if (track < 6)
	{
		return mits_skew_table[logical_sector];
	}
	/* This additional skew is required for strange historical reasons */
	return (((mits_skew_table[logical_sector] - 1) * 17) % 32) + 1;
}

/* Standard 8" floppy drive */
struct disk_type MITS8IN_FORMAT = {
	.type = "FDD_8IN",
	.sector_len = 137,
	.sector_data_len = 128,
	.num_tracks = 77,
	.reserved_tracks = 2,
	.sectors_per_track = 32,
	.block_size = 2048,
	.num_directories = 64,
	.directory_allocs = 2,
	.image_size = 337568,	/* Note images formatted in simh are 337664 */
	.skew_table_size = sizeof(mits_skew_table),
	.skew_table = mits_skew_table,
	.skew_function = &mits8in_skew_function,
	.format_function = &mits8in_format_disk,
	.offsets = {
		{ 0,  5, 3, 0, 0, 131, 133, 132, 0 },
		{ 6, 77, 7, 0, 1, 135, 136, 4, 1 }
	}
};

/* The FDC+ controller supports an 8MB "floppy" disk */
struct disk_type MITS8IN8MB_FORMAT = {
	.type = "FDD_8IN_8MB",
	.sector_len = 137,
	.sector_data_len = 128,
	.num_tracks = 2048,
	.reserved_tracks = 2,
	.sectors_per_track = 32,
	.block_size = 4096,
	.num_directories = 512,
	.directory_allocs = 4,
	.image_size = 8978432,	
	.skew_table_size = sizeof(mits_skew_table),
	.skew_table = mits_skew_table,
	.skew_function = &mits8in_skew_function,
	.format_function = &mits8in_format_disk,
	.offsets = {
		{ 0,  5, 3, 0, 0, 131, 133, 132, 0 },
		{ 6, 77, 7, 0, 1, 135, 136, 4, 1 }
	}
};


/* Skew table for the 5MB HDD. Note that we require a 
 * skew for each CPM sector. Not physical sector */
int	hd5mb_skew_table[] = {
	0,1,14,15,28,29,42,43,8,9,22,23,
	36,37,2,3,16,17,30,31,44,45,10,11,
	24,25,38,39,4,5,18,19,32,33,46,47,
	12,13,26,27,40,41,6,7,20,21,34,35,
	48,49,62,63,76,77,90,91,56,57,70,71,
	84,85,50,51,64,65,78,79,92,93,58,59,
	72,73,86,87,52,53,66,67,80,81,94,95,
	60,61,74,75,88,89,54,55,68,69,82,83
};

int standard_skew_function(int track, int logical_sector)
{
	return disk_type->skew_table[logical_sector] + 1;
}


/* MITS 5MB HDD Format */
struct disk_type MITS5MBHDD_FORMAT = {
	.type = "HDD_5MB",
	.sector_len = 128,
	.sector_data_len = 128,
	.num_tracks = 406,
	.reserved_tracks = 1,
	.sectors_per_track = 96,
	.block_size = 4096,
	.num_directories = 256,
	.directory_allocs = 2,
	.image_size = 4988928,
	.skew_table_size = sizeof(hd5mb_skew_table),
	.skew_table = hd5mb_skew_table,
	.skew_function = &standard_skew_function,
	.format_function = &format_disk,
	.offsets = {
		{ 0, 406, 0, -1, -1, -1, -1, -1, -1 },
		{ -1, -1, 0, -1, -1, -1, -1, -1, -1 }
	}
};

/* MITS 5MB HDD Format with 1024 directory entries */
struct disk_type MITS5MBHDD1024_FORMAT = {
	.type = "HDD_5MB_1024",
	.sector_len = 128,
	.sector_data_len = 128,
	.num_tracks = 406,
	.reserved_tracks = 1,
	.sectors_per_track = 96,
	.block_size = 4096,
	.num_directories = 1024,
	.directory_allocs = 8,
	.image_size = 4988928,
	.skew_table_size = sizeof(hd5mb_skew_table),
	.skew_table = hd5mb_skew_table,
	.skew_function = &standard_skew_function,
	.format_function = &format_disk,
	.offsets = {
		{ 0, 406, 0, -1, -1, -1, -1, -1, -1 },
		{ -1, -1, 0, -1, -1, -1, -1, -1, -1 }
	}
};

int tarbell_skew_table[] = {
	 0,  6, 12, 18, 24,  4,
	10, 16, 22,  2,  8, 14,
	20,  1,  7, 13, 19, 25,
	 5, 11, 17, 23,  3,  9,
	15, 21
};

/* Tarbell Floppy format */
struct disk_type TARBELLFDD_FORMAT = {
	.type = "FDD_TAR",
	.sector_len = 128,
	.sector_data_len = 128,
	.num_tracks = 77,
	.reserved_tracks = 2,
	.sectors_per_track = 26,
	.block_size = 1024,
	.num_directories = 64,
	.directory_allocs = 2,
	.image_size = 256256,
	.skew_table_size = sizeof(hd5mb_skew_table),
	.skew_table = tarbell_skew_table,
	.skew_function = &standard_skew_function,
	.format_function = &format_disk,
	.offsets = {
		{ 0, 77,  0,  -1, -1, -1, -1, -1, -1 },
		{ -1, -1, 0, -1, -1, -1, -1, -1, -1 }
	}
};

int fdd15mb_skew_table[] = {
	 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
	10,11,12,13,14,15,16,17,18,19,
	20,21,22,23,24,25,26,27,28,29,
	30,31,32,33,34,35,36,37,38,39,
	40,41,42,43,44,45,46,47,48,49,
	50,51,52,53,54,55,56,57,58,59,
	60,61,62,63,64,65,66,67,68,69,
	70,71,72,73,74,75,76,77,78,79
};

/* FDC+ controller supports 1.5MB floppy disks */
struct disk_type FDD15MB_FORMAT = {
	.type = "FDD_1.5MB",
	.sector_len = 128,
	.sector_data_len = 128,
	.num_tracks = 149,
	.reserved_tracks = 1,
	.sectors_per_track = 80,
	.block_size = 4096,
	.num_directories = 256,
	.directory_allocs = 2,
	.image_size = 1525760,
	.skew_table_size = sizeof(fdd15mb_skew_table),
	.skew_table = fdd15mb_skew_table,
	.skew_function = &standard_skew_function,
	.format_function = &format_disk,
	.offsets = {
		{ 0, 77,  0,  -1, -1, -1, -1, -1, -1 },
		{ -1, -1, 0, -1, -1, -1, -1, -1, -1 }
	}
};

/* Global Variables */
int VERBOSE = 0;	/* Print out Sector read/write and other information */
int EXIT_VALUE = EXIT_SUCCESS;

void print_usage(char* argv0); 
void print_mits_5mb_1k_warning(FILE* fp);
void error_exit(int eno, char *str, ...);
void error(int eno, char *str, ...);

void directory_list(int user);
void raw_directory_list();
void copy_from_cpm(int cpm_fd, int host_fd, cpm_dir_entry* dir_entry, int text_mode);
void copy_to_cpm(int cpm_fd, int host_fd, const char* cpm_filename, const char* host_filename, int user);
void extract_cpm(int cpm_fd, int host_fd);
void install_cpm(int cpm_fd, int host_fd);

void load_directory_table(int fd); 
cpm_dir_entry* find_dir_by_filename(const char *full_filename, cpm_dir_entry *prev_entry, int wildcards, int user);
int exist_filename_other_users(cpm_dir_entry *entry);
int filename_equals(const char* fn1, const char* fn2, int wildcards);
cpm_dir_entry* find_free_dir_entry(void);
void raw_to_cpmdir(cpm_dir_entry* entry);
int find_free_alloc(void);
void copy_filename(raw_dir_entry *entry, const char *filename);
void erase_file(int fd, cpm_dir_entry* entry);

ssize_t safe_read(int fd, void *buf, size_t count);
ssize_t full_write(int fd, const void *buf, size_t count);

void write_dir_entry(int fd, cpm_dir_entry* entry);
void read_sector(int fd, int alloc_num, int rec_num, void* buffer); 
void write_sector(int fd, int alloc_num, int rec_num, void* buffer);
void write_raw_sector(int fd, int track, int sector, void* buffer);
void convert_track_sector(int allocation, int record, int* track, int* sector);
uint8_t calc_checksum(uint8_t *buffer);

void validate_cpm_filename(const char *filename, char *validated_filename);
int compare_sort(const void *a, const void *b);
int compare_sort_ptr(const void *a, const void *b);
int get_raw_allocation(raw_dir_entry* raw, int entry_nr);
void set_raw_allocation(raw_dir_entry *entry, int entry_nr, int alloc);
int is_first_extent(cpm_dir_entry* dir_entry);
char* strip_quotes(char* filename);

void disk_format_disk(int fd);
int disk_sector_len();
int disk_data_sector_len();
int disk_num_tracks();
int disk_reserved_tracks();
int disk_sectors_per_track();
int disk_block_size();
int disk_num_directories();
int disk_skew_table_size();
int disk_skew_sector(int track_nr, int logical_sector);
int disk_track_len();
int disk_total_allocs();
int disk_recs_per_alloc();
int disk_recs_per_extent();
int disk_directory_allocs();
int disk_dirs_per_sector();
int disk_dirs_per_alloc();
struct disk_offsets *disk_get_offsets(int track_nr);
int disk_off_track_nr(int track_nr);
int disk_off_sect_nr(int track_nr);
int disk_off_data(int track_nr);
int disk_off_stop(int track_nr);
int disk_off_zero(int track_nr);
int disk_off_csum(int track_nr);
int disk_csum_method(int track_nr);
int disk_detect_type(int fd);
void disk_set_type(int img_fd, const char* type);
void disk_dump_parameters();
void disk_format_disk(int fd);

int main(int argc, char**argv)
{
	int open_mode = O_RDONLY;	/* read or write depending on selected options */
	mode_t open_umask = 0666;

	/* command line options */
	int opt;
	int do_dir = 0, do_raw = 0, do_get = 0;
	int do_put = 0 , do_help = 0, do_format = 0;
	int do_erase = 0, do_multiput = 0, do_multiget = 0;
	int do_multierase = 0, do_extractsystem = 0, do_writesystem = 0;
	int has_type = 0;				/* has the user specified a type? */
	int text_mode = -1;				/* default to auto-detect text/binary */
	char *disk_filename = NULL; 	/* Altair disk image filename */
	char from_filename[PATH_MAX];	/* filename to get / put */
	char to_filename[PATH_MAX];		/* filename to get / put */
	char *image_type;				/* manually specify type of disk image */
	int user = -1;					/* The CP/M user -1 = all users*/

	/* Default to 8" floppy. This default should not be used. Just here for safety */
	disk_type = &MITS8IN_FORMAT;

	/* parse command line options */
	while ((opt = getopt(argc, argv, "drhgGpPvFeEtbxsT:u:")) != -1)
	{
		switch (opt)
		{
			case 'h':
				do_help = 1;
				break;
			case 'd':
				do_dir = 1;
				open_mode = O_RDONLY;
				break;
			case 'r':
				do_raw = 1;
				open_mode = O_RDONLY;
				break;
			case 'g':
				do_get = 1;
				open_mode = O_RDONLY;
				break;
			case 'G':
				do_multiget = 1;
				open_mode = O_RDONLY;
				break;
			case 'p':
				do_put = 1;
				open_mode = O_RDWR;
				break;
			case 'P':
				do_multiput = 1;
				open_mode = O_RDWR;
				break;
			case 'v':
				VERBOSE = 1;
				break;
			case 'e':
				do_erase = 1;
				open_mode = O_RDWR;
				break;
			case 'E':
				do_multierase = 1;
				open_mode = O_RDWR;
				break;
			case 'F':
				do_format = 1;
				open_mode = O_WRONLY | O_CREAT | O_TRUNC;
				break;
			case 't':
				text_mode = 1;
				break;
			case 'b':
				text_mode = 0;
				break;
			case 'T':
				has_type = 1;
				image_type = optarg;
				break;
			case 'u':
			{
				char* end;
				user = strtol(optarg, &end, 10);
				if(*end != '\0' || user < 0 || user > 15)
				{
					error_exit(0, "User must be a valid number between 0 and 15\n");
				}
				break;
			}
			case 'x':
				do_extractsystem = 1;
				open_mode = O_RDONLY;
				break;
			case 's':
				do_writesystem = 1;
				open_mode = O_RDWR;
				break;
			case '?':
				exit(EXIT_FAILURE);
		}
	}
	/* make sure only one option is selected */
	int nr_opts = do_dir + do_raw + do_help + 
				  do_put + do_get + do_format +
				  do_erase + do_multiget + do_multiput +
				  do_multierase + do_extractsystem + do_writesystem;
	if (nr_opts > 1)
	{
		fprintf(stderr, "%s: Too many options supplied.\n", basename(argv[0]));
		exit(EXIT_FAILURE);
	}
	/* default to directory listing if no option supplied */
	if (nr_opts == 0) 
	{
		do_dir = 1;
	}
	if (do_help)
	{
		print_usage(argv[0]);
		exit(EXIT_SUCCESS);
	}

	/* get the disk image filename */
	if (optind == argc)
	{
		fprintf(stderr, "%s: <disk_image> not supplied.\n", basename(argv[0]));
		exit(EXIT_FAILURE);
	}
	else
	{
		/* get the Altair disk image filename */
		disk_filename = argv[optind++];
	}

	/* Get and Put need a from_filename and an optional to_filename*/
	/* Erase, extract and system just need a single filename */
	if (do_get || do_put || do_erase || do_extractsystem || do_writesystem) 
	{
		if (optind == argc) 
		{
			fprintf(stderr, "%s: <filename> not supplied\n", basename(argv[0]));
			exit(EXIT_FAILURE);
		} 
		else 
		{
			strcpy(from_filename, argv[optind++]);
			if (!(do_erase || do_extractsystem || do_writesystem) && optind < argc)
			{
				strcpy(to_filename, argv[optind++]);
			}
			else
			{
				strcpy(to_filename,from_filename);
			}
		}
	}
	/* For multiget and multi-put, just make sure at least 1 filename supplied */
	/* Filenames will be processed later */
	if (do_multiget || do_multiput || do_multierase)
	{
		if (optind == argc) 
		{
			fprintf(stderr, "%s: <filename ...> not supplied\n", basename(argv[0]));
			exit(EXIT_FAILURE);
		} 
	} 
	else if (optind != argc) 
	{
		fprintf(stderr, "%s: Too many arguments supplied.\n", basename(argv[0]));
		exit(EXIT_FAILURE);
	}

	/*
	 * Start of processing
	 */
	int fd_img = -1;		/* fd of disk image */
	
	/* Open the Altair disk image*/
	if ((fd_img = open(disk_filename, open_mode | O_BINARY, open_umask)) < 0)
	{
		error_exit(errno, "Error opening disk image file %s", disk_filename);
	}

	/* Set the format of this image */
	if (has_type)
	{
		disk_set_type(fd_img, image_type);
	}
	else
	{
		/* try to auto-detect type */
		if (disk_detect_type(fd_img) < 0)
		{
			if (!do_format)
			{
				error_exit(0, "Unknown disk image type. Use -h to see supported types and -T to force a type.");
			}
			else
			{
				// For format we default to mits 8IN
				disk_type = &MITS8IN_FORMAT;
				fprintf(stderr, "Defaulting to disk type: %s\n", disk_type->type);
			}
		}
	}

	if (VERBOSE)
		disk_dump_parameters();

	/* Initialize allocation table - Reserve allocations used by directories */
	for (int i = 0; i < disk_directory_allocs(); i++)
	{
	    alloc_table[i] = 1;
	}

	/* Read all directory entries - except for commands that don't need it */
	if (!do_format && !do_extractsystem && !do_writesystem)
	{
		load_directory_table(fd_img);
	}

	/* Raw Directory Listing */
	if (do_raw)
	{
		raw_directory_list();
		exit(EXIT_VALUE);
	}

	/* Formatted directory listing */
	if (do_dir)
	{
		directory_list(user);
		exit(EXIT_VALUE);
	}

	/* Copy file from disk image to host */
	if (do_get)
	{
		/* does the file exist in CPM? */
		cpm_dir_entry* entry = find_dir_by_filename(basename(from_filename), NULL, 0, user);
		if (entry == NULL)
		{
			error_exit(ENOENT, "Error copying file %s", from_filename);
		}
		/* Try and remove file file we are about to get */
		if ((unlink(to_filename) < 0) && (errno != ENOENT))
		{
			error_exit(errno, "Error removing old file %s", to_filename);
		}
		/* open file to save into */
		int fd_file = open(to_filename, O_CREAT | O_WRONLY | O_TRUNC | O_BINARY, 0666);
		if (fd_file < 0)
		{
			error_exit(errno, "Error opening file %s", from_filename);
		}
		/* finally copy the file from disk image*/
		copy_from_cpm(fd_img, fd_file, entry, text_mode);
		exit(EXIT_VALUE);
	}

	/* Copy multiple files from disk image to host */
	if (do_multiget)
	{
		char this_filename[FULL_FILENAME_LEN + 3];			/* current file being copied +3 for _uu (user number) */
		while (optind != argc)
		{
			int file_found = 0;
			cpm_dir_entry *entry = NULL;
			strcpy(from_filename, strip_quotes(argv[optind++]));
			/* process all filenames */
			while(1)
			{
				/* The filename may contain wildcards. If so, loop for each expanded filename */
				entry = find_dir_by_filename(from_filename, entry, 1, user);

				if (entry == NULL)
				{
					/* If not at least 1 file found for this from_filename */
					if (!file_found)
					{
						error(ENOENT, "Error copying %s", from_filename);
					}
					/* process next file */
					break;
				}
				/* Check if there are multiple copies of this filename for different users
				 * If so, append _user to the filename
				 * But don't append user number for user 0 */
				if (user == -1 && 
					entry->user != 0 &&
					exist_filename_other_users(entry))
				{
					sprintf(this_filename, "%s_%d", entry->full_filename, entry->user);
				}
				else
				{
					strcpy(this_filename, entry->full_filename);
				}
				file_found = 1;
				/* delete the host file we are about to copy into */
				if ((unlink(this_filename) < 0) && (errno != ENOENT))
				{
					error(errno, "Skipping file. Error removing old file %s.", this_filename);
					break;
				}
				/* create the file to copy into */
				int fd_file = open(this_filename, O_CREAT | O_WRONLY | O_TRUNC | O_BINARY, 0666);
				if (fd_file < 0)
				{
					error(errno, "Skipping file. Error opening file %s", this_filename);
					break;
				}
				/* copy it */
				copy_from_cpm(fd_img, fd_file, entry, text_mode);
				close(fd_file);
			}
		}
		exit(EXIT_VALUE);
	}

	/* Copy file from host to disk image */
	if (do_put)
	{
		int fd_file = open(from_filename, O_RDONLY);
		if (fd_file < 0)
		{
			error_exit(errno, "Error opening file %s", from_filename);
		}
		copy_to_cpm(fd_img, fd_file, basename(to_filename), from_filename, user);
		exit(EXIT_VALUE);
	}

	/* Copy multiple files from host to disk image */
	if (do_multiput)
	{
		/* process for each file passed on the command file */
		while (optind != argc)
		{
			strcpy(from_filename, argv[optind++]);
			strcpy(to_filename, from_filename);

			int fd_file = open(from_filename, O_RDONLY | O_BINARY);
			if (fd_file < 0)
			{
				error(errno, "Error opening file %s", from_filename);
				continue;
			}
			copy_to_cpm(fd_img, fd_file, basename(to_filename), from_filename, user);
			close(fd_file);
		}
		exit(EXIT_VALUE);
	}

	/* erase a single file from the disk image */
	if (do_erase)
	{
		cpm_dir_entry *entry = find_dir_by_filename(from_filename, NULL, 0, user);
		if (entry == NULL)
		{
			error_exit(ENOENT, "Error erasing %s", from_filename);
		}
		erase_file(fd_img, entry);
		exit(EXIT_VALUE);
	}

	if(do_multierase)
	{
		while (optind != argc)
		{
			int file_found = 0;
			cpm_dir_entry *entry = NULL;

			strcpy(from_filename, strip_quotes(argv[optind++]));
			/* process all filenames */
			while(1)
			{
				/* The filename may contain wildcards. If so, loop for each expanded filename */
				entry = find_dir_by_filename(from_filename, entry, 1, user);

				if (entry == NULL)
				{
					/* If not at least 1 file found for this from_filename */
					if (!file_found)
					{
						error(ENOENT, "Error erasing %s", from_filename);
					}
					/* process next file */
					break;
				}
				file_found = 1;
				erase_file(fd_img, entry);
			}
		}
		exit(EXIT_VALUE);
	}

	/* format and existing image or create a newly formatted image */
	if (do_format)
	{
		if (disk_type == &MITS5MBHDD1024_FORMAT)
		{
			print_mits_5mb_1k_warning(stderr);
		}
		/* Call the disk-specific format function */
		disk_format_disk(fd_img);
		exit(EXIT_VALUE);
	}

	/* Extract the CP/M system files*/
	if (do_extractsystem)
	{
		int fd_file = open(to_filename, O_CREAT | O_WRONLY | O_TRUNC | O_BINARY, open_umask);
		if (fd_file < 0)
		{
			error_exit(errno, "Error opening %s", to_filename);
		}
		extract_cpm(fd_img, fd_file);
		exit(EXIT_VALUE);
	}

	/* Copy system tracks onto disk image */
	if (do_writesystem)
	{
		int fd_file = open(from_filename, O_RDONLY | O_BINARY, open_umask);
		if (fd_file < 0)
		{
			error_exit(errno, "Error opening %s", from_filename);
		}
		install_cpm(fd_img, fd_file);
		exit(EXIT_VALUE);
	}

	exit(EXIT_VALUE);
}


/*
 * Usage information
 */
void print_usage(char* argv0)
{
	char *progname = basename(argv0);
	printf("%s: -[d|r|F]v  [-T <type>] [-u <user>] <disk_image>\n", progname);
	printf("%s: -[g|p|e][t|b]v [-T <type>] [-u <user>] <disk_image> <src_filename> [dst_filename]\n", progname);
	printf("%s: -[G|P|E][t|b]v [-T <type>] [-u <user>] <disk_image> <filename ...>\n", progname);
	printf("%s: -[x|s]v        [-T <type>] <disk_image> <system_image>\n", progname);
	printf("%s: -h\n", progname);
	printf("\t-d\tDirectory listing (default)\n");
	printf("\t-r\tRaw directory listing\n");
	printf("\t-F\tFormat existing or create new disk image. Defaults to %s\n", MITS8IN_FORMAT.type);
	printf("\t-g\tGet - Copy file from Altair disk image to host\n");
	printf("\t-G\tGet Multiple - Copy multiple files from Altair disk image to host\n");
	printf("\t  \t               wildcards * and ? are supported e.g '*.COM'\n");
	printf("\t-p\tPut - Copy file from host to Altair disk image\n");
	printf("\t-P\tPut Multiple - Copy multiple files from host to Altair disk image\n");
	printf("\t-e\tErase a file\n");
	printf("\t-E\tErase multiple files - wildcards supported\n");
	printf("\t-t\tPut/Get a file in text mode\n");
	printf("\t-b\tPut/Get a file in binary mode\n");
	printf("\t-u\tUser - Restrict operation to CP/M user\n");
	printf("\t-x\tExtract CP/M system (from a bootable disk image) to a file\n");
	printf("\t-s\tWrite saved CP/M system image to disk image (make disk bootable)\n");
	printf("\t-T\tDisk image type. Auto-detected if possible. Supported types are:\n");
	printf("\t\t\t* %s - MITS 8\" Floppy Disk (Default)\n", MITS8IN_FORMAT.type);
	printf("\t\t\t* %s - MITS 5MB Hard Disk\n", MITS5MBHDD_FORMAT.type);
	printf("\t\t\t* %s - MITS 5MB, with 1024 directories (!!!)\n", MITS5MBHDD1024_FORMAT.type);
	printf("\t\t\t* %s - Tarbell Floppy Disk\n", TARBELLFDD_FORMAT.type);
	printf("\t\t\t* %s - FDC+ 1.5MB Floppy Disk\n", FDD15MB_FORMAT.type);
	printf("\t\t\t* %s - FDC+ 8MB \"Floppy\" Disk\n", MITS8IN8MB_FORMAT.type);
	printf("\t-v\tVerbose - Prints image type and sector read/write information\n");
	printf("\t-h\tHelp\n\n");

	print_mits_5mb_1k_warning(stdout);
}

/*
 * Print a warning that this format cannot be auto-detected.
 */
void print_mits_5mb_1k_warning(FILE* fp)
{
	fprintf(fp, "!!! The %s type cannot be auto-detected. Always use -T with this format,\n", MITS5MBHDD1024_FORMAT.type);
	fprintf(fp, "otherwise your disk image will auto-detect as the standard 5MB type and could be corrupted.\n");
}

/* 
 * Print formatted error string and exit.
 */
void error_exit(int eno, char *str, ...)
{
	va_list argp;
  	va_start(argp, str);

	vfprintf(stderr, str, argp);
	if (eno > 0)
		fprintf(stderr,": %s\n", strerror(eno));
	else
		fprintf(stderr, "\n");
	exit(EXIT_FAILURE);
}

/* 
 * Print formatted error string. 
 * Set global EXIT_VALUE to failure value.
 */
void error(int eno, char *str, ...)
{
	va_list argp;
  	va_start(argp, str);

	vfprintf(stderr, str, argp);
	if (eno > 0)
		fprintf(stderr,": %s\n", strerror(eno));
	else
		fprintf(stderr, "\n");
	va_end(argp);
	EXIT_VALUE = EXIT_FAILURE;
}

/*
 * Print nicely formatted directory listing 
 * user - -1 = all users, otherwise restrict to that user number
 */
void directory_list(int user)
{
	int file_count = 0;
	int kb_used = 0;
	int kb_free = 0;
	int entry_count = 0;

	int kb_total = (disk_total_allocs() - disk_directory_allocs()) * disk_block_size() / 1024;

	printf("Name     Ext   Length Used U At\n");

	cpm_dir_entry *entry = NULL;
	int this_records = 0;
	int this_allocs = 0;
	int this_kb = 0;
	char *last_filename = "";
	int last_user = -1;

	for (int i = 0 ; i < disk_num_directories() ; i++)
	{
		/* Valid entries are sorted before invalid ones. So stop on first invalid */
		entry = sorted_dir_table[i];
		if (!entry->valid)
		{
			break;
		}

		entry_count++;

		/* skip if not for all users or not for this user */
		if (user != -1 && user != entry->user)
			continue;

		/* If this is the first record for this file, then reset the file totals */
		if((strcmp(entry->full_filename, last_filename) != 0) ||
			(entry->user != last_user))
		{
			file_count++;
			this_records = 0;
			this_allocs = 0;
			this_kb = 0;
			last_filename = entry->full_filename;
			last_user = entry->user;
		}

		this_records += entry->num_records;
		this_allocs += entry->num_allocs;

		/* If there are no more dir entries for this file, print out the file details */
		if(entry->next_entry == NULL)
		{
			this_kb += (this_allocs * disk_block_size()) / 1024;
			kb_used += this_kb;

			printf("%s %s %7dB %3dK %d %s\n", 
				entry->filename, 
				entry->type,
				this_records * disk_sector_len(),
				this_kb,
				entry->user,
				entry->attribs);
		}
	}
	for (int i = disk_directory_allocs() ; i < disk_total_allocs() ; i++)
	{
		if(alloc_table[i] == 0)
		{
			kb_free+= disk_block_size() / 1024;
		}
	}
	printf("%d file(s), occupying %dK of %dK total capacity\n",
			file_count, kb_used, kb_total);
	printf("%d directory entries and %dK bytes remain\n",
			disk_num_directories() - entry_count, kb_free);
}

/*
 * Print raw directory table.
 */
void raw_directory_list()
{
	printf("IDX:U:FILENAME:TYP:AT:EXT:REC:[ALLOCATIONS]\n");
	for (int i = 0 ; i < disk_num_directories() ; i++)
	{
		cpm_dir_entry *entry = &dir_table[i];
		if (entry->valid)
		{
			printf("%03d:%u:%s:%s:%s:%03u:%03u:[", 
				entry->index,
				entry->user, entry->filename, entry->type,
				entry->attribs,
				entry->extent_nr, entry->num_records);
			for (int i = 0 ; i < ALLOCS_PER_EXT / 2 ; i++)	/* Only 8 of the 16 entries are used */
			{
				if (i < ALLOCS_PER_EXT / 2 - 1)
				{
					printf("%u,", entry->allocation[i]);
				} 
				else
				{
					printf("%u", entry->allocation[i]);
				}
			}
			printf("]\n");
		}
	}
	printf ("FREE ALLOCATIONS:\n");
	int nr_output = 0;
	for (int i = 0 ; i < disk_total_allocs() ; i++)
	{
		if (alloc_table[i] == 0)
		{
			printf("%03d ", i);
			if ((++nr_output % 16) == 0)
			{
				printf("\n");
			}	
		}
	}
	printf("\n");
}

/*
 * Copy a file from CPM disk to host
 * dir_entry - The first directory entry for the file to be copied.
 * text_mode - -1 = auto-detect, 0 = binary, 1 = text
 */
void copy_from_cpm(int cpm_fd, int host_fd, cpm_dir_entry* dir_entry, int text_mode)
{
	uint8_t sector_data[MAX_SECT_SIZE];
	int data_len = disk_data_sector_len();
	while (dir_entry != NULL)
	{
		/* Each record in this extent represents a 128 byte sector to a maximum of 128 entries. (exception below)
		 * Where more than 128 records are allowed and there are more than 4 allocations used in this extent,
		 * then the number of records is actually 128 + the record number. But the maximum record number is still 128.
		 * .i.e. 128 means 256. In this case the extent number will also be 1 more than normally expected. 
		 * e.g. It could be 1 for the first extent, 3 for the second and 4 for the third extent */
		int num_records = ((disk_recs_per_extent() > 128) && (dir_entry->num_allocs > 4)) ? 
							128 + dir_entry->num_records : dir_entry->num_records;

		for (int recnr = 0 ; recnr < num_records ; recnr ++)
		{
			int alloc = dir_entry->allocation[recnr / disk_recs_per_alloc()];
			/* if no more allocations, then done with this extent */
			if (alloc == 0)
				break;
		
			/* get data for this allocation and record number */
			read_sector(cpm_fd, alloc, recnr, sector_data);

			/* If in auto-detect mode or if in text_mode and this is the last sector */
			if ((text_mode == -1) ||
				((text_mode == 1) && (recnr == num_records - 1)))
			{
				for (int i = 0 ; i < disk_data_sector_len() ; i++)
				{
					/* If auto-detecting text mode, check if char is "text"
					 * where "text" means 7 bit only  */
					if (text_mode == -1)
					{
						if (sector_data[i] & 0x80)
						{
							/* not "text", so set to binary mode */
							text_mode = 0;
							break;
						}
					}
					/* If in text mode and on last block, then check for ^Z for EOF 
					 * Set data_len to make sure that data stops writing prior to first ^Z */
					if (text_mode && (recnr == num_records - 1) &&
							sector_data[i] == 0x1a)
					{
						data_len = i;
						break;
					}
				}
			}
			/* write out current sector */
			if (full_write(host_fd, sector_data, data_len) < 0)
			{
				error(errno, "Error writing local file");
				return;
			}
		}
		dir_entry = dir_entry->next_entry;
	}
}

/*
 * Read a full buffer's worth of data
 */
ssize_t full_read(int fd, void *buf, size_t count)
{
	size_t bytes_left = count;
	size_t bytes_read = 0;
	ssize_t nbytes = 0;

	while ((nbytes = read(fd, buf + bytes_read, bytes_left)) > 0)
	{
		bytes_read += nbytes;
		bytes_left -= nbytes;

		if (bytes_read == count)
		{
			return bytes_read;
		}
	}
	if (nbytes < 0)
		return nbytes;
	return bytes_read;
}

/*
 * Write a full buffer's worth of data
 */
ssize_t full_write(int fd, const void *buf, size_t count)
{
	size_t bytes_left = count;
	size_t bytes_written = 0;
	ssize_t nbytes = 0;

	while((nbytes = write(fd, buf + bytes_written, bytes_left)) > 0)
	{
		bytes_written += nbytes;
		bytes_left -= nbytes;

		if (nbytes == count)
		{
			return bytes_written;
		}
	}
	if (nbytes < 0)
		return nbytes;
	return bytes_written;
}

/*
 * Copy file from host to Altair CPM disk image
 */
void copy_to_cpm(int cpm_fd, int host_fd, const char* cpm_filename, const char* host_filename, int user)
{
	uint8_t sector_data[MAX_SECT_SIZE];
	char valid_filename[FULL_FILENAME_LEN];

	if (user == -1)
	{
		user = 0;
	}

	/* Turn the supplied filename into something valid for CP/M */
	validate_cpm_filename(cpm_filename, valid_filename);
	if (strcasecmp(cpm_filename, valid_filename))
	{
		fprintf(stderr, "Converting filename %s to %s\n", cpm_filename, valid_filename);
	}
	if (find_dir_by_filename(valid_filename, 0, 0, user) != NULL)
	{
		/* File already exists. Error and skip */
		error(EEXIST, "Error creating file %s", valid_filename);
		return;
	}
	/*
	 * For each 128 byte sector. Increment the record number.
     * If reach # recs / alloc, then find a new free allocation.
	 * If reach # recs / extent, then write out this extent and create a new one
	 * If reach rec % 128, then increment the extent number (to cater for > 128 recs / extent)
	 * Note that even for > 128 recs per extent, the rec number still has a max of 128.
	 */
	int rec_nr = 0;
	int nr_extents = 0;
	int allocation = 0;
	int nr_allocs = 0;
	int nbytes;
	cpm_dir_entry *dir_entry = NULL;

	/* Fill the sector with Ctrl-Z (EOF) in case not fully filled by read from host*/
	memset (sector_data, 0x1a, disk_data_sector_len()); 
	/* Read the first sector */
	nbytes = full_read(host_fd, sector_data, disk_data_sector_len());
	if (nbytes < 0)
	{
		error(errno,"Error reading from file %s. File not copied.\n", host_filename);
		return;
	}
	/* Note will enter the loop once for an empty file */
	do
	{
		/* Is this a new Extent (i.e directory entry) ? */
		if ((rec_nr % disk_recs_per_extent()) == 0)
		{
			/* if there is already a directory entry, write it to disk */
			if (dir_entry != NULL)
			{
				raw_to_cpmdir(dir_entry);
				write_dir_entry(cpm_fd, dir_entry);
			}
			/* Get new directory entry */
			dir_entry = find_free_dir_entry();
			if (dir_entry == NULL)
			{
				error_exit(0, "Error writing %s: No free directory entries", cpm_filename);
			}
			/* Initialise the directory entry */
			memset(&dir_entry->raw_entry, 0, sizeof(raw_dir_entry));
			copy_filename(&dir_entry->raw_entry, valid_filename);
			dir_entry->raw_entry.user = user;
			nr_allocs = 0;
		}
		/* Is this a new allocation? */
		if ((rec_nr % disk_recs_per_alloc()) == 0)
		{
			/* A zero length file has 0 allocations */
			allocation = (nbytes > 0) ? find_free_alloc() : 0;

			if (allocation < 0)
			{
				/* No free allocations! 
				 * write out directory entry (if it has any allocations) before exit */
				if (get_raw_allocation(&dir_entry->raw_entry, 0) != 0)
				{
					raw_to_cpmdir(dir_entry);
					write_dir_entry(cpm_fd, dir_entry);
				}
				error_exit(0, "Error writing %s: No free allocations", valid_filename);
			}
			set_raw_allocation(&dir_entry->raw_entry, nr_allocs, allocation);
			nr_allocs++;
		}
		dir_entry->raw_entry.num_records = (rec_nr % RECORD_MAX) + 1;
		dir_entry->raw_entry.extent_l = nr_extents % 32;
		dir_entry->raw_entry.extent_h = nr_extents / 32;
		if (nbytes > 0)
		{
			write_sector(cpm_fd, allocation, rec_nr, sector_data);
			memset (sector_data, 0x1a, disk_data_sector_len());
		}
		rec_nr++;
		if ((rec_nr % RECORD_MAX) == 0)
		{
			nr_extents++;
		}
	}
	while ((nbytes = full_read(host_fd, sector_data, disk_data_sector_len())) > 0);
	/* File is done. Write out the last directory entry */
	raw_to_cpmdir(dir_entry);
	write_dir_entry(cpm_fd, dir_entry);
}	

/* 
 * Extract the CP/M operating system tracks and save to host file
 */
void extract_cpm(int cpm_fd, int host_fd)
{
	uint8_t sector_data[MAX_SECT_SIZE];
	if (lseek(cpm_fd, 0, SEEK_SET) < 0)
	{
		error_exit(errno, "extract_cpm: Error seeking disk image");
	}
	int sector_len = disk_sector_len();
	for (int track_nr = 0 ; track_nr < disk_reserved_tracks() ; track_nr++)
	{
		for (int sect_nr = 0 ; sect_nr < disk_sectors_per_track() ; sect_nr++)
		{
			if (full_read(cpm_fd, sector_data, sector_len) != sector_len)
			{
				error_exit(errno, "extract_cpm: Error reading sector");
			}
			if (full_write(host_fd, sector_data, sector_len) != sector_len)
			{
				error_exit(errno, "extract_cpm: Error writing sector");
			}
		}
	}
}

/*
 * Install the CP/M operating system tracks from a host file
 */
void install_cpm(int cpm_fd, int host_fd)
{
	uint8_t sector_data[MAX_SECT_SIZE];
	int required_size = disk_reserved_tracks() * disk_track_len();
	if (lseek(host_fd, 0, SEEK_END) != required_size)
	{
		error_exit(0, "System image size must be %d bytes. Aborting", required_size);
	}
	if (lseek(host_fd, 0, SEEK_SET) < 0)
	{
		error_exit(errno, "install_cpm: Error seeking system image");
	}
	if (lseek(cpm_fd, 0, SEEK_SET) < 0)
	{
		error_exit(errno, "install_cpm: Error seeking disk image");
	}

	int sector_len = disk_sector_len();
	for (int track_nr = 0 ; track_nr < disk_reserved_tracks() ; track_nr++)
	{
		for (int sect_nr = 0 ; sect_nr < disk_sectors_per_track() ; sect_nr++)
		{
			if (full_read(host_fd, sector_data, sector_len) != sector_len)
			{
				error_exit(errno, "install_cpm: Error reading sector");
			}
			if (full_write(cpm_fd, sector_data, sector_len) != sector_len)
			{
				error_exit(errno, "install_cpm: Error writing sector");
			}
		}
	}
}

/*
 * Loads all of the directory entries into dir_table 
 * sorted pointers stored to sorted_dir_table
 * Related directory entries are linked through next_entry.
 */
void load_directory_table(int fd)
{
	uint8_t sector_data[MAX_SECT_SIZE];

	for (int sect_nr = 0 ; sect_nr < (disk_num_directories()) / disk_dirs_per_sector(); sect_nr++)
	{
		/* Read each sector containing a directory entry */
		int allocation = sect_nr / disk_recs_per_alloc();
		int	record = (sect_nr % disk_recs_per_alloc());

		read_sector(fd, allocation, record, sector_data);
		for (int dir_nr = 0 ; dir_nr < disk_dirs_per_sector() ; dir_nr++)
		{
			/* Calculate which directory entry number this is */
			int index = sect_nr * disk_dirs_per_sector() + dir_nr;
			cpm_dir_entry *entry = &dir_table[index];
			entry->index = index;
			memcpy(&entry->raw_entry, sector_data + (DIR_ENTRY_LEN * dir_nr), DIR_ENTRY_LEN);
			sorted_dir_table[index] = entry;

			if (entry->raw_entry.user <= MAX_USER)
			{
				raw_to_cpmdir(entry);

				/* Mark off the used allocations */
				for (int alloc_nr = 0 ; alloc_nr < ALLOCS_PER_EXT ; alloc_nr++)
				{
					int alloc = entry->allocation[alloc_nr];
					
					/* Allocation of 0, means no more allocations used by this entry */
					if (alloc == 0)
						break;
					/* otherwise mark the allocation as used */
					if (alloc >= MAX_ALLOCS)
					{
						error(0, "Invalid allocation number found in directory table.\nPossible incorrect image type. Use -v to check image type detected or selected.");
					}
					else
					{
						alloc_table[alloc] = 1;
					}
				}
			}
		}
	}

	/* Create a list of pointers to the directory table, sorted by:
	 * Valid, Filename, Type, User, Extent */
	qsort(&sorted_dir_table, disk_num_directories(), sizeof(cpm_dir_entry*), compare_sort_ptr);

	/* link related directory entries */
	/* No need to check last entry, it can't be related to anything */
	for (int i = 0 ; i < disk_num_directories() - 1 ; i++)
	{
		cpm_dir_entry* entry = sorted_dir_table[i];
		cpm_dir_entry* next_entry = sorted_dir_table[i+1];

		if (entry->valid)
		{
			/* Check if there are more extents for this file */
			if ((strcmp(entry->full_filename, next_entry->full_filename) == 0) &&
				(entry->user == next_entry->user))
			{
				entry->next_entry = next_entry;
			}
		}
	}
}

/*
 * Erase a file
 */
void erase_file(int fd, cpm_dir_entry* entry)
{
	/* Set user on all directory entries for this file to "DELETED" */
	do
	{
		entry->raw_entry.user = DELETED_FLAG;
		write_dir_entry(fd,entry);
	} while ((entry = entry->next_entry) != NULL);
}


/*
 * Create a newly formatted disk / format an existing disk.
 * The standard format function which fills every byte with 0xE5
 */
void format_disk(int fd)
{

	uint8_t sector_data[MAX_SECT_SIZE];

	memset(sector_data, 0xe5, disk_sector_len());

	for (int track = 0 ; track < disk_num_tracks() ; track++)
	{
		for (int sector = 0 ; sector < disk_sectors_per_track() ; sector++)
		{
			write_raw_sector(fd, track, sector + 1, sector_data);
		}
	}
}

/*
 * Create a newly formatted disk / format an existing disk.
 * This needs to format the raw disk sectors.
 */
void mits8in_format_disk(int fd)
{
	uint8_t sector_data[MAX_SECT_SIZE];

	memset(sector_data, 0xe5, disk_sector_len());
	sector_data[1] = 0x00;
	sector_data[2] = 0x01;
	/* Stop byte = 0xff */
	sector_data[disk_off_stop(0)] = 0xff;
	/* From zero byte to end of sector must be set to 0x00 */
	memset(sector_data+disk_off_zero(0), 0, disk_sector_len() - disk_off_zero(0));

	for (int track = 0 ; track < disk_num_tracks() ; track++)
	{
		if (track == 6)
		{
			memset(sector_data, 0xe5, disk_sector_len());
			sector_data[2] = 0x01;
			sector_data[disk_off_stop(6)] = 0xff;
			sector_data[disk_off_zero(6)] = 0x00;
			memset(sector_data+disk_off_zero(6), 0, disk_sector_len() - disk_off_zero(6));
		}
		for (int sector = 0 ; sector < disk_sectors_per_track() ; sector++)
		{
			if (track < 6)
			{
				sector_data[disk_off_track_nr(0)] = track | 0x80;
				sector_data[disk_off_csum(0)] = calc_checksum(sector_data+disk_off_data(0));
			}
			else
			{
				sector_data[disk_off_track_nr(6)] = track | 0x80;
				sector_data[disk_off_sect_nr(6)] = (sector * 17) % 32;
				uint8_t checksum = calc_checksum(sector_data+disk_off_data(6));
				checksum += sector_data[2];
				checksum += sector_data[3];
				checksum += sector_data[5];
				checksum += sector_data[6];
				sector_data[disk_off_csum(6)] = checksum;
			}
			write_raw_sector(fd, track, sector + 1, sector_data);
		}
	}
}


/*
 * Find the directory entry related to a filename.
 * If prev_entry != NULL, start searching from the next entry after prev_entry
 * If wildcards = 1, allow wildcard characters * and ? to be used when matching to the filename
 * user - user number or -1 for all users
 */
cpm_dir_entry* find_dir_by_filename(const char *full_filename, cpm_dir_entry *prev_entry, int wildcards, int user)
{
	int start_index = (prev_entry == NULL) ? 0 : prev_entry->index + 1;
	for (int i = start_index ; i < disk_num_directories() ; i++)
	{
		/* Is this the first extent for a file? 
		 * And is this entry for the correct user (or all users) */
		if (dir_table[i].valid &&
			is_first_extent(&dir_table[i]))
		{
			/* If filename and user matches, return the directory entry */
			if ((filename_equals(full_filename, dir_table[i].full_filename, wildcards) == 0) &&
				(user == -1 || user == dir_table[i].user))
			{
				return &dir_table[i];
			}
		}
	}
	/* No matching filename / user found */
	return NULL;
}

/*
 * Check if this filename.ext exists for other users in the directory table.
 * Returns 1 if exists for other users, otherwise 0
 */
int exist_filename_other_users(cpm_dir_entry *entry)
{
	for (int i = 0 ; i < disk_num_directories() ; i++)
	{
		/* Does directory table entry have same filename, but is not the same entry as being one being checked */
		if (dir_table[i].valid &&
			&dir_table[i] != entry &&
			is_first_extent(&dir_table[i]) &&
			filename_equals(entry->full_filename, dir_table[i].full_filename, 0))
			{
				return 1;
			}
	}
	return 0;
}

/* 
 * Check if 2 filenames match, using wildcard matching.
 * Only s1 can contain wildcard characters. * and ? are supported.
 * Note that A*E* is interpreted as A*
 * This doesn't work identically to CPM, but I prefer this as 
 * copying '*' will copy everything, rather than needing '*.*'
 */
int filename_equals(const char *s1, const char *s2, int wildcards)
{
	int found_dot = 0;	/* have we found the dot separator between filename and type*/
	char eos = '\0';	/* end of string char */
	while(*s1 != '\0' && *s2 != '\0')
	{
		/* If it's a '*' wildcard it matches everything here onwards, so return equal
		 * if we've already found the '.'. Otherwise keep searching from '.' onwards */
		if (wildcards && *s1 == '*')
		{
			if (found_dot)
			{
				return 0;
			}
			else
			{
				s1 = strchr(s1, '.');
				/* if wildcard has no extension e.g. T* then equal */
				if (s1 == NULL)
					return 0;
				s2 = strchr(s2, '.');
				if (s2 == NULL)
					s2 = &eos;
			}
		}
		/* ? matches 1 character, process next char */
		else if (wildcards && *s1 == '?')
		{
			s1++;
			s2++;
			continue;
		}
		else
		{
			if (*s2 == '.')
				found_dot = 1;
			int result = toupper(*s1) - toupper(*s2);
			/* If chars are not equal, return not equal */
			if (result)
				return result;
		}
		s1++;
		s2++;
	}
	/* If equal, both will be at end of string */
	if (*s1 == *s2 && *s1 == '\0')
		return 0;
	/* Special case for filenames ending in '.' 
	 * Treat ABC. and ABC as equal */
	if (*s1 == '\0' && *s2 == '.' && *(s2 + 1) == '\0')
		return 0;
	if (*s2 == '\0' && *s1 == '.' && *(s1 + 1) == '\0')
		return 0;
	return 1;	/* not equal */
}

/*
 * Find an unused directory entry.
 */
cpm_dir_entry* find_free_dir_entry(void)
{
	for (int i = 0 ; i < disk_num_directories() ; i++)
	{
		if (!dir_table[i].valid)
		{
			return &dir_table[i];
		}
	}
	return NULL;
}

/*
 * Convert a raw cpm directory entry (extent) into an structure that is
 * easier to work with.
 */
void raw_to_cpmdir(cpm_dir_entry* entry)
{
	char *space_pos;

	raw_dir_entry *raw = &entry->raw_entry;
	entry->next_entry = 0;
	entry->user = raw->user;
	entry->extent_nr = raw->extent_h * 32 + raw->extent_l;
	strncpy(entry->filename, raw->filename, FILENAME_LEN);
	entry->filename[FILENAME_LEN] = '\0';
	for (int i = 0 ; i < TYPE_LEN ; i++)
	{
		/* remove the top bit as it encodes file attributes*/
		entry->type[i] = raw->type[i] & 0x7f;	
	}
	entry->type[TYPE_LEN] = '\0';
	/* If high bit is set on 1st TYPE char, then read-only, otherwise read-write */
	entry->attribs[0] = (raw->type[0] & 0x80) ? 'R' : 'W';
	/* If high bit is set on 2nd TYPE char, then this is a "system/hidden" file */
	entry->attribs[1] = (raw->type[1] & 0x80) ? 'S' : ' ';
	entry->attribs[2] = '\0';
	strcpy(entry->full_filename, entry->filename);
	space_pos = strchr(entry->full_filename, ' ');
	/* strip out spaces from filename */
	if (space_pos != NULL)
	{
		*space_pos = '\0';
	}
	/* Only add a '.' if there really is an extension */
	if (entry->type[0] != ' ')
	{
		strcat(entry->full_filename,".");
		strcat(entry->full_filename, entry->type);
		space_pos = strchr(entry->full_filename, ' ');
		/* strip out spaces from type */
		if (space_pos != NULL)
		{
			*space_pos = '\0';
		}
	}
	entry->num_records = raw->num_records;
	int num_allocs = 0;
	for (int i = 0 ; i < ALLOCS_PER_EXT ; i++)
	{
		int alloc_nr = get_raw_allocation(&entry->raw_entry, i);
		if (disk_total_allocs() <= 256)
		{
			/* an 8 bit allocation number */	
			entry->allocation[i] = alloc_nr;
		}
		else
		{
			/* a 16 bit allocation number. */
			entry->allocation[i/2] = alloc_nr;
			i++;
		}
		/* a zero allocation entry means there are no more allocations to come */
		if (alloc_nr == 0)
			break;

		num_allocs++;
	}
	entry->num_allocs = num_allocs;
	entry->valid = 1;
}

/*
 * Find a free allocation. Mark is as used.
 * Returns the allocation, or -1 if no free allocation found
 */
int find_free_alloc(void)
{
	for (int i = 0 ; i < disk_total_allocs() ; i++)
	{
		if(alloc_table[i] == 0)
		{
			alloc_table[i] = 1;
			return i;
		}
	}
	return -1;
}

/*
 * Copy a "file.ext" format filename into a directory entry,
 * converting to upper case.
 */
void copy_filename(raw_dir_entry *entry, const char *filename)
{
	for (int i = 0 ; i < FILENAME_LEN ; i++)
	{
		if ((*filename == '\0') || (*filename == '.'))
		{
			entry->filename[i] = ' ';
		}
		else
		{
			entry->filename[i] = toupper(*filename++);
		}
	}
	/* Skip the '.' if present */
	if (*filename == '.')
	{
		filename++;
	}
	for (int i = 0 ; i < TYPE_LEN ; i++)
	{
		if (*filename == '\0')
		{
			entry->type[i] = ' ';
		}
		else
		{
			entry->type[i] = toupper(*filename++);
		}
	}
}

/*
 * Write the directory entry to the disk image.
 */
void write_dir_entry(int fd, cpm_dir_entry* entry)
{
	uint8_t sector_data[MAX_SECT_SIZE];

	int allocation = entry->index / disk_dirs_per_alloc();
	int record = entry->index / disk_dirs_per_sector();
	/* start_index is the index of the directory entry that is at 
	 * the beginning of this sector */
	int start_index = entry->index / disk_dirs_per_sector() * disk_dirs_per_sector();
	for (int i = 0 ; i < disk_dirs_per_sector() ; i++)
	{
		/* copy all directory entries for the sector */
		memcpy(sector_data + i * DIR_ENTRY_LEN, 
			&dir_table[start_index+i].raw_entry,
			DIR_ENTRY_LEN);
	}
	
	write_sector(fd, allocation, record, sector_data);
}

/*
 * Read an allocation / record from disk.
 */
void read_sector(int fd, int alloc_num, int rec_num, void* buffer)
{
	int track;
	int sector;
	int offset;

	convert_track_sector(alloc_num, rec_num, &track, &sector);
	offset = track * disk_track_len() + (sector - 1) * disk_sector_len();
	/* For 8" floppy format data is offset from start of sector */
	offset += disk_off_data(track);

	if (VERBOSE)
		printf("Reading from TRACK[%d], SECTOR[%d], OFFSET[%d]\n", track, sector, offset);

	if (lseek(fd, offset, SEEK_SET) < 0)
	{
		error_exit(errno, "read_sector: Error seeking");
	}
	if (full_read(fd, buffer, disk_data_sector_len()) < 0)
	{
		error_exit(errno, "read_sector: Error on read");
	}
}


/*
 * Write an allocation / record to disk
 */
void write_sector(int fd, int alloc_num, int rec_num, void* buffer)
{
	int track;
	int sector;
	char checksum_buf[7];		/* additional checksum data for track 6 onwards */

	convert_track_sector(alloc_num, rec_num, &track, &sector);

	/* offset to start of sector */
	int sector_offset = track * disk_track_len() + (sector - 1) * disk_sector_len();

	/* Get the offset to start of data, relative to the start of sector */
	int data_offset = sector_offset + disk_off_data(track);

	if (VERBOSE)
		printf("Writing to TRACK[%d], SECTOR[%d], OFFSET[%d]\n", track, sector, data_offset);

	/* write the data */
	if (lseek(fd, data_offset, SEEK_SET) < 0)
	{
		error_exit(errno, "write_sector: Error seeking");
	}
	if (full_write(fd, buffer, disk_data_sector_len()) < 0)
	{
		error_exit(errno, "write_sector: Error on write");
	}

	if (disk_csum_method(track) >= 0)
	{
		/* calculate the checksum and offset if required */	
		uint16_t csum = calc_checksum(buffer);
		int csum_offset = sector_offset + disk_off_csum(track);

		/* For track 6 onwards, some non-data bytes are added to the checksum */
		if (track >= 6)
		{
			if (lseek(fd, sector_offset, SEEK_SET) < 0)
			{
				error_exit(errno, "write_sector: Error seeking");
			}
			
			if (full_read(fd, checksum_buf, 7) < 0)
			{
				error_exit(errno, "write_sector: Error on read checksum bytes");
			}
			csum += checksum_buf[2];
			csum += checksum_buf[3];
			csum += checksum_buf[5];
			csum += checksum_buf[6];
		}

		/* write the checksum */
		if (lseek(fd, csum_offset, SEEK_SET) < 0)
		{
			error_exit(errno, "write_sector: Error seeking");
		}
		if (full_write(fd, &csum, 1) < 0)
		{
			error_exit(errno, "write_sector: Error on write");
		}
	}
}


/*
 * Write an newly formatted sector
 * Must contain all sector data, including checksum, stop bytes etc.
 */
void write_raw_sector(int fd, int track, int sector, void* buffer)
{
	/* offset to start of sector */
	int sector_offset = track * disk_track_len() + (sector - 1) * disk_sector_len();

	if (VERBOSE)
		printf("Writing to TRACK[%d], SECTOR[%d], OFFSET[%d] (RAW)\n", track, sector, sector_offset);

	/* write the data */
	if (lseek(fd, sector_offset, SEEK_SET) < 0)
	{
		error_exit(errno, "write_raw_sector: Error seeking");
	}
	if (full_write(fd, buffer, disk_sector_len()) < 0)
	{
		error_exit(errno, "write_raw_sector: Error on write");
	}
}

/* 
 * Convert allocation and record numbers into track and sector numbers
 */
void convert_track_sector(int allocation, int record, int* track, int* sector)
{
	/* Find the number of records this allocation and record number equals 
	 * Each record = 1 sector. Divide number of records by number of sectors per track to get the track.
	 * This works because we enforce that each sector is 128 bytes and each record is 128 bytes.
	 * Note: For some disks the block size is not a multiple of the sectors/track, so can't just
	 *       calculate allocs/track here. 
	 */
	*track = (allocation * disk_recs_per_alloc() + (record % disk_recs_per_alloc())) / 
				disk_sectors_per_track() + disk_reserved_tracks();
	int logical_sector = 
			(allocation * disk_recs_per_alloc() + (record % disk_recs_per_alloc())) % 
			disk_sectors_per_track();

	if (VERBOSE)
		printf("ALLOCATION[%d], RECORD[%d], LOGICAL[%d], ", allocation, record, logical_sector);

	/* Need to "skew" the logical sector into a physical sector */
	*sector = disk_skew_sector(*track, logical_sector);
}

/*
 * Calculate the sector checksum for the data portion.
 * Note this is not the full checksum as 4 non-data bytes
 * need to be included in the checksum. (MITS *IN Formats only)
 */
uint8_t calc_checksum(uint8_t *buffer)
{
	uint8_t csum = 0;
	for (int i = 0 ; i < disk_data_sector_len() ; i++)
	{
		csum += buffer[i];
	}
	return csum;
}

/*
 * Check that the passed in filename can be represented as "8.3"
 * CPM Manual says that filenames cannot include:
 * < > . , ; : = ? * [ ] % | ( ) / \
 * while all alphanumerics and remaining special characters are allowed.
 * We'll also enforce that it is at least a "printable" character
 */
void validate_cpm_filename(const char *filename, char *validated_filename)
{
	const char *in_char = filename;
	char *out_char = validated_filename;
	int found_dot = 0;
	int char_count = 0;
	int ext_count = 0;
	while (*in_char != '\0')
	{
		if (isprint(*in_char) &&
			*in_char != '<' && *in_char != '>' &&
			*in_char != ',' && *in_char != ';' &&
			*in_char != ':' && *in_char != '?' &&
			*in_char != '*' && *in_char != '[' &&
			*in_char != '[' && *in_char != ']' &&
			*in_char != '%' && *in_char != '|' &&
			*in_char != '(' && *in_char != ')' &&
			*in_char != '/' && *in_char != '\\')
		{
			if (*in_char == '.')
			{
				if (found_dot)
				{
					/* Only process first '.' in filename */
					in_char++;
					continue;
				}
				found_dot = 1;
			}
			/* It's a valid filename character */
			/* copy the character */
			*out_char++ = toupper(*in_char);
			char_count++;
			/* If we have a file filename (excluding ext), but not found a dot */
			/* then add a dot and ignore everything up until the next dot */
			if (char_count == FILENAME_LEN && !found_dot && *(in_char+1) != '\0')
			{
				/* make sure filename contains a separator */
				*out_char++ = '.';
				char_count++;
				found_dot = 1;
				/* skip multiple consecutive dots in filename e.g. m80......com */
				while (*in_char == '.' && *in_char != '\0') 
					in_char++;
				/* now go looking for the separator */
				while (*in_char != '.' && *in_char != '\0')
					in_char++;
			}
			if (char_count == FULL_FILENAME_LEN - 1)
			{
				/* otherwise end of filename. done */
				break;
			}
			if (found_dot && ext_count++ == TYPE_LEN)
			{
				/* max extension length reached */
				break;
			}
		}
		in_char++;		
	}
	*out_char = '\0';
}

/* 
 * Sort by valid, filename+type, then user, then extent_nr
 * This sort order is optimal for searching by name.
 * Note code relies on valid entries being sorted first.
 * Note code relies on lower extent nr's being sorted before higher extent numbers (for the same file)
 */
int compare_sort_ptr(const void* a, const void* b)
{
	cpm_dir_entry **first = (cpm_dir_entry**) a;
	cpm_dir_entry **second = (cpm_dir_entry**) b;
	/* If neither a valid, they are equal */
	if (!(*first)->valid && !(*second)->valid)
	{
		return 0;
	}
	/* Otherwise, sort on valid, filename, user, extent_nr */
	int result = (*second)->valid - (*first)->valid;
	if (result == 0)
	{
		result = strcmp((*first)->full_filename, (*second)->full_filename); 
	}
	if (result == 0)
	{
		result = (*first)->user - (*second)->user;
	}
	if (result == 0)
	{
		result = (*first)->extent_nr - (*second)->extent_nr;
	}
	return result;
}

/*
 * Convert a raw allocation into the int representing that allocation
 */
int get_raw_allocation(raw_dir_entry *raw, int entry_nr)
{
	if (disk_total_allocs() <= 256)
	{
		/* an 8 bit allocation number */
		return raw->allocation[entry_nr];
	}
	else
	{
		/* a 16 bit allocation number. Low byte first */
		return raw->allocation[entry_nr] | (raw->allocation[entry_nr+1] << 8);
	}
}

/* 
 * Set the allocation number in the raw directory entry
 * For <=256 total allocs, this is set in the first 8 entries of the allocation array
 * Otherwise each entry in the allocation array is set in pairs of low byte, high byte
 */
void set_raw_allocation(raw_dir_entry *entry, int entry_nr, int alloc)
{
	if (disk_total_allocs() <= 256)
	{
		entry->allocation[entry_nr] = alloc;
	}
	else
	{
		entry->allocation[entry_nr * 2] = alloc & 0xff;
		entry->allocation[entry_nr * 2 + 1] = (alloc >> 8) & 0xff;
	}
}

/* 
 * Returns TRUE if this is the first extent for a file 
 */
int is_first_extent(cpm_dir_entry* dir_entry)
{
	return ((disk_recs_per_extent() > 128) && (dir_entry->num_allocs > 4) && dir_entry->extent_nr == 1) ||
			(dir_entry->extent_nr == 0);
}

/*
 * On windows, strip single quotes from filenames. e.g. '*' becomes *
 */
char* strip_quotes(char* filename)
{
#if !defined(_WIN32)
	return filename;
#else
	char *ptr = filename;
	/* If starts with ' */
	if (*ptr == '\'')
	{
		while(*ptr++ != '\0');
		/* If ends with ' then remove it */
		if(*(ptr-2) == '\'')
		{
			*(ptr-2) = '\0';
			return filename + 1;
		}
	}
	return filename;
#endif
}


/* 
 * Disk parameter support routines.
 * These generally get optimised away by GCC for any optimisation level.
 */
int disk_sector_len()
{
	return disk_type->sector_len;
}

int disk_data_sector_len()
{
	return disk_type->sector_data_len;
}

int disk_num_tracks()
{
	return disk_type->num_tracks;
}

int disk_reserved_tracks()
{
	return disk_type->reserved_tracks;
}

int disk_sectors_per_track()
{
	return disk_type->sectors_per_track;
}

int disk_block_size()
{
	return disk_type->block_size;
}

int disk_num_directories()
{
	return disk_type->num_directories;
}

int disk_skew_table_size()
{
	return disk_type->skew_table_size;
}

int disk_skew_sector(int track_nr, int logical_sector)
{
	return disk_type->skew_function(track_nr, logical_sector);
}

int disk_track_len()
{
	return disk_type->sector_len * disk_type->sectors_per_track;
}

int disk_total_allocs()
{
	return (disk_type->num_tracks - disk_type->reserved_tracks) *
		disk_type->sectors_per_track *
		disk_type->sector_data_len /
		disk_type->block_size;
}

int disk_recs_per_alloc()
{
	return disk_type->block_size / disk_type->sector_data_len;
}

int disk_recs_per_extent()
{
	/* 8 = nr of allocations per extent as per CP/M specification  */
	/* result rounded upwards to multiple of 128 */
	return ((disk_recs_per_alloc() * 8) + 127)/ 128 * 128;
}

int disk_dirs_per_sector()
{
	return disk_type->sector_data_len / DIR_ENTRY_LEN;
}

int disk_dirs_per_alloc()
{
	return disk_type->block_size / DIR_ENTRY_LEN;
}

int disk_directory_allocs()
{
	return disk_type->directory_allocs;
}

struct disk_offsets *disk_get_offsets(int track_nr)
{
	/* Assumes only 2 offsets. Which is pretty safe. Only MITS 8IN formats use them */
	if ((track_nr >= disk_type->offsets[0].start_track) && 
		(track_nr <= disk_type->offsets[0].end_track))
	{
		return &disk_type->offsets[0];
	}
	return &disk_type->offsets[1];
}

int disk_off_track_nr(int track_nr)
{
	return disk_get_offsets(track_nr)->off_track_nr;
}

int disk_off_sect_nr(int track_nr)
{
	return disk_get_offsets(track_nr)->off_sect_nr;
}

int disk_off_data(int track_nr)
{
	return disk_get_offsets(track_nr)->off_data;
}

int disk_off_stop(int track_nr)
{
	return disk_get_offsets(track_nr)->off_stop;
}

int disk_off_zero(int track_nr)
{
	return disk_get_offsets(track_nr)->off_zero;
}

int disk_off_csum(int track_nr)
{
	return disk_get_offsets(track_nr)->off_csum;
}

int disk_csum_method(int track_nr)
{
	return disk_get_offsets(track_nr)->csum_method;
}

/*
 * Detect the image type based on the file size
 */
int disk_detect_type(int fd)
{
	off_t length = lseek(fd, 0, SEEK_END);
	if (length <= 0)
	{
		return -1;
	}

	/* Some emulators write out in multiples of 128 bytes, rather than the 137 bytes used by the 8" disk */
	off_t mits_alt_length = (MITS8IN_FORMAT.image_size + 127) / 128 * 128;	/* round up to nearest 128 byte boundary */

	if (length == MITS8IN_FORMAT.image_size || length == mits_alt_length)
	{
		disk_type = &MITS8IN_FORMAT;
	}
	else if (length == MITS5MBHDD_FORMAT.image_size)
	{
		disk_type = &MITS5MBHDD_FORMAT;
	}
	else if (length == TARBELLFDD_FORMAT.image_size)
	{
		disk_type = &TARBELLFDD_FORMAT;
	}
	else if (length == FDD15MB_FORMAT.image_size)
	{
		disk_type = &FDD15MB_FORMAT;
	}
	else if (length == MITS8IN8MB_FORMAT.image_size)
	{
		disk_type = &MITS8IN8MB_FORMAT;
	}
	else
	{
		return -1;
	}
	if (VERBOSE)
		printf("Detected image type: %s\n", disk_type->type);
	return 0;
}

/*
 * Manually set the image type
 */
void disk_set_type(int fd, const char* type)
{

	off_t length = lseek(fd, 0, SEEK_END);

	if (!strcasecmp(type, MITS8IN_FORMAT.type))
	{
		disk_type = &MITS8IN_FORMAT;
	}
	else if (!strcasecmp(type, MITS5MBHDD_FORMAT.type))
	{
		disk_type = &MITS5MBHDD_FORMAT;
	}
	else if (!strcasecmp(type, MITS5MBHDD1024_FORMAT.type))
	{
		disk_type = &MITS5MBHDD1024_FORMAT;
	}
	else if (!strcasecmp(type, TARBELLFDD_FORMAT.type))
	{
		disk_type = &TARBELLFDD_FORMAT;
	}
	else if (!strcasecmp(type, FDD15MB_FORMAT.type))
	{
		disk_type = &FDD15MB_FORMAT;
	}
	else if (!strcasecmp(type, MITS8IN8MB_FORMAT.type))
	{
		disk_type = &MITS8IN8MB_FORMAT;
	}
	else
	{
		error_exit(0,"Invalid disk image type: %s", type);
	}

	if (length != 0 && length != disk_type->image_size)
	{
		fprintf(stderr, "WARNING: Disk image size does not equal the expected size of %d.\n", disk_type->image_size);
	}
	if (VERBOSE)
		printf("Selected image type: %s\n", disk_type->type);

}

void disk_format_disk(int fd)
{
    disk_type->format_function(fd);
}

void disk_dump_parameters()
{
	printf("Sector Len: %d\n", disk_sector_len());
	printf("Data Len  : %d\n", disk_data_sector_len());
	printf("Num Tracks: %d\n", disk_num_tracks());
	printf("Res Tracks: %d\n", disk_reserved_tracks());
	printf("Secs/Track: %d\n", disk_sectors_per_track());
	printf("Block Size: %d\n", disk_block_size());
	printf("Num Tracks: %d\n", disk_num_tracks());
	printf("Track Len : %d\n", disk_track_len());
	printf("Recs/Ext  : %d\n", disk_recs_per_extent());
	printf("Recs/Alloc: %d\n", disk_recs_per_alloc());
	printf("Dirs/Sect : %d\n", disk_dirs_per_sector());
	printf("Dirs/Alloc: %d\n", disk_dirs_per_alloc());
	printf("Dir Allocs: %d\n", disk_directory_allocs());
	printf("Num Dirs  : %d [max: %d]\n", disk_num_directories(), MAX_DIRS);
	printf("Tot Allocs: %d [max: %d]\n", disk_total_allocs(), MAX_ALLOCS);
}
