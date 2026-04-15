import Foundation

enum OxcBridge {
    struct Result {
        let javascript: String
        let error: String?
    }

    static func transform(source: String, filename: String) -> Result {
        let result = source.withCString { srcPtr in
            filename.withCString { fnPtr in
                oxc_transform(srcPtr, fnPtr)
            }
        }

        defer {
            oxc_free_string(result.javascript)
            oxc_free_string(result.error)
        }

        let js = result.javascript != nil
            ? String(cString: result.javascript)
            : ""
        let err = result.error != nil
            ? String(cString: result.error)
            : nil

        return Result(javascript: js, error: err)
    }
}
