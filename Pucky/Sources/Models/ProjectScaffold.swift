import Foundation

/// Thin compatibility wrapper around the template catalog.
///
/// The scaffold now lives on `ProjectTemplate` itself so starter
/// definitions are centralized. This helper keeps the rest of the app
/// readable where "scaffold files for template" is the intent.
enum ProjectScaffold {
    static func files(for template: ProjectTemplate) -> [ProjectFile] {
        template.makeProjectFiles()
    }
}
