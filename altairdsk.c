/*
 *****************************************************************************
 * ALTAIR Disk Tools 
 *
 * Manipulate Altair MITS 2.2 CPM Disk Images
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
/* TODO: 	Stop auto-appending '.' to filenames that don't have an extension.
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

#define SECT_LEN		137	/* Size of on-disk sector */
#define SECT_DATA_LEN	128	/* only 128 bytes of the 137 sector bytes contains data */
#define SECT_PER_TRACK	32	/* Sectors per track */
#define TRACK_LEN 		(SECT_LEN * SECT_PER_TRACK)
#define NUM_TRACKS		77	/* Total tracks on disk */
#define RES_TRACKS		2	/* Unused tracks - reserved for OS */
#define DIR_OFFSET 		(2 * TRACK_LEN + SECT_OFFSET_0)	/* Directory is on TRACK 2 */
#define DIR_ENTRY_LEN	32	/* Length of a single directory entry (extent)*/
#define NUM_DIRS		64	/* Total number of directory entries */
#define DIRS_PER_SECTOR (SECT_DATA_LEN / DIR_ENTRY_LEN)
#define RECS_PER_ALLOC	16	/* Number of records per allocation */
#define RECS_PER_EXTENT	128 /* Number of records per directory entry (extent) */
#define ALLOCS_PER_TRACK 2
#define TOTAL_ALLOCS	(NUM_TRACKS - RES_TRACKS) * ALLOCS_PER_TRACK	/* This * 2 should be calculated */
#define TRACK_OFF_T0	0
#define DATA_OFF_T0		3	/* Sector data is offset by 3 bytes on TRACKS 0-5  */
#define STOP_OFF_T0		131
#define CSUM_OFF_T0		132	/* Checksum offset for Track 0-5 */
#define	ZERO_OFF_T0		133

#define TRACK_OFF_T6	0
#define SECT_OFF_T6		1	
#define CSUM_OFF_T6		4	/* Checksum offset for Track 6+ */
#define DATA_OFF_T6		7   /* Sectors data is offset by 7 bytes on TRACKS 6-76 */
#define STOP_OFF_T6		135
#define	ZERO_OFF_T6		136

#define FILENAME_LEN 	8	
#define TYPE_LEN	 	3
#define FULL_FILENAME_LEN (FILENAME_LEN+TYPE_LEN+2)
#define MAX_USER		15
#define DELETED_FLAG	0xe5
#define ALLOCS_PER_ENT	16	
#define RECORD_MAX		128	/* Max records per directory entry (extent) */

/* On-disk representation of a directory entry */
typedef struct raw_dir_entry
{
	uint8_t		user;					/* User (0-15). E5 = Deleted */
	char 		filename[FILENAME_LEN];	
	char 		type[TYPE_LEN];
	uint8_t		extent_l;				/* Extent number. */
	uint8_t		reserved;
	uint8_t		extent_h;				/* Not used */
	uint8_t		num_records;			/* Number of sectors used for this directory entry */
	uint8_t 	allocation[ALLOCS_PER_ENT];	/* List of 2K Allocations used for the file */
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
	struct cpm_dir_entry*	next_entry; /* pointer to next directory entry if multiple */
}	cpm_dir_entry;

cpm_dir_entry	dir_table[NUM_DIRS];			/* Directory entires in order read from "disk" */
cpm_dir_entry*	sorted_dir_table[NUM_DIRS];		/* Pointers to entries, sorted by name+type and extent nr*/
uint8_t			alloc_table[TOTAL_ALLOCS];		/* Allocation table. 0 = Unused, 1 = Used */

/* Skew table. Converts logical sectors to on-disk sectors */
int skew_table[] = {
	1,9,17,25,3,11,19,27,05,13,21,29,7,15,23,31,
	2,10,18,26,4,12,20,28,06,14,22,30,8,16,24,32
};

void print_usage(char* argv0); 
void error_exit(int eno, char *str, ...);

void directory_list();
void raw_directory_list();
void copy_from_cpm(int cpm_fd, int host_fd, cpm_dir_entry* dir_entry, int text_mode);
void copy_to_cpm(int cpm_fd, int host_fd, const char* cpm_filename);

void load_directory_table(int fd); 
cpm_dir_entry* find_dir_by_filename(const char *full_filename, cpm_dir_entry *prev_entry, int wildcards);
int filename_equals(const char* fn1, const char* fn2, int wildcards);
cpm_dir_entry* find_free_dir_entry(void);
void raw_to_cpmdir(cpm_dir_entry* entry);
int find_free_alloc(void);
void copy_filename(raw_dir_entry *entry, const char *filename);
void erase_file(int fd, const char* cpm_filename);
void format_disk(int fd);

void write_dir_entry(int fd, cpm_dir_entry* entry);
void read_sector(int fd, int alloc_num, int rec_num, void* buffer); 
void write_sector(int fd, int alloc_num, int rec_num, void* buffer);
void write_raw_sector(int fd, int track, int sector, void* buffer);
void convert_track_sector(int allocation, int record, int* track, int* sector);
uint8_t calc_checksum(uint8_t *buffer);

void validate_cpm_filename(const char *filename, char *validated_filename);
int compare_sort(const void *a, const void *b);
int compare_sort_ptr(const void *a, const void *b);

int VERBOSE = 0;	/* Print out Sector read/write information */

int main(int argc, char**argv)
{
	int open_mode;	/* read or write depending on selected options */
	mode_t open_umask = 0666;
	
	/* command line options */
	int opt;
	int do_dir = 0, do_raw = 0, do_get = 0;
	int do_put = 0 , do_help = 0, do_format = 0;
	int do_erase = 0, do_multiput = 0, do_multiget = 0;
	int text_mode = -1;				/* default to auto-detect text/binary */
	char *disk_filename = NULL; 	/* Altair disk image filename */
	char from_filename[PATH_MAX];	/* filename to get / put */
	char to_filename[PATH_MAX];		/* filename to get / put */

	/* parse options */
	while ((opt = getopt(argc, argv, "drhgGpPvFetb")) != -1)
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
			case 'F':
				do_format = 1;
				open_mode = O_WRONLY | O_CREAT;
				break;
			case 't':
				text_mode = 1;
				break;
			case 'b':
				text_mode = 0;
				break;
			case '?':
				exit(EXIT_FAILURE);
		}
	}
	/* make sure only one option selected */
	int nr_opts = do_dir + do_raw + do_help + 
				  do_put + do_get + do_format +
				  do_erase + do_multiget + do_multiput;
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
	/* Erase just needs a from_filename */
	if (do_get || do_put || do_erase) 
	{
		if (optind == argc) 
		{
			fprintf(stderr, "%s: <filename> not supplied\n", basename(argv[0]));
			exit(EXIT_FAILURE);
		} 
		else 
		{
			strcpy(from_filename, argv[optind++]);
			if (!do_erase && optind < argc)
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
	if (do_multiget || do_multiput)
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
	
	/* Initialise allocation tables. First 2 allocs are reserved */
	alloc_table[0] = alloc_table[1] = 1;

	/* Open the Altair disk image*/
	if ((fd_img = open(disk_filename, open_mode, open_umask)) < 0)
	{
		error_exit(errno, "Error opening file %s", disk_filename);
	}

	/* Read all directory entries - except for format command */
	if (!do_format)
	{
		load_directory_table(fd_img);
	}

	/* Raw Directory Listing */
	if (do_raw)
	{
		raw_directory_list();
		exit(EXIT_SUCCESS);
	}

	/* Formatted directory listing */
	if (do_dir)
	{
		directory_list();
		exit(EXIT_SUCCESS);
	}

	/* Copy file from disk image to host */
	if (do_get)
	{
		/* does the file exist in CPM? */
		cpm_dir_entry* entry = find_dir_by_filename(basename(from_filename), NULL, 0);
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
		int fd_file = open(to_filename, O_CREAT | O_WRONLY, 0666);
		if (fd_file < 0)
		{
			error_exit(errno, "Error opening file %s", from_filename);
		}
		/* finally copy the file from disk image*/
		copy_from_cpm(fd_img, fd_file, entry, text_mode);
		exit(EXIT_SUCCESS);
	}

	/* Copy multiple files from disk image to host */
	if (do_multiget)
	{
		while (optind != argc)
		{
			int idx = 0;
			int file_found = 0;
			cpm_dir_entry *entry = NULL;

			strcpy(from_filename, argv[optind++]);
			while(1)
			{
				/* The filename may contain wildcards. If so, loop for each expanded filename */
				entry = find_dir_by_filename(from_filename, entry, 1);

				if (entry == NULL)
				{
					/* error exit if there is not at least one file copied */
					if (!file_found)
						error_exit(ENOENT, "Error copying %s", from_filename);
					else
						break;
				}
				char *this_filename = entry->full_filename;
				file_found = 1;
				if ((unlink(this_filename) < 0) && (errno != ENOENT))
				{
					error_exit(errno, "Error removing old file %s", this_filename);
				}
				int fd_file = open(this_filename, O_CREAT | O_WRONLY, 0666);
				if (fd_file < 0)
				{
					error_exit(errno, "Error opening file %s", this_filename);
				}
				copy_from_cpm(fd_img, fd_file, entry, text_mode);
				close(fd_file);
			}
		}
		exit(EXIT_SUCCESS);
	}

	/* Copy file from host to disk image */
	if (do_put)
	{
		int fd_file = open(from_filename, O_RDONLY);
		if (fd_file < 0)
		{
			error_exit(errno, "Error opening file %s", from_filename);
		}
		copy_to_cpm(fd_img, fd_file, basename(to_filename));
		exit(EXIT_SUCCESS);
	}

	/* Copy multiple files from host to disk image */
	if (do_multiput)
	{
		/* process for each file passed on the command file */
		while (optind != argc)
		{
			strcpy(from_filename, argv[optind++]);
			strcpy(to_filename, from_filename);

			int fd_file = open(from_filename, O_RDONLY);
			if (fd_file < 0)
			{
				error_exit(errno, "Error opening file %s", from_filename);
			}
			copy_to_cpm(fd_img, fd_file, basename(to_filename));
		}
		exit(EXIT_SUCCESS);
	}

	/* erase a single file from the disk image */
	if (do_erase)
	{
		erase_file(fd_img, from_filename);
	}

	/* format and existing image or create a newly formatted image */
	if (do_format)
	{
		format_disk(fd_img);
		exit(EXIT_SUCCESS);
	}

	return 0;
}

/*
 * Usage information
 */
void print_usage(char* argv0)
{
	char *progname = basename(argv0);
	printf("%s: -[d|r|F]v	<disk_image>\n", progname);
	printf("%s: -[g|p|e][t|b]v <disk_image> <src_filename> [dst_filename]\n", progname);
	printf("%s: -[G|P][t|b]v <disk_image> <filename ...> \n", progname);
	printf("%s: -h\n", progname);
	printf("\t-d\tDirectory listing (default)\n");
	printf("\t-r\tRaw directory listing\n");
	printf("\t-F\tFormat existing or create new disk image\n");
	printf("\t-g\tGet - Copy file from Altair disk image to host\n");
	printf("\t-p\tPut - Copy file from host to Altair disk image\n");
	printf("\t-G\tGet Multiple - Copy multiple files from Altair disk image to host\n");
	printf("\t  \t               wildcards * and ? are supported e.g '*.COM'\n");
	printf("\t-P\tPut Multiple - Copy multiple files from host to Altair disk image\n");
	printf("\t-e\tErase a file\n");
	printf("\t-t\tPut/Get a file in text mode\n");
	printf("\t-b\tPut/Get a file in binary mode\n");
	printf("\t-v\tVerbose - Prints sector read/write information\n");
	printf("\t-h\tHelp\n");
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
 * Print nicely formatted directory listing 
 */
void directory_list(void)
{
	int file_count = 0;
	int kb_used = 0;
	int kb_free = 0;
	int entry_count = 0;
	printf("Name     Ext  Length Used U At\n");

	cpm_dir_entry *entry = NULL;
	int this_records = 0;
	int this_allocs = 0;
	int this_kb = 0;

	for (int i = 0 ; i < NUM_DIRS ; i++)
	{
		/* Valid entries are sorted before invalid ones */
		entry = sorted_dir_table[i];
		if (!entry->valid)
		{
			break;
		}
		entry_count++;
		/* If this is the first record for this file, then reset the file totals */
		if(entry->extent_nr == 0)
		{
			file_count++;
			this_records = 0;
			this_allocs = 0;
			this_kb = 0;
		}
	
		this_records += entry->num_records;
		this_allocs += entry->num_allocs;

		/* If there are no more dir entries, print out the file details */
		if(entry->next_entry == NULL)
		{
			this_kb += (this_allocs * RECS_PER_ALLOC * SECT_DATA_LEN) / 1024;
			kb_used += this_kb;

			printf("%s %s %6dB %3dK %d %s\n", 
				entry->filename, 
				entry->type,
				this_records * SECT_LEN,
				this_kb,
				entry->user,
				entry->attribs);
		}
	}
	for (int i = 0 ; i < TOTAL_ALLOCS ; i++)
	{
		if(alloc_table[i] == 0)
		{
			kb_free+= RECS_PER_ALLOC * SECT_DATA_LEN / 1024;
		}
	}
	printf("%d file(s), occupying %dK of %dK total capacity\n",
			file_count, kb_used, kb_used + kb_free);
	printf("%d directory entries and %dK bytes remain\n",
			NUM_DIRS - entry_count, kb_free);
}

/*
 * Print raw directory table.
 */
void raw_directory_list()
{
	printf("IDX:U:FILENAME:TYP:AT:EXT:REC:[ALLOCATIONS]\n");
	for (int i = 0 ; i < NUM_DIRS ; i++)
	{
		cpm_dir_entry *entry = &dir_table[i];
		if (entry->valid)
		{
			printf("%03d:%u:%s:%s:%s:%03u:%03u:[", 
				entry->index,
				entry->user, entry->filename, entry->type,
				entry->attribs,
				entry->extent_nr, entry->num_records);
			for (int i = 0 ; i < ALLOCS_PER_ENT ; i++)
			{
				if (i < ALLOCS_PER_ENT - 1)
				{
					printf("%u,", entry->raw_entry.allocation[i]);
				} 
				else
				{
					printf("%u", entry->raw_entry.allocation[i]);
				}
			}
			printf("]\n");
		}
	}
	printf ("FREE ALLOCATIONS:\n");
	int nr_output = 0;
	for (int i = 0 ; i < TOTAL_ALLOCS ; i++)
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
	uint8_t sector_data[SECT_DATA_LEN];
	int data_len = SECT_DATA_LEN;
	while (dir_entry != NULL)
	{
		for (int recnr = 0 ; recnr < dir_entry->num_records ; recnr++)
		{
			int alloc = dir_entry->raw_entry.allocation[recnr / RECS_PER_ALLOC];
		
			/* get data for this allocation and record number */
			read_sector(cpm_fd, alloc, recnr, sector_data);
			/* If in auto-detect mode or if in text_mode and this is the last sector */
			if ((text_mode == -1) ||
				((text_mode == 1) && (recnr == dir_entry->num_records - 1)))
			{
				for (int i = 0 ; i < SECT_DATA_LEN ; i++)
				{
					/* If auto-detecting text mode, check if char is "text"
					 * where "text" means printable, CR, LF, TAB and ^Z */
					if (text_mode == -1)
					{
						if(!isprint(sector_data[i]) && 
								sector_data[i] != 0x1a &&
								sector_data[i] != '\r' &&
								sector_data[i] != '\n' &&
								sector_data[i] != '\t')
						{
							/* not "text", so set to binary mode */
							text_mode = 0;
							break;
						}
					}
					/* If in text mode and on last block, then check for ^Z for EOF 
					 * Set data_len to make sure that data stop writing prior to first ^Z */
					if (text_mode && (recnr == dir_entry->num_records - 1) &&
							sector_data[i] == 0x1a)
					{
						data_len = i;
						break;
					}
				}
			}
			write(host_fd, sector_data, data_len);
		}
		dir_entry = dir_entry->next_entry;
	}
}

/*
 * Copy file from host to Altair CPM disk image
 */
void copy_to_cpm(int cpm_fd, int host_fd, const char* cpm_filename)
{
	uint8_t sector_data[SECT_DATA_LEN];
	char valid_filename[FULL_FILENAME_LEN];

	validate_cpm_filename(cpm_filename, valid_filename);
	if (strcasecmp(cpm_filename, valid_filename))
	{
		fprintf(stderr, "Converting filename %s to %s\n", cpm_filename, valid_filename);
	}
	if (find_dir_by_filename(valid_filename, 0, 0) != NULL)
	{
		error_exit(EEXIST, "Error creating file %s", valid_filename);
	}
	
	int rec_nr = 0;
	int nr_extents = 0;
	int allocation = 0;
	int nr_allocs = 0;
	cpm_dir_entry *dir_entry = NULL;
	int nbytes;

	/* Fill the sector with Ctrl-Z (EOF) in case not fully filled by read from host*/
	memset (&sector_data, 0x1a, SECT_DATA_LEN); 
	while((nbytes = read(host_fd, &sector_data, SECT_DATA_LEN)) > 0)
	{
		/* Is this a new Extent (i.e directory entry) ? */
		if ((rec_nr % RECORD_MAX) == 0)
		{
			/* if there is a previous directory entry, write it to disk */
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
			dir_entry->raw_entry.user = 0;
			copy_filename(&dir_entry->raw_entry, valid_filename);
			dir_entry->raw_entry.extent_l = nr_extents;
			dir_entry->raw_entry.extent_h = 0;
			dir_entry->raw_entry.num_records = 0;
			nr_extents++;
			nr_allocs = 0;
		}
		/* Is this a new allocation? */
		if ((rec_nr % RECS_PER_ALLOC) == 0)
		{
			allocation = find_free_alloc();
			if (allocation < 0)
			{
				/* No free allocations! 
				 * write out directory entry (if it has any allocations) before exit */
				if (dir_entry->raw_entry.allocation[0] != 0)
				{
					raw_to_cpmdir(dir_entry);
					write_dir_entry(cpm_fd, dir_entry);
				}
				error_exit(0, "Error writing %s: No free allocations", valid_filename);
			}
			dir_entry->raw_entry.allocation[nr_allocs] = allocation;
			nr_allocs++;
		}
		dir_entry->raw_entry.num_records = (rec_nr % RECS_PER_EXTENT) + 1;
		write_sector(cpm_fd, allocation, rec_nr, &sector_data);
		memset (&sector_data, 0x1a, SECT_DATA_LEN);
		rec_nr++;
	}
	/* File is done. Write out the last directory entry */
	raw_to_cpmdir(dir_entry);
	write_dir_entry(cpm_fd, dir_entry);
}	

/*
 * Loads all of the directory entries into dir_table 
 * sorted pointers stored to sorted_dir_table
 * Related directory entries are linked through next_entry.
 */
void load_directory_table(int fd)
{
	uint8_t sector_data[SECT_DATA_LEN];

	for (int sect_nr = 0 ; sect_nr < NUM_DIRS / DIRS_PER_SECTOR; sect_nr++)
	{
		/* Read each sector containing a directory entry */
		/* All directory data is on first 16 sectors of TRACK 2*/
		int allocation = sect_nr / RECS_PER_ALLOC;
		int	record = (sect_nr % RECS_PER_ALLOC);

		read_sector(fd, allocation, record, &sector_data);
		/* TODO: Why is this 4???? Make a constant instead */
		for (int dir_nr = 0 ; dir_nr < DIRS_PER_SECTOR ; dir_nr++)
		{
			/* Calculate which directory entry number this is */
			int index = sect_nr * DIRS_PER_SECTOR + dir_nr;
			cpm_dir_entry *entry = &dir_table[index];
			entry->index = index;
			memcpy(&entry->raw_entry, sector_data + (DIR_ENTRY_LEN * dir_nr), DIR_ENTRY_LEN);
			sorted_dir_table[index] = entry;

			if (entry->raw_entry.user <= MAX_USER)
			{
				raw_to_cpmdir(entry);

				/* Mark off the used allocations */
				for (int alloc_nr = 0 ; alloc_nr < ALLOCS_PER_ENT ; alloc_nr++)
				{
					uint8_t alloc = entry->raw_entry.allocation[alloc_nr];
					
					/* Allocation of 0, means no more allocations used by this entry */
					if (alloc == 0)
						break;
					/* otherwise mark the allocation as used */
					alloc_table[alloc] = 1;
				}
			}
		}
	}

	/* Create a list of pointers to the directory table, sorted by:
	 * Valid, Filename, Type, Extent */
	qsort(&sorted_dir_table, NUM_DIRS, sizeof(cpm_dir_entry*), compare_sort_ptr);

	/* link related directory entries */
	/* No need to check last entry, it can't be related to anything */
	for (int i = 0 ; i < NUM_DIRS - 1 ; i++)
	{
		cpm_dir_entry* entry = sorted_dir_table[i];
		cpm_dir_entry* next_entry = sorted_dir_table[i+1];

		if (entry->valid)
		{
			/* Check if there are more extents for this file */
			if (entry->num_records == RECORD_MAX &&
				next_entry->extent_nr == entry->extent_nr + 1)
			{
				/* If this entry is a full extent, and the next entry has an
				 * an entr nr + 1*/
				entry->next_entry = next_entry;
			}
		}
	}
}

/*
 * Erase a file
 */
void erase_file(int fd, const char* cpm_filename)
{
	cpm_dir_entry *entry = find_dir_by_filename(cpm_filename, NULL, 0);
	if (entry == NULL)
	{
		error_exit(ENOENT, "Error erasing %s", cpm_filename);
	}
	/* Set user on all directory entries for this file to "DELETED" */
	do
	{
		entry->raw_entry.user = DELETED_FLAG;
		write_dir_entry(fd,entry);
	} while ((entry = entry->next_entry) != NULL);
}


/*
 * Create a newly formatted disk / format an existing disk.
 */
void format_disk(int fd)
{
	uint8_t sector_data[SECT_LEN];

	memset(sector_data, 0xe5, SECT_LEN);
	sector_data[1] = 0x00;
	sector_data[2] = 0x01;
	sector_data[STOP_OFF_T0] = 0xff;
	memset(sector_data+ZERO_OFF_T0, 0, SECT_LEN - ZERO_OFF_T0);

	for (int track = 0 ; track < NUM_TRACKS ; track++)
	{
		if (track == 6)
		{
			memset(sector_data, 0xe5, SECT_LEN);
			sector_data[2] = 0x01;
			sector_data[STOP_OFF_T6] = 0xff;
			sector_data[ZERO_OFF_T6] = 0x00;
			memset(sector_data+ZERO_OFF_T6, 0, SECT_LEN - ZERO_OFF_T6);
		}
		for (int sector = 0 ; sector < SECT_PER_TRACK ; sector++)
		{
			if (track < 6)
			{
				sector_data[TRACK_OFF_T0] = track | 0x80;
				sector_data[CSUM_OFF_T0] = calc_checksum(sector_data+DATA_OFF_T0);
			}
			else
			{
				sector_data[TRACK_OFF_T6] = track | 0x80;
				sector_data[SECT_OFF_T6] = (sector * 17) % 32;
				uint8_t checksum = calc_checksum(sector_data+DATA_OFF_T6);
				checksum += sector_data[2];
				checksum += sector_data[3];
				checksum += sector_data[5];
				checksum += sector_data[6];
				sector_data[CSUM_OFF_T6] = checksum;
			}
			write_raw_sector(fd, track, sector + 1, &sector_data);
		}
	}
}

/*
 * Find the directory entry related to a filename.
 * If prev_entry != NULL, start searching from the next entry after prev_entry
 * If wildcards = 1, allow wildcard characters * and ? to be used when matching to the filename
 */
cpm_dir_entry* find_dir_by_filename(const char *full_filename, cpm_dir_entry *prev_entry, int wildcards)
{
	int start_index = (prev_entry == NULL) ? 0 : prev_entry->index + 1;
	for (int i = start_index ; i < NUM_DIRS ; i++)
	{
		if (dir_table[i].extent_nr == 0)
		{
			/* If filename matches, return it */
			if (filename_equals(full_filename, dir_table[i].full_filename, wildcards) == 0)
			{
				return &dir_table[i];
			}
		}
	}
	/* No matching filename found */
	return NULL;
}

/* 
 * Check if 2 filenames match, using wildcard matching.
 * Only s1 can contain wildcard characters. * and ? are supported.
 * Note that A*E* is interpreted as A*
 */
int filename_equals(const char *s1, const char *s2, int wildcards)
{
	int found_dot = 0;	/* have we found the dot separator between filename and type*/
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
				s1 = index(s1, '.');
				/* if wildcard has no extension e.g. T* then equal */
				if (s1 == NULL)
					return 0;
				/* The cpm filename will always end in a '.' even if no extension
				 * so this should never be null.
				 * TODO: Should probably change this as files without extensions become 
				 * FILE. when wildcards are used.
				 */
				s2 = index(s2, '.');
			}
		}
		/* ? matches 1 character, next char*/
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
	return *s1 - *s2;
}

/*
 * Find an unused directory entry.
 */
cpm_dir_entry* find_free_dir_entry(void)
{
	for (int i = 0 ; i < NUM_DIRS ; i++)
	{
		if (dir_table[i].valid)
			continue;
		return &dir_table[i];
	}
	return NULL;
}

/*
 * Convert each cpm directory entry (extent) into an structure that is
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
	strcat(entry->full_filename,".");
	strcat(entry->full_filename, entry->type);
	space_pos = strchr(entry->full_filename, ' ');
	/* strip out spaces from type */
	if (space_pos != NULL)
	{
		*space_pos = '\0';
	}
	entry->num_records = raw->num_records;
	int num_allocs = 0;
	for (int i = 0 ; i < ALLOCS_PER_ENT ; i++)
	{
		if (raw->allocation[i] == 0)
		break;
		num_allocs++;
	}
	entry->num_allocs = num_allocs;
	entry->valid = 1;
}

/*
 * Find a free allocation. Mark is as used.
 */
int find_free_alloc(void)
{
	for (int i = 0 ; i < TOTAL_ALLOCS ; i++)
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
 * Copy a "file.ext" format filename to a directory entry
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
	uint8_t sector_data[SECT_DATA_LEN];

	int allocation = 0;			/* Directories are on allocation 0 */
	int record = entry->index / DIRS_PER_SECTOR;
	/* start_index is the index of this directory entry that is at 
	 * the beginning of the sector */
	int start_index = entry->index / DIRS_PER_SECTOR * DIRS_PER_SECTOR;
	for (int i = 0 ; i <DIRS_PER_SECTOR ; i++)
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
	offset = track * TRACK_LEN + (sector - 1) * SECT_LEN;
	offset += (track < 6) ? DATA_OFF_T0 : DATA_OFF_T6;
	if (VERBOSE)
		printf("Reading from TRACK[%d], SECTOR[%d], OFFSET[%d]\n", track, sector, offset);

	if (lseek(fd, offset, SEEK_SET) < 0)
	{
		error_exit(errno, "read_sector: Error seeking");
	}
	if (read(fd, buffer, SECT_DATA_LEN) < 0)
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
	int sector_offset = track * TRACK_LEN + (sector - 1) * SECT_LEN;

	/* Get the offset to start of data, relative to the start of sector */
	int data_offset = sector_offset + ((track < 6) ? DATA_OFF_T0 : DATA_OFF_T6);

	/* calculate the checksum and offset */	
	uint16_t csum = calc_checksum(buffer);
	int csum_offset = sector_offset + ((track < 6) ? CSUM_OFF_T0 : CSUM_OFF_T6);

	if (VERBOSE)
		printf("Writing to TRACK[%d], SECTOR[%d], OFFSET[%d]\n", track, sector, data_offset);

	/* For track 6 onwards, some non-data bytes are added to the checksum */
	if (track >= 6)
	{
		if (lseek(fd, sector_offset, SEEK_SET) < 0)
		{
			error_exit(errno, "write_sector: Error seeking");
		}
		
		if (read(fd, checksum_buf, 7) < 0)
		{
			error_exit(errno, "write_sector: Error on read checksum bytes");
		}
		csum += checksum_buf[2];
		csum += checksum_buf[3];
		csum += checksum_buf[5];
		csum += checksum_buf[6];
	}

	/* write the data */
	if (lseek(fd, data_offset, SEEK_SET) < 0)
	{
		error_exit(errno, "write_sector: Error seeking");
	}
	if (write(fd, buffer, SECT_DATA_LEN) < 0)
	{
		error_exit(errno, "write_sector: Error on write");
	}

	/* and the checksum */
	if (lseek(fd, csum_offset, SEEK_SET) < 0)
	{
		error_exit(errno, "write_sector: Error seeking");
	}
	if (write(fd, &csum, 1) < 0)
	{
		error_exit(errno, "write_sector: Error on write");
	}
}


/*
 * Write an newly formatted sector
 * Must contain all sector data, including checksum, stop bytes etc.
 */
void write_raw_sector(int fd, int track, int sector, void* buffer)
{
	/* offset to start of sector */
	int sector_offset = track * TRACK_LEN + (sector - 1) * SECT_LEN;

	if (VERBOSE)
		printf("Writing to TRACK[%d], SECTOR[%d], OFFSET[%d] (RAW)\n", track, sector, sector_offset);

	/* write the data */
	if (lseek(fd, sector_offset, SEEK_SET) < 0)
	{
		error_exit(errno, "write_raw_sector: Error seeking");
	}
	if (write(fd, buffer, SECT_LEN) < 0)
	{
		error_exit(errno, "write_raw_sector: Error on write");
	}
}


/* 
 * Convert allocation and record numbers into track and sector numbers
 */
void convert_track_sector(int allocation, int record, int* track, int* sector)
{
	/* TODO: The constants below should be calculated.. but we'll do that 
	 * when additional formats are supported */
	*track = allocation / ALLOCS_PER_TRACK + RES_TRACKS;
	int logical_sector = (allocation % 2) * 16 + (record % 16);

	if (VERBOSE)
		printf("ALLOCATION[%d], RECORD[%d], ", allocation, record);

	/* Need to "skew" the logical sector into a physical sector */
	if (*track < 6)		
	{
		*sector = skew_table[logical_sector];
	}
	else
	{
		/* This calculation is due to historical weirdness. It is just how it works.*/
		*sector = (((skew_table[logical_sector] - 1) * 17) % 32) + 1;
	}
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
			if (char_count == FILENAME_LEN && !found_dot)
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
 * Sort by valid = 1, filename+type, then extent_nr 
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
	/* Otherwise, sort on valid, filename, extent_nr */
	int result = (*second)->valid - (*first)->valid;
	if (result == 0)
	{
		result = strcmp((*first)->full_filename, (*second)->full_filename); 
	}
	if (result == 0)
	{
		result = (*first)->extent_nr - (*second)->extent_nr;
	}
	return result;
}


/*
 * Calculate the sector checksum for the data portion.
 * Note this is not the full checksum as 4 non-data bytes
 * need to be included in the checksum.
 */
uint8_t calc_checksum(uint8_t *buffer)
{
	uint8_t csum = 0;
	for (int i = 0 ; i < SECT_DATA_LEN ; i++)
	{
		csum += buffer[i];
	}
	return csum;
}