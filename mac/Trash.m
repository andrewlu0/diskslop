#import <Foundation/Foundation.h>
#include <string.h>

char *dt_system_trash(const char *path, bool directory) {
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithFileSystemRepresentation:path isDirectory:directory relativeToURL:nil];
        NSError *error = nil;
        if ([[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:&error]) {
            return NULL;
        }
        return strdup(error.localizedDescription.UTF8String ?: "macOS could not move the item to Trash.");
    }
}
