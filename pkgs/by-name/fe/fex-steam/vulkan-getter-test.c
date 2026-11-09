/* Check a Vulkan 1.2 loader self-lookup without requiring a GPU in the build sandbox. */
#include <dlfcn.h>
#include <stdio.h>

typedef void (*VulkanFunction)(void);
typedef VulkanFunction (*GetInstanceProcAddr)(void *, const char *);
typedef VulkanFunction (*GetDeviceProcAddr)(void *, const char *);

int main(void) {
  void *library = dlopen("libvulkan.so.1", RTLD_NOW);
  if (!library) {
    fprintf(stderr, "dlopen Vulkan thunk: %s\n", dlerror());
    return 1;
  }
  GetInstanceProcAddr getter = (GetInstanceProcAddr)dlsym(library, "vkGetInstanceProcAddr");
  if (!getter || !getter(NULL, "vkGetInstanceProcAddr")) {
    fprintf(stderr, "Vulkan getter self-lookup returned NULL\n");
    return 2;
  }
#ifdef EXPECT_FEX_VULKAN_THUNK
  /* FEX handles these self-lookups before accessing the instance/device.
     Exercise that guest implementation directly, without creating a GPU device. */
  GetDeviceProcAddr device_getter = (GetDeviceProcAddr)getter(NULL, "vkGetDeviceProcAddr");
  if (!device_getter || device_getter(NULL, "vkGetDeviceProcAddr") != (VulkanFunction)device_getter) {
    fprintf(stderr, "FEX device getter self-lookup failed\n");
    return 3;
  }
#endif
  /* FEX/C++ callbacks must remain valid after an application's dlclose and
     during process cleanup. Returning from main exercises the exit handlers. */
  if (dlclose(library)) {
    fprintf(stderr, "Vulkan dlclose failed: %s\n", dlerror());
    return 4;
  }
  return 0;
}
