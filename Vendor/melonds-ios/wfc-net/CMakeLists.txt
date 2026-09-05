# Standalone iOS build of the melonDS user-mode network stack for the WFC
# spike (see the header of EmulateurGBA/EmulatorCore/Bridge/MelonDSPlatform.cpp).
#
# Deliberately NOT the upstream `net-utils` target: that one also builds
# LocalMP / LAN / Netplay and requires enet + (optionally) pcap. Online WFC
# only needs the slirp path — Net + Net_Slirp + PacketDispatcher + the
# vendored libslirp (which ships its own glib shim, so there is no glib
# dependency). Building only these keeps the fork's CMake untouched and
# adds zero new external dependencies.

cmake_minimum_required(VERSION 3.16)
project(melonds-wfc-net C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(MELONDS_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../../melonds/src")

# The vendored libslirp is self-contained (glib shim included).
add_subdirectory("${MELONDS_SRC}/net/libslirp"
                 "${CMAKE_BINARY_DIR}/libslirp"
                 EXCLUDE_FROM_ALL)

add_library(melonds-net STATIC
    "${MELONDS_SRC}/net/Net.cpp"
    "${MELONDS_SRC}/net/Net_Slirp.cpp"
    "${MELONDS_SRC}/net/PacketDispatcher.cpp"
)

target_include_directories(melonds-net PUBLIC
    "${MELONDS_SRC}/net"
    "${MELONDS_SRC}"
)

target_link_libraries(melonds-net PUBLIC slirp)
