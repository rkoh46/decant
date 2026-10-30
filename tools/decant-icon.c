/* decant-icon: write an app's home-screen icon as PNG using the SpringBoard service.
 * Usage: decant-icon -u UDID BUNDLEID OUT.png [BUNDLEID OUT.png ...]
 * Exit 0 when at least one icon was written. Decant's own code on libimobiledevice (LGPL-2.1). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/sbservices.h>

int main(int argc, char **argv) {
    const char *udid = NULL; int i = 1;
    if (argc > 2 && strcmp(argv[1], "-u") == 0) { udid = argv[2]; i = 3; }
    if (argc - i < 2 || (argc - i) % 2) { fprintf(stderr, "usage: decant-icon [-u UDID] BUNDLEID OUT.png ...\n"); return 2; }
    idevice_t dev = NULL;
    if (idevice_new_with_options(&dev, udid, IDEVICE_LOOKUP_USBMUX | IDEVICE_LOOKUP_NETWORK) != IDEVICE_E_SUCCESS) { fprintf(stderr, "no device\n"); return 1; }
    lockdownd_client_t ld = NULL; lockdownd_service_descriptor_t svc = NULL; sbservices_client_t sb = NULL;
    if (lockdownd_client_new_with_handshake(dev, &ld, "decant-icon") != LOCKDOWN_E_SUCCESS ||
        lockdownd_start_service(ld, SBSERVICES_SERVICE_NAME, &svc) != LOCKDOWN_E_SUCCESS ||
        sbservices_client_new(dev, svc, &sb) != SBSERVICES_E_SUCCESS) { fprintf(stderr, "springboard service unavailable (is the phone unlocked?)\n"); idevice_free(dev); return 1; }
    int written = 0;
    for (; i + 1 < argc; i += 2) {
        char *png = NULL; uint64_t size = 0;
        if (sbservices_get_icon_pngdata(sb, argv[i], &png, &size) == SBSERVICES_E_SUCCESS && png && size > 0) {
            FILE *f = fopen(argv[i + 1], "wb");
            if (f) { fwrite(png, 1, size, f); fclose(f); written++; }
        }
        free(png);
    }
    sbservices_client_free(sb); lockdownd_service_descriptor_free(svc); lockdownd_client_free(ld); idevice_free(dev);
    return written ? 0 : 1;
}
