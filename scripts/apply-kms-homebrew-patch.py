#!/usr/bin/env python3
"""Adapt upstream's restricted SteamOS KMS helper for Homebrew physical and virtual DRM capture."""

from __future__ import annotations

import pathlib
import sys


def replace_once(path: pathlib.Path, old: str, new: str) -> None:
    source = path.read_text(encoding="utf-8")
    count = source.count(old)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one KMS Homebrew patch target in {path}, found {count}; "
            "upstream changed and needs review."
        )
    path.write_text(source.replace(old, new, 1), encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} UPSTREAM_SOURCE_DIR")

    root = pathlib.Path(sys.argv[1]).resolve()
    protocol = root / "src/platform/linux/kms_capture_protocol.h"
    kmsgrab = root / "src/platform/linux/kmsgrab.cpp"
    helper = root / "packaging/linux/steamos/local/vibeshine-kms-capture.c"
    helper_test = root / "packaging/linux/steamos/tests/test-kms-capture-helper.c"

    for path in (protocol, kmsgrab, helper, helper_test):
        if not path.is_file():
            raise SystemExit(f"Missing upstream KMS source required by Homebrew: {path}")

    replace_once(
        protocol,
        '#define VIBESHINE_KMS_CAPTURE_HELPER "/opt/vibeshine-private-display/current/bin/vibeshine-kms-capture"',
        '#define VIBESHINE_KMS_CAPTURE_HELPER "/var/lib/vibepollo/drm/bin/vibeshine-kms-capture"',
    )

    replace_once(
        kmsgrab,
        """        if (!admin.active()) {
          // The SteamOS host stays capability-free. Only the managed virtual
          // driver can use the separately installed, restricted capture helper.
          if (driver_name != "vibeshine_drm") {
            return -1;
          }
          capture_helper = kms_capture::client_t::open(fd.el);
          if (!capture_helper) {
            BOOST_LOG(error) << "The private display capture helper is unavailable: "sv << strerror(errno);
            return -1;
          }
        }""",
        """        if (!admin.active()) {
          // Keep CAP_SYS_ADMIN out of the network-facing Vibepollo process.
          // The restricted helper handles framebuffer export for physical
          // cards and the presentation ioctls for vibeshine_drm only.
          capture_helper = kms_capture::client_t::open(fd.el);
          if (!capture_helper) {
            BOOST_LOG(error) << "The restricted KMS capture helper is unavailable for "sv
                             << path << ": " << strerror(errno);
            return -1;
          }
        }""",
    )

    replace_once(
        helper,
        """static bool managed_card_path(const char *card_name) {
  struct stat sysfs;
  char path[PATH_MAX], resolved[PATH_MAX];
  return snprintf(path, sizeof(path), "/sys/class/drm/%s", card_name) < (int) sizeof(path) &&
      realpath(path, resolved) &&
      !strncmp(resolved, "/sys/devices/faux/vibeshine/", strlen("/sys/devices/faux/vibeshine/")) &&
      !stat(resolved, &sysfs) && S_ISDIR(sysfs.st_mode) && !sysfs.st_uid;
}

static bool managed_device_identity(int fd, const char *card_name, dev_t device) {
  struct stat opened;
  if (fstat(fd, &opened) || !S_ISCHR(opened.st_mode) || opened.st_uid ||
      opened.st_rdev != device || !managed_card_path(card_name)) return false;
  drmVersionPtr version = drmGetVersion(fd);
  const bool valid = version && version->name && version->name_len == strlen("vibeshine_drm") &&
                     !memcmp(version->name, "vibeshine_drm", version->name_len);
  if (version) drmFreeVersion(version);
  return valid;
}

static int open_managed_device(uint32_t card_major, uint32_t card_minor) {
  const dev_t wanted = makedev(card_major, card_minor);
  if (major(wanted) != card_major || minor(wanted) != card_minor || card_major != 226) {
    errno = EACCES; return -1;
  }
  DIR *directory = opendir("/dev/dri");
  if (!directory) return -1;
  int result = -1;
  struct dirent *entry;
  while ((entry = readdir(directory))) {
    if (!valid_card_name(entry->d_name) || !managed_card_path(entry->d_name)) continue;
    struct stat attributes;
    if (fstatat(dirfd(directory), entry->d_name, &attributes, AT_SYMLINK_NOFOLLOW) ||
        !S_ISCHR(attributes.st_mode) || attributes.st_uid || attributes.st_rdev != wanted) continue;
    int fd = openat(dirfd(directory), entry->d_name, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY);
    if (fd < 0) continue;
    if (!managed_device_identity(fd, entry->d_name, wanted)) { close(fd); continue; }
    if (drmIsMaster(fd)) {
      if (!set_effective(true)) _exit(126);
      const int dropped = drmDropMaster(fd);
      if (!set_effective(false)) _exit(126);
      if (dropped) { close(fd); continue; }
    }
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) ||
        drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1)) { close(fd); continue; }
    result = fd;
    break;
  }
  closedir(directory);
  if (result < 0) errno = EACCES;
  return result;
}""",
        """static bool card_sysfs_path(const char *card_name, char *resolved, size_t resolved_size) {
  struct stat sysfs;
  char path[PATH_MAX];
  static const char sysfs_devices[] = "/sys/devices/";
  if (!resolved || !resolved_size ||
      snprintf(path, sizeof(path), "/sys/class/drm/%s", card_name) >= (int) sizeof(path) ||
      !realpath(path, resolved) || strncmp(resolved, sysfs_devices, sizeof(sysfs_devices) - 1) ||
      stat(resolved, &sysfs) || !S_ISDIR(sysfs.st_mode) || sysfs.st_uid) return false;
  return true;
}

static bool is_vibeshine_sysfs_path(const char *resolved) {
  static const char managed_root[] = "/sys/devices/faux/vibeshine/";
  return resolved && !strncmp(resolved, managed_root, sizeof(managed_root) - 1);
}

static bool driver_name_is_vibeshine(const char *name, int name_length) {
  static const char expected[] = "vibeshine_drm";
  return name && name_length == (int) (sizeof(expected) - 1) &&
         !memcmp(name, expected, sizeof(expected) - 1);
}

static bool managed_device_identity(int fd, const char *card_name, dev_t device,
                                    bool *is_vibeshine) {
  struct stat opened;
  if (!is_vibeshine) return false;
  *is_vibeshine = false;
  char sysfs_path[PATH_MAX];
  if (fstat(fd, &opened) || !S_ISCHR(opened.st_mode) || opened.st_uid ||
      opened.st_rdev != device || !card_sysfs_path(card_name, sysfs_path, sizeof(sysfs_path)) ||
      drmGetNodeTypeFromFd(fd) != DRM_NODE_PRIMARY) return false;
  drmVersionPtr version = drmGetVersion(fd);
  const bool valid = version && version->name && version->name_len > 0;
  if (valid) {
    const bool driver_is_vibeshine = driver_name_is_vibeshine(version->name, version->name_len);
    const bool path_is_vibeshine = is_vibeshine_sysfs_path(sysfs_path);
    // Never let a device claim the private-driver protocol unless both the
    // DRM driver and its sysfs origin identify the managed virtual card.
    if (driver_is_vibeshine != path_is_vibeshine) {
      drmFreeVersion(version);
      return false;
    }
    *is_vibeshine = driver_is_vibeshine;
  }
  if (version) drmFreeVersion(version);
  return valid;
}

static int open_card_device(uint32_t card_major, uint32_t card_minor,
                            bool *is_vibeshine) {
  const dev_t wanted = makedev(card_major, card_minor);
  if (!is_vibeshine || major(wanted) != card_major || minor(wanted) != card_minor ||
      !card_major) {
    errno = EACCES; return -1;
  }
  *is_vibeshine = false;
  DIR *directory = opendir("/dev/dri");
  if (!directory) return -1;
  int result = -1;
  struct dirent *entry;
  while ((entry = readdir(directory))) {
    if (!valid_card_name(entry->d_name) || !valid_card_sysfs_path(entry->d_name)) continue;
    struct stat attributes;
    if (fstatat(dirfd(directory), entry->d_name, &attributes, AT_SYMLINK_NOFOLLOW) ||
        !S_ISCHR(attributes.st_mode) || attributes.st_uid || attributes.st_rdev != wanted) continue;
    int fd = openat(dirfd(directory), entry->d_name, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY);
    if (fd < 0) continue;
    bool candidate_is_vibeshine = false;
    if (!managed_device_identity(fd, entry->d_name, wanted, &candidate_is_vibeshine)) {
      close(fd); continue;
    }
    if (drmIsMaster(fd)) {
      if (!set_effective(true)) _exit(126);
      const int dropped = drmDropMaster(fd);
      if (!set_effective(false)) _exit(126);
      if (dropped) { close(fd); continue; }
    }
    // Universal planes are required for framebuffer selection. Atomic support
    // is optional here, matching the unprivileged KMS client policy.
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1)) {
      close(fd); continue;
    }
    (void) drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1);
    *is_vibeshine = candidate_is_vibeshine;
    result = fd;
    break;
  }
  closedir(directory);
  if (result < 0) errno = EACCES;
  return result;
}

""",
    )

    replace_once(
        helper,
        """static int perform(int *card, const struct vibeshine_kms_capture_request *request,
                   struct vibeshine_kms_capture_response *response) {
  if (!vibeshine_kms_capture_request_valid(request, *card >= 0)) return EINVAL;
  if (request->operation == VIBESHINE_KMS_CAPTURE_OPEN) {
    *card = open_managed_device(request->card_major, request->card_minor);
    return *card < 0 ? errno : 0;
  }
  if (!known_crtc(*card, request->crtc_id)) return ENOENT;
  if (request->operation == VIBESHINE_KMS_CAPTURE_FB) {
    int error = export_framebuffer(*card, request, &response->frame);
    if (!error && !valid_frame_response(&response->frame, request->crtc_id)) error = EPROTO;
    return error;
  }
  int result, error;""",
        """static int perform(int *card, bool *card_is_vibeshine,
                   const struct vibeshine_kms_capture_request *request,
                   struct vibeshine_kms_capture_response *response) {
  if (!card_is_vibeshine ||
      !vibeshine_kms_capture_request_valid(request, *card >= 0)) return EINVAL;
  if (request->operation == VIBESHINE_KMS_CAPTURE_OPEN) {
    *card = open_card_device(request->card_major, request->card_minor, card_is_vibeshine);
    return *card < 0 ? errno : 0;
  }
  if (!known_crtc(*card, request->crtc_id)) return ENOENT;
  if (request->operation == VIBESHINE_KMS_CAPTURE_FB) {
    int error = export_framebuffer(*card, request, &response->frame);
    if (!error && !valid_frame_response(&response->frame, request->crtc_id)) error = EPROTO;
    return error;
  }
  // Physical GPUs use the normal polling capture path. These custom ioctls
  // belong exclusively to the managed Vibeshine presentation ABI.
  if (!*card_is_vibeshine) return EOPNOTSUPP;
  int result, error;""",
    )

    replace_once(
        helper,
        """  int card = -1;
  for (;;) {""",
        """  int card = -1;
  bool card_is_vibeshine = false;
  for (;;) {""",
    )
    replace_once(
        helper,
        "    response.error = perform(&card, &request, &response);",
        "    response.error = perform(&card, &card_is_vibeshine, &request, &response);",
    )

    replace_once(
        helper_test,
        """  assert(open_managed_device(1, 3) == -1 && errno == EACCES);
  /* Reject every physical card present, without opening any of them. */
  DIR *cards = opendir("/dev/dri");
  if (cards) {
    struct dirent *entry;
    while ((entry = readdir(cards))) {
      struct stat card;
      if (!valid_card_name(entry->d_name) || managed_card_path(entry->d_name) ||
          fstatat(dirfd(cards), entry->d_name, &card, AT_SYMLINK_NOFOLLOW) ||
          !S_ISCHR(card.st_mode)) continue;
      assert(open_managed_device(major(card.st_rdev), minor(card.st_rdev)) == -1 && errno == EACCES);
    }
    closedir(cards);
  }""",
        """  bool is_vibeshine = false;
  assert(open_card_device(1, 3, &is_vibeshine) == -1 && errno == EACCES);
  assert(driver_name_is_vibeshine("vibeshine_drm", 13));
  assert(!driver_name_is_vibeshine("amdgpu", 6));
  assert(!driver_name_is_vibeshine("nvidia-drm", 10));
  assert(!driver_name_is_vibeshine("i915", 4));""",
    )

    print("Applied Homebrew KMS helper path and generic physical-card capture support.")
    print("The restricted helper retains WAIT/FRAME ioctls only for vibeshine_drm.")


if __name__ == "__main__":
    main()
