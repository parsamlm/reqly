#include "reqly_quickjs.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "quickjs.h"

struct ReqlyRuntime {
    JSRuntime *runtime;
    /// When the running script must stop, in seconds of the monotonic clock. 0 while none runs.
    double deadline;
};

static double now(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}

/// QuickJS asks this every so often while a script runs; nonzero stops it.
static int interrupt(JSRuntime *rt, void *opaque) {
    (void)rt;
    ReqlyRuntime *runtime = opaque;
    return runtime->deadline > 0 && now() > runtime->deadline;
}

ReqlyRuntime *reqly_runtime_new(size_t memory_limit, size_t stack_size) {
    ReqlyRuntime *runtime = calloc(1, sizeof *runtime);
    if (!runtime) return NULL;
    runtime->runtime = JS_NewRuntime();
    if (!runtime->runtime) {
        free(runtime);
        return NULL;
    }
    JS_SetMemoryLimit(runtime->runtime, memory_limit);
    JS_SetMaxStackSize(runtime->runtime, stack_size);
    JS_SetInterruptHandler(runtime->runtime, interrupt, runtime);
    return runtime;
}

void reqly_runtime_free(ReqlyRuntime *runtime) {
    JS_FreeRuntime(runtime->runtime);
    free(runtime);
}

static char *copy(const char *text, size_t length, size_t *result_length) {
    char *copied = malloc(length + 1);
    if (!copied) {
        *result_length = 0;
        return NULL;
    }
    memcpy(copied, text, length);
    copied[length] = 0;
    *result_length = length;
    return copied;
}

/// A value as text, such as a string's own text or an error's message.
static char *text_of(JSContext *ctx, JSValueConst value, size_t *result_length) {
    size_t length = 0;
    const char *text = JS_ToCStringLen(ctx, &length, value);
    if (!text) {
        // Turning it into text threw, too; that exception isn't the one to report.
        JS_FreeValue(ctx, JS_GetException(ctx));
        return copy("The script failed.", strlen("The script failed."), result_length);
    }
    char *copied = copy(text, length, result_length);
    JS_FreeCString(ctx, text);
    return copied;
}

/// The thrown value as text: the error's message, then the stack that says where it happened.
static char *error_text(JSContext *ctx, JSValueConst error, size_t *result_length) {
    size_t message_length = 0;
    char *message = text_of(ctx, error, &message_length);
    if (!message || !JS_IsError(error)) return message;
    JSValue stack = JS_GetPropertyStr(ctx, error, "stack");
    if (!JS_IsString(stack)) {
        JS_FreeValue(ctx, stack);
        return message;
    }
    size_t stack_length = 0;
    char *trace = text_of(ctx, stack, &stack_length);
    JS_FreeValue(ctx, stack);
    if (!trace) return message;
    char *joined = malloc(message_length + 1 + stack_length + 1);
    if (!joined) {
        free(trace);
        return message;
    }
    memcpy(joined, message, message_length);
    joined[message_length] = '\n';
    memcpy(joined + message_length + 1, trace, stack_length);
    joined[message_length + 1 + stack_length] = 0;
    *result_length = message_length + 1 + stack_length;
    free(message);
    free(trace);
    return joined;
}

static char *exception_text(JSContext *ctx, size_t *result_length) {
    JSValue exception = JS_GetException(ctx);
    char *text = error_text(ctx, exception, result_length);
    JS_FreeValue(ctx, exception);
    return text;
}

int reqly_run(
    ReqlyRuntime *runtime, const char *prelude, size_t prelude_length, const char *script, size_t script_length,
    const char *entry, const char *argument, size_t argument_length, double seconds, char **result,
    size_t *result_length) {
    JSRuntime *rt = runtime->runtime;
    // Scripts run on more than one thread, one at a time; the stack check needs to know whose.
    JS_UpdateStackTop(rt);
    runtime->deadline = now() + seconds;
    *result = NULL;
    *result_length = 0;
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) {
        runtime->deadline = 0;
        *result = copy("Reqly couldn't start the script.", strlen("Reqly couldn't start the script."), result_length);
        return 1;
    }
    int failed = 0;
    JSValue value = JS_Eval(ctx, prelude, prelude_length, "reqly.js", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(value)) {
        failed = 1;
        *result = exception_text(ctx, result_length);
        goto done;
    }
    JS_FreeValue(ctx, value);
    value = JS_Eval(ctx, script, script_length, "script.js", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(value)) {
        failed = 1;
        *result = exception_text(ctx, result_length);
        goto done;
    }
    JS_FreeValue(ctx, value);

    JSValue global = JS_GetGlobalObject(ctx);
    JSValue function = JS_GetPropertyStr(ctx, global, entry);
    JSValue parameter = JS_NewStringLen(ctx, argument, argument_length);
    value = JS_Call(ctx, function, global, 1, (JSValueConst *)&parameter);
    JS_FreeValue(ctx, parameter);
    JS_FreeValue(ctx, function);
    JS_FreeValue(ctx, global);
    if (JS_IsException(value)) {
        failed = 1;
        *result = exception_text(ctx, result_length);
        goto done;
    }
    if (JS_IsPromise(value)) {
        // An async function: its jobs run now, since scripts have nothing to wait for.
        JSContext *job_context;
        int ran;
        while ((ran = JS_ExecutePendingJob(rt, &job_context)) > 0) {
        }
        if (ran < 0) {
            failed = 1;
            *result = exception_text(job_context, result_length);
            goto done;
        }
        JSPromiseStateEnum state = JS_PromiseState(ctx, value);
        JSValue settled = JS_PromiseResult(ctx, value);
        JS_FreeValue(ctx, value);
        value = settled;
        if (state == JS_PROMISE_REJECTED) {
            failed = 1;
            *result = error_text(ctx, value, result_length);
            goto done;
        }
        if (state == JS_PROMISE_PENDING) {
            failed = 1;
            const char *pending = "The script's promise never settled.";
            *result = copy(pending, strlen(pending), result_length);
            goto done;
        }
    }
    *result = text_of(ctx, value, result_length);

done:
    JS_FreeValue(ctx, value);
    JS_FreeContext(ctx);
    runtime->deadline = 0;
    // Memory a script left behind goes before the next one runs.
    JS_RunGC(rt);
    return failed;
}

int reqly_check(ReqlyRuntime *runtime, const char *script, size_t script_length, char **result, size_t *result_length) {
    JSRuntime *rt = runtime->runtime;
    JS_UpdateStackTop(rt);
    runtime->deadline = now() + 1;
    *result = NULL;
    *result_length = 0;
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) {
        runtime->deadline = 0;
        *result = copy("Reqly couldn't start the script.", strlen("Reqly couldn't start the script."), result_length);
        return 1;
    }
    JSValue compiled =
        JS_Eval(ctx, script, script_length, "script.js", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_COMPILE_ONLY);
    int failed = 0;
    if (JS_IsException(compiled)) {
        failed = 1;
        *result = exception_text(ctx, result_length);
    }
    JS_FreeValue(ctx, compiled);
    JS_FreeContext(ctx);
    runtime->deadline = 0;
    return failed;
}
