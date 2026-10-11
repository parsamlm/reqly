cmake_minimum_required(VERSION 3.20)
project(reqly VERSION 1.0.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_options(-O3 -pipe -Wall -Wextra)

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK3 REQUIRED gtk+-3.0)
find_package(OpenSSL REQUIRED)
find_package(Threads REQUIRED)

include_directories(
    src/core
    src/cli
    src/gui
    ${GTK3_INCLUDE_DIRS}
    ${OPENSSL_INCLUDE_DIR}
)

set(SOURCES
    src/core/ca.cpp
    src/core/process_resolver.cpp
    src/core/proxy_guard.cpp
    src/core/system_proxy.cpp
    src/core/rules.cpp
    src/core/storage.cpp
    src/core/proxy_server.cpp
    src/cli/cli_runner.cpp
    src/gui/gui_runner.cpp
    src/main.cpp
)

add_executable(reqly ${SOURCES})
target_compile_options(reqly PRIVATE ${GTK3_CFLAGS_OTHER})
target_link_libraries(reqly PRIVATE ${GTK3_LIBRARIES} OpenSSL::SSL OpenSSL::Crypto Threads::Threads)

# Dedicated Proxy Watchdog Daemon (Lightweight, zero GUI/SSL dependencies)
add_executable(reqly-guard src/guard/guard_main.cpp)
target_link_libraries(reqly-guard PRIVATE Threads::Threads)
