#!/usr/bin/env python3
"""Apply the KWin GPU-bridge-specific Homebrew staging and loader-safety patch."""
from __future__ import annotations
import pathlib
import sys

def replace_once(path: pathlib.Path, old: str, new: str) -> None:
    source = path.read_text(encoding="utf-8")
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one GPU-bridge patch target in {path}, found {count}; upstream CMake changed and needs review.")
    path.write_text(source.replace(old, new, 1), encoding="utf-8")

def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} UPSTREAM_SOURCE_DIR")
    root = pathlib.Path(sys.argv[1]).resolve()
    if not (root / "CMakeLists.txt").is_file():
        raise SystemExit(f"Not a Vibepollo source tree: {root}")
    libvirtualdisplay_root = root / "third-party/libvirtualdisplay-linux"
    if not (libvirtualdisplay_root / "CMakeLists.txt").is_file():
        libvirtualdisplay_root = root / "third-party/libvirtualdisplay"
    driver_cmake = libvirtualdisplay_root / "src/driver/CMakeLists.txt"
    if not driver_cmake.is_file():
        raise SystemExit("Linux libvirtualdisplay driver CMake source is missing")

    marker = """    include(GNUInstallDirs)
    pkg_check_modules(LIBVIRTUALDISPLAY_KWIN_DRM REQUIRED IMPORTED_TARGET libdrm)"""
    replacement = """    include(GNUInstallDirs)
    if(SUNSHINE_BUILD_HOMEBREW)
        set(VIBESHINE_KWIN_GPU_LIBRARY_INSTALL_DIR "${CMAKE_INSTALL_LIBDIR}" CACHE PATH
                "Homebrew staging directory for the KWin GPU bridge" FORCE)
        set(VIBESHINE_KWIN_GPU_SYSTEMD_USER_INSTALL_DIR "${CMAKE_INSTALL_LIBDIR}/systemd/user" CACHE PATH
                "Homebrew staging directory for KWin user-unit drop-ins" FORCE)
    endif()
    pkg_check_modules(LIBVIRTUALDISPLAY_KWIN_DRM REQUIRED IMPORTED_TARGET libdrm)"""
    replace_once(driver_cmake, marker, replacement)

    link_block = """    target_link_libraries(vibeshine_kwin_gpu PRIVATE
            PkgConfig::LIBVIRTUALDISPLAY_KWIN_DRM
            PkgConfig::LIBVIRTUALDISPLAY_KWIN_GBM
            ${CMAKE_DL_LIBS})"""
    link_replacement = link_block + """

    if(SUNSHINE_BUILD_HOMEBREW)
        # The privileged Cask copy resolves against host libraries, never a keg.
        set_target_properties(vibeshine_kwin_gpu PROPERTIES
                SKIP_BUILD_RPATH TRUE
                BUILD_RPATH ""
                INSTALL_RPATH ""
                INSTALL_RPATH_USE_LINK_PATH FALSE)
    endif()"""
    replace_once(driver_cmake, link_block, link_replacement)

    static_runtime_block = """    if(SUNSHINE_BUILD_HOMEBREW)
        # Homebrew's GCC toolchain can be newer than the host system runtime.
        # Keep libstdc++/libgcc inside the bridge so secure KWin loading never
        # resolves a Homebrew Cellar runtime or an incompatible host ABI.
        target_link_options(vibeshine_kwin_gpu PRIVATE -static-libstdc++ -static-libgcc)
    endif()"""
    link_replacement_full = link_replacement + "\\n" + static_runtime_block
    driver_text = driver_cmake.read_text(encoding="utf-8")
    if "target_link_options(vibeshine_kwin_gpu PRIVATE -static-libstdc++ -static-libgcc)" not in driver_text:
        replace_once(driver_cmake, link_replacement, link_replacement_full)

    install_block = """    install(TARGETS vibeshine_kwin_gpu
            LIBRARY DESTINATION "${VIBESHINE_KWIN_GPU_LIBRARY_INSTALL_DIR}"
            PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE
                        WORLD_READ WORLD_EXECUTE SETUID)"""
    install_replacement = """    if(SUNSHINE_BUILD_HOMEBREW)
        # The Cellar remains user-owned. The root-owned Cask copy gets the
        # set-user-ID loader trust marker only after privileged installation.
        install(TARGETS vibeshine_kwin_gpu
                LIBRARY DESTINATION "${VIBESHINE_KWIN_GPU_LIBRARY_INSTALL_DIR}"
                PERMISSIONS OWNER_READ OWNER_WRITE GROUP_READ WORLD_READ)
    else()
        install(TARGETS vibeshine_kwin_gpu
                LIBRARY DESTINATION "${VIBESHINE_KWIN_GPU_LIBRARY_INSTALL_DIR}"
                PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE
                            WORLD_READ WORLD_EXECUTE SETUID)
    endif()"""
    replace_once(driver_cmake, install_block, install_replacement)

    patched = driver_cmake.read_text(encoding="utf-8")
    required = (
        'set(VIBESHINE_KWIN_GPU_LIBRARY_INSTALL_DIR "${CMAKE_INSTALL_LIBDIR}" CACHE PATH',
        'set(VIBESHINE_KWIN_GPU_SYSTEMD_USER_INSTALL_DIR "${CMAKE_INSTALL_LIBDIR}/systemd/user" CACHE PATH',
        'SKIP_BUILD_RPATH TRUE',
        'target_link_options(vibeshine_kwin_gpu PRIVATE -static-libstdc++ -static-libgcc)',
        'PERMISSIONS OWNER_READ OWNER_WRITE GROUP_READ WORLD_READ',
    )
    missing = [token for token in required if token not in patched]
    if missing:
        raise SystemExit(f"GPU bridge Homebrew patch validation failed: {missing}")
    print("Applied the Homebrew KWin GPU-bridge staging and secure-loader patch")

if __name__ == "__main__":
    main()
