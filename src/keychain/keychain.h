/*
 * A small C API over Security.framework's generic-password items, for src/keychain.zig.
 * Only plain C types appear here, so the Zig side does not need CoreFoundation.
 *
 * keychain_path is a keychain file, or NULL for the default search list. Every
 * function that returns int returns 0 on success, 1 when the item is not found, and
 * -OSStatus for any other error. thysql_keychain_error_message takes that same value.
 */
#ifndef THYSQL_KEYCHAIN_H
#define THYSQL_KEYCHAIN_H

#include <stddef.h>

/* Reads the password. On success *out_password holds len bytes plus a NUL. Free it with thysql_keychain_free. */
int thysql_keychain_get(const char *keychain_path, const char *service, const char *account,
                        char **out_password, size_t *out_len);

/* Adds the item, or replaces the password of an existing one. */
int thysql_keychain_set(const char *keychain_path, const char *service, const char *account,
                        const char *password, size_t len);

int thysql_keychain_delete(const char *keychain_path, const char *service, const char *account);

/* Zeroes the password, then frees it. */
void thysql_keychain_free(char *password, size_t len);

/* The text of the error for a status from the calls above, or NULL. Free it with free(). */
char *thysql_keychain_error_message(int status);

#endif
