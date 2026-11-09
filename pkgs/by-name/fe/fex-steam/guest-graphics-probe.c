/* SPDX-License-Identifier: MIT */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef GUEST_BITS
#error GUEST_BITS must describe the compiled ELF
#endif

int main(int argc, char **argv) {
  const char *names[] = {
      "MESA_LOADER_DRIVER_OVERRIDE", "GALLIUM_DRIVER", "LIBGL_KOPPER_DISABLE"};
  const char *defaults[] = {"zink", "zink", "0"};
  const int native = argc > 1 && strcmp(argv[1], "--native") == 0;
  for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
    const char *actual = getenv(names[i]);
    const char *expected = GUEST_BITS == 64 && !native ? defaults[i] : NULL;
    if ((expected && (!actual || strcmp(actual, expected) != 0)) ||
        (!expected && actual)) {
      fprintf(stderr, "ELF%d: %s=%s, expected %s\n", GUEST_BITS, names[i],
              actual ? actual : "<unset>", expected ? expected : "<unset>");
      return 1;
    }
  }
  printf("ELF%d guest graphics: %s\n", GUEST_BITS,
         GUEST_BITS == 64 && !native ? "automatic Zink" : "native baseline");
  fflush(stdout);
  if (argc > 2 && strcmp(argv[1], "--exec") == 0) {
    execv(argv[2], &argv[2]);
    perror("execv");
    return 1;
  }
  return 0;
}
