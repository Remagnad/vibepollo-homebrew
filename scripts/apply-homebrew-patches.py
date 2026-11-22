#!/usr/bin/env python3
"""Apply the small, reviewable Linux Homebrew port patch to an upstream checkout."""

from __future__ import annotations

import pathlib
import sys


def replace_once(path: pathlib.Path, old: str, new: str) -> None:
    source = path.read_text(encoding="utf-8")
    count = source.count(old)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one patch target in {path}, found {count}; "
            "upstream CMake changed and needs review."
        )
    path.write_text(source.replace(old, new, 1), encoding="utf-8")


def insert_before_once(path: pathlib.Path, marker: str, block: str) -> None:
    source = path.read_text(encoding="utf-8")
    count = source.count(marker)
    if count != 1:
        raise SystemExit(
            f"Expected exactly one insertion point in {path}, found {count}; "
            "upstream CMake changed and needs review."
        )
    path.write_text(source.replace(marker, block + marker, 1), encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} UPSTREAM_SOURCE_DIR")

    root = pathlib.Path(sys.argv[1]).resolve()
    if not (root / "CMakeLists.txt").is_file():
        raise SystemExit(f"Not a Vibepollo source tree: {root}")

    # Recent upstream tags select a dedicated Linux libvirtualdisplay gitlink.
    # Older tags used the shared submodule path, so retain a compatibility fallback.
    libvirtualdisplay_root = root / "third-party/libvirtualdisplay-linux"
    if not (libvirtualdisplay_root / "CMakeLists.txt").is_file():
        libvirtualdisplay_root = root / "third-party/libvirtualdisplay"
    if not (libvirtualdisplay_root / "CMakeLists.txt").is_file():
        raise SystemExit("Linux libvirtualdisplay submodule source is missing")

    # Install the peer-credential broker with the app formula. Machine
    # services and privileged pool provisioning remain Cask-managed.
    replace_once(
        libvirtualdisplay_root / "src/driver/CMakeLists.txt",
        """    target_compile_features(vibeshine_vkms_peercred PRIVATE cxx_std_20)
endif()""",
        """    target_compile_features(vibeshine_vkms_peercred PRIVATE cxx_std_20)
    if(SUNSHINE_BUILD_HOMEBREW)
        # Homebrew rewrites PT_INTERP to its private loader when creating Linux
        # bottles. This tiny broker helper only needs libc syscalls and execv;
        # link it statically so it remains runnable inside ProtectHome=yes.
        target_link_options(vibeshine_vkms_peercred PRIVATE -static)
        install(TARGETS vibeshine_vkms_peercred RUNTIME DESTINATION libexec)
    endif()
endif()""",
    )

    # The module lives outside /lib/modules; load it through our controller.
    replace_once(
        libvirtualdisplay_root / "linux/packaging/vibeshine-vkms",
        """  log "loading the Vibeshine DRM HDR virtual-display module"
  if ! modprobe "$DRM_MODULE" create_default_dev=0; then
    error "${DRM_MODULE} is unavailable; refusing CPU-backed stock VKMS fallback"
    return 1
  fi""",
        """  log "loading the Vibeshine DRM HDR virtual-display module through the Homebrew controller"
  local controller="/var/lib/vibepollo/drm/bin/vibeshine-drmctl"
  if [[ ! -x "$controller" ]]; then
    error "Vibeshine DRM controller is unavailable: ${controller}"
    return 1
  fi
  if ! "$controller" load; then
    error "the signed ${DRM_MODULE} module could not be loaded; refusing CPU-backed stock VKMS fallback"
    return 1
  fi""",
    )

    replace_once(
        root / "CMakeLists.txt",
        """if(SUNSHINE_BUILD_STEAMOS)
    set(BUILD_VIBESHINE_KWIN_GPU_BRIDGE OFF CACHE BOOL
            "Build the Vibepollo KWin GPU-association bridge" FORCE)
else()
    set(BUILD_VIBESHINE_KWIN_GPU_BRIDGE ON CACHE BOOL
        "Build the Vibepollo KWin GPU-association bridge" FORCE)
endif()""",
        """if(SUNSHINE_BUILD_STEAMOS OR SUNSHINE_BUILD_HOMEBREW)
    set(BUILD_VIBESHINE_KWIN_GPU_BRIDGE OFF CACHE BOOL
            "Build the Vibepollo KWin GPU-association bridge" FORCE)
else()
    set(BUILD_VIBESHINE_KWIN_GPU_BRIDGE ON CACHE BOOL
        "Build the Vibepollo KWin GPU-association bridge" FORCE)
endif()""",
    )

    replace_once(
        root / "cmake/dependencies/common.cmake",
        """set(BUILD_VIBESHINE_KWIN_GPU_BRIDGE ON CACHE BOOL
        "Build the bundled libvirtualdisplay KWin GPU-association bridge" FORCE)""",
        """if(SUNSHINE_BUILD_STEAMOS OR SUNSHINE_BUILD_HOMEBREW)
    set(BUILD_VIBESHINE_KWIN_GPU_BRIDGE OFF CACHE BOOL
            "Build the bundled libvirtualdisplay KWin GPU-association bridge" FORCE)
else()
    set(BUILD_VIBESHINE_KWIN_GPU_BRIDGE ON CACHE BOOL
            "Build the bundled libvirtualdisplay KWin GPU-association bridge" FORCE)
endif()""",
    )

    replace_once(
        root / "cmake/prep/special_package_configuration.cmake",
        "if(CMAKE_SYSTEM_NAME STREQUAL \"Linux\" AND NOT SUNSHINE_BUILD_STEAMOS)",
        "if(CMAKE_SYSTEM_NAME STREQUAL \"Linux\" AND NOT SUNSHINE_BUILD_STEAMOS AND NOT SUNSHINE_BUILD_HOMEBREW)",
    )

    linux_packaging = root / "cmake/packaging/linux.cmake"
    homebrew_packaging = """if(SUNSHINE_BUILD_HOMEBREW)
    # Homebrew owns the Cellar payload. Do not install machine services,
    # privileged helpers, udev/sysusers rules, package hooks or kernel sources.
    install(FILES "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_FQDN}.desktop"
            DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/applications")
    install(FILES "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_FQDN}.terminal.desktop"
            DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/applications")
    if(SUNSHINE_ENABLE_KWIN)
        install(FILES "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_FQDN}.kwin.desktop"
                DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/applications")
    endif()
    install(FILES "${CMAKE_SOURCE_DIR}/apollo.svg"
            DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/icons/hicolor/scalable/apps"
            RENAME "${PROJECT_FQDN}.svg")
    if(SUNSHINE_ENABLE_TRAY AND SUNSHINE_TRAY STREQUAL "1")
        install(FILES "${CMAKE_SOURCE_DIR}/apollo.svg"
                DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/icons/hicolor/scalable/status"
                RENAME "${PROJECT_FQDN}-tray.svg")
        foreach(state playing pausing locked)
            install(FILES "${SUNSHINE_SOURCE_ASSETS_DIR}/common/assets/web/public/images/apollo-${state}.svg"
                    DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/icons/hicolor/scalable/status"
                    RENAME "${PROJECT_FQDN}-${state}.svg")
        endforeach()
    endif()
    install(FILES "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_FQDN}.metainfo.xml"
            DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/metainfo")
    # The active tray is compiled into the Vibepollo C++ process.
    # Do not install the unused Python/PySide companion or its second launcher.
    install(FILES "${CMAKE_SOURCE_DIR}/LICENSE" "${CMAKE_SOURCE_DIR}/NOTICE"
            DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/licenses/vibepollo")
    return()
endif()

"""
    insert_before_once(
        linux_packaging,
        "if(${SUNSHINE_BUILD_APPIMAGE} OR ${SUNSHINE_BUILD_FLATPAK})",
        homebrew_packaging,
    )

    replace_once(
        root / "cmake/packaging/unix.cmake",
        """set(CPACK_SET_DESTDIR true)
if(NOT CMAKE_INSTALL_PREFIX)
    set(CMAKE_INSTALL_PREFIX "/usr/share/vibepollo")
endif()""",
        """if(NOT SUNSHINE_BUILD_HOMEBREW)
    set(CPACK_SET_DESTDIR true)
    if(NOT CMAKE_INSTALL_PREFIX)
        set(CMAKE_INSTALL_PREFIX "/usr/share/vibepollo")
    endif()
endif()""",
    )

    # The Homebrew curl bottle has private zlib references that are not
    # propagated by pkg-config's public libcurl link flags. confighttp's
    # translation unit pulls those references into the final executable, so
    # link the Homebrew-compatible zlib explicitly.
    replace_once(
        root / "cmake/targets/common.cmake",
        "target_link_libraries(sunshine ${SUNSHINE_EXTERNAL_LIBRARIES} ${EXTRA_LIBS})",
        """target_link_libraries(sunshine ${SUNSHINE_EXTERNAL_LIBRARIES} ${EXTRA_LIBS})
if(SUNSHINE_BUILD_HOMEBREW)
    find_package(ZLIB REQUIRED)
    target_link_libraries(sunshine ZLIB::ZLIB)

    # The Homebrew tray lifecycle callbacks use GLib's main context. The tray
    # subproject links GLib privately, so expose the headers and link dependency
    # explicitly to the main C++ target that compiles system_tray.cpp.
    if(SUNSHINE_ENABLE_TRAY)
        find_package(PkgConfig REQUIRED)
        pkg_check_modules(VIBEPOLLO_GLIB REQUIRED IMPORTED_TARGET glib-2.0)
        target_link_libraries(sunshine PkgConfig::VIBEPOLLO_GLIB)
    endif()
endif()""",
    )

    replace_once(
        root / "cmake/targets/linux.cmake",
        """list(APPEND SUNSHINE_EXTERNAL_LIBRARIES
        -static-libgcc
)
if(NOT CUDA_FOUND)
    list(APPEND SUNSHINE_EXTERNAL_LIBRARIES -static-libstdc++)
endif()""",
        """if(NOT SUNSHINE_BUILD_HOMEBREW)
    list(APPEND SUNSHINE_EXTERNAL_LIBRARIES -static-libgcc)
    if(NOT CUDA_FOUND)
        list(APPEND SUNSHINE_EXTERNAL_LIBRARIES -static-libstdc++)
    endif()
endif()""",
    )

    # Upstream's PyroWave colorspace path references the RTX-HDR metadata
    # synthesizer even when the optional Linux TrueHDR target was not built.
    # Keep the branch available only when the feature's compile definition exists;
    # normal HDR-display metadata remains supported without CUDA/TrueHDR.
    replace_once(
        root / "src/video.cpp",
        """    const bool display_is_hdr = disp.is_hdr();
    bool hdr_display = display_is_hdr || config.rtx_hdr_active;

    const auto colorspace = colorspace_from_client_config(config, hdr_display);

    hdr_info = std::make_unique<hdr_info_raw_t>(false);
    if (colorspace_is_hdr(colorspace)) {
      SS_HDR_METADATA metadata {};
      if (config.rtx_hdr_active) {
        metadata = synthesize_rtx_hdr_metadata(config.rtx_hdr_peak_nits);
        hdr_info = std::make_unique<hdr_info_raw_t>(true, metadata);
      } else if (display_is_hdr && disp.get_hdr_metadata(metadata)) {""",
        """    const bool display_is_hdr = disp.is_hdr();
#ifdef SUNSHINE_ENABLE_NV_TRUEHDR
    const bool hdr_display = display_is_hdr || config.rtx_hdr_active;
#else
    const bool hdr_display = display_is_hdr;
#endif

    const auto colorspace = colorspace_from_client_config(config, hdr_display);

    hdr_info = std::make_unique<hdr_info_raw_t>(false);
    if (colorspace_is_hdr(colorspace)) {
      SS_HDR_METADATA metadata {};
#ifdef SUNSHINE_ENABLE_NV_TRUEHDR
      if (config.rtx_hdr_active) {
        metadata = synthesize_rtx_hdr_metadata(config.rtx_hdr_peak_nits);
        hdr_info = std::make_unique<hdr_info_raw_t>(true, metadata);
      } else
#endif
      if (display_is_hdr && disp.get_hdr_metadata(metadata)) {""",
    )

    # AppIndicator icons are resolved by the desktop's separate watcher process.
    # Supply Homebrew's private icon theme root explicitly so the watcher can
    # load the bundled hicolor SVGs even when it cannot inherit this process's
    # XDG_DATA_DIRS.
    replace_once(
        root / "third-party/tray/src/tray_linux.c",
        """  if (indicator == NULL || !IS_APP_INDICATOR(indicator)) {
    tray_log(TRAY_LOG_ERROR, "app_indicator_new() failed");
    return -1;
  }
  app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE);""",
        """  if (indicator == NULL || !IS_APP_INDICATOR(indicator)) {
    tray_log(TRAY_LOG_ERROR, "app_indicator_new() failed");
    return -1;
  }
  // AppIndicator's watcher runs in a separate process, so pass the private
  // Homebrew icon-theme root explicitly instead of relying on GTK discovery.
  const char *icon_theme_path = g_getenv("VIBEPOLLO_ICON_THEME_PATH");
  if (icon_theme_path != NULL && icon_theme_path[0] != '\\0' &&
      g_file_test(icon_theme_path, G_FILE_TEST_IS_DIR)) {
    app_indicator_set_icon_theme_path(indicator, icon_theme_path);
    tray_log(TRAY_LOG_DEBUG, "Using AppIndicator icon theme path: %s", icon_theme_path);
  } else if (icon_theme_path != NULL && icon_theme_path[0] != '\\0') {
    tray_log(TRAY_LOG_WARNING, "AppIndicator icon theme path does not exist: %s", icon_theme_path);
  }
  app_indicator_set_status(indicator, APP_INDICATOR_STATUS_ACTIVE);""",
    )
    # The Linux AppIndicator loop may call tray_exit() once from the owner
    # thread and again as the loop unwinds. Make libnotify cleanup idempotent
    # so the second call cannot inspect a released GObject.
    replace_once(
        root / "third-party/tray/src/tray_linux.c",
        """static gboolean tray_exit_internal(gpointer user_data) {
  if (currentNotification != NULL && NOTIFY_IS_NOTIFICATION(currentNotification)) {
    int v = notify_notification_close(currentNotification, NULL);
    if (v == TRUE) {
      g_object_unref(G_OBJECT(currentNotification));
    }
  }
  notify_uninit();
  return G_SOURCE_REMOVE;
}""",
        """static gboolean tray_exit_internal(gpointer user_data) {
  NotifyNotification *notification = currentNotification;
  currentNotification = NULL;

  if (notification != NULL && NOTIFY_IS_NOTIFICATION(notification)) {
    int v = notify_notification_close(notification, NULL);
    if (v == TRUE) {
      g_object_unref(G_OBJECT(notification));
    }
  }
  if (notify_is_initted()) {
    notify_uninit();
  }
  return G_SOURCE_REMOVE;
}""",
    )

    # Closing the RTSP acceptor during normal shutdown completes its pending
    # async_accept with operation_aborted. Do not run another session clear
    # from that callback while the RTSP loop is also draining sessions.
    replace_once(
        root / "src/rtsp.cpp",
        """      if (ec) {
        BOOST_LOG(error) << \"Couldn't accept incoming connections: \"sv << ec.message();

        // Stop server
        clear();
        return;
      }""",
        """      if (ec) {
        // Closing the acceptor during shutdown completes the outstanding
        // async_accept with operation_aborted. That is not a server error,
        // and must not trigger another session cleanup pass.
        if (stopping.load(std::memory_order_acquire) ||
            ec == boost::asio::error::operation_aborted) {
          return;
        }

        BOOST_LOG(error) << \"Couldn't accept incoming connections: \"sv << ec.message();

        // Stop server
        clear();
        return;
      }""",
    )
    # Native NVENC needs its own PipeWire device factory. The synthetic
    # encoder probe already implements this factory, but PipeWire's shared
    # display class only implemented the FFmpeg/AVCodec CUDA factory. Restrict
    # native GL/CUDA NVENC to a NVIDIA capture device with advertised DMA-BUFs.
    insert_before_once(
        root / "src/platform/linux/pipewire.cpp",
        "    int dummy_img(platf::img_t *img) override {",
        """    std::unique_ptr<platf::nvenc_encode_device_t> make_nvenc_encode_device(platf::pix_fmt_e pix_fmt) override {
      (void) pix_fmt;
#ifdef SUNSHINE_BUILD_CUDA
      // Native NVENC imports the active NVIDIA display's DMA-BUFs through GL/CUDA.
      // Do not offer it for hybrid or CPU-buffer capture: another GPU's DMA-BUF
      // cannot be imported into the NVIDIA CUDA context.
      if (mem_type == platf::mem_type_e::cuda && display_is_nvidia && n_dmabuf_infos > 0) {
        return cuda::make_nvenc_gl_encode_device(width, height, 0, 0, pix_fmt);
      }
#endif
      return nullptr;
    }

""",
    )

    # Vulkan's encoder in vulkan_encode.cpp imports DMA-BUF exclusively.
    # The generic PipeWire MemPtr/MemFd fallback creates descriptors without a
    # DMA-BUF FD, which this encoder cannot upload or import. Keep that fallback
    # for the other memory backends, but never advertise it for Vulkan capture.
    replace_once(
        root / "src/platform/linux/pipewire.cpp",
        """        // Add fallback for memptr
        for (const auto &fmt : format_map) {
          if (force_hdr10_formats_) {
            // The current CPU conversion path assumes 8-bit BGR pixels.
            // HDR capture requires an importable 10-bit DMA-BUF.
            break;
          }
          if ((force_sdr_formats_ && !is_sdr_format(fmt.pw_format)) ||
              (force_hdr10_formats_ && fmt.pw_format != SPA_VIDEO_FORMAT_xBGR_210LE)) {
            continue;
          }
          auto format_param = build_format_parameter(&pod_builder, width, height, refresh_rate, fmt.pw_format, nullptr, 0);
          params[n_params] = format_param;
          n_params++;
        }""",
        """        // Vulkan's encoder imports DMA-BUF exclusively; it has no MemPtr/MemFd
        // upload path. Do not offer PipeWire's software fallback when that
        // encoder will be selected, or it may receive a descriptor with fd = -1.
        const bool vulkan_dmabuf_only =
          mem_type == platf::mem_type_e::vulkan && n_dmabuf_infos > 0;
        if (!vulkan_dmabuf_only) {
          // Add fallback for memptr
          for (const auto &fmt : format_map) {
            if (force_hdr10_formats_) {
              // The current CPU conversion path assumes 8-bit BGR pixels.
              // HDR capture requires an importable 10-bit DMA-BUF.
              break;
            }
            if ((force_sdr_formats_ && !is_sdr_format(fmt.pw_format)) ||
                (force_hdr10_formats_ && fmt.pw_format != SPA_VIDEO_FORMAT_xBGR_210LE)) {
              continue;
            }
            auto format_param = build_format_parameter(&pod_builder, width, height, refresh_rate, fmt.pw_format, nullptr, 0);
            params[n_params] = format_param;
            n_params++;
          }
        } else if (n_params == 0) {
          BOOST_LOG(error) << "[pipewire] Vulkan capture requires a compatible DMA-BUF format"sv;
        }""",
    )

    # Add Homebrew-only lifecycle controls to the Linux C++ tray.
    replace_once(
        root / "src/system_tray.cpp",
        """  #include <queue>
  #include <string>
  #include <thread>
  #include <utility>""",
        """  #include <queue>
  #include <string>
  #include <thread>
  #include <utility>
#ifdef __linux__
  #include <cerrno>
  #include <fstream>
  #include <glib.h>
  #include <spawn.h>
  #include <system_error>
  #include <sys/stat.h>
  #include <sys/wait.h>
  #include <unistd.h>
  extern char **environ;
#endif""",
    )
    insert_before_once(
        root / "src/system_tray.cpp",
        "  // Tray menu\n",
        """#ifdef __linux__
  namespace {
    constexpr const char *VIBEPOLLO_LIFECYCLE_HELPER =
      "/var/lib/vibepollo/drm/bin/vibepollo-lifecycle";
    constexpr const char *VIBEPOLLO_LIFECYCLE_STATE =
      "/var/lib/vibepollo/drm/state/vibepollo-lifecycle";

    bool lifecycle_helper_is_cask_owned() {
      struct stat st {};
      if (::access("/usr/bin/pkexec", X_OK) != 0 ||
          ::lstat(VIBEPOLLO_LIFECYCLE_HELPER, &st) != 0) {
        return false;
      }
      return S_ISREG(st.st_mode) && st.st_uid == 0 &&
             (st.st_mode & 0022) == 0 && (st.st_mode & 0111) != 0;
    }

    bool read_lifecycle_autostart_state() {
      struct stat st {};
      if (::lstat(VIBEPOLLO_LIFECYCLE_STATE, &st) != 0 ||
          !S_ISREG(st.st_mode) || st.st_uid != 0 || (st.st_mode & 0022) != 0) {
        return false;
      }
      std::ifstream state_file(VIBEPOLLO_LIFECYCLE_STATE);
      std::string line;
      constexpr const char *key = "autostart_enabled=";
      while (std::getline(state_file, line)) {
        if (line.rfind(key, 0) == 0) {
          return line.substr(std::strlen(key)) == "1";
        }
      }
      return false;
    }
  }  // namespace

  static const bool lifecycle_helper_available = lifecycle_helper_is_cask_owned();
  static std::atomic<bool> lifecycle_autostart_enabled {read_lifecycle_autostart_state()};
  static std::atomic<bool> lifecycle_action_pending {false};

  static void dispatch_lifecycle_completion(std::function<void()> fn);
  static void update_lifecycle_tray_menu();

  static void run_lifecycle_action(std::string action, bool update_autostart, bool desired_autostart) {
    if (!lifecycle_helper_available) {
      BOOST_LOG(warning) << "The Vibepollo Homebrew lifecycle integration or /usr/bin/pkexec is unavailable"sv;
      return;
    }

    const bool quit_requested = action == "stop-after-pid";
    bool expected = false;
    if (!lifecycle_action_pending.compare_exchange_strong(expected, true)) {
      BOOST_LOG(info) << "A Vibepollo lifecycle action is already running"sv;
      return;
    }
    update_lifecycle_tray_menu();

    try {
      std::thread([action = std::move(action), update_autostart, desired_autostart, quit_requested]() {
        std::string helper = VIBEPOLLO_LIFECYCLE_HELPER;
        std::string action_arg = action;
        std::string pid_arg;
        char *argv[5] = {};
        argv[0] = const_cast<char *>("/usr/bin/pkexec");
        argv[1] = helper.data();
        argv[2] = action_arg.data();
        if (action == "stop-after-pid") {
          pid_arg = std::to_string(static_cast<long>(::getpid()));
          argv[3] = pid_arg.data();
        }

        pid_t child = -1;
        const int spawn_error = ::posix_spawn(&child, "/usr/bin/pkexec", nullptr, nullptr, argv, environ);
        int status = 0;
        int wait_error = 0;
        bool success = false;
        if (spawn_error == 0) {
          pid_t waited;
          do {
            waited = ::waitpid(child, &status, 0);
          } while (waited < 0 && errno == EINTR);
          if (waited == child) {
            success = WIFEXITED(status) && WEXITSTATUS(status) == 0;
          } else {
            wait_error = errno;
          }
        }

        dispatch_lifecycle_completion([action, update_autostart, desired_autostart, quit_requested, success, spawn_error, wait_error]() {
          if (success && update_autostart) {
            lifecycle_autostart_enabled.store(desired_autostart);
          }
          lifecycle_action_pending.store(false);
          update_lifecycle_tray_menu();
          if (!success) {
            if (spawn_error != 0) {
              BOOST_LOG(error) << "Could not start pkexec for lifecycle action "sv
                               << action << ": " << std::strerror(spawn_error);
            } else if (wait_error != 0) {
              BOOST_LOG(error) << "Could not wait for lifecycle action "sv
                               << action << ": " << std::strerror(wait_error);
            } else {
              BOOST_LOG(warning) << "Vibepollo lifecycle action was cancelled or failed: "sv << action;
            }
            // Quit means quit even if polkit is unavailable or authorization
            // is cancelled. The system service stack remains untouched.
            if (quit_requested) {
              lifetime::exit_sunshine(0, true);
            }
          } else {
            BOOST_LOG(info) << "Vibepollo lifecycle action completed: "sv << action;
          }
        });
      }).detach();
    } catch (const std::system_error &exception) {
      lifecycle_action_pending.store(false);
      update_lifecycle_tray_menu();
      BOOST_LOG(error) << "Could not start the lifecycle authorization worker: "sv << exception.what();
      if (quit_requested) {
        lifetime::exit_sunshine(0, true);
      }
    }
  }

  void tray_quit_and_stop_services_cb([[maybe_unused]] struct tray_menu *item) {
    BOOST_LOG(info) << "Quitting Vibepollo and stopping system services from tray"sv;
    proc::proc.terminate();
    run_lifecycle_action("stop-after-pid", false, false);
  }

  static std::atomic<bool> module_update_available {
    std::getenv("VIBEPOLLO_MODULE_UPDATE_REQUIRED") != nullptr &&
    std::string(std::getenv("VIBEPOLLO_MODULE_UPDATE_REQUIRED")) == "1"
  };

  void tray_update_kernel_module_cb([[maybe_unused]] struct tray_menu *item) {
    if (!module_update_available.load()) return;
    BOOST_LOG(info) << "Kernel module update requested from tray"sv;
    run_lifecycle_action("update-module", false, false);
  }

  void tray_toggle_autostart_cb([[maybe_unused]] struct tray_menu *item) {
    const bool enable = !lifecycle_autostart_enabled.load();
    BOOST_LOG(info) << (enable ? "Enabling"sv : "Disabling"sv) << " Vibepollo system autostart";
    run_lifecycle_action(enable ? "enable-autostart" : "disable-autostart", true, enable);
  }
#endif

""",
    )
    insert_before_once(
        root / "src/system_tray.cpp",
        "  // Tray menu\n",
        """  // Explicit static storage is essential here. Runtime expressions in
  // a C compound literal are emitted as a temporary by the C++ compiler,
  // which leaves tray.menu pointing at expired stack memory.
  static struct tray_menu vibepollo_tray_menu[] = {
    {.text = "Open Vibepollo", .cb = tray_open_ui_cb},
    {.text = "-"},
    {.text = TRAY_MSG_NO_APP_RUNNING, .cb = tray_force_stop_cb},
    {.text = "Check for Update", .cb = [](tray_menu *) {
       BOOST_LOG(info) << "Manual update check requested from tray"sv;
       update::trigger_check(true);
     }},
    {.text = "Restart", .cb = tray_restart_cb},
    {.text = "Quit", .cb = tray_quit_cb},
    {.text = "-"},
    {.text = "Update kernel module", .disabled = 1,
     .cb = tray_update_kernel_module_cb},
    {.text = "Quit and stop services", .disabled = 0,
     .cb = tray_quit_and_stop_services_cb},
    {.text = "Start with system", .disabled = 0, .checked = 0, .checkbox = 1,
     .cb = tray_toggle_autostart_cb},
    {.text = nullptr}
  };

""",
    )
    replace_once(
        root / "src/system_tray.cpp",
        """    .menu =
      (struct tray_menu[]) {
        // todo - use boost/locale to translate menu strings
        {.text = "Open Vibepollo", .cb = tray_open_ui_cb},
        {.text = "-"},
        // { .text = "-" },
        // { .text = "Donate",
        //   .submenu =
        //   (struct tray_menu[]) {
        //   { .text = "GitHub Sponsors", .cb = tray_donate_github_cb },
        //   { .text = "MEE6", .cb = tray_donate_mee6_cb },
        //   { .text = "Patreon", .cb = tray_donate_patreon_cb },
        //   { .text = "PayPal", .cb = tray_donate_paypal_cb },
        //   { .text = nullptr } } },
        // { .text = "-" },
        {.text = TRAY_MSG_NO_APP_RUNNING, .cb = tray_force_stop_cb},
        {.text = "Check for Update", .cb = [](tray_menu *) {
           BOOST_LOG(info) << "Manual update check requested from tray"sv;
           update::trigger_check(true);
         }},

        {.text = "Restart", .cb = tray_restart_cb},
        {.text = "Quit", .cb = tray_quit_cb},
        {.text = nullptr}
      },""",
                """    .menu = vibepollo_tray_menu,""",
    )
    insert_before_once(
        root / "src/system_tray.cpp",
        "  template<typename Fn>\n  static void run_on_tray_thread(Fn &&fn) {",
        """#ifdef __linux__
  static void update_lifecycle_tray_menu() {
    if (!tray.menu) {
      return;
    }
    const bool disabled = !lifecycle_helper_available || lifecycle_action_pending.load();
    tray.menu[7].disabled = !module_update_available.load() || lifecycle_action_pending.load() ? 1 : 0;
    tray.menu[8].disabled = disabled ? 1 : 0;
    tray.menu[9].disabled = disabled ? 1 : 0;
    tray.menu[9].checked = lifecycle_autostart_enabled.load() ? 1 : 0;
    if (tray_initialized.load()) {
      tray_update(&tray);
    }
  }
#endif

""",
    )

    insert_before_once(
        root / "src/system_tray.cpp",
        "    int attempt = 0;\n",
        """#ifdef __linux__
    // Apply runtime state after the static menu table has been initialized.
    tray.menu[7].disabled = module_update_available.load() ? 0 : 1;
    tray.menu[8].disabled = lifecycle_helper_available ? 0 : 1;
    tray.menu[9].disabled = lifecycle_helper_available ? 0 : 1;
    tray.menu[9].checked = lifecycle_autostart_enabled.load() ? 1 : 0;
#endif

""",
    )

    insert_before_once(
        root / "src/system_tray.cpp",
        "  static int init_tray() {\n  #ifdef _WIN32",
        """#ifdef __linux__
  static gboolean run_lifecycle_completion(gpointer data) {
    auto *fn = static_cast<std::function<void()> *>(data);
    (*fn)();
    return G_SOURCE_REMOVE;
  }

  static void destroy_lifecycle_completion(gpointer data) {
    delete static_cast<std::function<void()> *>(data);
  }

  static void dispatch_lifecycle_completion(std::function<void()> fn) {
    // The Linux tray loop owns GTK's default GLib main context. g_idle_add_full
    // is thread-safe and schedules this callback on that context instead of
    // touching tray_menu from the pkexec worker thread.
    auto *task = new std::function<void()>(std::move(fn));
    if (g_idle_add_full(G_PRIORITY_DEFAULT, run_lifecycle_completion, task,
                        destroy_lifecycle_completion) == 0) {
      delete task;
    }
  }
#endif

""",
    )

    print("Applied the static peer-credential broker link fix.")
    print("Applied the PipeWire native NVENC device factory fix.")
    print("Applied the Linux AppIndicator shutdown cleanup fix.")
    print("Applied the RTSP shutdown cancellation fix.")
    print("Applied the Linux Homebrew CMake port patch.")
    print("libvirtualdisplay's user-space driver client remains linked; machine integration is excluded.")


if __name__ == "__main__":
    main()
