#!/bin/sh
set -e

# [Soft link defense] Force MSYS2 to pull up real symbolic links at the Windows permission level
# Force MSYS2 to try to create a real Windows system-level soft link to avoid the build system reporting errors due to link failure
export MSYS="winsymlinks:sys"
# Enable POSIX and Windows NT permission security mapping to prevent permission denial when reading, writing and executing files.
export CYGWIN="ntsec"

# [Path Search] Automatically grab the real path of cc1.exe inside gcc and inject it into PATH
# Automatically capture the current internal core installation directory of gcc (including cc1.exe, collect2 and other back-end components)
export GCC_DIR="$(gcc -print-search-dirs | sed -ne '/^install: /s///p')"
# Append it to PATH to prevent old build systems from prompting "command not found" when calling the compiler component under the hood.
export PATH="$PATH:$GCC_DIR"

# [Compilation Environment Specification] Standardized C language compiler environment variables
# Explicitly specify the search paths for standard header files and library files to ensure that the compiler can accurately locate basic dependencies.
# Add -Wall -Wextra (or even -Werror if we want the warnings to interrupt compilation directly to force them to be fixed)
export CFLAGS="-I${GCC_DIR}/include -L${GCC_DIR} -L/usr/lib -Wall -Wextra"


# Extended compilation flags specific to the AST/Mamfile build system
# core key：-fno-use-linker-plugin 
#   Function: Turn off the modern GCC linker plug-in (LTO plug-in).
#   Reason: To prevent modern linker plugins from colliding with older, non-standard build system packaging/linking processes and causing crashes.
export CCFLAGS="${CFLAGS} -fno-use-linker-plugin"


# Specifies a private directory where the GCC linker searches for library files at compile time
export LIBRARY_PATH="${GCC_DIR}"

# [Global Shebang added] Traverse all .sh scripts in the src directory, and insert the header safely into #!/bin/sh
if [ -d src ]; then
    echo "Safely padding the /bin/sh boot header for all .sh scripts in the src directory..."
    find src -name "*.sh" -type f | while read -r sh_file; do
        if ! head -n 1 "$sh_file" | grep -q "/bin/sh"; then
            sed -i '1s/^/#!\/bin\/sh\n/' "$sh_file"
        fi
    done
fi

# [UNC Compatible] Inject macro isolation patch into astconf.c in place before compilation
if [ -f src/lib/libast/port/astconf.c ]; then
    patch -p1 <ksh-unc-paths.patch
fi

# [Replace the old cygwin interface]
#   src/lib/libast/path/pathnative.c
#   src/lib/libast/path/pathposix.c

sed -Ei '/^\s*extern\s+void\s+.*cygwin_conv_to_win32_path/c\#include <sys/cygwin.h>' "src/lib/libast/path/pathnative.c"
sed -i 's/cygwin_conv_to_win32_path(path, tmp);/cygwin_conv_path(CCP_POSIX_TO_WIN_A, path, tmp, PATH_MAX);/g' "src/lib/libast/path/pathnative.c"
sed -i 's/cygwin_conv_to_win32_path(path, buf);/cygwin_conv_path(CCP_POSIX_TO_WIN_A, path, buf, siz);/g' "src/lib/libast/path/pathnative.c"

sed -Ei '/^\s*extern\s+void\s+.*cygwin_conv_to_posix_path/c\#include <sys/cygwin.h>' "src/lib/libast/path/pathposix.c"
sed -i 's/cygwin_conv_to_posix_path(path, tmp);/cygwin_conv_path(CCP_WIN_A_TO_POSIX, path, tmp, PATH_MAX);/g' "src/lib/libast/path/pathposix.c"
sed -i 's/cygwin_conv_to_posix_path(path, buf);/cygwin_conv_path(CCP_WIN_A_TO_POSIX, path, buf, siz);/g' "src/lib/libast/path/pathposix.c"

# [Macro Conflict Interception] Forcibly remove system iconv macro definition confusion
if [ -f src/lib/libast/features/iconv ]; then
    sed -i '6s/^/#undef _lib_iconv_open\n/' src/lib/libast/features/iconv
fi

# [Environment variables ready] Add the local target compilation bin directory to PATH
TARGET_BIN="$PWD/arch/cygwin.i386/bin"
mkdir -p bin "$TARGET_BIN"
export PATH="$PWD/bin:$TARGET_BIN:$PATH"

echo "[Phase 1] Start the first round of compilation (it is normal if interruption is caused by the fragile fork mechanism of Windows)..."
CC="/usr/bin/gcc" /bin/sh bin/package make PACKAGEROOT="$PWD" | tee ../ksh_build_log.txt 2>&1 || true

# [Detection] Check whether the target ksh binary file has been successfully generated
KSH_BIN=$(ls arch/*/bin/ksh 2>/dev/null || true)

if [ -n "$KSH_BIN" ] && [ -f "$KSH_BIN" ]; then
    echo "[Skip] Detected ksh binary successfully generated in first round!"
else
    echo "[Phase 2] It is found that the binary is not ready yet, and the second round of in-situ resurrection compilation is started..."
    CC="/usr/bin/gcc" /bin/sh bin/package make PACKAGEROOT="$PWD" | tee -a ../ksh_build_log.txt 2>&1
fi

echo "=========================================================="
echo "Congratulations, man! Rigorous [complete body] Ksh93 u+m binary file compiled successfully!"
echo "Your native ksh.exe is already safely located in the following path:"
ls -l arch/*/bin/ksh
echo "=========================================================="

# Automatically find the compiled ksh and install it to /usr/local/bin/ksh
KSH_SRC=$(ls arch/*/bin/ksh 2>/dev/null)

if [ -f "$KSH_SRC" ]; then
    echo "[Standardized Installation] Deploying ksh to /usr/local/bin/..."
    install -Dm755 "$KSH_SRC" /usr/local/bin/ksh
    echo "Installation successful! Now you can call it directly by typing ksh anywhere."
else
    echo "The compiled ksh binary file was not found, please compile first!"
    exit 1
fi

# Check and write safely to /etc/shells
KSH_PATH="/usr/local/bin/ksh"

if ! grep -qxF "$KSH_PATH" /etc/shells; then
    echo "[Registration Shell] Writing $KSH_PATH to /etc/shells..."
    echo "$KSH_PATH" >> /etc/shells
    echo "Registration completed!"
else
    echo "/etc/shells the path already exists in the directory and registration is skipped."
fi

# test
./arch/cygwin.i386/bin/ksh.exe --version
./arch/cygwin.i386/bin/ksh.exe -c 'print -r -- "Math test: $(( 3.14159 * 2 ))"'

echo "all work done, log file is ../ksh_build_log.txt"

