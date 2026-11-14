/* Security.framework behind keychain.h. The deprecated keychain calls are used only
 * because they are the only way to name a keychain file. */
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include "keychain.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdlib.h>
#include <string.h>

/* Returns 0, or -OSStatus when the keychain file cannot be opened. */
static int open_keychain(const char *path, SecKeychainRef *out) {
    *out = NULL;
    if (path == NULL) {
        return 0;
    }
    OSStatus status = SecKeychainOpen(path, out);
    return status == errSecSuccess ? 0 : -(int)status;
}

/* A query for one generic-password item. The caller releases it. NULL on failure. */
static CFMutableDictionaryRef new_query(const char *service, const char *account) {
    CFStringRef service_ref = CFStringCreateWithCString(NULL, service, kCFStringEncodingUTF8);
    CFStringRef account_ref = CFStringCreateWithCString(NULL, account, kCFStringEncodingUTF8);
    CFMutableDictionaryRef query = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (service_ref == NULL || account_ref == NULL || query == NULL) {
        if (service_ref) CFRelease(service_ref);
        if (account_ref) CFRelease(account_ref);
        if (query) CFRelease(query);
        return NULL;
    }
    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, service_ref);
    CFDictionarySetValue(query, kSecAttrAccount, account_ref);
    CFRelease(service_ref);
    CFRelease(account_ref);
    return query;
}

/* Adds the keychain to a query's search list. The caller releases the returned array. */
static CFArrayRef search_list_for(SecKeychainRef keychain, CFMutableDictionaryRef query) {
    const void *values[1] = { keychain };
    CFArrayRef list = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    if (list) {
        CFDictionarySetValue(query, kSecMatchSearchList, list);
    }
    return list;
}

static int status_result(OSStatus status) {
    if (status == errSecSuccess) return 0;
    if (status == errSecItemNotFound) return 1;
    return -(int)status;
}

int thysql_keychain_get(const char *keychain_path, const char *service, const char *account,
                        char **out_password, size_t *out_len) {
    *out_password = NULL;
    *out_len = 0;
    SecKeychainRef keychain = NULL;
    int rc = open_keychain(keychain_path, &keychain);
    if (rc != 0) {
        return rc;
    }

    CFMutableDictionaryRef query = new_query(service, account);
    if (query == NULL) {
        if (keychain) CFRelease(keychain);
        return -(int)errSecAllocate;
    }
    CFArrayRef list = keychain ? search_list_for(keychain, query) : NULL;
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);

    CFTypeRef result = NULL;
    rc = status_result(SecItemCopyMatching(query, &result));
    if (rc == 0) {
        CFIndex length = CFDataGetLength((CFDataRef)result);
        char *buffer = malloc((size_t)length + 1);
        if (buffer == NULL) {
            rc = -(int)errSecAllocate;
        } else {
            memcpy(buffer, CFDataGetBytePtr((CFDataRef)result), (size_t)length);
            buffer[length] = '\0';
            *out_password = buffer;
            *out_len = (size_t)length;
        }
    }

    if (result) CFRelease(result);
    if (list) CFRelease(list);
    CFRelease(query);
    if (keychain) CFRelease(keychain);
    return rc;
}

int thysql_keychain_set(const char *keychain_path, const char *service, const char *account,
                        const char *password, size_t len) {
    SecKeychainRef keychain = NULL;
    int rc = open_keychain(keychain_path, &keychain);
    if (rc != 0) {
        return rc;
    }

    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)password, (CFIndex)len);
    CFMutableDictionaryRef add = new_query(service, account);
    if (data == NULL || add == NULL) {
        if (data) CFRelease(data);
        if (add) CFRelease(add);
        if (keychain) CFRelease(keychain);
        return -(int)errSecAllocate;
    }
    CFDictionarySetValue(add, kSecValueData, data);
    if (keychain) {
        CFDictionarySetValue(add, kSecUseKeychain, keychain);
    }

    OSStatus status = SecItemAdd(add, NULL);
    if (status == errSecDuplicateItem) {
        // The item exists, so only its password changes.
        CFMutableDictionaryRef query = new_query(service, account);
        CFMutableDictionaryRef update = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (query != NULL && update != NULL) {
            CFArrayRef list = keychain ? search_list_for(keychain, query) : NULL;
            CFDictionarySetValue(update, kSecValueData, data);
            status = SecItemUpdate(query, update);
            if (list) CFRelease(list);
        }
        if (query) CFRelease(query);
        if (update) CFRelease(update);
    }

    rc = status_result(status);
    CFRelease(add);
    CFRelease(data);
    if (keychain) CFRelease(keychain);
    return rc;
}

int thysql_keychain_delete(const char *keychain_path, const char *service, const char *account) {
    SecKeychainRef keychain = NULL;
    int rc = open_keychain(keychain_path, &keychain);
    if (rc != 0) {
        return rc;
    }

    CFMutableDictionaryRef query = new_query(service, account);
    if (query == NULL) {
        if (keychain) CFRelease(keychain);
        return -(int)errSecAllocate;
    }
    CFArrayRef list = keychain ? search_list_for(keychain, query) : NULL;
    rc = status_result(SecItemDelete(query));

    if (list) CFRelease(list);
    CFRelease(query);
    if (keychain) CFRelease(keychain);
    return rc;
}

void thysql_keychain_free(char *password, size_t len) {
    if (password == NULL) {
        return;
    }
    /* A volatile pointer keeps the compiler from dropping the zeroing as dead stores. */
    volatile unsigned char *bytes = (volatile unsigned char *)password;
    for (size_t i = 0; i < len + 1; i++) {
        bytes[i] = 0;
    }
    free(password);
}

char *thysql_keychain_error_message(int status) {
    CFStringRef message = SecCopyErrorMessageString((OSStatus)-status, NULL);
    if (message == NULL) {
        return NULL;
    }
    CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(message), kCFStringEncodingUTF8) + 1;
    char *buffer = malloc((size_t)size);
    if (buffer != NULL && !CFStringGetCString(message, buffer, size, kCFStringEncodingUTF8)) {
        free(buffer);
        buffer = NULL;
    }
    CFRelease(message);
    return buffer;
}
