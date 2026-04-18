#include <stdlib.h>
#include <stdio.h>
#include "scheme.h"
#include "petite_boot.h"
#include "anchorc_boot.h"

int main(int argc, const char *argv[]) {
    setenv("_ANCHORC_ARGV0", argv[0], 1);

    Sscheme_init(NULL);

    Sregister_boot_file_bytes("petite.boot",  (void *)petite_boot,  (iptr)petite_boot_len);
    Sregister_boot_file_bytes("anchorc.boot", (void *)anchorc_boot, (iptr)anchorc_boot_len);

    Sbuild_heap(NULL, NULL);

    Sscheme_start(argc, argv);

    Sscheme_deinit();
    return 0;
}
