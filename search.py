alltracks = []
def track_sect(rec):
    return rec[1]+rec[2];

with open("tdsk.dsk","rb") as f:
    b = f.read();
    for i in range(0,len(b)-1):
        if (b[i] == ord('X') and b[i+1] == ord('X') and b[i-1] != ord('X')):
            track=chr(b[i-4])+chr(b[i-3])
            sect=chr(b[i-2])+chr(b[i-1])
            loc = i-4
            alltracks.append([loc,track,sect]);
            #print("{0:d}:{1}:{2}".format(loc,track,sect));
alltracks.sort(key=track_sect)
for loc,track,sect in alltracks:
    print("{0:d}:{1}:{2}".format(loc,track,sect));
