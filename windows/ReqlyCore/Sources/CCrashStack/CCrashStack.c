#include "CCrashStack.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0A00
#include <windows.h>

// Swift's runtime and libraries, which the core loads with it. A crash in them, or in the core,
// counts; a fault in .NET's code, such as a null reference, .NET handles itself.
static const wchar_t *const libraries[] = {
    L"swiftCore.dll", L"swift_Concurrency.dll", L"swiftDispatch.dll", L"dispatch.dll", L"BlocksRuntime.dll",
    L"Foundation.dll", L"FoundationEssentials.dll", L"FoundationInternationalization.dll",
    L"FoundationNetworking.dll", L"FoundationXML.dll", L"_FoundationICU.dll", L"swiftCRT.dll",
    L"swiftWinSDK.dll", L"swift_StringProcessing.dll", L"swift_RegexParser.dll", L"swiftSynchronization.dll",
    L"swiftObservation.dll", L"swiftSwiftOnoneSupport.dll",
};

#define MAX_MODULES 32
#define MAX_FRAMES 64

static void *modules[MAX_MODULES];
static int moduleCount;
static volatile LONG installed;
static volatile LONG written;
static void (*then)(void);

// MARK: Writing, without the C runtime, which a crash may have left in the middle of something

typedef struct {
    char text[1024];
    int length;
} Line;

static void add(Line *line, const char *text) {
    while (*text && line->length < (int)sizeof(line->text) - 1) {
        line->text[line->length++] = *text++;
    }
}

static void addHex(Line *line, unsigned long long value, int digits) {
    char hex[17];
    for (int i = 15; i >= 0; i--) {
        hex[i] = "0123456789abcdef"[value & 0xf];
        value >>= 4;
    }
    hex[16] = 0;
    add(line, hex + 16 - digits);
}

static void addNumber(Line *line, unsigned long value) {
    char digits[12];
    int i = 11;
    digits[i] = 0;
    do {
        digits[--i] = (char)('0' + value % 10);
        value /= 10;
    } while (value && i > 0);
    add(line, digits + i);
}

static void send(HANDLE out, Line *line) {
    add(line, "\r\n");
    DWORD done;
    WriteFile(out, line->text, (DWORD)line->length, &done, NULL);
    line->length = 0;
}

/// A module's file, in UTF-8, and its name, the part after the last backslash.
static const char *fileOf(void *module, char *path, int size) {
    wchar_t wide[MAX_PATH];
    DWORD length = GetModuleFileNameW((HMODULE)module, wide, MAX_PATH);
    path[0] = 0;
    if (length == 0 || length >= MAX_PATH) {
        return path;
    }
    int bytes = WideCharToMultiByte(CP_UTF8, 0, wide, (int)length, path, size - 1, NULL, NULL);
    path[bytes > 0 ? bytes : 0] = 0;
    const char *name = path;
    for (const char *c = path; *c; c++) {
        if (*c == '\\') {
            name = c + 1;
        }
    }
    return name;
}

// MARK: The stack

/// The crashed thread's frames, from where it stopped, by unwinding as Windows does, through code
/// that has unwind information, which Swift's, .NET's and Windows' all have.
static int walk(const CONTEXT *crashed, unsigned long long *frames) {
    CONTEXT context = *crashed;
    ULONG_PTR low = 0, high = 0;
    GetCurrentThreadStackLimits(&low, &high);
    int count = 0;
    __try {
        while (count < MAX_FRAMES && context.Rip != 0) {
            frames[count++] = context.Rip;
            DWORD64 image = 0;
            DWORD64 before = context.Rsp;
            PRUNTIME_FUNCTION function = RtlLookupFunctionEntry(context.Rip, &image, NULL);
            if (function) {
                PVOID data = NULL;
                DWORD64 frame = 0;
                RtlVirtualUnwind(UNW_FLAG_NHANDLER, image, context.Rip, function, &context, &data, &frame, NULL);
            } else {
                // A function that calls none has no unwind information: what called it is on top of the stack.
                if (context.Rsp < low || context.Rsp + 8 > high) {
                    break;
                }
                context.Rip = *(DWORD64 *)context.Rsp;
                context.Rsp += 8;
            }
            if (context.Rsp <= before || context.Rsp < low || context.Rsp > high) {
                break;
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        // The stack led to memory that can't be read; the frames before it stay.
    }
    return count;
}

static int isSwift(void *module) {
    for (int i = 0; i < moduleCount; i++) {
        if (modules[i] == module) {
            return 1;
        }
    }
    return 0;
}

static void writeCrash(const char *reason, EXCEPTION_RECORD *record, CONTEXT *context) {
    HANDLE out = GetStdHandle(STD_ERROR_HANDLE);
    if (out == NULL || out == INVALID_HANDLE_VALUE) {
        return;
    }
    unsigned long long frames[MAX_FRAMES];
    int count = walk(context, frames);
    Line line = {{0}, 0};
    send(out, &line);
    add(&line, "*** Program crashed: ");
    add(&line, reason);
    if (record->ExceptionCode == EXCEPTION_ACCESS_VIOLATION && record->NumberParameters >= 2) {
        add(&line, record->ExceptionInformation[0] == 1 ? " writing 0x" : record->ExceptionInformation[0] == 8 ? " running 0x" : " reading 0x");
        addHex(&line, record->ExceptionInformation[1], 16);
    }
    add(&line, " at 0x");
    addHex(&line, (unsigned long long)record->ExceptionAddress, 16);
    add(&line, " ***");
    send(out, &line);
    send(out, &line);
    add(&line, "Thread ");
    addNumber(&line, GetCurrentThreadId());
    add(&line, " crashed:");
    send(out, &line);
    send(out, &line);
    void *seen[MAX_FRAMES];
    int seenCount = 0;
    int inNoModule = 0;
    char path[MAX_PATH * 3];
    for (int i = 0; i < count; i++) {
        void *module = NULL;
        RtlPcToFileHeader((PVOID)frames[i], &module);
        inNoModule |= module == NULL;
        addNumber(&line, (unsigned long)i);
        // After the first, each frame is where a call returns to.
        add(&line, i == 0 ? "      0x" : " [ra] 0x");
        addHex(&line, frames[i], 16);
        add(&line, " <unknown>");
        if (module) {
            add(&line, " in ");
            add(&line, fileOf(module, path, (int)sizeof(path)));
            int known = 0;
            for (int j = 0; j < seenCount; j++) {
                known |= seen[j] == module;
            }
            if (!known) {
                seen[seenCount++] = module;
            }
        }
        send(out, &line);
    }
    send(out, &line);
    // Each module the stack went through: where it was, the time stamp its build gave it, and its file.
    add(&line, "Images:");
    send(out, &line);
    send(out, &line);
    for (int i = 0; i < seenCount; i++) {
        unsigned char *base = (unsigned char *)seen[i];
        IMAGE_NT_HEADERS64 *headers = (IMAGE_NT_HEADERS64 *)(base + ((IMAGE_DOS_HEADER *)base)->e_lfanew);
        const char *name = fileOf(seen[i], path, (int)sizeof(path));
        add(&line, "0x");
        addHex(&line, (unsigned long long)base, 16);
        add(&line, "-0x");
        addHex(&line, (unsigned long long)base + headers->OptionalHeader.SizeOfImage, 16);
        add(&line, " ");
        addHex(&line, headers->FileHeader.TimeDateStamp, 8);
        add(&line, " ");
        add(&line, name);
        add(&line, " ");
        add(&line, path);
        send(out, &line);
    }
    send(out, &line);
    if (inNoModule && then) {
        __try {
            then();
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            // What it wrote before it failed stays, and the stack above it.
        }
    }
}

static LONG CALLBACK onException(EXCEPTION_POINTERS *info) {
    const char *reason;
    switch (info->ExceptionRecord->ExceptionCode) {
    // How Swift stops when a check fails, or on fatalError.
    case EXCEPTION_ILLEGAL_INSTRUCTION: reason = "Illegal instruction"; break;
    case EXCEPTION_ACCESS_VIOLATION: reason = "Access violation"; break;
    case EXCEPTION_INT_DIVIDE_BY_ZERO: reason = "Integer divide by zero"; break;
    case EXCEPTION_PRIV_INSTRUCTION: reason = "Privileged instruction"; break;
    case EXCEPTION_IN_PAGE_ERROR: reason = "In-page error"; break;
    default: return EXCEPTION_CONTINUE_SEARCH;
    }
    void *module = NULL;
    if (!RtlPcToFileHeader(info->ExceptionRecord->ExceptionAddress, &module) || !isSwift(module)) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    // Once: what follows from it, Windows' report and .NET's, stops Reqly.
    if (InterlockedExchange(&written, 1) == 0) {
        writeCrash(reason, info->ExceptionRecord, info->ContextRecord);
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

void crashstack_install(void (*after)(void)) {
    if (InterlockedExchange(&installed, 1)) {
        return;
    }
    then = after;
    HMODULE core = NULL;
    if (GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCWSTR)(void *)&crashstack_install, &core)) {
        modules[moduleCount++] = core;
    }
    for (size_t i = 0; i < sizeof(libraries) / sizeof(libraries[0]) && moduleCount < MAX_MODULES; i++) {
        HMODULE library = GetModuleHandleW(libraries[i]);
        if (library) {
            modules[moduleCount++] = library;
        }
    }
    // First, ahead of .NET's, which stops Reqly at once for a fault in native code it called.
    AddVectoredExceptionHandler(1, onException);
}

#else

void crashstack_install(void (*after)(void)) { (void)after; }

#endif
