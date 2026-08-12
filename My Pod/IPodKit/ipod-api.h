/*
 * ipod-api.h - Swift-friendly C API for libgpod
 *
 * This header provides a clean C interface with no GLib dependencies,
 * making it easy to use from Swift via a bridging header or module map.
 *
 * Copyright (c) 2026 Studio Rischio LLC
 * SPDX-License-Identifier: MIT
 *
 * See ipod-api.c for why this is MIT while libgpod remains LGPL.
 */

#ifndef IPOD_API_H
#define IPOD_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handle to iPod database */
typedef struct IPodDB IPodDB;

/* Result structure for operations that can fail */
typedef struct {
    int success;      /* 1 = success, 0 = failure */
    char *error;      /* Error message if failed, NULL if success. Caller must free with ipod_free_string() */
} IPodResult;

/* Device information */
typedef struct {
    char *model_name;       /* e.g. "iPod Classic" */
    char *generation;       /* e.g. "Classic (3rd Gen.)" */
    double capacity_gb;     /* Storage capacity in GB */
    int track_count;        /* Number of tracks on device */
    int playlist_count;     /* Number of playlists */
    char *uuid;             /* Device UUID (may be NULL) */
    char *mountpoint;       /* Mount path */
} IPodDeviceInfo;

/* Track information */
typedef struct {
    uint32_t id;            /* Unique track ID */
    char *title;            /* Track title */
    char *artist;           /* Artist name */
    char *album;            /* Album name */
    char *genre;            /* Genre */
    char *composer;         /* Composer */
    int track_number;       /* Track number in album */
    int disc_number;        /* Disc number */
    int duration_ms;        /* Duration in milliseconds */
    uint32_t size_bytes;    /* File size in bytes */
    int bitrate;            /* Bitrate in kbps */
    int samplerate;         /* Sample rate in Hz */
    int year;               /* Release year */
    int rating;             /* Rating 0-100 (stars * 20) */
    int playcount;          /* Number of times played */
    char *ipod_path;        /* Path on iPod (colon-separated) */
    char *filetype;         /* File type description */
} IPodTrackInfo;

/* Playlist information */
typedef struct {
    uint64_t id;            /* Playlist ID */
    char *name;             /* Playlist name (UTF-8) */
    int is_master;          /* 1 for the master playlist ("iPod"), 0 for user playlists */
    int track_count;        /* Number of track entries */
    uint32_t *track_ids;    /* track_count entries, in playlist order (NULL when empty) */
} IPodPlaylistInfo;

/* Sync statistics */
typedef struct {
    int added;              /* Tracks added */
    int skipped;            /* Tracks skipped (already exist) */
    int removed;            /* Tracks removed */
    int failed;             /* Tracks that failed to sync */
    int total_on_device;    /* Total tracks on device after sync */
} IPodSyncStats;

/* ============================================================================
 * Core Functions
 * ============================================================================ */

/**
 * Open an iPod database from a mountpoint.
 *
 * @param mountpoint  Path to mounted iPod (e.g., "/Volumes/iPod")
 * @param error       Pointer to receive error message on failure (caller must free)
 * @return            Handle to iPod database, or NULL on failure
 */
IPodDB *ipod_open(const char *mountpoint, char **error);

/**
 * Close an iPod database and free resources.
 *
 * @param db  Database handle from ipod_open()
 */
void ipod_close(IPodDB *db);

/**
 * Save changes to the iPod database.
 * Call this after adding/removing tracks to persist changes.
 *
 * @param db  Database handle
 * @return    Result with success status and error message if failed
 */
IPodResult ipod_save(IPodDB *db);

/* ============================================================================
 * Device Information
 * ============================================================================ */

/**
 * Get device information.
 *
 * @param db  Database handle
 * @return    Device info struct (caller must free with ipod_free_device_info())
 */
IPodDeviceInfo *ipod_get_device_info(IPodDB *db);

/**
 * Free device info structure.
 *
 * @param info  Device info to free
 */
void ipod_free_device_info(IPodDeviceInfo *info);

/* ============================================================================
 * Track Listing
 * ============================================================================ */

/**
 * Get the number of tracks on the iPod.
 *
 * @param db  Database handle
 * @return    Number of tracks
 */
int ipod_get_track_count(IPodDB *db);

/**
 * Get track information by index.
 *
 * @param db     Database handle
 * @param index  Zero-based track index (0 to track_count-1)
 * @return       Track info (caller must free with ipod_free_track_info()), or NULL if invalid index
 */
IPodTrackInfo *ipod_get_track_at_index(IPodDB *db, int index);

/**
 * Get track information by ID.
 *
 * @param db        Database handle
 * @param track_id  Track ID
 * @return          Track info (caller must free with ipod_free_track_info()), or NULL if not found
 */
IPodTrackInfo *ipod_get_track_by_id(IPodDB *db, uint32_t track_id);

/**
 * Free track info structure.
 *
 * @param info  Track info to free
 */
void ipod_free_track_info(IPodTrackInfo *info);

/* ============================================================================
 * Track Operations
 * ============================================================================ */

/**
 * Add a track to the iPod.
 * The file will be copied to the iPod and added to the master playlist.
 *
 * @param db            Database handle
 * @param filepath      Path to audio file on local filesystem
 * @param title         Track title (or NULL to use filename)
 * @param artist        Artist name (or NULL)
 * @param album         Album name (or NULL)
 * @param track_number  Track number (or 0)
 * @return              Result with success status
 */
IPodResult ipod_add_track(IPodDB *db, const char *filepath,
                          const char *title, const char *artist,
                          const char *album, int track_number);

/**
 * Add a track with full audio metadata.
 *
 * Identical to ipod_add_track() but populates the duration / bitrate / sample
 * rate / year / genre / disc number fields, which the iPod player needs to
 * actually decode and play many file formats. Pass 0 / NULL to leave a field
 * unset (with the same fallback behaviour as ipod_add_track).
 *
 * @param db            Database handle
 * @param filepath      Path to audio file on local filesystem
 * @param title         Track title (or NULL to use filename)
 * @param artist        Artist name (or NULL)
 * @param album         Album name (or NULL)
 * @param track_number  Track number (or 0 to use filename)
 * @param disc_number   Disc number (or 0)
 * @param duration_ms   Track duration in milliseconds (or 0)
 * @param bitrate       Bitrate in kbps (or 0)
 * @param samplerate    Sample rate in Hz (or 0)
 * @param year          Release year (or 0)
 * @param genre         Genre (or NULL)
 * @param filetype      Track type display string ("Apple Lossless audio file",
 *                      "AAC audio file", etc.) — overrides extension-based
 *                      default if non-NULL
 * @param artwork_path  Path to a cover-art image (JPEG/PNG/etc) to attach to
 *                      this track. Pass NULL to skip artwork. Mirrors the
 *                      ipod-sync.c flow where set_thumbnails is called as part
 *                      of the same atomic add — keeps artwork wiring tied to
 *                      track creation.
 * @return              Result with success status
 */
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
                               const char *artwork_path);

/**
 * Remove a track from the iPod.
 * Removes from database and deletes the file from the iPod.
 *
 * @param db        Database handle
 * @param track_id  Track ID to remove
 * @return          Result with success status
 */
IPodResult ipod_remove_track(IPodDB *db, uint32_t track_id);

/**
 * Remove a track by matching artist/album/title.
 *
 * @param db      Database handle
 * @param artist  Artist to match
 * @param album   Album to match
 * @param title   Title to match
 * @return        Result with success status
 */
IPodResult ipod_remove_track_by_name(IPodDB *db, const char *artist,
                                      const char *album, const char *title);

/* ============================================================================
 * Sync Operations
 * ============================================================================ */

/**
 * Sync a music folder to the iPod.
 *
 * Expected folder structure:
 *   music_folder/
 *     Artist Name/
 *       Album Name/
 *         01 - Track Title.mp3
 *
 * @param db              Database handle
 * @param music_folder    Path to music folder
 * @param remove_missing  If non-zero, remove tracks not in music_folder
 * @param error           Pointer to receive error message on failure
 * @return                Sync statistics
 */
IPodSyncStats ipod_sync_folder(IPodDB *db, const char *music_folder,
                                int remove_missing, char **error);

/**
 * Sync a music folder to the iPod (extended version with force resync).
 *
 * @param db              Database handle
 * @param music_folder    Path to music folder
 * @param remove_missing  If non-zero, remove tracks not in music_folder
 * @param force_resync    If non-zero, remove all existing tracks before syncing
 * @param error           Pointer to receive error message on failure
 * @return                Sync statistics
 */
IPodSyncStats ipod_sync_folder_ex(IPodDB *db, const char *music_folder,
                                   int remove_missing, int force_resync, char **error);

/* ============================================================================
 * Playlists
 * ============================================================================ */

/**
 * Get the number of playlists on the iPod, including the master playlist.
 *
 * @param db  Database handle
 * @return    Number of playlists
 */
int ipod_get_playlist_count(IPodDB *db);

/**
 * Get playlist information by index, including the ordered track IDs of its
 * entries. Use `is_master` to skip the master playlist, which mirrors the
 * whole library rather than being a user playlist.
 *
 * @param db     Database handle
 * @param index  Zero-based playlist index (0 to playlist_count-1)
 * @return       Playlist info (caller must free with ipod_free_playlist_info()),
 *               or NULL if invalid index
 */
IPodPlaylistInfo *ipod_get_playlist_at_index(IPodDB *db, int index);

/**
 * Free playlist info structure.
 *
 * @param info  Playlist info to free
 */
void ipod_free_playlist_info(IPodPlaylistInfo *info);

/**
 * Create a new (non-smart) playlist.
 *
 * @param db    Database handle
 * @param name  Playlist name (UTF-8). Must be non-NULL.
 * @return      The new playlist's ID, or 0 on failure.
 */
uint64_t ipod_create_playlist(IPodDB *db, const char *name);

/**
 * Append a track (already on the iPod) to a playlist.
 *
 * @param db           Database handle
 * @param playlist_id  Playlist ID returned from ipod_create_playlist
 * @param track_id     Track ID
 * @return             Result with success status
 */
IPodResult ipod_playlist_add_track(IPodDB *db, uint64_t playlist_id, uint32_t track_id);

/**
 * Remove every user-created (non-master) playlist from the database.
 *
 * Does not affect tracks themselves — only playlist objects. Useful as a
 * "clear and rewrite" step when syncing playlists from an external source.
 *
 * @param db  Database handle
 * @return    Number of playlists removed.
 */
int ipod_clear_user_playlists(IPodDB *db);

/* ============================================================================
 * Artwork
 * ============================================================================ */

/**
 * Set the thumbnail for a track from an image file.
 *
 * The image file can be in any format supported by gdk-pixbuf (JPEG, PNG, etc).
 * Thumbnails are rendered lazily when ipod_save() is called.
 *
 * @param db          Database handle
 * @param track_id    Track ID
 * @param image_path  Path to the image file
 * @return            Result with success status
 */
IPodResult ipod_set_track_artwork(IPodDB *db, uint32_t track_id, const char *image_path);

/* ============================================================================
 * Database Reset/Initialization
 * ============================================================================ */

/**
 * Reset the iPod database to a fresh state.
 *
 * This deletes the existing database files and reinitializes them.
 * Use this to fix a corrupted database.
 *
 * WARNING: This will remove ALL tracks and playlists from the iPod database.
 * The actual music files in iPod_Control/Music are NOT deleted.
 *
 * @param mountpoint  Path to the iPod mount point
 * @return            Result with success status
 */
IPodResult ipod_reset_database(const char *mountpoint);

/**
 * Fully reset the iPod - delete all music files AND reinitialize the database.
 *
 * This deletes:
 *   - All files in iPod_Control/Music/
 *   - All files in iPod_Control/Artwork/
 *   - The database files (iTunesDB, etc.)
 *
 * Then reinitializes a fresh database.
 *
 * WARNING: This will permanently delete ALL music from the iPod!
 *
 * @param mountpoint  Path to the iPod mount point
 * @return            Result with success status
 */
IPodResult ipod_full_reset(const char *mountpoint);

/* ============================================================================
 * Utility Functions
 * ============================================================================ */

/**
 * Free a string returned by the API.
 *
 * @param str  String to free (safe to pass NULL)
 */
void ipod_free_string(char *str);

/**
 * Get the API version string.
 *
 * @return  Version string (do not free)
 */
const char *ipod_get_version(void);

#ifdef __cplusplus
}
#endif

#endif /* IPOD_API_H */
