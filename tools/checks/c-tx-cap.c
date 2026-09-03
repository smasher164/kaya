/* The KayaTx cap probe, run by tools/check-c-bounds.py. Built TWICE —
 * against bindings/c/kaya_wire.h as it stands and against the PRE-CAP
 * header spliced out of git with -DKAYA_TX_PRE_CAP — so the negative is
 * the shipped bug itself. `walled()` hands back exactly `cap` writable
 * bytes with the next byte unmapped, which is the PRIMARY proof; the
 * `heap*` modes are the ASan companion's, on a plain malloc, and only the
 * compiler flake.nix names has an ASan that runs here (docs/traps.md). */

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

/* Every packer the encode path has, once. What a guest emits is some
 * sequence of these, so bytes identical here are identical for every
 * guest. */
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

    /* The whole repertoire into a buffer that fits it, hexdumped: the
     * gate compares this line across the two headers. */
    if (strcmp(mode, "bytes") == 0) {
        uint8_t buf[4096];
        KayaTx tx = tx_over(buf, sizeof buf);
        repertoire(&tx);
        hexdump(tx.buf, tx.len);
        return 0;
    }

    /* THE SAME REPERTOIRE, WALLED at its own exact size: nothing here
     * overflows, so this catches a fits() off by a byte the SAFE way. */
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

    /* Three 24-byte records into a walled 24 bytes. Which packer takes
     * the fault is the point: `overflow` exercises the string arm, this
     * one the u64 and the two u32s. */
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

    /* THE COMPANION'S TWO MODES, on a plain malloc of exactly cap: only
     * a sanitizer attributes the pre-cap overrun — measured 2026-08-27,
     * unsanitized it exits 0 in silence and under the dev shell's
     * hardening it dies of a mute SIGTRAP. ASan only. */
    if (strcmp(mode, "heap") == 0) {
        uint8_t *heap = malloc(64);
        KayaTx tx = tx_over(heap, 64);
        one_big_record(&tx);
        printf("heap len=%zu\n", tx.len);
#ifndef KAYA_TX_PRE_CAP
        printf("heap ok=%d\n", kaya_tx_ok(&tx));
#endif
        free(heap);
        return 0;
    }

    if (strcmp(mode, "heap-many") == 0) {
        uint8_t *heap = malloc(24);
        KayaTx tx = tx_over(heap, 24);
        for (int i = 0; i < 3; i++)
            kaya_tx_create_widget(&tx, (uint64_t)i + 1, KAYA_KIND_LABEL);
        printf("heap-many len=%zu\n", tx.len);
#ifndef KAYA_TX_PRE_CAP
        printf("heap-many ok=%d\n", kaya_tx_ok(&tx));
#endif
        free(heap);
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
    /* GROW AND RETRY, the reason the refusal is a refusal: grow to the
     * len it reported and get the bytes a big-enough buffer would give. */
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
