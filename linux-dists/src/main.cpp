#include "types.hpp"
#include "ca.hpp"
#include "storage.hpp"
#include "rules.hpp"
#include "proxy_server.hpp"
#include "system_proxy.hpp"
#include "proxy_guard.hpp"
#include "cli_runner.hpp"
#include "gui_runner.hpp"
#include <iostream>
#include <string>
#include <unistd.h>
#include <csignal>

using namespace reqly;

static LinuxSystemProxy* g_sp = nullptr;
static ProxyServer* g_ps = nullptr;

static void onSig(int sig) {
    if (g_sp) g_sp->disable();
    if (g_ps) g_ps->stop();
    ProxyGuard::restoreProxyDirect();
    std::exit(sig);
}

int main(int argc, char** argv) {
    // 0. Recover proxy settings in case of prior crash or power loss (mirrors Mac ProxyGuard.recoverAtLaunch())
    ProxyGuard::recoverAtLaunch();

    std::signal(SIGINT, onSig);
    std::signal(SIGTERM, onSig);
    std::signal(SIGSEGV, onSig);
    std::signal(SIGABRT, onSig);
    std::signal(SIGQUIT, onSig);
    std::signal(SIGHUP, onSig);

    bool forceGui = false;
    bool forceCli = false;
    int port = 9090;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--gui" || a == "-g") forceGui = true;
        else if (a == "--cli" || a == "-c") forceCli = true;
        else if ((a == "--port" || a == "-p") && i + 1 < argc) port = std::stoi(argv[++i]);
        else if (a == "--restore-proxy" || a == "--clean-proxy") {
            ProxyGuard::restoreProxyDirect();
            std::cout << "[Reqly] System proxy settings restored to 'none'.\n";
            return 0;
        }
        else if (a == "--help" || a == "-h") {
            std::cout << "Reqly Linux - Network Traffic Inspector\n\n"
                      << "Usage:\n"
                      << "  reqly [options]\n\n"
                      << "Options:\n"
                      << "  --gui, -g          Launch Graphical User Interface directly\n"
                      << "  --cli, -c          Launch Command Line Interface directly\n"
                      << "  --port, -p <N>     Set proxy port (default: 9090)\n"
                      << "  --restore-proxy    Reset system proxy settings to 'none'\n"
                      << "  --help, -h         Show this help message\n";
            return 0;
        }
    }

    TrafficStorage storage;
    RulesEngine rules;
    CertificateAuthority ca;
    ca.initialize();
    ProxyServer proxy(storage, rules, ca);
    LinuxSystemProxy sysProxy;

    g_sp = &sysProxy;
    g_ps = &proxy;

    bool launchGui = false;
    if (forceGui) {
        launchGui = true;
    } else if (forceCli) {
        launchGui = false;
    } else {
        if (!isatty(STDIN_FILENO)) {
            launchGui = true;
        } else {
            std::cout << "\033[1m\033[38;2;11;154;131mReqly Network Traffic Inspector\033[0m\n";
            std::cout << "Select interface mode:\n";
            std::cout << "  [1] Desktop GUI (Full Application)\n";
            std::cout << "  [2] CLI Inspector (Terminal Mode)\n";
            std::cout << "Choice [1/2] (default: 1): ";
            std::string c;
            std::getline(std::cin, c);
            launchGui = (c != "2");
        }
    }

    proxy.start(port);
    sysProxy.enable(port);

    int ret = 0;
    if (launchGui) {
        GuiRunner gui(storage, proxy, rules, sysProxy);
        ret = gui.run(argc, argv);
    } else {
        CliRunner cli(storage, proxy, sysProxy);
        ret = cli.run();
    }

    sysProxy.disable();
    proxy.stop();
    return ret;
}
