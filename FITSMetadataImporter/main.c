// FITS Spotlight metadata importer (legacy CFPlugIn .mdimporter).
//
// The modern CSImportExtension (com.apple.spotlight.import) is non-functional
// on this macOS, so this is the classic Metadata.framework MDImporter plugin:
// a CoreFoundation COM plug-in exposing a single ImporterImportData entry.
//
// Plugin type UUID : 8B08C4BF-415B-11D8-B3F9-0003936726FC
// Interface UUID   : 6EBC27C4-899C-11D8-849E-0003936726FC

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreServices/CoreServices.h>

#include "fits_header.h"

// ---------------------------------------------------------------------------
// The importer proper: fill `attributes` from the FITS file at `pathToFile`.
// ---------------------------------------------------------------------------

static void set_str(CFMutableDictionaryRef d, CFStringRef key, const char *s) {
    if (!s || !*s) return;
    CFStringRef v = CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8);
    if (v) { CFDictionarySetValue(d, key, v); CFRelease(v); }
}

static void set_num_double(CFMutableDictionaryRef d, CFStringRef key, double v) {
    CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &v);
    if (n) { CFDictionarySetValue(d, key, n); CFRelease(n); }
}

static void set_num_long(CFMutableDictionaryRef d, CFStringRef key, long v) {
    CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberLongType, &v);
    if (n) { CFDictionarySetValue(d, key, n); CFRelease(n); }
}

// Append a non-empty C string to a Keywords array.
static void kw_add(CFMutableArrayRef arr, const char *s) {
    if (!s || !*s) return;
    CFStringRef v = CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8);
    if (v) { CFArrayAppendValue(arr, v); CFRelease(v); }
}

// Parse a FITS DATE-OBS / T_OBS string ("YYYY-MM-DDTHH:MM:SS[.sss][Z]") into a
// CFDate. Returns NULL on failure. Treated as UTC (FITS times are UTC).
static CFDateRef make_date(const char *s) {
    if (!s || !*s) return NULL;
    int y = 0, mo = 0, da = 0, h = 0, mi = 0;
    double sec = 0.0;
    int n = sscanf(s, "%d-%d-%dT%d:%d:%lf", &y, &mo, &da, &h, &mi, &sec);
    if (n < 3) return NULL;
    CFGregorianDate g;
    g.year = y; g.month = (SInt8)mo; g.day = (SInt8)da;
    g.hour = (SInt8)h; g.minute = (SInt8)mi; g.second = sec;
    CFTimeZoneRef utc = CFTimeZoneCreateWithTimeIntervalFromGMT(kCFAllocatorDefault, 0.0);
    CFAbsoluteTime at = CFGregorianDateGetAbsoluteTime(g, utc);
    if (utc) CFRelease(utc);
    return CFDateCreate(kCFAllocatorDefault, at);
}

static Boolean GetMetadataForFile(void *thisInstance,
                                  CFMutableDictionaryRef attributes,
                                  CFStringRef contentTypeUTI,
                                  CFStringRef pathToFile) {
    (void)thisInstance; (void)contentTypeUTI;
    if (!pathToFile) return FALSE;

    char path[PATH_MAX];
    if (!CFStringGetCString(pathToFile, path, sizeof path, kCFStringEncodingUTF8))
        return FALSE;

    fits_meta m;
    if (fits_read_meta(path, &m) != 0) return FALSE;

    // ---- standard Spotlight attributes ----
    if (m.has_dims) {
        set_num_long(attributes, kMDItemPixelWidth,  m.width);
        set_num_long(attributes, kMDItemPixelHeight, m.height);
    }
    if (m.has_telescop) set_str(attributes, kMDItemAcquisitionMake,  m.telescop);
    if (m.has_instrume) set_str(attributes, kMDItemAcquisitionModel, m.instrume);
    if (m.has_exptime)  set_num_double(attributes, kMDItemExposureTimeSeconds, m.exptime);
    if (m.has_bitpix)   set_num_long(attributes, kMDItemBitsPerSample,
                                     (m.bitpix < 0 ? -m.bitpix : m.bitpix));

    CFDateRef date = m.has_dateobs ? make_date(m.dateobs)
                   : (m.has_tobs   ? make_date(m.tobs) : NULL);
    if (date) {
        CFDictionarySetValue(attributes, kMDItemContentCreationDate, date);
    }

    // ---- Title: OBJECT, else "<TELESCOP> <WAVELNTH><WAVEUNIT>" ----
    if (m.has_object) {
        set_str(attributes, kMDItemTitle, m.object);
    } else if (m.has_telescop || m.has_wavelnth) {
        char title[160];
        char wl[64] = "";
        if (m.has_wavelnth) {
            if (m.wavelnth == (long)m.wavelnth)
                snprintf(wl, sizeof wl, "%ld%s", (long)m.wavelnth,
                         m.has_waveunit ? m.waveunit : "");
            else
                snprintf(wl, sizeof wl, "%g%s", m.wavelnth,
                         m.has_waveunit ? m.waveunit : "");
        }
        snprintf(title, sizeof title, "%s%s%s",
                 m.has_telescop ? m.telescop : "",
                 (m.has_telescop && wl[0]) ? " " : "", wl);
        set_str(attributes, kMDItemTitle, title);
    }

    // ---- Keywords: a compact science summary, since Keywords is the one
    // metadata row Finder still renders in Get Info (custom displayattrs are no
    // longer honored on macOS 26). Tokens: telescope · instrument · detector ·
    // wavelength · observation time · exposure. All Spotlight-searchable.
    {
        CFMutableArrayRef kws = CFArrayCreateMutable(kCFAllocatorDefault, 8, &kCFTypeArrayCallBacks);
        if (m.has_telescop) kw_add(kws, m.telescop);
        if (m.has_instrume) kw_add(kws, m.instrume);
        if (m.has_detector) kw_add(kws, m.detector);
        if (m.has_wavelnth) {
            char wl[80];
            if (m.wavelnth == (long)m.wavelnth) snprintf(wl, sizeof wl, "%ld", (long)m.wavelnth);
            else                                snprintf(wl, sizeof wl, "%g", m.wavelnth);
            if (m.has_waveunit && m.waveunit[0]) {
                size_t n = strlen(wl);
                snprintf(wl + n, sizeof wl - n, " %s", m.waveunit);
            }
            kw_add(kws, wl);
        }
        if (m.has_dateobs) kw_add(kws, m.dateobs);        // e.g. 2013-01-01T00:00:11.34
        if (m.has_exptime) {
            char ex[48];
            snprintf(ex, sizeof ex, "exp %g s", m.exptime);
            kw_add(kws, ex);
        }
        if (CFArrayGetCount(kws) > 0) CFDictionarySetValue(attributes, kMDItemKeywords, kws);
        CFRelease(kws);
    }

    // ---- one-line description ----
    {
        char desc[512];
        char dims[48] = "";
        if (m.has_dims) snprintf(dims, sizeof dims, "%ldx%ld", m.width, m.height);
        snprintf(desc, sizeof desc,
                 "FITS image%s%s%s%s%s%s, %d HDU%s",
                 dims[0] ? " " : "", dims,
                 m.has_telescop ? " from " : "", m.has_telescop ? m.telescop : "",
                 m.has_dateobs ? " at " : "", m.has_dateobs ? m.dateobs : "",
                 m.nhdus, m.nhdus == 1 ? "" : "s");
        set_str(attributes, kMDItemDescription, desc);
    }

    // ---- custom com_gillyspace27_fits_* attributes ----
    if (m.has_wavelnth) set_num_double(attributes, CFSTR("com_gillyspace27_fits_wavelnth"), m.wavelnth);
    if (m.has_instrume) set_str(attributes, CFSTR("com_gillyspace27_fits_instrume"), m.instrume);
    if (m.has_telescop) set_str(attributes, CFSTR("com_gillyspace27_fits_telescop"), m.telescop);
    if (date)           CFDictionarySetValue(attributes, CFSTR("com_gillyspace27_fits_dateobs"), date);
    if (m.has_exptime)  set_num_double(attributes, CFSTR("com_gillyspace27_fits_exptime"), m.exptime);
    set_num_long(attributes, CFSTR("com_gillyspace27_fits_nhdus"), m.nhdus);

    if (date) CFRelease(date);
    return TRUE;
}

// ---------------------------------------------------------------------------
// CFPlugIn COM boilerplate (classic MDImporter template).
// ---------------------------------------------------------------------------

#define PLUGIN_ID    "8B08C4BF-415B-11D8-B3F9-0003936726FC"
#define INTERFACE_ID "6EBC27C4-899C-11D8-849E-0003936726FC"

// MDImporterInterfaceStruct is declared by MDImporter.h (IUNKNOWN_C_GUTS +
// ImporterImportData); do not redefine it.

typedef struct __MDImporterPluginType {
    MDImporterInterfaceStruct *conduitInterface;
    CFUUIDRef factoryID;
    UInt32 refCount;
} MDImporterPluginType;

static MDImporterPluginType *AllocMDImporterPluginType(CFUUIDRef inFactoryID);
static void DeallocMDImporterPluginType(MDImporterPluginType *thisInstance);
static HRESULT MDImporterQueryInterface(void *thisInstance, REFIID iid, LPVOID *ppv);
static ULONG MDImporterAddRef(void *thisInstance);
static ULONG MDImporterRelease(void *thisInstance);

static MDImporterInterfaceStruct testInterfaceFtbl = {
    NULL,                        // _reserved
    MDImporterQueryInterface,
    MDImporterAddRef,
    MDImporterRelease,
    GetMetadataForFile
};

static MDImporterPluginType *AllocMDImporterPluginType(CFUUIDRef inFactoryID) {
    MDImporterPluginType *self = (MDImporterPluginType *)malloc(sizeof(MDImporterPluginType));
    self->conduitInterface = &testInterfaceFtbl;
    self->factoryID = (CFUUIDRef)CFRetain(inFactoryID);
    CFPlugInAddInstanceForFactory(inFactoryID);
    self->refCount = 1;
    return self;
}

static void DeallocMDImporterPluginType(MDImporterPluginType *thisInstance) {
    CFUUIDRef theFactoryID = thisInstance->factoryID;
    free(thisInstance);
    if (theFactoryID) {
        CFPlugInRemoveInstanceForFactory(theFactoryID);
        CFRelease(theFactoryID);
    }
}

static HRESULT MDImporterQueryInterface(void *thisInstance, REFIID iid, LPVOID *ppv) {
    CFUUIDRef interfaceID = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, iid);
    MDImporterPluginType *o = (MDImporterPluginType *)thisInstance;
    if (CFEqual(interfaceID, kMDImporterInterfaceID) ||
        CFEqual(interfaceID, IUnknownUUID)) {
        o->conduitInterface->AddRef(thisInstance);
        *ppv = thisInstance;
        CFRelease(interfaceID);
        return S_OK;
    }
    *ppv = NULL;
    CFRelease(interfaceID);
    return E_NOINTERFACE;
}

static ULONG MDImporterAddRef(void *thisInstance) {
    ((MDImporterPluginType *)thisInstance)->refCount += 1;
    return ((MDImporterPluginType *)thisInstance)->refCount;
}

static ULONG MDImporterRelease(void *thisInstance) {
    MDImporterPluginType *o = (MDImporterPluginType *)thisInstance;
    o->refCount -= 1;
    if (o->refCount == 0) {
        DeallocMDImporterPluginType(o);
        return 0;
    }
    return o->refCount;
}

// The exported factory. Name must match CFPlugInFactories in Info.plist.
void *FITSImporterPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeID);
void *FITSImporterPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeID) {
    (void)allocator;
    if (CFEqual(typeID, kMDImporterTypeID)) {
        CFUUIDRef uuid = CFUUIDCreateFromString(kCFAllocatorDefault, CFSTR(PLUGIN_ID));
        MDImporterPluginType *result = AllocMDImporterPluginType(uuid);
        CFRelease(uuid);
        return result;
    }
    return NULL;
}
