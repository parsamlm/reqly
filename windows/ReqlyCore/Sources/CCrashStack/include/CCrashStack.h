// The crashed thread's stack, when Swift's code stops Reqly, as a failed check does: written to
// the standard error, which the app points at its run's file, the way Swift's own backtracer
// writes it. That backtracer can't run in a Windows app: it gets a console of its own, and what it
// writes goes with it. Windows only; elsewhere it does nothing.

#ifndef CCRASHSTACK_H
#define CCRASHSTACK_H

/// Watches, from now on, for a crash in Swift's code: the core's, and Swift's runtime and libraries'.
/// Calling it again does nothing. Once it has written the stack, on the crashed thread, it calls
/// `then`, if there is one and the stack went through code in no module, such as .NET's, which it
/// compiles as it runs: .NET can name those frames itself, and only before the process ends.
void crashstack_install(void (*then)(void));

#endif
