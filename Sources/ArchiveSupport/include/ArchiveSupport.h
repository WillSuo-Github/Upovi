#ifndef UPOVI_ARCHIVE_SUPPORT_H
#define UPOVI_ARCHIVE_SUPPORT_H
#include <stddef.h>
int upovi_extract_zip(const char *source, const char *destination, char *error, size_t error_size, int (*cancelled)(void));
#endif
