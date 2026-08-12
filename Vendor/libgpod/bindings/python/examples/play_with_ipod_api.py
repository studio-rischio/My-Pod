#!/usr/bin/python

import gpod
import sys

if len(sys.argv) > 1:
    db = gpod.Database(sys.argv[1])
else:
    db = gpod.Database()


print db

for track in db[4:20]:
    print track
    print track['title']

for pl in db.Playlists:
    print pl
    for track in pl:
        print " ", track
