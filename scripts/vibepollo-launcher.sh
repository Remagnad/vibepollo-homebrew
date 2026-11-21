#!/bin/sh
set -eu

if [ -z "${DBUS_SYSTEM_BUS_ADDRESS:-}" ]; then
  for bus_socket in /run/dbus/system_bus_socket /var/run/dbus/system_bus_socket; do
    if [ -S "$bus_socket" ]; then
      DBUS_SYSTEM_BUS_ADDRESS="unix:path=$bus_socket"
      export DBUS_SYSTEM_BUS_ADDRESS
      break
    fi
  done
fi

launcher_path="$(readlink -f -- "$0")" || exit 126
case "$launcher_path" in
  */bin/vibepollo) formula_prefix="${launcher_path%/bin/vibepollo}" ;;
  *)
    echo "vibepollo: cannot resolve the Homebrew installation path" >&2
    exit 126
    ;;
esac

# GTK's icon theme does not normally search the Homebrew prefix.
# Expose packaged AppIndicator icons while preserving host icon paths.
xdg_data_dirs="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
case ":$xdg_data_dirs:" in
  *":$formula_prefix/share:"*) ;;
  *) xdg_data_dirs="$formula_prefix/share:$xdg_data_dirs" ;;
esac
XDG_DATA_DIRS="$xdg_data_dirs"
export XDG_DATA_DIRS
VIBEPOLLO_ICON_THEME_PATH="$formula_prefix/share/icons"
export VIBEPOLLO_ICON_THEME_PATH

# Homebrew Mesa is the normal GL implementation for AMD/Intel. When the
# proprietary NVIDIA EGL vendor is installed, use the host's matching GLVND
# client libraries so GLVND can dispatch to NVIDIA (and other host vendors).
# Resolve paths from the host loader cache; never assume /usr/lib or /usr/lib64.
# This is deliberately independent of the encoder selected in Vibepollo.
find_ldconfig() {
  command -v ldconfig 2>/dev/null && return 0
  for candidate in /sbin/ldconfig /usr/sbin/ldconfig /usr/bin/ldconfig; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ldconfig_bin="$(find_ldconfig || true)"
if [ -n "$ldconfig_bin" ]; then
  ldconfig_cache="$("$ldconfig_bin" -p 2>/dev/null || true)"
  if [ -n "$ldconfig_cache" ]; then
    homebrew_prefix="${HOMEBREW_PREFIX:-}"
    case "$formula_prefix" in
      */Cellar/*)
        derived_prefix="${formula_prefix%%/Cellar/*}"
        [ -n "$homebrew_prefix" ] || homebrew_prefix="$derived_prefix"
        ;;
    esac
    if [ -z "$homebrew_prefix" ] && command -v brew >/dev/null 2>&1; then
      homebrew_prefix="$(brew --prefix 2>/dev/null || true)"
    fi
    homebrew_prefix_real=""
    if [ -n "$homebrew_prefix" ]; then
      homebrew_prefix_real="$(readlink -f -- "$homebrew_prefix" 2>/dev/null || true)"
    fi

    host_library() {
      printf '%s\n' "$ldconfig_cache" | awk \
        -v soname="$1" \
        -v prefix="$homebrew_prefix" \
        -v prefix_real="$homebrew_prefix_real" '
          function inside(path, root) {
            return root != "" && (path == root || index(path, root "/") == 1)
          }
          $1 == soname && $NF ~ /^\// {
            # This tap currently ships x86_64 bottles. Skip 32-bit multilib
            # entries so the loader never receives a library of the wrong ABI.
            if ($0 !~ /,x86-64([-,)]|$)/ && $0 !~ /,x86_64([-,)]|$)/) {
              next
            }
            if (inside($NF, prefix) || inside($NF, prefix_real)) {
              next
            }
            print $NF
            exit
          }
        '
    }

    resolve_host_library() {
      candidate="$(host_library "$1")"
      [ -n "$candidate" ] || return 1
      resolved="$(readlink -e -- "$candidate" 2>/dev/null || true)"
      [ -n "$resolved" ] && [ -r "$resolved" ] || return 1
      if [ -n "$homebrew_prefix" ]; then
        case "$resolved" in
          "$homebrew_prefix"|"$homebrew_prefix"/*) return 1 ;;
        esac
      fi
      if [ -n "$homebrew_prefix_real" ]; then
        case "$resolved" in
          "$homebrew_prefix_real"|"$homebrew_prefix_real"/*) return 1 ;;
        esac
      fi
      printf '%s\n' "$resolved"
    }

    # Detect the graphics vendor, not NVENC/CUDA. AMD and Intel systems do not
    # expose this NVIDIA vendor module and keep the regular Homebrew Mesa stack.
    nvidia_egl_vendor="$(resolve_host_library libEGL_nvidia.so.0 2>/dev/null || true)"
    if [ -n "$nvidia_egl_vendor" ]; then
      host_gl_preload=""
      missing_library=""
      for soname in \
        libEGL.so.1 \
        libGL.so.1 \
        libGLX.so.0 \
        libOpenGL.so.0 \
        libGLdispatch.so.0 \
        libgbm.so.1 \
        libdrm.so.2
      do
        if library_path="$(resolve_host_library "$soname" 2>/dev/null)"; then
          if [ -n "$host_gl_preload" ]; then
            host_gl_preload="$host_gl_preload:$library_path"
          else
            host_gl_preload="$library_path"
          fi
        else
          missing_library="$soname"
          break
        fi
      done

      # Only switch when the entire host graphics set is present. On an
      # incomplete/unsupported host, leave the normal Homebrew Mesa path intact.
      if [ -z "$missing_library" ]; then
        if [ -n "${LD_PRELOAD:-}" ]; then
          LD_PRELOAD="$host_gl_preload:$LD_PRELOAD"
        else
          LD_PRELOAD="$host_gl_preload"
        fi
        export LD_PRELOAD
        echo "vibepollo: NVIDIA EGL vendor detected; using host GLVND/EGL/GBM libraries" >&2
      else
        echo "vibepollo: NVIDIA EGL vendor detected, but host graphics stack is incomplete (missing $missing_library); keeping Homebrew Mesa" >&2
      fi
    fi
  fi
fi

# Starting the Homebrew app manually also starts the managed virtual-display
# stack. Keep CLI version/help probes side-effect free.
if [ "${1:-}" != "--version" ] && [ "${1:-}" != "--help" ] &&
   [ -x /var/lib/vibepollo/drm/bin/vibepollo-lifecycle ] &&
   [ -f /var/lib/vibepollo/drm/state/vibepollo-lifecycle ] &&
   [ ! -L /var/lib/vibepollo/drm/bin/vibepollo-lifecycle ] &&
   [ "$(stat -c '%u' /var/lib/vibepollo/drm/bin/vibepollo-lifecycle 2>/dev/null || echo invalid)" = 0 ] &&
   [ "$(stat -c '%u' /var/lib/vibepollo/drm/state/vibepollo-lifecycle 2>/dev/null || echo invalid)" = 0 ] &&
   ! systemctl is-active --quiet vibeshine-vkms.service; then
  if [ ! -x /usr/bin/pkexec ]; then
    echo "vibepollo: pkexec is required to start the managed virtual-display services" >&2
    exit 1
  fi
  /usr/bin/pkexec /var/lib/vibepollo/drm/bin/vibepollo-lifecycle start || {
    echo "vibepollo: could not start the managed virtual-display services; launch cancelled" >&2
    exit 1
  }
fi

exec "$formula_prefix/libexec/vibepollo-bin" "$@"
