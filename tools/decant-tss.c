// decant-tss: ask Apple's signing server (TSS) for a ticket and save it as an .shsh2 blob, using libtatsu,
// the current TSS library behind idevicerestore. Replaces tsschecker, whose request format Apple stopped
// accepting for iOS 27. Nothing here touches the phone; it only needs identifiers read from it.
//
//   decant-tss --manifest BuildManifest.plist --board D84AP --ecid 1787668751007772 \
//              [--generator 0x1111111111111111 | --apnonce <hex>] [--bbsnum <hex> --bbcert <int>] \
//              [--update] --out blob.shsh2
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <ctype.h>
#include <plist/plist.h>
#include <libtatsu/tss.h>
#include <CommonCrypto/CommonDigest.h>
#include <Security/SecRandom.h>

static void die(const char *msg) { fprintf(stderr, "error: %s\n", msg); exit(1); }

static int hex2bin(const char *hex, unsigned char *out, size_t max) {
    if (!strncasecmp(hex, "0x", 2)) hex += 2;
    size_t n = strlen(hex);
    if (n % 2 || n / 2 > max) return -1;
    for (size_t i = 0; i < n / 2; i++) { unsigned v; if (sscanf(hex + 2 * i, "%2x", &v) != 1) return -1; out[i] = (unsigned char)v; }
    return (int)(n / 2);
}

static plist_t find_identity(plist_t manifest, const char *board, const char *behavior) {
    plist_t ids = plist_dict_get_item(manifest, "BuildIdentities");
    uint32_t n = plist_array_get_size(ids);
    for (uint32_t i = 0; i < n; i++) {
        plist_t bi = plist_array_get_item(ids, i);
        plist_t info = plist_dict_get_item(bi, "Info");
        char *dc = NULL, *rb = NULL;
        plist_get_string_val(plist_dict_get_item(info, "DeviceClass"), &dc);
        plist_get_string_val(plist_dict_get_item(info, "RestoreBehavior"), &rb);
        int match = dc && rb && !strcasecmp(dc, board) && !strcasecmp(rb, behavior);
        free(dc); free(rb);
        if (match) return bi;
    }
    return NULL;
}

int main(int argc, char **argv) {
    const char *manifest_path = NULL, *board = NULL, *generator = NULL, *apnonce = NULL, *bbsnum = NULL, *out = NULL;
    uint64_t ecid = 0, bbcert = 0; int update = 0, debug = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--manifest") && i + 1 < argc) manifest_path = argv[++i];
        else if (!strcmp(argv[i], "--board") && i + 1 < argc) board = argv[++i];
        else if (!strcmp(argv[i], "--ecid") && i + 1 < argc) ecid = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--generator") && i + 1 < argc) generator = argv[++i];
        else if (!strcmp(argv[i], "--apnonce") && i + 1 < argc) apnonce = argv[++i];
        else if (!strcmp(argv[i], "--bbsnum") && i + 1 < argc) bbsnum = argv[++i];
        else if (!strcmp(argv[i], "--bbcert") && i + 1 < argc) bbcert = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--out") && i + 1 < argc) out = argv[++i];
        else if (!strcmp(argv[i], "--update")) update = 1;
        else if (!strcmp(argv[i], "--debug")) debug = 1;
        else { fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
    }
    if (!manifest_path || !board || !ecid || !out) die("need --manifest, --board, --ecid and --out");
    { FILE *f = fopen(out, "rb"); if (f) { fclose(f); die("refusing to overwrite an existing blob"); } }   /* a saved blob is irreplaceable */
    if (debug) tss_set_debug_level(1);

    plist_t manifest = NULL;
    if (plist_read_from_file(manifest_path, &manifest, NULL) != PLIST_ERR_SUCCESS || !manifest) die("cannot read the BuildManifest");
    plist_t identity = find_identity(manifest, board, update ? "Update" : "Erase");
    if (!identity) die("no build identity for that board in the manifest");

    // ApNonce: given, or derived from the generator the way A12+ chips do (SHA-384 of the 8 bytes, first 32).
    unsigned char nonce[32]; int nonce_len = 0;
    if (apnonce) { nonce_len = hex2bin(apnonce, nonce, sizeof nonce); if (nonce_len <= 0) die("bad --apnonce"); }
    else if (generator) {
        unsigned char gen[8]; if (hex2bin(generator, gen, sizeof gen) != 8) die("generator must be 8 bytes, like 0x1111111111111111");
        unsigned char digest[CC_SHA384_DIGEST_LENGTH];
        CC_SHA384(gen, 8, digest);
        memcpy(nonce, digest, 32); nonce_len = 32;
    } else { SecRandomCopyBytes(kSecRandomDefault, 32, nonce); nonce_len = 32; }
    unsigned char sepnonce[20]; SecRandomCopyBytes(kSecRandomDefault, sizeof sepnonce, sepnonce);

    plist_t parameters = plist_new_dict();
    plist_dict_set_item(parameters, "ApECID", plist_new_uint(ecid));
    plist_dict_set_item(parameters, "ApNonce", plist_new_data((const char *)nonce, nonce_len));
    plist_dict_set_item(parameters, "ApSepNonce", plist_new_data((const char *)sepnonce, sizeof sepnonce));
    plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));
    plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
    plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
    tss_parameters_add_from_manifest(parameters, identity, 1);

    plist_t request = tss_request_new(NULL);
    if (tss_request_add_common_tags(request, parameters, NULL) < 0) die("common tags");
    if (tss_request_add_ap_tags(request, parameters, NULL) < 0) die("ap tags");
    if (tss_request_add_ap_img4_tags(request, parameters) < 0) die("img4 tags");

    if (bbsnum && bbcert) {
        unsigned char snum[32]; int sl = hex2bin(bbsnum, snum, sizeof snum); if (sl <= 0) die("bad --bbsnum");
        unsigned char bbnonce[20]; SecRandomCopyBytes(kSecRandomDefault, sizeof bbnonce, bbnonce);
        plist_dict_set_item(parameters, "BbNonce", plist_new_data((const char *)bbnonce, sizeof bbnonce));
        plist_dict_set_item(parameters, "BbGoldCertId", plist_new_uint(bbcert));
        plist_dict_set_item(parameters, "BbSNUM", plist_new_data((const char *)snum, sl));
        if (tss_request_add_baseband_tags(request, parameters, NULL) < 0) die("baseband tags");
    }

    plist_t response = tss_request_send(request, NULL);
    if (!response) { fprintf(stderr, "not signed (the signing server refused the request)\n"); return 3; }

    if (generator) plist_dict_set_item(response, "generator", plist_new_string(generator));
    if (plist_write_to_file(response, out, PLIST_FORMAT_XML, 0) != PLIST_ERR_SUCCESS) die("cannot write the blob");
    unsigned char *ticket = NULL; unsigned int tlen = 0;
    tss_response_get_ap_img4_ticket(response, &ticket, &tlen);
    printf("signed: ticket %u bytes saved to %s\n", tlen, out);
    free(ticket);
    return 0;
}
