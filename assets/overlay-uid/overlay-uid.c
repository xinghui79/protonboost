/* Preloaded into a Steam game run in a session's network namespace, where the
 * user is root: Steam's overlay names what it shares with the Steam client
 * after getuid(), so it answers the overlay with the user the client runs as.
 * Every other caller, Wine among them, gets the real uid. */
#define _GNU_SOURCE
#include <link.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static uintptr_t overlay_start, overlay_end;

static int find_overlay(struct dl_phdr_info *info, size_t size, void *data)
{
    const char *name = info->dlpi_name;
    uintptr_t start = UINTPTR_MAX, end = 0;
    int i;

    (void)size;
    (void)data;
    if (!name || !strstr(name, "/gameoverlayrenderer.so"))
        return 0;
    for (i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *phdr = &info->dlpi_phdr[i];
        if (phdr->p_type != PT_LOAD)
            continue;
        if (info->dlpi_addr + phdr->p_vaddr < start)
            start = info->dlpi_addr + phdr->p_vaddr;
        if (info->dlpi_addr + phdr->p_vaddr + phdr->p_memsz > end)
            end = info->dlpi_addr + phdr->p_vaddr + phdr->p_memsz;
    }
    if (end) {
        overlay_start = start;
        overlay_end = end;
    }
    return 1;
}

static long overlay_uid(void)
{
    const char *value = getenv("WINRUN_OVERLAY_UID");
    long uid = 0;

    if (!value || !*value)
        return -1;
    for (; *value; value++) {
        if (*value < '0' || *value > '9')
            return -1;
        uid = uid * 10 + (*value - '0');
    }
    return uid;
}

uid_t getuid(void)
{
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    long uid;

    if (!overlay_end)
        dl_iterate_phdr(find_overlay, NULL);
    if (caller >= overlay_start && caller < overlay_end && (uid = overlay_uid()) >= 0)
        return (uid_t)uid;
    return (uid_t)syscall(SYS_getuid);
}
