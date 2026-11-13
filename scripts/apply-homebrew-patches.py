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

    print("Applied the Linux AppIndicator shutdown cleanup fix.")
    print("Applied the RTSP shutdown cancellation fix.")
    print("Applied the Linux Homebrew CMake port patch.")
    print("libvirtualdisplay's user-space driver client remains linked; machine integration is excluded.")


if __name__ == "__main__":
    main()
