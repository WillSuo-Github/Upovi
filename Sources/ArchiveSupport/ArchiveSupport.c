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
#include <limits.h>
#include <copyfile.h>

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
/* Apply an AppleDouble blob to an extracted member with copyfile(3), as ditto does. */
static int unpack_onto(const char *target, const void *blob, size_t size) {
    char carrier[PATH_MAX];
    const char *directory = getenv("TMPDIR");
    if (!directory || !*directory) directory = "/tmp";
    size_t length = strlen(directory);
    if (snprintf(carrier, sizeof carrier, "%s%supovi-appledouble-XXXXXX", directory, directory[length - 1] == '/' ? "" : "/") >= (int)sizeof carrier) return -1;
    int file = mkstemp(carrier);
    if (file < 0) return -1;
    size_t offset = 0;
    while (offset < size) {
        ssize_t written = write(file, (const char *)blob + offset, size - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) break;
        offset += (size_t)written;
    }
    close(file);
    /* Parents were opened without following links, so the path names the member that was just extracted. */
    int applied = offset == size ? copyfile(carrier, target, NULL, COPYFILE_UNPACK | COPYFILE_NOFOLLOW | COPYFILE_XATTR) : -1;
    unlink(carrier);
    return applied == 0 ? 0 : -1;
}
/* libarchive folds __MACOSX/ carriers into the main entry's Mac metadata instead of returning them. */
static int apply_mac_metadata(const char *destination, const char *name, struct archive_entry *entry) {
    size_t size = 0;
    const void *blob = archive_entry_mac_metadata(entry, &size);
    if (!blob || !size) return 0;
    if (size > 64u * 1024u * 1024u) return -1;
    char target[PATH_MAX];
    if (snprintf(target, sizeof target, "%s/%s", destination, name) >= (int)sizeof target) return -1;
    for (size_t length = strlen(target); length && target[length - 1] == '/'; ) target[--length] = 0;
    return unpack_onto(target, blob, size);
}
/* Open existing parent directories without creating or following anything. */
static int existing_parent_fd(int root, const char *path, const char **leaf) {
    char *copy = strdup(path);
    if (!copy) return -1;
    int fd = dup(root);
    char *last = strrchr(copy, '/'), *cursor = NULL;
    *leaf = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
    if (last) {
        *last = 0;
        for (char *part = strtok_r(copy, "/", &cursor); fd >= 0 && part; part = strtok_r(NULL, "/", &cursor)) {
            if (!strcmp(part, ".")) continue;
            int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            close(fd); fd = next;
        }
    }
    free(copy); return fd;
}
/* Finder and ditto store extended attributes (including the detached code signatures of non-executable
   bundle files) in AppleDouble "._name" members, inline or under __MACOSX/. Apply one to its extracted
   sibling as ditto does instead of writing it into the bundle, where it would break the seal. */
static int apply_appledouble(int root, const char *destination, const char *logical, const void *blob, size_t size) {
    const char *leaf = NULL;
    int parent = existing_parent_fd(root, logical, &leaf);
    if (parent < 0) return 0; /* The described member is not part of this extraction. */
    struct stat status;
    const char *sibling = leaf + 2;
    int present = *sibling && strcmp(sibling, ".") && strcmp(sibling, "..") && !fstatat(parent, sibling, &status, AT_SYMLINK_NOFOLLOW);
    close(parent);
    if (!present) return 0;
    char target[PATH_MAX];
    size_t prefix = (size_t)(leaf - logical);
    if (snprintf(target, sizeof target, "%s/%.*s%s", destination, (int)prefix, logical, sibling) >= (int)sizeof target) return -1;
    return unpack_onto(target, blob, size);
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
        /* AppleDouble carriers describe other members; they are applied, never written. */
        int sequestered = !strncmp(name, "__MACOSX/", 9) || !strcmp(name, "__MACOSX");
        const char *logical = sequestered ? name + 9 : name;
        const char *base = strrchr(logical, '/') ? strrchr(logical, '/') + 1 : logical;
        if (archive_entry_filetype(entry) == AE_IFREG && !strncmp(base, "._", 2) && archive_entry_size(entry) >= 0
            && archive_entry_size(entry) <= 64 * 1024 * 1024) {
            size_t size = (size_t)archive_entry_size(entry), filled = 0;
            char *blob = malloc(size ? size : 1);
            la_ssize_t count = 0;
            while (blob && filled < size && (count = archive_read_data(reader, blob + filled, size - filled)) > 0) filled += (size_t)count;
            static const unsigned char magic[4] = { 0x00, 0x05, 0x16, 0x07 };
            if (blob && filled == size && size >= 4 && !memcmp(blob, magic, 4)) {
                int applied = apply_appledouble(root, destination, logical, blob, size);
                free(blob);
                if (applied) { result = fail(error, error_size, "Cannot restore archive metadata"); break; }
                continue;
            }
            free(blob);
            if (sequestered && filled == size) continue; /* Other __MACOSX payloads are not needed. */
            /* A non-AppleDouble "._" member would be written into the bundle; refuse it conservatively. */
            result = fail(error, error_size, "Unsupported archive member name"); break;
        }
        if (sequestered) continue;
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
        if (!result && apply_mac_metadata(destination, name, entry)) {
            result = fail(error, error_size, "Cannot restore archive metadata"); break;
        }
        if (result) { fail(error, error_size, "Unsafe archive entry, duplicate member, or extraction failure"); break; }
    }
    if (!result && status != ARCHIVE_EOF) result = fail(error, error_size, archive_error_string(reader));
    archive_read_free(reader); close(root); return result;
}
