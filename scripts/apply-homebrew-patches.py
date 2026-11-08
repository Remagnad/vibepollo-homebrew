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
    install(FILES "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_FQDN}.metainfo.xml"
            DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/metainfo")
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

    print("Applied the Linux Homebrew CMake port patch.")
    print("libvirtualdisplay's user-space driver client remains linked; machine integration is excluded.")


if __name__ == "__main__":
    main()
