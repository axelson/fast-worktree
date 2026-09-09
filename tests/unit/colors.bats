load ../test_helper

setup() {
    isolate_env
    source "$FW_ROOT/lib/colors.sh"
}

# The gate is re-evaluated by fw_color_init, so each test pins the env then
# re-inits to a known state (source-time state depends on the runner's tty).

@test "colors: FW_COLOR=always sets the legacy escape codes" {
    FW_COLOR=always fw_color_init
    [ "$C_RESET" = $'\033[0m' ]
    [ "$C_RED" = $'\033[0;31m' ]
    [ "$C_GREEN" = $'\033[0;32m' ]
    [ "$C_YELLOW" = $'\033[1;33m' ]
    [ "$C_BLUE" = $'\033[0;34m' ]
    [ "$C_CYAN" = $'\033[0;36m' ]
    [ "$C_MAGENTA" = $'\033[0;35m' ]
    [ "$C_BLUE_BRIGHT" = $'\033[1;94m' ]
    [ "$C_DIM" = $'\033[2m' ]
}

@test "colors: FW_COLOR=never blanks every constant" {
    FW_COLOR=never fw_color_init
    [ -z "$C_RESET" ]
    [ -z "$C_RED" ]
    [ -z "$C_GREEN" ]
    [ -z "$C_YELLOW" ]
    [ -z "$C_BLUE" ]
    [ -z "$C_CYAN" ]
    [ -z "$C_MAGENTA" ]
    [ -z "$C_BLUE_BRIGHT" ]
    [ -z "$C_DIM" ]
}

@test "colors: NO_COLOR disables color under auto but FW_COLOR=always overrides it" {
    NO_COLOR=1 FW_COLOR=auto fw_color_init
    [ -z "$C_RED" ]
    NO_COLOR=1 FW_COLOR=always fw_color_init
    [ "$C_RED" = $'\033[0;31m' ]
}

@test "colors: auto without a tty (piped test stdout) blanks color" {
    # bats captures stdout, so [ -t 1 ] is false here — auto must gate off.
    unset NO_COLOR
    FW_COLOR=auto fw_color_init
    [ -z "$C_RED" ]
}
