/* The KayaTx cap probe, run by tools/check-c-bounds.sh.
 *
 * Built TWICE — against bindings/c/kaya_wire.h as it stands, and against
 * the PRE-CAP header spliced out of git with -DKAYA_TX_PRE_CAP — so the
 * negative is the shipped bug itself rather than a hand-written imitation.
 *
 * THE BUFFER IS WALLED: `walled()` hands back exactly `cap` writable bytes
 * whose NEXT byte is an unmapped page, so a write one byte past cap is a
 * fault and not a heuristic. AddressSanitizer would be the obvious tool and
 * cannot serve on this host — an -fsanitize=address binary with no error in
 * it hangs before main (docs/traps.md) — and the wall is the better proof
 * anyway: byte-exact, no runtime, and the linux lane can run it too. */

#include <kaya.h>
#include <kaya_wire.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* Exactly `cap` writable bytes, the byte after them unmapped. */
static uint8_t *walled(size_t cap) {
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0 || cap > (size_t)page) {
        fprintf(stderr, "probe: cap %zu does not fit one %ld-byte page\n", cap, page);
        exit(2);
    }
    size_t span = (size_t)page * 2;
    uint8_t *base = mmap(NULL, span, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (base == MAP_FAILED) {
        perror("probe: mmap");
        exit(2);
    }
    if (mprotect(base + page, (size_t)page, PROT_NONE) != 0) {
        perror("probe: mprotect");
        exit(2);
    }
    return base + (size_t)page - cap;
}

static KayaTx tx_over(uint8_t *buf, size_t cap) {
    KayaTx tx;
    tx.buf = buf;
    tx.len = 0;
#ifndef KAYA_TX_PRE_CAP
    tx.cap = cap;
#else
    (void)cap;
#endif
    return tx;
}

/* Every packer the encode path has, once: begin/end, u32, u64, pad (the
 * 13-byte string), values (a key path and a field list), variant_schemas,
 * and a value of all five tags. What a guest emits is some sequence of
 * these, so bytes identical here are bytes identical for every guest. */
static void repertoire(KayaTx *tx) {
    const uint32_t tags[] = {KAYA_VALUE_STR, KAYA_VALUE_BOOL};
    KayaVariantSchema variants[1];
    variants[0].tags = tags;
    variants[0].len = 2;

    kaya_tx_create_signal(tx, 1, kaya_str("thirteen byte"));
    kaya_tx_write_signal(tx, 1, kaya_i64(-7));
    kaya_tx_write_signal(tx, 2, kaya_f64(1.5));
    kaya_tx_write_signal(tx, 3, kaya_bool(1));
    kaya_tx_write_signal(tx, 4, kaya_blob(99));
    kaya_tx_create_widget(tx, 5, KAYA_KIND_LABEL);
    kaya_tx_set_text(tx, 5, "odd");
    kaya_tx_add_child(tx, 5, 6);
    kaya_tx_mount(tx, 0, 5);
    kaya_tx_create_collection(tx, 7, variants, 1);
    KayaVal path[] = {kaya_str("g2")};
    KayaVal fields[] = {kaya_str("water plants"), kaya_bool(0)};
    kaya_tx_collection_insert(tx, 7, path, 1, kaya_str("a"), 0, fields, 2);
}

static void hexdump(const uint8_t *buf, size_t len) {
    for (size_t i = 0; i < len; i++)
        printf("%02x", buf[i]);
    printf("\n");
}

/* A record that cannot fit: 200 bytes of text into a 64-byte transaction. */
static void one_big_record(KayaTx *tx) {
    char big[201];
    memset(big, 'x', sizeof big - 1);
    big[sizeof big - 1] = '\0';
    kaya_tx_write_signal(tx, 1, kaya_str(big));
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "";

    /* The whole repertoire into a buffer that fits it, hexdumped. The gate
     * compares this line across the two headers: a caller who sized right
     * gets the bytes the pre-cap header wrote, to the byte. */
    if (strcmp(mode, "bytes") == 0) {
        uint8_t buf[4096];
        KayaTx tx = tx_over(buf, sizeof buf);
        repertoire(&tx);
        hexdump(tx.buf, tx.len);
        return 0;
    }

    /* THE SAME REPERTOIRE, WALLED at its own exact size. Nothing here
     * overflows, so this is the clause that would catch a fits() check
     * that is off by a byte in the SAFE direction. */
    if (strcmp(mode, "exact") == 0) {
        uint8_t sized[4096];
        KayaTx measure = tx_over(sized, sizeof sized);
        repertoire(&measure);
        size_t need = measure.len;
        uint8_t *wall = walled(need);
        KayaTx tx = tx_over(wall, need);
        repertoire(&tx);
        printf("exact len=%zu\n", tx.len);
        hexdump(tx.buf, tx.len);
        return 0;
    }

    /* One record too big for a walled 64-byte buffer. The pre-cap header
     * writes past the wall and dies of the signal; this one refuses. */
    if (strcmp(mode, "overflow") == 0) {
        uint8_t *wall = walled(64);
        KayaTx tx = tx_over(wall, 64);
        one_big_record(&tx);
        printf("overflow len=%zu\n", tx.len);
#ifndef KAYA_TX_PRE_CAP
        printf("overflow ok=%d\n", kaya_tx_ok(&tx));
#endif
        return 0;
    }

    /* Three 24-byte records into a walled 24 bytes: the first fits to
     * the byte and the second runs off the end through the SMALL
     * packers. Which packer takes the fault is the point — `overflow`
     * exercises the string arm, this one the u64 and the two u32s, so a
     * check removed from any of them has a mode that catches it. */
    if (strcmp(mode, "many") == 0) {
        uint8_t *wall = walled(24);
        KayaTx tx = tx_over(wall, 24);
        for (int i = 0; i < 3; i++)
            kaya_tx_create_widget(&tx, (uint64_t)i + 1, KAYA_KIND_LABEL);
        printf("many len=%zu\n", tx.len);
#ifndef KAYA_TX_PRE_CAP
        printf("many ok=%d\n", kaya_tx_ok(&tx));
#endif
        return 0;
    }

    /* Cap 4: the 8-byte record header does not itself fit, which is the
     * refusal's OTHER branch — the one that cannot name a kind because
     * nothing wrote one down. */
    if (strcmp(mode, "header") == 0) {
        uint8_t *wall = walled(4);
        KayaTx tx = tx_over(wall, 4);
        kaya_tx_mount(&tx, 0, 5);
        printf("header len=%zu\n", tx.len);
        return 0;
    }

#ifndef KAYA_TX_PRE_CAP
    /* GROW AND RETRY, the reason the refusal is a refusal: build into a
     * buffer that cannot hold it, grow to the len it reported, build again,
     * and get the bytes a big-enough buffer would have given. */
    if (strcmp(mode, "retry") == 0) {
        size_t cap = 64;
        uint8_t *heap = malloc(cap);
        KayaTx tx = tx_over(heap, cap);
        repertoire(&tx);
        if (kaya_tx_ok(&tx)) {
            fprintf(stderr, "probe: 64 bytes held the repertoire — retry proves nothing\n");
            return 2;
        }
        printf("retry first=%zu cap=%zu\n", tx.len, cap);
        cap = tx.len;
        heap = realloc(heap, cap);
        KayaTx grown = tx_over(heap, cap);
        repertoire(&grown);
        printf("retry second=%zu ok=%d\n", grown.len, kaya_tx_ok(&grown));
        hexdump(grown.buf, grown.len);
        free(heap);
        return 0;
    }

    /* The transaction stays usable: a record that fits after one that did
     * not is still refused, because len never comes back under cap. */
    if (strcmp(mode, "sticky") == 0) {
        uint8_t *wall = walled(64);
        KayaTx tx = tx_over(wall, 64);
        one_big_record(&tx);
        size_t after = tx.len;
        kaya_tx_mount(&tx, 0, 5);
        printf("sticky after=%zu final=%zu ok=%d\n", after, tx.len, kaya_tx_ok(&tx));
        return 0;
    }
#endif

    fprintf(stderr, "probe: unknown mode \"%s\"\n", mode);
    return 2;
}
