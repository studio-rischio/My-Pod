/*
 * ipod-api.c - Swift-friendly C API for libgpod
 *
 * Implementation of the iPod API wrapper.
 *
 * Copyright (c) 2026 Studio Rischio LLC
 * SPDX-License-Identifier: MIT
 *
 * MIT rather than LGPL despite linking libgpod: this file contains no libgpod
 * code, it only calls the public API and includes itdb.h. LGPL 2.1 section 5
 * calls that a "work that uses the Library" and states it is not a derivative
 * work. libgpod itself (Vendor/libgpod) remains LGPL-2.1-or-later, and linking
 * it statically carries the section 6 relink obligation described in LICENSE.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <ctype.h>
#include <time.h>

#include <glib.h>
#include <glib/gstdio.h>
#include "itdb.h"
#include "ipod-api.h"

#define IPOD_API_VERSION "1.0.0"

/* Internal structure for database handle */
struct IPodDB {
    Itdb_iTunesDB *itdb;
    char *mountpoint;
};

/* Supported audio extensions */
static const char *audio_extensions[] = {
    ".mp3", ".m4a", ".m4b", ".m4p", ".aac", ".wav", ".aiff", ".aif", NULL
};

/* ============================================================================
 * Helper Functions
 * ============================================================================ */

/* Duplicate a string safely (handles NULL) */
static char *safe_strdup(const char *s)
{
    return s ? strdup(s) : NULL;
}

/* Copy GLib string to regular C string */
static char *glib_strdup(const gchar *s)
{
    return s ? strdup(s) : NULL;
}

/* Convert GError to string and free the error */
static char *error_to_string(GError *error)
{
    if (!error) return NULL;
    char *msg = strdup(error->message ? error->message : "Unknown error");
    g_error_free(error);
    return msg;
}

/* Check if filename has audio extension */
static int is_audio_file(const char *filename)
{
    const char *ext = strrchr(filename, '.');
    if (!ext) return 0;

    for (int i = 0; audio_extensions[i]; i++) {
        if (g_ascii_strcasecmp(ext, audio_extensions[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

/* Get filetype string from extension */
static const char *get_filetype(const char *filename)
{
    const char *ext = strrchr(filename, '.');
    if (!ext) return "Audio";

    if (g_ascii_strcasecmp(ext, ".mp3") == 0) return "MP3-file";
    if (g_ascii_strcasecmp(ext, ".m4a") == 0) return "AAC audio file";
    if (g_ascii_strcasecmp(ext, ".m4b") == 0) return "AAC audio file";
    if (g_ascii_strcasecmp(ext, ".m4p") == 0) return "AAC audio file";
    if (g_ascii_strcasecmp(ext, ".aac") == 0) return "AAC audio file";
    if (g_ascii_strcasecmp(ext, ".wav") == 0) return "WAV audio file";
    if (g_ascii_strcasecmp(ext, ".aiff") == 0) return "AIFF audio file";
    if (g_ascii_strcasecmp(ext, ".aif") == 0) return "AIFF audio file";

    return "Audio";
}

/* Parse track number and title from filename */
static void parse_track_filename(const char *filename, int *track_nr, char **title)
{
    char *basename = g_path_get_basename(filename);
    char *dot = strrchr(basename, '.');
    if (dot) *dot = '\0';

    *track_nr = 0;
    *title = NULL;

    char *p = basename;
    if (isdigit(*p)) {
        *track_nr = atoi(p);
        while (*p && isdigit(*p)) p++;
        while (*p && (*p == ' ' || *p == '-' || *p == '.' || *p == '_')) p++;
    }

    if (*p) {
        *title = strdup(p);
    } else {
        *title = strdup(basename);
    }

    g_free(basename);
}

/* Find track by artist/album/title */
static Itdb_Track *find_track_by_name(Itdb_iTunesDB *itdb, const char *artist,
                                       const char *album, const char *title)
{
    GList *l;
    for (l = itdb->tracks; l; l = l->next) {
        Itdb_Track *track = (Itdb_Track *)l->data;

        int artist_match = ((!artist && !track->artist) ||
                           (artist && track->artist &&
                            g_ascii_strcasecmp(artist, track->artist) == 0));
        int album_match = ((!album && !track->album) ||
                          (album && track->album &&
                           g_ascii_strcasecmp(album, track->album) == 0));
        int title_match = ((!title && !track->title) ||
                          (title && track->title &&
                           g_ascii_strcasecmp(title, track->title) == 0));

        if (artist_match && album_match && title_match) {
            return track;
        }
    }
    return NULL;
}

/* ============================================================================
 * Core Functions
 * ============================================================================ */

/* Forward all glib log messages to stderr so libgpod / gdk-pixbuf warnings
 * raised during itdb_save (artwork rendering, etc.) are visible. The default
 * glib handler also writes to stderr but the format is less greppable. */
static void mypod_glib_log_handler(const gchar *log_domain,
                                   GLogLevelFlags log_level,
                                   const gchar *message,
                                   gpointer user_data)
{
    (void)log_level;
    (void)user_data;
    fprintf(stderr, "[libgpod %s] %s\n",
            log_domain ? log_domain : "?",
            message ? message : "");
    fflush(stderr);
}

IPodDB *ipod_open(const char *mountpoint, char **error)
{
    static int log_handler_installed = 0;
    if (!log_handler_installed) {
        g_log_set_default_handler(mypod_glib_log_handler, NULL);
        log_handler_installed = 1;
    }

    if (!mountpoint) {
        if (error) *error = strdup("Mountpoint is NULL");
        return NULL;
    }

    GError *gerror = NULL;
    Itdb_iTunesDB *itdb = itdb_parse(mountpoint, &gerror);

    if (!itdb) {
        if (error) {
            *error = gerror ? error_to_string(gerror) : strdup("Failed to parse iPod database");
        } else if (gerror) {
            g_error_free(gerror);
        }
        return NULL;
    }

    IPodDB *db = (IPodDB *)malloc(sizeof(IPodDB));
    if (!db) {
        itdb_free(itdb);
        if (error) *error = strdup("Memory allocation failed");
        return NULL;
    }

    db->itdb = itdb;
    db->mountpoint = strdup(mountpoint);

    if (error) *error = NULL;
    return db;
}

void ipod_close(IPodDB *db)
{
    if (!db) return;

    if (db->itdb) {
        itdb_free(db->itdb);
        db->itdb = NULL;
    }
    if (db->mountpoint) {
        free(db->mountpoint);
        db->mountpoint = NULL;
    }
    free(db);
}

/* Diagnostic: log per-track artwork state using only public Itdb_Track
 * fields. Called before/after itdb_write so we can see what libgpod's
 * mark_new_doubles dedup did to each track. */
static void mypod_dump_artwork_state(IPodDB *db, const char *label)
{
    if (!db || !db->itdb) return;

    int n_total = 0, n_has_artwork = 0;
    GList *gl;
    fprintf(stderr, "[artwork-state %s] === per-track dump ===\n", label);
    for (gl = db->itdb->tracks; gl; gl = gl->next) {
        Itdb_Track *t = gl->data;
        n_total++;
        const char *album = t->album ? t->album : "(null)";
        const char *title = t->title ? t->title : "(null)";
        gboolean has_thumbs = itdb_track_has_thumbnails(t);
        if (t->has_artwork) n_has_artwork++;

        fprintf(stderr, "[artwork-state %s] tid=%u has_artwork=%d artwork_count=%d "
                        "artwork_size=%d has_thumbs=%d album=\"%s\" title=\"%s\"\n",
                        label, t->id, t->has_artwork, t->artwork_count,
                        t->artwork_size, has_thumbs ? 1 : 0,
                        album, title);
    }
    fprintf(stderr, "[artwork-state %s] totals: tracks=%d has_artwork=%d\n",
            label, n_total, n_has_artwork);
    fflush(stderr);
}

IPodResult ipod_save(IPodDB *db)
{
    IPodResult result = {0, NULL};

    if (!db || !db->itdb) {
        result.error = strdup("Invalid database handle");
        return result;
    }

    mypod_dump_artwork_state(db, "before-save");

    GError *gerror = NULL;
    if (itdb_write(db->itdb, &gerror)) {
        result.success = 1;
    } else {
        result.error = error_to_string(gerror);
    }

    mypod_dump_artwork_state(db, "after-save");

    return result;
}

/* ============================================================================
 * Device Information
 * ============================================================================ */

IPodDeviceInfo *ipod_get_device_info(IPodDB *db)
{
    if (!db || !db->itdb) return NULL;

    IPodDeviceInfo *info = (IPodDeviceInfo *)calloc(1, sizeof(IPodDeviceInfo));
    if (!info) return NULL;

    Itdb_Device *device = db->itdb->device;

    if (device) {
        const Itdb_IpodInfo *ipod_info = itdb_device_get_ipod_info(device);
        if (ipod_info) {
            info->model_name = glib_strdup(itdb_info_get_ipod_model_name_string(ipod_info->ipod_model));
            info->generation = glib_strdup(itdb_info_get_ipod_generation_string(ipod_info->ipod_generation));
            info->capacity_gb = ipod_info->capacity;
        }

        /* itdb_device_get_uuid returns a pointer into the device's
           sysinfo hash table - do NOT free it */
        const gchar *uuid = itdb_device_get_uuid(device);
        if (uuid) {
            info->uuid = glib_strdup(uuid);
        }
    }

    info->track_count = g_list_length(db->itdb->tracks);
    info->playlist_count = g_list_length(db->itdb->playlists);
    info->mountpoint = safe_strdup(db->mountpoint);

    return info;
}

void ipod_free_device_info(IPodDeviceInfo *info)
{
    if (!info) return;

    free(info->model_name);
    free(info->generation);
    free(info->uuid);
    free(info->mountpoint);
    free(info);
}

/* ============================================================================
 * Track Listing
 * ============================================================================ */

int ipod_get_track_count(IPodDB *db)
{
    if (!db || !db->itdb) return 0;
    return g_list_length(db->itdb->tracks);
}

/* Create IPodTrackInfo from Itdb_Track */
static IPodTrackInfo *track_to_info(Itdb_Track *track)
{
    if (!track) return NULL;

    IPodTrackInfo *info = (IPodTrackInfo *)calloc(1, sizeof(IPodTrackInfo));
    if (!info) return NULL;

    info->id = track->id;
    info->title = glib_strdup(track->title);
    info->artist = glib_strdup(track->artist);
    info->album = glib_strdup(track->album);
    info->genre = glib_strdup(track->genre);
    info->composer = glib_strdup(track->composer);
    info->track_number = track->track_nr;
    info->disc_number = track->cd_nr;
    info->duration_ms = track->tracklen;
    info->size_bytes = track->size;
    info->bitrate = track->bitrate;
    info->samplerate = track->samplerate;
    info->year = track->year;
    info->rating = track->rating;
    info->playcount = track->playcount;
    info->ipod_path = glib_strdup(track->ipod_path);
    info->filetype = glib_strdup(track->filetype);

    return info;
}

IPodTrackInfo *ipod_get_track_at_index(IPodDB *db, int index)
{
    if (!db || !db->itdb || index < 0) return NULL;

    GList *item = g_list_nth(db->itdb->tracks, index);
    if (!item) return NULL;

    return track_to_info((Itdb_Track *)item->data);
}

IPodTrackInfo *ipod_get_track_by_id(IPodDB *db, uint32_t track_id)
{
    if (!db || !db->itdb) return NULL;

    Itdb_Track *track = itdb_track_by_id(db->itdb, track_id);
    return track_to_info(track);
}

void ipod_free_track_info(IPodTrackInfo *info)
{
    if (!info) return;

    free(info->title);
    free(info->artist);
    free(info->album);
    free(info->genre);
    free(info->composer);
    free(info->ipod_path);
    free(info->filetype);
    free(info);
}

/* Remove track from all playlists (must be done before itdb_track_remove) */
static void remove_track_from_all_playlists(Itdb_iTunesDB *itdb, Itdb_Track *track)
{
    GList *l;
    for (l = itdb->playlists; l; l = l->next) {
        Itdb_Playlist *pl = (Itdb_Playlist *)l->data;
        itdb_playlist_remove_track(pl, track);
    }
}

/* ============================================================================
 * Track Operations
 * ============================================================================ */

IPodResult ipod_add_track(IPodDB *db, const char *filepath,
                          const char *title, const char *artist,
                          const char *album, int track_number)
{
    return ipod_add_track_full(db, filepath, title, artist, album,
                               track_number, 0, 0, 0, 0, 0, NULL, NULL, NULL);
}

IPodResult ipod_add_track_full(IPodDB *db,
                               const char *filepath,
                               const char *title,
                               const char *artist,
                               const char *album,
                               int track_number,
                               int disc_number,
                               int duration_ms,
                               int bitrate,
                               int samplerate,
                               int year,
                               const char *genre,
                               const char *filetype,
                               const char *artwork_path)
{
    IPodResult result = {0, NULL};

    if (!db || !db->itdb) {
        result.error = strdup("Invalid database handle");
        return result;
    }

    if (!filepath) {
        result.error = strdup("Filepath is NULL");
        return result;
    }

    struct stat st;
    if (g_stat(filepath, &st) != 0) {
        result.error = strdup("Cannot access file");
        return result;
    }

    /* Parse title from filename if not provided */
    int parsed_track_nr = 0;
    char *parsed_title = NULL;
    if (!title) {
        parse_track_filename(filepath, &parsed_track_nr, &parsed_title);
    }

    Itdb_Track *track = itdb_track_new();
    if (!track) {
        free(parsed_title);
        result.error = strdup("Failed to create track");
        return result;
    }

    track->title = g_strdup(title ? title : parsed_title);
    track->artist = g_strdup(artist ? artist : "Unknown Artist");
    track->album = g_strdup(album ? album : "Unknown Album");
    if (genre) track->genre = g_strdup(genre);
    track->track_nr = track_number > 0 ? track_number : parsed_track_nr;
    track->cd_nr = disc_number > 0 ? disc_number : 0;
    track->size = (guint32)st.st_size;
    track->tracklen = duration_ms > 0 ? duration_ms : 0;
    track->bitrate = bitrate > 0 ? bitrate : 0;
    if (samplerate > 0 && samplerate <= 0xFFFF) {
        track->samplerate = (guint16)samplerate;
        track->samplerate_low = (guint16)samplerate;
    }
    track->year = year > 0 ? year : 0;
    track->filetype = g_strdup(filetype ? filetype : get_filetype(filepath));
    track->mediatype = ITDB_MEDIATYPE_AUDIO;
    track->time_added = (time_t)time(NULL);

    free(parsed_title);

    /* Attach thumbnails BEFORE itdb_track_add — mirrors the order used by
     * ipod-sync.c (the known-working CLI). libgpod renders the actual
     * thumbnail bytes during itdb_write; this call just stores the source
     * path on track->artwork. Failure is non-fatal (matches CLI). */
    if (artwork_path) {
        if (!itdb_track_set_thumbnails(track, artwork_path)) {
            fprintf(stderr, "[ipod-api] set_thumbnails failed for %s (path=%s)\n",
                    title ? title : filepath, artwork_path);
        }
    }

    itdb_track_add(db->itdb, track, -1);

    Itdb_Playlist *mpl = itdb_playlist_mpl(db->itdb);
    if (mpl) {
        itdb_playlist_add_track(mpl, track, -1);
    }

    GError *gerror = NULL;
    if (!itdb_cp_track_to_ipod(track, filepath, &gerror)) {
        remove_track_from_all_playlists(db->itdb, track);
        itdb_track_remove(track);
        result.error = error_to_string(gerror);
        return result;
    }

    result.success = 1;
    return result;
}

IPodResult ipod_remove_track(IPodDB *db, uint32_t track_id)
{
    IPodResult result = {0, NULL};

    if (!db || !db->itdb) {
        result.error = strdup("Invalid database handle");
        return result;
    }

    Itdb_Track *track = itdb_track_by_id(db->itdb, track_id);
    if (!track) {
        result.error = strdup("Track not found");
        return result;
    }

    /* Delete file from iPod */
    if (track->ipod_path) {
        char *full_path = itdb_filename_on_ipod(track);
        if (full_path) {
            g_unlink(full_path);
            g_free(full_path);
        }
    }

    /* Remove from all playlists, then from database */
    remove_track_from_all_playlists(db->itdb, track);
    itdb_track_remove(track);

    result.success = 1;
    return result;
}

IPodResult ipod_remove_track_by_name(IPodDB *db, const char *artist,
                                      const char *album, const char *title)
{
    IPodResult result = {0, NULL};

    if (!db || !db->itdb) {
        result.error = strdup("Invalid database handle");
        return result;
    }

    Itdb_Track *track = find_track_by_name(db->itdb, artist, album, title);
    if (!track) {
        result.error = strdup("Track not found");
        return result;
    }

    /* Delete file from iPod */
    if (track->ipod_path) {
        char *full_path = itdb_filename_on_ipod(track);
        if (full_path) {
            g_unlink(full_path);
            g_free(full_path);
        }
    }

    /* Remove from all playlists, then from database */
    remove_track_from_all_playlists(db->itdb, track);
    itdb_track_remove(track);

    result.success = 1;
    return result;
}

/* ============================================================================
 * Sync Operations
 * ============================================================================ */

/* Sync stats accumulator */
typedef struct {
    int added;
    int skipped;
    int removed;
    int failed;
} SyncStats;

/* Add a single track during sync */
static void sync_add_track(IPodDB *db, const char *filepath,
                           const char *artist, const char *album,
                           SyncStats *stats)
{
    int track_nr;
    char *title;
    parse_track_filename(filepath, &track_nr, &title);

    /* Check if track already exists */
    Itdb_Track *existing = find_track_by_name(db->itdb, artist, album, title);
    if (existing) {
        free(title);
        stats->skipped++;
        return;
    }

    /* Get file info */
    struct stat st;
    if (g_stat(filepath, &st) != 0) {
        free(title);
        stats->failed++;
        return;
    }

    /* Create new track */
    Itdb_Track *track = itdb_track_new();
    track->title = g_strdup(title);
    track->artist = g_strdup(artist);
    track->album = g_strdup(album);
    track->track_nr = track_nr;
    track->size = (guint32)st.st_size;
    track->filetype = g_strdup(get_filetype(filepath));
    track->mediatype = ITDB_MEDIATYPE_AUDIO;

    free(title);

    /* Add to database */
    itdb_track_add(db->itdb, track, -1);

    /* Add to master playlist */
    Itdb_Playlist *mpl = itdb_playlist_mpl(db->itdb);
    if (mpl) {
        itdb_playlist_add_track(mpl, track, -1);
    }

    /* Copy file to iPod */
    GError *error = NULL;
    if (!itdb_cp_track_to_ipod(track, filepath, &error)) {
        if (error) g_error_free(error);
        remove_track_from_all_playlists(db->itdb, track);
        itdb_track_remove(track);
        stats->failed++;
        return;
    }

    stats->added++;
}

/* Scan album directory */
static void sync_scan_album(IPodDB *db, const char *album_path,
                            const char *artist, const char *album,
                            SyncStats *stats)
{
    DIR *dir = opendir(album_path);
    if (!dir) return;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;

        char *filepath = g_build_filename(album_path, entry->d_name, NULL);
        struct stat st;

        if (g_stat(filepath, &st) == 0 && S_ISREG(st.st_mode)) {
            if (is_audio_file(entry->d_name)) {
                sync_add_track(db, filepath, artist, album, stats);
            }
        }

        g_free(filepath);
    }

    closedir(dir);
}

/* Scan artist directory */
static void sync_scan_artist(IPodDB *db, const char *artist_path,
                             const char *artist, SyncStats *stats)
{
    DIR *dir = opendir(artist_path);
    if (!dir) return;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;

        char *album_path = g_build_filename(artist_path, entry->d_name, NULL);
        struct stat st;

        if (g_stat(album_path, &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                sync_scan_album(db, album_path, artist, entry->d_name, stats);
            } else if (S_ISREG(st.st_mode) && is_audio_file(entry->d_name)) {
                sync_add_track(db, album_path, artist, "Unknown Album", stats);
            }
        }

        g_free(album_path);
    }

    closedir(dir);
}

/* Build hash set of source files */
static GHashTable *build_source_file_set(const char *music_path)
{
    GHashTable *set = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);

    DIR *artist_dir = opendir(music_path);
    if (!artist_dir) return set;

    struct dirent *artist_entry;
    while ((artist_entry = readdir(artist_dir)) != NULL) {
        if (artist_entry->d_name[0] == '.') continue;

        char *artist_path = g_build_filename(music_path, artist_entry->d_name, NULL);
        struct stat st;

        if (g_stat(artist_path, &st) == 0 && S_ISDIR(st.st_mode)) {
            DIR *album_dir = opendir(artist_path);
            if (album_dir) {
                struct dirent *album_entry;
                while ((album_entry = readdir(album_dir)) != NULL) {
                    if (album_entry->d_name[0] == '.') continue;

                    char *album_path = g_build_filename(artist_path, album_entry->d_name, NULL);

                    if (g_stat(album_path, &st) == 0 && S_ISDIR(st.st_mode)) {
                        DIR *track_dir = opendir(album_path);
                        if (track_dir) {
                            struct dirent *track_entry;
                            while ((track_entry = readdir(track_dir)) != NULL) {
                                if (track_entry->d_name[0] == '.') continue;
                                if (is_audio_file(track_entry->d_name)) {
                                    int track_nr;
                                    char *title;
                                    parse_track_filename(track_entry->d_name, &track_nr, &title);

                                    char *key = g_strdup_printf("%s|%s|%s",
                                        artist_entry->d_name, album_entry->d_name, title);
                                    gchar *lower_key = g_ascii_strdown(key, -1);
                                    g_hash_table_insert(set, lower_key, GINT_TO_POINTER(1));
                                    g_free(key);
                                    free(title);
                                }
                            }
                            closedir(track_dir);
                        }
                    }
                    g_free(album_path);
                }
                closedir(album_dir);
            }
        }
        g_free(artist_path);
    }

    closedir(artist_dir);
    return set;
}

/* Remove tracks not in source folder */
static void remove_missing_tracks(IPodDB *db, const char *music_path, SyncStats *stats)
{
    GHashTable *source_files = build_source_file_set(music_path);
    GList *tracks_to_remove = NULL;

    /* Find tracks to remove */
    GList *l;
    for (l = db->itdb->tracks; l; l = l->next) {
        Itdb_Track *track = (Itdb_Track *)l->data;

        char *key = g_strdup_printf("%s|%s|%s",
            track->artist ? track->artist : "",
            track->album ? track->album : "",
            track->title ? track->title : "");
        gchar *lower_key = g_ascii_strdown(key, -1);

        if (!g_hash_table_contains(source_files, lower_key)) {
            tracks_to_remove = g_list_prepend(tracks_to_remove, track);
        }

        g_free(key);
        g_free(lower_key);
    }

    /* Remove tracks */
    for (l = tracks_to_remove; l; l = l->next) {
        Itdb_Track *track = (Itdb_Track *)l->data;

        if (track->ipod_path) {
            char *full_path = itdb_filename_on_ipod(track);
            if (full_path) {
                g_unlink(full_path);
                g_free(full_path);
            }
        }

        remove_track_from_all_playlists(db->itdb, track);
        itdb_track_remove(track);
        stats->removed++;
    }

    g_list_free(tracks_to_remove);
    g_hash_table_destroy(source_files);
}

/* Remove all tracks from database - used for force resync */
static void remove_all_tracks(IPodDB *db, SyncStats *stats)
{
    GList *tracks_to_remove = NULL;

    /* Collect all tracks first */
    for (GList *l = db->itdb->tracks; l; l = l->next) {
        tracks_to_remove = g_list_prepend(tracks_to_remove, l->data);
    }

    /* Remove tracks */
    for (GList *l = tracks_to_remove; l; l = l->next) {
        Itdb_Track *track = (Itdb_Track *)l->data;

        if (track->ipod_path) {
            char *full_path = itdb_filename_on_ipod(track);
            if (full_path) {
                g_unlink(full_path);
                g_free(full_path);
            }
        }

        remove_track_from_all_playlists(db->itdb, track);
        itdb_track_remove(track);
        stats->removed++;
    }

    g_list_free(tracks_to_remove);
}

IPodSyncStats ipod_sync_folder(IPodDB *db, const char *music_folder,
                                int remove_missing, char **error)
{
    return ipod_sync_folder_ex(db, music_folder, remove_missing, 0, error);
}

IPodSyncStats ipod_sync_folder_ex(IPodDB *db, const char *music_folder,
                                   int remove_missing, int force_resync, char **error)
{
    IPodSyncStats result = {0, 0, 0, 0, 0};
    SyncStats stats = {0, 0, 0, 0};

    if (!db || !db->itdb) {
        if (error) *error = strdup("Invalid database handle");
        return result;
    }

    if (!music_folder) {
        if (error) *error = strdup("Music folder is NULL");
        return result;
    }

    if (!g_file_test(music_folder, G_FILE_TEST_IS_DIR)) {
        if (error) *error = strdup("Music folder does not exist");
        return result;
    }

    /* Force resync: remove all existing tracks first */
    if (force_resync) {
        remove_all_tracks(db, &stats);
    }

    /* Scan and add tracks */
    DIR *dir = opendir(music_folder);
    if (!dir) {
        if (error) *error = strdup("Cannot open music folder");
        return result;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;

        char *artist_path = g_build_filename(music_folder, entry->d_name, NULL);
        struct stat st;

        if (g_stat(artist_path, &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                sync_scan_artist(db, artist_path, entry->d_name, &stats);
            } else if (S_ISREG(st.st_mode) && is_audio_file(entry->d_name)) {
                sync_add_track(db, artist_path, "Unknown Artist", "Unknown Album", &stats);
            }
        }

        g_free(artist_path);
    }

    closedir(dir);

    /* Remove missing tracks if requested (only if not force resync, since we already removed all) */
    if (remove_missing && !force_resync) {
        remove_missing_tracks(db, music_folder, &stats);
    }

    result.added = stats.added;
    result.skipped = stats.skipped;
    result.removed = stats.removed;
    result.failed = stats.failed;
    result.total_on_device = g_list_length(db->itdb->tracks);

    if (error) *error = NULL;
    return result;
}

/* ============================================================================
 * Playlists
 * ============================================================================ */

int ipod_get_playlist_count(IPodDB *db)
{
    if (!db || !db->itdb) return 0;
    return g_list_length(db->itdb->playlists);
}

IPodPlaylistInfo *ipod_get_playlist_at_index(IPodDB *db, int index)
{
    if (!db || !db->itdb || index < 0) return NULL;

    GList *item = g_list_nth(db->itdb->playlists, index);
    if (!item) return NULL;
    Itdb_Playlist *pl = (Itdb_Playlist *)item->data;
    if (!pl) return NULL;

    IPodPlaylistInfo *info = (IPodPlaylistInfo *)calloc(1, sizeof(IPodPlaylistInfo));
    if (!info) return NULL;

    info->id = pl->id;
    info->name = glib_strdup(pl->name);
    info->is_master = itdb_playlist_is_mpl(pl) ? 1 : 0;

    guint count = g_list_length(pl->members);
    info->track_count = (int)count;
    if (count > 0) {
        info->track_ids = (uint32_t *)calloc(count, sizeof(uint32_t));
        if (!info->track_ids) {
            /* Report the playlist without its members rather than failing outright. */
            info->track_count = 0;
        } else {
            int i = 0;
            for (GList *m = pl->members; m; m = m->next) {
                Itdb_Track *track = (Itdb_Track *)m->data;
                info->track_ids[i++] = track ? track->id : 0;
            }
        }
    }

    return info;
}

void ipod_free_playlist_info(IPodPlaylistInfo *info)
{
    if (!info) return;

    free(info->name);
    free(info->track_ids);
    free(info);
}

uint64_t ipod_create_playlist(IPodDB *db, const char *name)
{
    if (!db || !db->itdb || !name) return 0;
    Itdb_Playlist *pl = itdb_playlist_new(name, FALSE);
    if (!pl) return 0;
    itdb_playlist_add(db->itdb, pl, -1);
    return pl->id;
}

IPodResult ipod_playlist_add_track(IPodDB *db, uint64_t playlist_id, uint32_t track_id)
{
    IPodResult result = {0, NULL};

    if (!db || !db->itdb) {
        result.error = strdup("Invalid database handle");
        return result;
    }

    Itdb_Playlist *pl = itdb_playlist_by_id(db->itdb, playlist_id);
    if (!pl) {
        result.error = strdup("Playlist not found");
        return result;
    }

    Itdb_Track *track = itdb_track_by_id(db->itdb, track_id);
    if (!track) {
        result.error = strdup("Track not found");
        return result;
    }

    itdb_playlist_add_track(pl, track, -1);
    result.success = 1;
    return result;
}

int ipod_clear_user_playlists(IPodDB *db)
{
    if (!db || !db->itdb) return 0;

    /* Copy the list head before iterating since itdb_playlist_remove mutates it. */
    GList *snapshot = g_list_copy(db->itdb->playlists);
    int removed = 0;
    for (GList *iter = snapshot; iter; iter = iter->next) {
        Itdb_Playlist *pl = (Itdb_Playlist *)iter->data;
        if (itdb_playlist_is_mpl(pl)) continue;
        itdb_playlist_remove(pl);
        removed++;
    }
    g_list_free(snapshot);
    return removed;
}

/* ============================================================================
 * Artwork
 * ============================================================================ */

IPodResult ipod_set_track_artwork(IPodDB *db, uint32_t track_id, const char *image_path)
{
    IPodResult result = {0, NULL};

    if (!db || !db->itdb) {
        result.error = strdup("Invalid database handle");
        return result;
    }
    if (!image_path) {
        result.error = strdup("Image path is NULL");
        return result;
    }

    Itdb_Track *track = itdb_track_by_id(db->itdb, track_id);
    if (!track) {
        char buf[64];
        snprintf(buf, sizeof(buf), "Track %u not found", track_id);
        result.error = strdup(buf);
        return result;
    }

    if (!itdb_track_set_thumbnails(track, image_path)) {
        result.error = strdup("itdb_track_set_thumbnails failed (image unreadable or unsupported)");
        return result;
    }

    result.success = 1;
    return result;
}

/* ============================================================================
 * Database Reset/Initialization
 * ============================================================================ */

IPodResult ipod_reset_database(const char *mountpoint)
{
    IPodResult result = {0, NULL};

    if (!mountpoint) {
        result.error = strdup("Mountpoint is NULL");
        return result;
    }

    /* Delete existing database files */
    char *itunes_dir = g_build_filename(mountpoint, "iPod_Control", "iTunes", NULL);

    char *itdb_path = g_build_filename(itunes_dir, "iTunesDB", NULL);
    char *itcdb_path = g_build_filename(itunes_dir, "iTunesCDB", NULL);
    char *itsd_path = g_build_filename(itunes_dir, "iTunesSD", NULL);

    /* Remove existing database files if they exist */
    if (g_file_test(itdb_path, G_FILE_TEST_EXISTS)) {
        g_unlink(itdb_path);
    }
    if (g_file_test(itcdb_path, G_FILE_TEST_EXISTS)) {
        g_unlink(itcdb_path);
    }
    if (g_file_test(itsd_path, G_FILE_TEST_EXISTS)) {
        g_unlink(itsd_path);
    }

    g_free(itdb_path);
    g_free(itcdb_path);
    g_free(itsd_path);
    g_free(itunes_dir);

    /* Initialize a fresh iPod database */
    GError *error = NULL;
    if (!itdb_init_ipod(mountpoint, NULL, "iPod", &error)) {
        if (error) {
            result.error = strdup(error->message);
            g_error_free(error);
        } else {
            result.error = strdup("Failed to initialize iPod database");
        }
        return result;
    }

    result.success = 1;
    return result;
}

/* Helper to recursively delete directory contents */
static void delete_directory_contents(const char *path)
{
    GDir *dir = g_dir_open(path, 0, NULL);
    if (!dir) return;

    const gchar *name;
    while ((name = g_dir_read_name(dir)) != NULL) {
        gchar *full_path = g_build_filename(path, name, NULL);

        if (g_file_test(full_path, G_FILE_TEST_IS_DIR)) {
            /* Recursively delete subdirectory */
            delete_directory_contents(full_path);
            g_rmdir(full_path);
        } else {
            g_unlink(full_path);
        }

        g_free(full_path);
    }

    g_dir_close(dir);
}

IPodResult ipod_full_reset(const char *mountpoint)
{
    IPodResult result = {0, NULL};

    if (!mountpoint) {
        result.error = strdup("Mountpoint is NULL");
        return result;
    }

    /* Delete all music files in iPod_Control/Music */
    char *music_dir = g_build_filename(mountpoint, "iPod_Control", "Music", NULL);
    if (g_file_test(music_dir, G_FILE_TEST_IS_DIR)) {
        delete_directory_contents(music_dir);
    }
    g_free(music_dir);

    /* Delete artwork database */
    char *artwork_dir = g_build_filename(mountpoint, "iPod_Control", "Artwork", NULL);
    if (g_file_test(artwork_dir, G_FILE_TEST_IS_DIR)) {
        delete_directory_contents(artwork_dir);
    }
    g_free(artwork_dir);

    /* Now reset the database */
    return ipod_reset_database(mountpoint);
}

/* ============================================================================
 * Utility Functions
 * ============================================================================ */

void ipod_free_string(char *str)
{
    free(str);
}

const char *ipod_get_version(void)
{
    return IPOD_API_VERSION;
}
