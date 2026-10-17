import Presentation

/// The script editor's examples, as the Mac's Examples menu titles them.
extension ScriptExamples.Example {
    var title: String {
        switch id {
        case "addHeader": "Add a Header to Requests"
        case "changeJSON": "Change a JSON Response"
        case "answer": "Answer Without the Server"
        case "sendElsewhere": "Send Requests to Another Server"
        case "rememberToken": "Remember a Token From a Sign-In"
        case "log": "Log What Passes"
        default: id
        }
    }
}
