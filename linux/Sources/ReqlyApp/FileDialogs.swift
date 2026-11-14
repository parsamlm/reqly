import CGtk
import Foundation
import GtkBinding

/// GTK's file dialogs, as Reqly asks with them: a file to open, several, where to save one, or a
/// folder, over a window. GtkFileDialog goes through the desktop's file portal where there is one,
/// and has no room for options at any GTK version, so whatever a command needs to know besides the
/// file is asked first, in a dialog of Reqly's own, as on Windows. Closing a dialog without
/// choosing is no problem, so it says nothing; any other failure is logged, and gives nothing too.
@MainActor
enum FileDialogs {
    /// A filter a dialog offers, such as "HAR Files" for names that end in `.har`.
    struct Filter: Equatable, Sendable {
        var name: String
        /// The ends of the names it shows, without their dot, such as `har`, in any case.
        var suffixes: [String]
    }

    /// The file you choose to open, or `nil` when you close the dialog.
    static func open(title: String, over window: Widget, filters: [Filter] = [], in folder: URL? = nil) async -> URL? {
        let dialog = make(title: title, filters: filters, folder: folder)
        return await ask(dialog) { call in
            gtk_file_dialog_open(dialog, cast(window), nil, call.callback, call.context)
        } finish: { source, result, error in
            gtk_file_dialog_open_finish(cast(source), result, &error).flatMap(path).map { [$0] }
        }?.first
    }

    /// The files you choose to open, several at once, or none when you close the dialog.
    static func openSeveral(
        title: String, over window: Widget, filters: [Filter] = [], in folder: URL? = nil
    ) async -> [URL] {
        let dialog = make(title: title, filters: filters, folder: folder)
        return await ask(dialog) { call in
            gtk_file_dialog_open_multiple(dialog, cast(window), nil, call.callback, call.context)
        } finish: { source, result, error in
            gtk_file_dialog_open_multiple_finish(cast(source), result, &error).map(paths)
        } ?? []
    }

    /// Where you choose to save a file, starting from `name`, or `nil` when you close the dialog.
    /// The dialog asks before it lets you choose a file that's there already.
    static func save(
        title: String, over window: Widget, name: String, filters: [Filter] = [], in folder: URL? = nil
    ) async -> URL? {
        let dialog = make(title: title, filters: filters, folder: folder)
        gtk_file_dialog_set_initial_name(dialog, name)
        return await ask(dialog) { call in
            gtk_file_dialog_save(dialog, cast(window), nil, call.callback, call.context)
        } finish: { source, result, error in
            gtk_file_dialog_save_finish(cast(source), result, &error).flatMap(path).map { [$0] }
        }?.first
    }

    /// The folder you choose, or `nil` when you close the dialog.
    static func chooseFolder(title: String, over window: Widget, in folder: URL? = nil) async -> URL? {
        let dialog = make(title: title, filters: [], folder: folder)
        return await ask(dialog) { call in
            gtk_file_dialog_select_folder(dialog, cast(window), nil, call.callback, call.context)
        } finish: { source, result, error in
            gtk_file_dialog_select_folder_finish(cast(source), result, &error).flatMap(path).map { [$0] }
        }?.first
    }

    // MARK: - Making and asking

    /// A modal dialog titled `title`, with `filters`, the first chosen, and `folder` first.
    private static func make(title: String, filters: [Filter], folder: URL?) -> OpaquePointer {
        let dialog = gtk_file_dialog_new()!
        gtk_file_dialog_set_title(dialog, title)
        gtk_file_dialog_set_modal(dialog, 1)
        if !filters.isEmpty {
            let list = g_list_store_new(gtk_file_filter_get_type())!
            for filter in filters {
                let made = gtk_file_filter_new()!
                gtk_file_filter_set_name(made, filter.name)
                for suffix in filter.suffixes {
                    gtk_file_filter_add_suffix(made, suffix)
                }
                g_list_store_append(list, raw(made))
                g_object_unref(raw(made))
            }
            gtk_file_dialog_set_filters(dialog, cast(list))
            if let first = g_list_model_get_item(cast(list), 0) {
                gtk_file_dialog_set_default_filter(dialog, cast(first))
                g_object_unref(first)
            }
            g_object_unref(raw(list))
        }
        if let folder {
            let file = g_file_new_for_path(folder.path)
            gtk_file_dialog_set_initial_folder(dialog, file)
            g_object_unref(raw(file))
        }
        return dialog
    }

    /// The callback a dialog's call ends with, and its context.
    struct Call {
        var callback: GAsyncReadyCallback
        var context: UnsafeMutableRawPointer
    }

    /// What reads the files from a dialog's result, its source and its result, or sets the error.
    private typealias Finish =
        @MainActor (UnsafeMutablePointer<GObject>?, OpaquePointer?, inout UnsafeMutablePointer<GError>?) -> [URL]?

    /// Shows `dialog` with `start`, and gives what `finish` reads from its result, or `nil` when
    /// you closed it, or it failed, which is logged. Then the dialog goes, and any window GTK 4.14
    /// left behind with it: see ``closeWhatTheDialogLeft()``.
    private static func ask(
        _ dialog: OpaquePointer, _ start: (Call) -> Void, finish: @escaping Finish
    ) async -> [URL]? {
        await withCheckedContinuation { done in
            let (callback, context) = whenReady { source, result in
                var error: UnsafeMutablePointer<GError>?
                let chosen = finish(source, result, &error)
                if let error {
                    let isDismissed =
                        error.pointee.domain == gtk_dialog_error_quark()
                        && (error.pointee.code == Int32(GTK_DIALOG_ERROR_DISMISSED.rawValue)
                            || error.pointee.code == Int32(GTK_DIALOG_ERROR_CANCELLED.rawValue))
                    if !isDismissed {
                        AppLog.write("the file dialog failed: \(message(error))")
                    }
                    g_error_free(error)
                }
                if chosen == nil {
                    closeWhatTheDialogLeft()
                }
                g_object_unref(raw(dialog))
                done.resume(returning: chosen)
            }
            start(Call(callback: callback, context: context))
        }
    }

    /// A GFile's path, which it gives up.
    private static func path(_ file: OpaquePointer) -> URL? {
        defer { g_object_unref(raw(file)) }
        return takeString(g_file_get_path(file)).map { URL(filePath: $0) }
    }

    /// The paths of a list of GFiles, which it gives up.
    private static func paths(_ list: OpaquePointer) -> [URL] {
        defer { g_object_unref(raw(list)) }
        return (0..<g_list_model_get_n_items(list)).compactMap { index in
            guard let item = g_list_model_get_item(list, index) else { return nil }
            defer { g_object_unref(item) }
            return takeString(g_file_get_path(cast(item))).map { URL(filePath: $0) }
        }
    }

    /// GTK 4.14's file dialog, closed while it still reads its folder, as with a quick Escape,
    /// says it couldn't, "The folder contents could not be displayed", in a window of its own with
    /// no window under it, which keeps the keyboard and the mouse from Reqly's until it's closed.
    /// For a second after the dialog closes, such a window is closed: a modal GtkMessageDialog
    /// with no parent, which Reqly never makes.
    static func closeWhatTheDialogLeft() {
        var checks = 0
        timeout(50) {
            checks += 1
            let windows = gtk_window_get_toplevels()
            let left = (0..<g_list_model_get_n_items(windows)).compactMap { index -> Widget? in
                guard let item = g_list_model_get_item(windows, index) else { return nil }
                g_object_unref(item)
                let window: Widget = cast(item)
                let isLeft =
                    typeName(item) == "GtkMessageDialog" && gtk_window_get_modal(cast(window)) != 0
                    && gtk_window_get_transient_for(cast(window)) == nil && gtk_widget_get_mapped(window) != 0
                return isLeft ? window : nil
            }
            for window in left {
                gtk_window_destroy(cast(window))
            }
            return checks < 20
        }
    }
}
