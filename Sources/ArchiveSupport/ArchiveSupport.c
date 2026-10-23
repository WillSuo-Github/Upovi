#include "ArchiveSupport.h"
#include <archive.h>
#include <archive_entry.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <time.h>

static int fail(char *out, size_t length, const char *message) {
    if (out && length) snprintf(out, length, "%s", message ? message : "Archive extraction failed");
    return -1;
}
static int safe_path(const char *path) {
    if (!path || !*path || *path == '/' || strlen(path) >= 4096 || strchr(path, '\\')) return 0;
    char *copy = strdup(path), *cursor = NULL;
    if (!copy) return 0;
    int valid = 1;
    for (char *part = strtok_r(copy, "/", &cursor); part; part = strtok_r(NULL, "/", &cursor)) {
        if (!strcmp(part, "..")) { valid = 0; break; }
    }
    free(copy); return valid;
}
/* Resolve parent directories by file descriptor. No archive member may write through a symlink. */
static int parent_fd(int root, char *path, char **leaf) {
    int fd = dup(root);
    if (fd < 0) return -1;
    char *last = strrchr(path, '/');
    if (!last) { *leaf = path; return fd; }
    *last = 0; *leaf = last + 1;
    char *cursor = NULL;
    for (char *part = strtok_r(path, "/", &cursor); part; part = strtok_r(NULL, "/", &cursor)) {
        if (!strcmp(part, ".")) continue;
        if (mkdirat(fd, part, 0755) && errno != EEXIST) { close(fd); return -1; }
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); fd = next;
        if (fd < 0) return -1;
    }
    return fd;
}
int upovi_extract_zip(const char *source, const char *destination, char *error, size_t error_size, int (*cancelled)(void)) {
    int root = open(destination, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) return fail(error, error_size, "Cannot open extraction directory");
    struct archive *reader = archive_read_new();
    archive_read_support_format_zip(reader);
    if (archive_read_open_filename(reader, source, 65536) != ARCHIVE_OK) {
        fail(error, error_size, archive_error_string(reader)); archive_read_free(reader); close(root); return -1;
    }
    struct archive_entry *entry;
    unsigned long entries = 0;
    unsigned long long total = 0;
    time_t started = time(NULL);
    int result = 0, status;
    while ((status = archive_read_next_header(reader, &entry)) == ARCHIVE_OK) {
        const char *name = archive_entry_pathname(entry);
        if ((cancelled && cancelled()) || ++entries > 100000 || time(NULL) - started > 300 || !safe_path(name) || archive_entry_hardlink(entry)) {
            result = fail(error, error_size, "Unsafe archive member or extraction limit exceeded"); break;
        }
        char *path = strdup(name);
        size_t length = strlen(path);
        while (length && path[length - 1] == '/') path[--length] = 0;
        if (!length || !strcmp(path, ".")) { free(path); continue; }
        char *leaf = NULL;
        int parent = parent_fd(root, path, &leaf);
        if (parent < 0 || !leaf || !*leaf || !strcmp(leaf, ".")) {
            if (parent >= 0) close(parent);
            free(path); result = fail(error, error_size, "Archive path crosses a symlink or invalid directory"); break;
        }
        mode_t type = archive_entry_filetype(entry);
        if (type == AE_IFDIR) {
            if (mkdirat(parent, leaf, 0755) && errno != EEXIST) result = -1;
            int directory = openat(parent, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (directory < 0) result = -1; else close(directory);
        } else if (type == AE_IFLNK) {
            const char *target = archive_entry_symlink(entry);
            // Conservative symlink support covers normal versioned frameworks; parent traversal is refused.
            if (!safe_path(target) || symlinkat(target, parent, leaf)) result = -1;
        } else if (type == AE_IFREG) {
            if (archive_entry_size(entry) < 0 || (unsigned long long)archive_entry_size(entry) > 8000000000ULL - total) result = -1;
            int file = result ? -1 : openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (file < 0) result = -1;
            char buffer[65536];
            la_ssize_t count;
            while (!result && (count = archive_read_data(reader, buffer, sizeof(buffer))) > 0) {
                total += (unsigned long long)count;
                if ((cancelled && cancelled()) || total > 8000000000ULL || time(NULL) - started > 300) { result = -1; break; }
                la_ssize_t offset = 0;
                while (offset < count) {
                    ssize_t written = write(file, buffer + offset, (size_t)(count - offset));
                    if (written < 0 && errno == EINTR) continue;
                    if (written <= 0) { result = -1; break; }
                    offset += written;
                }
            }
            if (!result && count < 0) result = -1;
            if (file >= 0) {
                if (!result && fchmod(file, (archive_entry_perm(entry) & 0111) ? 0755 : 0644)) result = -1;
                close(file);
            }
        } else result = -1;
        close(parent); free(path);
        if (result) { fail(error, error_size, "Unsafe archive entry, duplicate member, or extraction failure"); break; }
    }
    if (!result && status != ARCHIVE_EOF) result = fail(error, error_size, archive_error_string(reader));
    archive_read_free(reader); close(root); return result;
}
