#ifndef REQLY_QUICKJS_H
#define REQLY_QUICKJS_H

#include <stddef.h>

/// A QuickJS runtime and the deadline of the script running in it. Use one from one thread
/// at a time.
typedef struct ReqlyRuntime ReqlyRuntime;

/// A runtime whose scripts may use up to `memory_limit` bytes and `stack_size` bytes of stack.
/// The stack size must fit in the stack of the threads that run scripts.
ReqlyRuntime *_Nullable reqly_runtime_new(size_t memory_limit, size_t stack_size);
void reqly_runtime_free(ReqlyRuntime *_Nonnull runtime);

/// Runs `prelude`, then `script`, in a fresh context, then calls the global function `entry`
/// with `argument`, a string. If the function returns a promise, it runs until it settles.
///
/// Returns 0 with the function's result as text in `*result`, or 1 with the error as text,
/// including where it happened. Stops the script after `seconds`. The caller frees `*result`.
int reqly_run(
    ReqlyRuntime *_Nonnull runtime, const char *_Nonnull prelude, size_t prelude_length,
    const char *_Nonnull script, size_t script_length, const char *_Nonnull entry,
    const char *_Nonnull argument, size_t argument_length, double seconds, char *_Nullable *_Nonnull result,
    size_t *_Nonnull result_length);

/// Compiles `script` without running it. Returns 0, or 1 with the syntax error as text in
/// `*result`, which the caller frees.
int reqly_check(
    ReqlyRuntime *_Nonnull runtime, const char *_Nonnull script, size_t script_length,
    char *_Nullable *_Nonnull result, size_t *_Nonnull result_length);

#endif
