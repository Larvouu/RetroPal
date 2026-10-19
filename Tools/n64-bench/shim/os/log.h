// os_log for the host build of N64VulkanFrontend: printed to stderr, with
// Apple's %{public}s privacy annotations turned back into plain %s.
#pragma once
#include <cstdio>
#include <cstring>
#include <string>
#pragma GCC diagnostic ignored "-Wformat-security"
typedef int os_log_t;
static inline os_log_t os_log_create(const char *, const char *) { return 0; }
#define os_log_error(log, fmt, ...) do { (void)(log); \
    std::string _f(fmt); size_t _p; \
    while ((_p = _f.find("%{public}")) != std::string::npos) _f.erase(_p + 1, 8); \
    fprintf(stderr, "[os_log] "); fprintf(stderr, _f.c_str(), ##__VA_ARGS__); fprintf(stderr, "\n"); } while (0)
