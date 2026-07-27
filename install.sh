#!/bin/bash
# LEM - Linux Environment Manager
# One-click installation script
# Usage: bash install.sh [options]
#        bash install.sh uninstall

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

LEM_VERSION="0.1.0"
LEM_PREFIX="$HOME/.local"
LEM_INSTALL_DIR=""
LEM_BIN_DIR=""
LEM_CONFIG_DIR=""
FORCE=false
SKIP_DEPS=false
NO_COMPILE=false
ACTION="install"

show_help() {
    echo "Usage: bash install.sh [options]"
    echo "       bash install.sh uninstall"
    echo ""
    echo "Options:"
    echo "  --prefix=<path>   Installation prefix (default: \$HOME/.local)"
    echo "                    Files go to <prefix>/share/lem, binary to <prefix>/bin"
    echo "  --skip-deps       Skip automatic dependency installation"
    echo "  --no-compile      Skip C native module compilation"
    echo "  --force           Force reinstall even if LEM is already installed"
    echo "  --help, -h        Show this help message"
    echo ""
    echo "Commands:"
    echo "  uninstall         Remove LEM from the system"
    echo ""
    echo "Examples:"
    echo "  bash install.sh                     # Default install"
    echo "  bash install.sh --prefix=/opt/lem   # Custom install location"
    echo "  bash install.sh --skip-deps         # Skip dependency installation"
    echo "  bash install.sh uninstall            # Remove LEM"
}

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --skip-deps) SKIP_DEPS=true ;;
        --no-compile) NO_COMPILE=true ;;
        --prefix=*) LEM_PREFIX="${arg#*=}" ;;
        uninstall) ACTION="uninstall" ;;
        --help|-h)
            show_help
            exit 0
            ;;
    esac
done

# Derive paths from prefix
LEM_INSTALL_DIR="${LEM_INSTALL_DIR:-$LEM_PREFIX/share/lem}"
LEM_BIN_DIR="${LEM_BIN_DIR:-$LEM_PREFIX/bin}"
LEM_CONFIG_DIR="${LEM_CONFIG_DIR:-$HOME/.config/lem}"

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BLUE}==>${NC} $1"; }

# Check if running on Linux
check_os() {
    if [ "$(uname)" != "Linux" ]; then
        error "LEM only supports Linux systems."
    fi
    info "OS: $(uname -s) $(uname -r)"
}

# Check for existing installation
check_existing() {
    if [ -d "$LEM_INSTALL_DIR" ] && [ -f "$LEM_BIN_DIR/lem" ]; then
        if [ "$FORCE" = true ]; then
            warn "Existing LEM installation found. Reinstalling (--force)..."
        else
            warn "Existing LEM installation found at $LEM_INSTALL_DIR"
            warn "Use --force to reinstall: bash install.sh --force"
            echo ""
            read -p "Continue with reinstall? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                info "Installation cancelled."
                exit 0
            fi
        fi
    fi
}

# Detect package manager
detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
        PKG_INSTALL="sudo apt-get install -y"
        PKG_UPDATE="sudo apt-get update"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="sudo dnf install -y"
        PKG_UPDATE="sudo dnf check-update || true"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL="sudo yum install -y"
        PKG_UPDATE="sudo yum check-update || true"
    elif command -v pacman &>/dev/null; then
        PKG_MANAGER="pacman"
        PKG_INSTALL="sudo pacman -S --noconfirm"
        PKG_UPDATE="sudo pacman -Sy"
    else
        warn "No supported package manager found. Install dependencies manually."
        PKG_MANAGER="unknown"
        PKG_INSTALL=""
        PKG_UPDATE=""
    fi
    info "Package manager: $PKG_MANAGER"
}

# Install dependencies
install_dependencies() {
    step "Installing dependencies..."

    if [ -z "$PKG_INSTALL" ]; then
        warn "Skipping automatic dependency installation."
        warn "Please manually install: lua5.4, libsqlite3-dev, gcc, make"
        return
    fi

    # Update package lists
    info "Updating package lists..."
    eval "$PKG_UPDATE" 2>/dev/null || true

    # Install core dependencies
    case "$PKG_MANAGER" in
        apt)
            $PKG_INSTALL lua5.4 liblua5.4-dev libsqlite3-dev gcc make 2>/dev/null || \
            $PKG_INSTALL lua5.4 liblua5.4-0-dev libsqlite3-dev gcc make 2>/dev/null || \
            warn "Some packages may not be available. Check manually."
            ;;
        dnf|yum)
            $PKG_INSTALL lua lua-devel sqlite-devel gcc make 2>/dev/null || \
            warn "Some packages may not be available. Check manually."
            ;;
        pacman)
            $PKG_INSTALL lua sqlite gcc make 2>/dev/null || \
            warn "Some packages may not be available. Check manually."
            ;;
    esac

    # Verify critical tools
    if command -v lua5.4 &>/dev/null || command -v lua &>/dev/null; then
        local lua_ver=$(lua5.4 -v 2>/dev/null || lua -v 2>/dev/null || echo "unknown")
        info "Lua: $lua_ver"
    else
        warn "Lua not found. LEM can still run with Lua fallback (no C modules)."
    fi

    if command -v gcc &>/dev/null; then
        info "GCC: $(gcc --version | head -1)"
    else
        warn "GCC not found. C native modules will not be available."
    fi

    if command -v sqlite3 &>/dev/null; then
        info "SQLite3: $(sqlite3 --version | head -1)"
    fi
}

# Install LEM files
install_files() {
    step "Installing LEM files..."

    # Determine source directory
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local SRC_DIR="$SCRIPT_DIR"

    # Create directories
    mkdir -p "$LEM_INSTALL_DIR"
    mkdir -p "$LEM_BIN_DIR"
    mkdir -p "$LEM_CONFIG_DIR"
    mkdir -p "$LEM_CONFIG_DIR/sources"
    mkdir -p "$LEM_CONFIG_DIR/recipes"
    mkdir -p "$LEM_INSTALL_DIR/backups"
    mkdir -p "$HOME/.cache/lem"

    # Copy project files
    info "Copying source files..."
    cp -r "$SRC_DIR/src" "$LEM_INSTALL_DIR/"
    cp -r "$SRC_DIR/recipes" "$LEM_INSTALL_DIR/" 2>/dev/null || true
    cp -r "$SRC_DIR/native" "$LEM_INSTALL_DIR/" 2>/dev/null || true

    # Copy main.lua
    cp "$SRC_DIR/src/main.lua" "$LEM_INSTALL_DIR/"

    # Copy config files
    info "Copying config files..."
    if [ -d "$SRC_DIR/config" ]; then
        cp -r "$SRC_DIR/config" "$LEM_INSTALL_DIR/"
        info "Config files copied to $LEM_INSTALL_DIR/config/"
    else
        warn "Config directory not found in source."
    fi

    # Create lem launcher script
    info "Creating launcher..."
    cat > "$LEM_BIN_DIR/lem" << LAUNCHER
#!/bin/bash
# LEM - Linux Environment Manager
# Auto-generated launcher

LEM_ROOT="\${LEM_ROOT:-$LEM_INSTALL_DIR}"
LUA_PATH="\$LEM_ROOT/src/?.lua;\$LEM_ROOT/src/?/init.lua;./src/?.lua;./src/?/init.lua"

# Find Lua interpreter
LUA=""
if command -v lua5.4 &>/dev/null; then
    LUA="lua5.4"
elif command -v lua &>/dev/null; then
    LUA="lua"
else
    echo "Error: Lua interpreter not found."
    echo "Install with: sudo apt install lua5.4"
    exit 1
fi

exec \$LUA -e "package.path=\"\$LUA_PATH;\" .. package.path" \
    -e "_G.LEM_ROOT=\"\$LEM_ROOT\"" \
    "\$LEM_ROOT/src/main.lua" "\$@"
LAUNCHER
    chmod +x "$LEM_BIN_DIR/lem"

    info "Installed to: $LEM_INSTALL_DIR"
    info "Launcher: $LEM_BIN_DIR/lem"
}

# Compile C native modules
compile_native() {
    step "Compiling C native modules..."

    if ! command -v gcc &>/dev/null; then
        warn "GCC not found. Skipping native module compilation."
        warn "LEM will use Lua fallback implementations."
        return
    fi

    local NATIVE_DIR="$LEM_INSTALL_DIR/native"
    if [ ! -f "$NATIVE_DIR/Makefile" ]; then
        warn "Native source not found. Skipping."
        return
    fi

    # Check for Lua headers
    local LUA_INC=""
    if pkg-config --exists lua5.4 2>/dev/null; then
        LUA_INC=$(pkg-config --cflags lua5.4)
    elif pkg-config --exists lua 2>/dev/null; then
        LUA_INC=$(pkg-config --cflags lua)
    elif [ -d "/usr/include/lua5.4" ]; then
        LUA_INC="-I/usr/include/lua5.4"
    elif [ -d "/usr/include/lua" ]; then
        LUA_INC="-I/usr/include/lua"
    fi

    if [ -n "$LUA_INC" ]; then
        info "Lua include flags: $LUA_INC"
        cd "$NATIVE_DIR"
        if make LUA_CFLAGS="$LUA_INC" 2>/dev/null; then
            info "Native modules compiled successfully."
        else
            warn "Native compilation failed. LEM will use Lua fallback."
        fi
        cd - >/dev/null
    else
        warn "Lua development headers not found."
        warn "Install with: sudo apt install liblua5.4-dev"
        warn "LEM will use Lua fallback implementations."
    fi
}

# Generate default environment variables
generate_env() {
    step "Generating default environment variables..."

    local ENV_FILE="$LEM_CONFIG_DIR/env.sh"

    if [ -f "$ENV_FILE" ] && [ "$FORCE" != true ]; then
        info "Environment file already exists: $ENV_FILE"
        return
    fi

    cat > "$ENV_FILE" << ENVVARS
# LEM - Linux Environment Manager
# Default environment variables
# Edit this file to customize your environment
# Load with: source ~/.config/lem/env.sh

# Editor
export EDITOR="\${EDITOR:-vim}"
export VISUAL="\${VISUAL:-vim}"

# Pager
export PAGER="\${PAGER:-less}"

# LEM paths
export LEM_CONFIG="\${LEM_CONFIG:-$LEM_CONFIG_DIR}"
export LEM_DATA="\${LEM_DATA:-$LEM_INSTALL_DIR}"
export LEM_CACHE="\${LEM_CACHE:-$HOME/.cache/lem}"
ENVVARS

    info "Environment file generated: $ENV_FILE"
}

# Setup PATH
setup_path() {
    step "Configuring PATH..."

    if echo "$PATH" | grep -q "$LEM_BIN_DIR"; then
        info "PATH already includes $LEM_BIN_DIR"
        return
    fi

    local SHELL_RC=""
    local SHELL_NAME=$(basename "$SHELL")

    case "$SHELL_NAME" in
        zsh)  SHELL_RC="$HOME/.zshrc" ;;
        bash)
            if [ -f "$HOME/.bashrc" ]; then
                SHELL_RC="$HOME/.bashrc"
            elif [ -f "$HOME/.bash_profile" ]; then
                SHELL_RC="$HOME/.bash_profile"
            else
                SHELL_RC="$HOME/.bashrc"
            fi
            ;;
        *) SHELL_RC="$HOME/.profile" ;;
    esac

    local PATH_LINE="export PATH=\"$LEM_BIN_DIR:\$PATH\""

    if [ -f "$SHELL_RC" ] && grep -q "$LEM_BIN_DIR" "$SHELL_RC" 2>/dev/null; then
        info "PATH already configured in $SHELL_RC"
    else
        echo "" >> "$SHELL_RC"
        echo "# LEM - Linux Environment Manager" >> "$SHELL_RC"
        echo "$PATH_LINE" >> "$SHELL_RC"
        info "Added $LEM_BIN_DIR to PATH in $SHELL_RC"
    fi

    # Also create symlink in /usr/local/bin if possible
    if [ -w "/usr/local/bin" ] 2>/dev/null; then
        ln -sf "$LEM_BIN_DIR/lem" "/usr/local/bin/lem"
        info "Created symlink: /usr/local/bin/lem"
    fi
}

# Run tests
run_tests() {
    step "Running tests..."

    local TEST_DIR="$LEM_INSTALL_DIR/tests"
    local TEST_RUNNER="$TEST_DIR/test_runner.lua"

    if [ ! -f "$TEST_RUNNER" ]; then
        # Try to copy tests from source
        local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -d "$SCRIPT_DIR/tests" ]; then
            cp -r "$SCRIPT_DIR/tests" "$LEM_INSTALL_DIR/"
        fi
    fi

    if [ ! -f "$TEST_RUNNER" ]; then
        warn "Test runner not found. Skipping tests."
        return
    fi

    # Find Lua interpreter
    local LUA=""
    if command -v lua5.4 &>/dev/null; then
        LUA="lua5.4"
    elif command -v lua &>/dev/null; then
        LUA="lua"
    else
        warn "Lua interpreter not found. Skipping tests."
        return
    fi

    info "Running test suite..."
    cd "$LEM_INSTALL_DIR"
    if $LUA -e "package.path=\"$LEM_INSTALL_DIR/src/?.lua;$LEM_INSTALL_DIR/src/?/init.lua;\" .. package.path" \
        "$TEST_RUNNER" 2>/dev/null; then
        info "All tests passed."
    else
        warn "Some tests failed or encountered errors."
        warn "Run manually: cd $LEM_INSTALL_DIR && $LUA tests/test_runner.lua"
    fi
    cd - >/dev/null
}

# Run LEM init
run_init() {
    step "Running LEM initialization..."

    export PATH="$LEM_BIN_DIR:$PATH"

    if command -v lem &>/dev/null; then
        lem init --force 2>/dev/null && info "LEM initialized successfully." || warn "LEM init encountered issues."
    else
        warn "LEM command not available yet. Run 'source $SHELL_RC' then 'lem init'."
    fi
}

# Record dependencies in state DB
record_deps() {
    step "Recording dependencies in LEM state..."
    
    export PATH="$LEM_BIN_DIR:$PATH"
    
    local LUA=""
    if command -v lua5.4 &>/dev/null; then
        LUA="lua5.4"
    elif command -v lua &>/dev/null; then
        LUA="lua"
    fi
    
    if [ -n "$LUA" ]; then
        $LUA -e "
            package.path='$LEM_INSTALL_DIR/src/?.lua;' .. package.path
            _G.LEM_ROOT='$LEM_INSTALL_DIR'
            local DB = require('core.db')
            local FS = require('core.fs')
            local data_dir = FS.expand_path('~/.local/share/lem')
            DB.init(data_dir)
            local deps = {'lua5.4', 'libsqlite3-dev', 'gcc', 'make', 'sqlite3'}
            for _, name in ipairs(deps) do
                DB.add_package({name='lem-dep:'..name, manager='lem-internal', version='system'})
            end
            DB.close()
            print('Dependencies recorded in state database.')
        " 2>/dev/null || warn "Could not record dependencies (non-critical)"
    fi
}

# Print summary
print_summary() {
    step "Installation complete!"
    echo ""
    echo -e "${GREEN}LEM v$LEM_VERSION installed successfully!${NC}"
    echo ""
    echo "Installation details:"
    echo "  Files:      $LEM_INSTALL_DIR"
    echo "  Launcher:   $LEM_BIN_DIR/lem"
    echo "  Config:     $LEM_CONFIG_DIR"
    echo "  Env file:   $LEM_CONFIG_DIR/env.sh"
    echo ""

    # Show component status
    echo "Component status:"
    if command -v lua5.4 &>/dev/null || command -v lua &>/dev/null; then
        echo -e "  Lua:        ${GREEN}OK${NC}"
    else
        echo -e "  Lua:        ${RED}NOT FOUND${NC}"
    fi
    if command -v gcc &>/dev/null && ls "$LEM_INSTALL_DIR/native/"*.so &>/dev/null 2>&1; then
        echo -e "  C modules:  ${GREEN}compiled${NC}"
    elif command -v gcc &>/dev/null; then
        echo -e "  C modules:  ${YELLOW}not compiled (fallback available)${NC}"
    else
        echo -e "  C modules:  ${YELLOW}skipped (no GCC, fallback available)${NC}"
    fi
    if [ -f "$LEM_CONFIG_DIR/env.sh" ]; then
        echo -e "  Env vars:   ${GREEN}generated${NC}"
    else
        echo -e "  Env vars:   ${YELLOW}not generated${NC}"
    fi
    echo ""

    echo "Quick start:"
    echo "  source $SHELL_RC    # Reload shell (or open new terminal)"
    echo "  lem help            # See available commands"
    echo "  lem init            # Initialize environment"
    echo "  lem apply dev       # Set up development environment"
    echo ""
    echo "Or use full path:"
    echo "  $LEM_BIN_DIR/lem help"
    echo ""
}

# Uninstall LEM
uninstall() {
    echo ""
    echo -e "${RED}==>${NC} Uninstalling LEM..."
    echo ""

    local found=false

    # Remove installation directory
    if [ -d "$LEM_INSTALL_DIR" ]; then
        info "Removing $LEM_INSTALL_DIR"
        rm -rf "$LEM_INSTALL_DIR"
        found=true
    else
        warn "Installation directory not found: $LEM_INSTALL_DIR"
    fi

    # Remove launcher binary
    if [ -f "$LEM_BIN_DIR/lem" ]; then
        info "Removing $LEM_BIN_DIR/lem"
        rm -f "$LEM_BIN_DIR/lem"
        found=true
    fi

    # Remove symlink in /usr/local/bin
    if [ -L "/usr/local/bin/lem" ]; then
        info "Removing /usr/local/bin/lem symlink"
        rm -f "/usr/local/bin/lem"
        found=true
    fi

    # Remove PATH entry from shell RC files
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile"; do
        if [ -f "$rc" ] && grep -q "LEM - Linux Environment Manager" "$rc" 2>/dev/null; then
            info "Cleaning PATH from $rc"
            sed -i '/# LEM - Linux Environment Manager/d' "$rc"
            sed -i "\|export PATH=\"$LEM_BIN_DIR|d" "$rc"
            found=true
        fi
    done

    # Ask about config and data
    if [ -d "$LEM_CONFIG_DIR" ]; then
        echo ""
        read -p "Remove config directory ($LEM_CONFIG_DIR)? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$LEM_CONFIG_DIR"
            info "Removed $LEM_CONFIG_DIR"
        else
            info "Kept $LEM_CONFIG_DIR"
        fi
    fi

    if [ "$found" = true ]; then
        echo ""
        info "LEM has been uninstalled."
    else
        echo ""
        warn "No LEM installation found."
    fi
    echo ""
}

# Main
main() {
    echo ""
    echo "  _     ___  ___  __  __"
    echo " | |   / _ \/ __||  \/  |"
    echo " | |__| (_) \__ \| |\/| |"
    echo " |____\___/|___/|_|  |_|"
    echo ""
    echo " Linux Environment Manager v$LEM_VERSION"
    echo " Installer"
    echo ""

    if [ "$ACTION" = "uninstall" ]; then
        uninstall
        exit 0
    fi

    check_os
    check_existing
    install_files
    if [ "$SKIP_DEPS" = true ]; then
        step "Skipping dependency installation (--skip-deps)"
    else
        detect_package_manager
        install_dependencies
    fi
    if [ "$NO_COMPILE" = true ]; then
        step "Skipping C module compilation (--no-compile)"
        warn "LEM will use Lua fallback implementations."
    else
        compile_native
    fi
    generate_env
    setup_path
    run_tests
    run_init
    record_deps
    print_summary
}

main "$@"
