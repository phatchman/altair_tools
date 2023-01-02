#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <libgen.h>
#include <string.h>
#include <stdint.h>
#include <endian.h>
#include <errno.h>
#include <stdarg.h>

#define SECT_LEN		137
#define SECT_USED		128	/* only 128 bytes of the 137 sector bytes contains data */
#define NUM_SECTORS		32
#define TRACK_LEN 		(SECT_LEN * NUM_SECTORS)
#define NUM_TRACKS		77
#define RES_TRACKS		2
#define SECT_OFFSET_0	3 /* Sectors are offset by 3 bytes on TRACKS 0-5  */
#define SECT_OFFSET_6	7 /* Sectors are offset by 7 bytes on TRACKS 6-76 */
#define DIR_OFFSET 		(2 * TRACK_LEN + SECT_OFFSET_0)	/* Directory is on TRACK 2 */
#define DIR_ENTRY_LEN	32
#define NUM_DIRS		64
#define DIRS_PER_SECTOR (SECT_USED / DIR_ENTRY_LEN)
#define RECS_PER_ALLOC	16
#define TOTAL_ALLOCS	(NUM_TRACKS - RES_TRACKS) * 2	/* This * 2 should be calculated */
#define CSUM_OFF_T0		132
#define CSUM_OFF_T6		4


#define FILENAME_LEN 	8
#define TYPE_LEN	 	3
#define MAX_USER		15
#define DELETED			0xE5
#define NR_ALLOCS		16	/* TODO: This needs to be renamed. Too easily confused with TOTAL_ALLOCS */
#define RECORD_MAX		128


typedef struct raw_dir_entry
{
	uint8_t		user;
	char 		filename[FILENAME_LEN];
	char 		type[TYPE_LEN];
	uint8_t		extent_l;
	uint8_t		reserved;
	uint8_t		extent_h;
	uint8_t		num_records;
	uint8_t 	allocation[NR_ALLOCS];
} raw_dir_entry;

typedef struct cpm_dir_entry 
{
	int				index;
	uint8_t			valid;
	raw_dir_entry	raw_entry;
	int				extent_nr;
	int				user;
	char			filename[FILENAME_LEN+1];
	char			type[TYPE_LEN+1];
	char			attribs[3];
	char			full_filename[FILENAME_LEN+TYPE_LEN+2];
	int				num_records;
	int				num_allocs;
	struct cpm_dir_entry*	next_entry;
}	cpm_dir_entry;

cpm_dir_entry	dir_table[NUM_DIRS];			/* Directory entires in order read from "disk" */
cpm_dir_entry*	sorted_dir_table[NUM_DIRS];		/* Pointers to entries, sorted by name+type and extent nr*/
uint8_t			alloc_table[TOTAL_ALLOCS];		/* Allocation table. 0 = Unused, 1 = Used */

/* Skew table for tracks 0-5 */
int skew_table[] = {
	1,9,17,25,3,11,19,27,05,13,21,29,7,15,23,31,
	2,10,18,26,4,12,20,28,06,14,22,30,8,16,24,32
};


void raw_to_cpm( cpm_dir_entry* entry);
int load_directory_table(int fd); 
void raw_directory_list();
void directory_list();
int compare_sort(const void* a, const void* b);
int copy_from_cpm(int cpm_fd, int host_fd, const char* cpm_filename);
void convert_track_sector(int allocation, int record, int* track, int* sector);
cpm_dir_entry* find_dir_by_filename (const char *full_filename);
cpm_dir_entry* find_free_dir_entry(void);
int find_free_alloc(void);
void write_dir_entry(int fd, cpm_dir_entry* entry);
int read_block(int fd, int alloc_num, int rec_num, void* buffer); 
int write_block(int fd, int alloc_num, int rec_num, void* buffer);
int compare_sort_ptr(const void* a, const void* b);
int copy_to_cpm(int cpm_fd, int host_fd, const char* cpm_filename);
uint8_t calc_checksum(u_char *buffer);
void print_usage(char* argv0); 

/* 
 * Print formatted error string and exit.
 */
void error_exit(char *str, ...)
{
	va_list argp;
  	va_start(argp, str);

	vfprintf(stderr, str, argp);
	fprintf(stderr,": %s\n", strerror(errno));
	exit(EXIT_FAILURE);
}

void print_usage(char* argv0)
{
	char *progname = basename(argv0);
	printf("%s: -[d|r|h] <disk_image>\n", progname);
	printf("%s: -[g|p]   <disk_image> <filename>\n", progname);
	printf("\t-d\tDirectory listing\n");
	printf("\t-r\tRaw directory listing\n");
	printf("\t-h\tHelp\n");
	printf("\t-g\tGet - Copy file from Altair disk image to host\n");
	printf("\t-p\tPut - Copy file from host to Altair disk image\n");
}

int main(int argc, char**argv)
{
	int opt;
	int open_mode;
	/* command line options */
	int do_dir, do_raw, do_get, do_put, do_help = 0;
	char *disk_filename = NULL;
	char *filename = NULL;

	while ((opt = getopt(argc, argv, "drhgp")) != -1)
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
			case 'p':
				do_put = 1;
				open_mode = O_RDWR;
				break;
			case '?':
				exit(EXIT_FAILURE);
		}
	}
	/* make sure only one option selected */
	int nr_opts = do_dir + do_raw + do_help + do_put + do_get;
	if (nr_opts == 0) 
	{
		fprintf(stderr, "%s: No option supplied.\n", basename(argv[0]));
		exit(EXIT_FAILURE);
	}
	if (nr_opts > 1)
	{
		fprintf(stderr, "%s: Too many options supplied.\n", basename(argv[0]));
		exit(EXIT_FAILURE);
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
		disk_filename = argv[optind++];
	}

	/* Get and Put need an additional filename */
	if (do_get || do_put) 
	{
		if (optind == argc) 
		{
			fprintf(stderr, "%s: <filename> not supplied\n", basename(argv[0]));
			exit(EXIT_FAILURE);
		} 
		else 
		{
			filename = argv[optind++];
		}
	}
	if (optind != argc) 
	{
		fprintf(stderr, "%s: Too many arguments supplied.\n", basename(argv[0]));
		exit(EXIT_FAILURE);
	}

	if (do_get) printf("Get: %s %s\n", disk_filename, filename);
	if (do_put) printf("Put: %s %s\n", disk_filename, filename);
	if (do_raw) printf("Raw: %s\n", disk_filename);
	if (do_dir) printf("Dir: %s\n", disk_filename);

	/*
	 * Start of processing
	 */
	int fd_img = -1;		/* fd of disk image */
	
	/* Initialise tables */
	alloc_table[0] = alloc_table[1] = 1;

	/* Open the Altair disk image*/
	if ((fd_img = open(disk_filename, open_mode)) < 0)
	{
		error_exit("Error opening file %s", disk_filename);
	}

	load_directory_table(fd_img);

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
		int fd_file = open(filename, O_CREAT | O_WRONLY, 0666);
		if (fd_file < 0)
		{
			error_exit("Error opening file %s", filename);
		}
		copy_from_cpm(fd_img, fd_file, filename);
		exit(EXIT_SUCCESS);
	}


	exit(EXIT_SUCCESS);


#if 0
	if (argc == 2)
	{
		fn = argv[1];
	}

	/* TODO: Make this READ ONLY for READ OPERATIONS */
	if ((fd = open(fn, O_RDWR)) < 0)
	{
		error_exit("Error opening disk image");
	}

	memset(&dir_table, 0, sizeof(dir_table));
	memset(&alloc_table, 0, sizeof(alloc_table));
	/* First 2 allocations are reserved [0 and 1]*/
	alloc_table[0] = alloc_table[1] = 1;

	load_directory_table(fd);
	raw_directory_list();
/*
	int fd2 = open("BIG.TXT", O_CREAT | O_WRONLY, 0666);
	if (fd2 < 0)
	{
		error_exit ("Error Creating output file");
	}

	copy_from_cpm(fd, fd2, "BIG.TXT");
*/
	int fd2 = open ("write.txt", O_RDONLY);
	if (fd2 < 0)
	{
		error_exit ("Error opening input file");
	}
	copy_to_cpm(fd, fd2, "WRITEY.TXT");
/**/
#endif
	return 0;
}

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
		entry_count++;
		if (!entry->valid)
		{
			break;
		}
		/* If this is the first record for this file, then reset the totals */
		if(entry->extent_nr == 0)
		{
			file_count++;
			this_records = 0;
			this_allocs = 0;
			this_kb = 0;
		}
	
		this_records += entry->num_records;
		this_allocs += entry->num_allocs;

		/* If there are no more entries, print out the entry */
		if(entry->next_entry == NULL)
		{
			this_kb += (this_allocs * RECS_PER_ALLOC * SECT_USED) / 1024;
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
			kb_free+= RECS_PER_ALLOC * SECT_USED / 1024;
		}
	}
	printf("%d file(s), occupying %dK of %dK total capacity\n",
			file_count, kb_used, kb_used + kb_free);
	printf("%d directory entries and %dK bytes remain\n",
			NUM_DIRS - entry_count, kb_free);
}

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
			for (int i = 0 ; i < NR_ALLOCS ; i++)
			{
				if (i < NR_ALLOCS - 1)
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
 */
int copy_from_cpm(int cpm_fd, int host_fd, const char* cpm_filename)
{
	/* get the first directory entry*/
	cpm_dir_entry* dir_entry = find_dir_by_filename(cpm_filename);
	if (dir_entry == NULL)
	{
		return -ENOENT;
	}

	/* 
	 * The directory entry is called an EXTENT.
	 * Each EXTENT contains one or more ALLOCATIONs (up to 8 for a floppy disk)
	 * Each ALLOCATION represents 128*16 = 2048 bytes of data.
	 * Each EXTENT also contains a RECORD count, with each RECORD
	 * representing 128 bytes of data
	 * There are 16 RECORDs per ALLOCATION, meaning one EXTENT can represent
	 * 16 * 8 * 128 = 16K of data.
	 * Each RECORD is 128 bytes, or one SECTOR on the disk.
	 * If the file is greater than 16K, it is represented by multiple EXTENTS
	 * load_directory links the extents, through the next_entry pointer.
	 * 
	 * Convert ALLOCATION / RECORD into a disk BLOCK that is converted to an
	 * offset within the DISK image file.
	 */
	u_char block_data[SECT_USED];

	while (dir_entry != NULL)
	{
		for (int i = 0 ; i < dir_entry->num_records ; i++)
		{
			int alloc = dir_entry->raw_entry.allocation[i / RECS_PER_ALLOC];
		
			read_block(cpm_fd, alloc, i, block_data);
			write(host_fd, block_data, SECT_USED);
/*			printf(": %.4s\n", block_data);*/
		}
		dir_entry = dir_entry->next_entry;
	}
}

int copy_to_cpm(int cpm_fd, int host_fd, const char* cpm_filename)
{
	uint8_t sector_buffer[SECT_USED];

	int nbytes;

	if (find_dir_by_filename(cpm_filename) != NULL)
	{
		errno = EEXIST;
		error_exit("Error creating file");
	}
	/* Set any blank space to ctrl-Z (EOF)*/
	memset (&sector_buffer, 0x1a, SECT_USED); /* TODO: This should be set on each write!! */

	/* TODO: Handle multiple directory entries */
	cpm_dir_entry *dir_entry = find_free_dir_entry();
	if (dir_entry == NULL)
	{
		error_exit("No free directory entries");
	}
	int alloc = find_free_alloc();
	if (alloc < 0)
	{
		error_exit("No free allocations");
	}

	/* Init the directory entry */
	memset(&dir_entry->raw_entry, 0, sizeof(raw_dir_entry));
	dir_entry->raw_entry.user = 0;
	strncpy(dir_entry->raw_entry.filename,"WRITEY  ", FILENAME_LEN);
	strncpy(dir_entry->raw_entry.type,"TXT", TYPE_LEN);
	dir_entry->raw_entry.extent_l = 0;
	dir_entry->raw_entry.extent_h = 0;
	dir_entry->raw_entry.num_records = 1;
	dir_entry->raw_entry.allocation[0] = alloc;
	/* TODO: Fix this. The way index is set is weird.*/
	raw_to_cpm(dir_entry);
	/* TODO: When should the dir entry actually be saved? */
	write_dir_entry(cpm_fd, dir_entry);

	int rec_nr = 0;

	/* TODO: Handle multiple sectors, recs and allocs*/
	while(1)
	{
		if ((nbytes = read(host_fd, &sector_buffer, SECT_USED)) <= 0)
		{
			break;
		}
		write_block(cpm_fd, alloc, rec_nr, &sector_buffer);
		rec_nr++;
	}
}	

cpm_dir_entry* find_dir_by_filename(const char *full_filename)
{
	for (int i = 0 ; i < NUM_DIRS ; i++)
	{
		if (strcasecmp(dir_table[i].full_filename, full_filename) == 0)
		{
			return &dir_table[i];
		}
	}
	return NULL;
}

cpm_dir_entry* find_free_dir_entry(void)
{
	/* sort the directory table by index */

	for (int i = 0 ; i < NUM_DIRS ; i++)
	{
		if (dir_table[i].valid)
			continue;
/*		dir_table[i].index = i; */
		return &dir_table[i];
	}
	return NULL;
}

int find_free_alloc(void)
{
	for (int i = 0 ; i < TOTAL_ALLOCS ; i++)
	{
		if(alloc_table[i] == 0)
		{
			return i;
		}
	}
	return -1;
}

/*
 * Write the directory entry to the disk image.
 */
void write_dir_entry(int fd, cpm_dir_entry* entry)
{
	u_char sector_data[SECT_USED];

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
	
	write_block(fd, allocation, record, sector_data);
}

int read_block(int fd, int alloc_num, int rec_num, void* buffer)
{
	int track;
	int sector;
	int offset;

	/* TODO: We actually want the file offset not track and sector??? */
	convert_track_sector(alloc_num, rec_num, &track, &sector);
	offset = track * TRACK_LEN + (sector - 1) * SECT_LEN;
	offset += (track < 6) ? SECT_OFFSET_0 : SECT_OFFSET_6;
	printf("Reading from TRACK[%d], SECTOR[%d], OFFSET[%d]\n", track, sector, offset);

	if (lseek(fd, offset, SEEK_SET) < 0)
	{
		error_exit("Error seeking");
	}
	if (read(fd, buffer, SECT_USED) < 0)
	{
		error_exit("Error on read");
	}

	return 0;
}

int write_block(int fd, int alloc_num, int rec_num, void* buffer)
{
	int track;
	int sector;
	char checksum_buf[7];		/* additional checksum data for track 6 onwards */

	convert_track_sector(alloc_num, rec_num, &track, &sector);

	/* offset to start of sector */
	int sector_offset = track * TRACK_LEN + (sector - 1) * SECT_LEN;

	/* Get the offset to start of data, relative to the start of sector */
	int data_offset = sector_offset + ((track < 6) ? SECT_OFFSET_0 : SECT_OFFSET_6);

	/* calculate the checksum and offset */	
	uint16_t csum = calc_checksum(buffer);
	int csum_offset = sector_offset + ((track < 6) ? CSUM_OFF_T0 : CSUM_OFF_T6);

	printf("Writing to TRACK[%d], SECTOR[%d], OFFSET[%d]\n", track, sector, data_offset);

	/* For track 6 onwards, some non-data bytes are added to the checksum */
	if (track >= 6)
	{
		if (lseek(fd, sector_offset, SEEK_SET) < 0)
		{
			error_exit("Error seeking");
		}
		
		if (read(fd, checksum_buf, 7) < 0)
		{
			error_exit("Error on read checksum bytes");
		}
		csum += checksum_buf[2];
		csum += checksum_buf[3];
		csum += checksum_buf[5];
		csum += checksum_buf[6];
	}

	/* write the data */
	if (lseek(fd, data_offset, SEEK_SET) < 0)
	{
		error_exit("Error seeking");
	}
	if (write(fd, buffer, SECT_USED) < 0)
	{
		error_exit("Error on write");
	}

	/* and the checksum */

	if (lseek(fd, csum_offset, SEEK_SET) < 0)
	{
		error_exit("Error seeking");
	}
	if (write(fd, &csum, 1) < 0)
	{
		error_exit("Error on write");
	}

	return 0;
}

/* Convert allocation and record from an extent into track and sector */
void convert_track_sector(int allocation, int record, int* track, int* sector)
{
	*track = allocation / 2 + 2;		/* TODO: REPLACE with appropriate constants */
	int logical_sector = (allocation % 2) * 16 + (record % 16);

	printf("ALLOCATION[%d], RECORD[%d], ", allocation, record);

	/* Need to "skew" the logical sector into a physical sector */
	if (*track < 6)		
	{
		*sector = skew_table[logical_sector];
	}
	else
	{
		/* This calculation is due to historical weirdness. It just is how it works.*/
		*sector = (((skew_table[logical_sector] - 1) * 17) % 32) + 1;
	}
}

/*
 * Loads all of the directory entries into dir_table 
 * dir_table is then sorted and related extents are linked.
 */
int load_directory_table(int fd)
{
	u_char sector_data[SECT_USED];

	for (int i = 0 ; i < NUM_DIRS / DIRS_PER_SECTOR; i++)
	{
		/* Read each sector containing a directory entry */
		/* All directory data is on first 16 sectors of TRACK 2*/
		int allocation = i / RECS_PER_ALLOC;
		int	record = (i % RECS_PER_ALLOC);

/*		printf("ALLOC = %d, REC = %d\n", allocation, record); */
		read_block(fd, allocation, record, &sector_data);
		for (int j = 0 ; j < 4 ; j++)
		{
			/* Calculate which directory entry number this is */
			int index = i * DIRS_PER_SECTOR + j;
			cpm_dir_entry *entry = &dir_table[index];
			entry->index = index;
			memcpy(&entry->raw_entry, sector_data + (DIR_ENTRY_LEN * j), DIR_ENTRY_LEN);
			sorted_dir_table[index] = entry;

			if (entry->raw_entry.user <= MAX_USER)
			{
				raw_to_cpm(entry);

				/* Mark off the used allocations */
				for (int j = 0 ; j < NR_ALLOCS ; j++)
				{
					uint8_t alloc = entry->raw_entry.allocation[j];
					
					/* Allocation of 0, means no more allocations used by this entry */
					if (alloc == 0)
						break;
					/* otherwise mark the allocation as used */
					alloc_table[alloc] = 1;
				}
			}
		}
	}

	qsort(&sorted_dir_table, NUM_DIRS, sizeof(cpm_dir_entry*), compare_sort_ptr);

	/* link related directory entries and store update the "by index" array */
	/* No need to check last entry, it can't be related to anything */
	for (int i = 0 ; i < NUM_DIRS-1 ; i++)
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

	return 0;
}

/* Sort by valid = 1, filename+type, then extent_nr */
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
 * Convert each cpm directory entry (extent) into an structure that is
 * easier to work with.
*/
void raw_to_cpm(cpm_dir_entry* entry)
{
	char *space_pos;

//	entry->index = index;
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
	if (space_pos != NULL)
	{
		*space_pos = '\0';
	}
	strcat(entry->full_filename,".");
	strcat(entry->full_filename, entry->type);

	entry->num_records = raw->num_records;
	int num_allocs = 0;
	for (int i = 0 ; i < NR_ALLOCS ; i++)
	{
		if (raw->allocation[i] == 0)
		break;
		num_allocs++;
	}
	entry->num_allocs = num_allocs;
	entry->valid = 1;
}

uint8_t calc_checksum(u_char *buffer)
{
	uint8_t csum = 0;
	for (int i = 0 ; i < SECT_USED ; i++)
	{
		csum += buffer[i];
	}
	return csum;
}