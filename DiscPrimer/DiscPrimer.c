#include "DiscPrimer.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/scsi/SCSITaskLib.h>
#include <dispatch/dispatch.h>
#include <string.h>

static dispatch_queue_t primerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("CD Explorer disc primer", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

// Walks up from a disc to the drive service that provides the MMC interface.
static io_service_t driveForMedia(io_service_t media) {
    io_registry_entry_t entry = media;
    IOObjectRetain(entry);
    while (entry) {
        if (IOObjectConformsTo(entry, "IOBDServices") || IOObjectConformsTo(entry, "IODVDServices")
            || IOObjectConformsTo(entry, "IOCompactDiscServices")) {
            return entry;
        }
        io_registry_entry_t parent = 0;
        kern_return_t result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent);
        IOObjectRelease(entry);
        entry = result == KERN_SUCCESS ? parent : 0;
    }
    return 0;
}

// Sends READ TRACK INFORMATION for Track 1. Blocks until the drive answers,
// which may be after a slow read already in progress.
static int askAboutTrackOne(io_service_t media) {
    io_service_t drive = driveForMedia(media);
    if (!drive) return 0;
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    MMCDeviceInterface **mmc = NULL;
    int answered = 0;
    if (IOCreatePlugInInterfaceForService(drive, kIOMMCDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
                                          &plugin, &score) == kIOReturnSuccess && plugin) {
        (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOMMCDeviceInterfaceID), (LPVOID *)&mmc);
        if (mmc) {
            unsigned char info[48];
            memset(info, 0, sizeof(info));
            SCSITaskStatus status = kSCSITaskStatus_No_Status;
            SCSI_Sense_Data sense;
            memset(&sense, 0, sizeof(sense));
            // Address type 1: the field holds a track number.
            IOReturn result = (*mmc)->ReadTrackInformation(mmc, 1, 1, info, sizeof(info), &status, &sense);
            answered = result == kIOReturnSuccess && status == kSCSITaskStatus_GOOD;
            (*mmc)->Release(mmc);
        }
        IODestroyPlugInInterface(plugin);
    }
    IOObjectRelease(drive);
    return answered;
}

static void discsAppeared(void *refcon, io_iterator_t iterator) {
    io_object_t media;
    while ((media = IOIteratorNext(iterator))) {
        askAboutTrackOne(media);
        IOObjectRelease(media);
    }
}

void DiscPrimerStartWatching(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        IONotificationPortRef port = IONotificationPortCreate(kIOMainPortDefault);
        IONotificationPortSetDispatchQueue(port, primerQueue());
        io_iterator_t iterator = 0;
        if (IOServiceAddMatchingNotification(port, kIOFirstPublishNotification, IOServiceMatching("IOCDMedia"),
                                             discsAppeared, (void *)1, &iterator) == KERN_SUCCESS) {
            // Arm the notification, priming discs that were inserted before launch.
            dispatch_async(primerQueue(), ^{ discsAppeared(NULL, iterator); });
        }
    });
}

int DiscPrimerInsertedDiscState(void) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOCDMedia"), &iterator) != KERN_SUCCESS) {
        return 0;
    }
    int state = 0;
    io_object_t media;
    while ((media = IOIteratorNext(iterator))) {
        // A disc is ready once IOKit has finished matching it and its slices
        // (busy state zero) and it has been published as a BSD disk.
        uint32_t busy = 1;
        CFTypeRef bsdName = IORegistryEntryCreateCFProperty(media, CFSTR("BSD Name"), kCFAllocatorDefault, 0);
        int ready = IOServiceGetBusyState(media, &busy) == KERN_SUCCESS && busy == 0 && bsdName != NULL;
        if (bsdName) CFRelease(bsdName);
        if (ready) state = 2;
        else if (state == 0) state = 1;
        IOObjectRelease(media);
    }
    IOObjectRelease(iterator);
    return state;
}

unsigned long long DiscPrimerInsertedDiscIdentity(void) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOCDMedia"), &iterator) != KERN_SUCCESS) {
        return 0;
    }
    unsigned long long identity = 0;
    io_object_t media;
    while ((media = IOIteratorNext(iterator))) {
        CFTypeRef toc = IORegistryEntryCreateCFProperty(media, CFSTR("TOC"), kCFAllocatorDefault, 0);
        if (toc && CFGetTypeID(toc) == CFDataGetTypeID() && identity == 0) {
            // FNV-1a over the raw TOC.
            identity = 1469598103934665603ULL;
            const UInt8 *bytes = CFDataGetBytePtr(toc);
            for (CFIndex i = 0; i < CFDataGetLength(toc); i++) identity = (identity ^ bytes[i]) * 1099511628211ULL;
        }
        if (toc) CFRelease(toc);
        IOObjectRelease(media);
    }
    IOObjectRelease(iterator);
    return identity;
}

int DiscPrimerPrimeInsertedDiscs(void) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOCDMedia"), &iterator) != KERN_SUCCESS) {
        return 0;
    }
    int answered = 0;
    io_object_t media;
    while ((media = IOIteratorNext(iterator))) {
        answered += askAboutTrackOne(media);
        IOObjectRelease(media);
    }
    IOObjectRelease(iterator);
    return answered;
}
