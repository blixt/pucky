use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;

use oxc::allocator::Allocator;
use oxc::codegen::Codegen;
use oxc::parser::Parser;
use oxc::semantic::SemanticBuilder;
use oxc::span::SourceType;
use oxc::transformer::{HelperLoaderMode, TransformOptions, Transformer};

/// Result struct returned across FFI boundary.
#[repr(C)]
pub struct OxcTransformResult {
    /// Transformed JavaScript (caller must free with oxc_free_string)
    pub javascript: *mut c_char,
    /// Error message if transform failed, null on success (caller must free)
    pub error: *mut c_char,
}

/// Transform TypeScript/TSX source to JavaScript.
///
/// # Safety
/// `source` and `filename` must be valid null-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn oxc_transform(
    source: *const c_char,
    filename: *const c_char,
) -> OxcTransformResult {
    let source_str = match CStr::from_ptr(source).to_str() {
        Ok(s) => s,
        Err(e) => return error_result(&format!("Invalid source UTF-8: {e}")),
    };
    let filename_str = match CStr::from_ptr(filename).to_str() {
        Ok(s) => s,
        Err(e) => return error_result(&format!("Invalid filename UTF-8: {e}")),
    };

    match transform_inner(source_str, filename_str) {
        Ok(js) => OxcTransformResult {
            javascript: CString::new(js).unwrap_or_default().into_raw(),
            error: std::ptr::null_mut(),
        },
        Err(msg) => error_result(&msg),
    }
}

/// Free a string returned by oxc_transform.
///
/// # Safety
/// `ptr` must have been returned by oxc_transform, or be null.
#[no_mangle]
pub unsafe extern "C" fn oxc_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

fn error_result(msg: &str) -> OxcTransformResult {
    OxcTransformResult {
        javascript: std::ptr::null_mut(),
        error: CString::new(msg).unwrap_or_default().into_raw(),
    }
}

fn transform_inner(source_text: &str, filename: &str) -> Result<String, String> {
    let allocator = Allocator::default();
    let path = Path::new(filename);
    let source_type =
        SourceType::from_path(path).map_err(|e| format!("Unknown file type: {e}"))?;

    // 1. Parse
    let parser_ret = Parser::new(&allocator, source_text, source_type).parse();
    if !parser_ret.errors.is_empty() {
        let msgs: Vec<String> = parser_ret.errors.iter().map(|e| format!("{e}")).collect();
        return Err(msgs.join("\n"));
    }
    let mut program = parser_ret.program;

    // 2. Semantic analysis (required for scoping information)
    let sem_ret = SemanticBuilder::new()
        .with_excess_capacity(2.0)
        .build(&program);
    if !sem_ret.errors.is_empty() {
        let msgs: Vec<String> = sem_ret.errors.iter().map(|e| format!("{e}")).collect();
        return Err(msgs.join("\n"));
    }
    let scoping = sem_ret.semantic.into_scoping();

    // 3. Transform (strip TS types, lower JSX).
    //
    // `enable_all()` turns on React Fast Refresh, which injects
    // module footers like `$RefreshReg$(_c, "App")` at the top
    // level of every component. Those symbols are only defined by
    // real dev servers (Vite, Webpack, etc.); Pucky's WKWebView
    // preview runtime has nothing to register against, so the
    // footer throws `ReferenceError: $RefreshReg$ is not defined`
    // as soon as the first compiled module evaluates. Explicitly
    // disable the refresh pass so the footer is never emitted in
    // the first place. We still want dev-mode JSX (`jsxDEV` with
    // source/file annotations) because it gives the model
    // readable file/line info when it has to debug its own code.
    let mut transform_options = TransformOptions::enable_all();
    transform_options.helper_loader.mode = HelperLoaderMode::External;
    transform_options.jsx.refresh = None;

    let transform_ret = Transformer::new(&allocator, path, &transform_options)
        .build_with_scoping(scoping, &mut program);
    if !transform_ret.errors.is_empty() {
        let msgs: Vec<String> = transform_ret.errors.iter().map(|e| format!("{e}")).collect();
        return Err(msgs.join("\n"));
    }

    // 4. Codegen
    let output = Codegen::new().build(&program).code;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn test_transform_tsx() {
        let source = CString::new(
            r#"
import React from 'react';
import { View, Text } from 'react-native';

interface Props {
    title: string;
}

export default function App({ title }: Props) {
    return (
        <View>
            <Text>{title}</Text>
        </View>
    );
}
"#,
        )
        .unwrap();
        let filename = CString::new("App.tsx").unwrap();

        let result = unsafe { oxc_transform(source.as_ptr(), filename.as_ptr()) };

        assert!(result.error.is_null(), "Expected no error");
        assert!(!result.javascript.is_null(), "Expected JavaScript output");

        let js = unsafe { CStr::from_ptr(result.javascript).to_str().unwrap() };
        // Should have stripped the interface and transformed JSX
        assert!(!js.contains("interface"));
        assert!(!js.contains("<View>"));
        assert!(js.contains("createElement") || js.contains("jsx"));

        unsafe {
            oxc_free_string(result.javascript);
            oxc_free_string(result.error);
        }
    }

    #[test]
    fn react_fast_refresh_is_disabled() {
        // Regression guard: Pucky's preview runtime has no
        // React Fast Refresh host, so the transformer MUST NOT
        // emit `$RefreshReg$(...)` module footers. If it does,
        // every compiled component module throws a ReferenceError
        // at top-level evaluation and the whole preview dies
        // before rendering a single node.
        let source = CString::new(
            "import React from 'react';\n\
             export default function App() { return React.createElement('div'); }\n",
        )
        .unwrap();
        let filename = CString::new("App.tsx").unwrap();
        let result = unsafe { oxc_transform(source.as_ptr(), filename.as_ptr()) };
        assert!(result.error.is_null(), "unexpected error");
        let js = unsafe { CStr::from_ptr(result.javascript).to_str().unwrap().to_owned() };
        assert!(
            !js.contains("$RefreshReg$"),
            "transformer emitted React Fast Refresh footer: {js}"
        );
        assert!(
            !js.contains("$RefreshSig$"),
            "transformer emitted React Fast Refresh signature: {js}"
        );
        unsafe {
            oxc_free_string(result.javascript);
            oxc_free_string(result.error);
        }
    }

    #[test]
    fn test_transform_plain_ts() {
        let source = CString::new("const x: number = 42;\nexport default x;\n").unwrap();
        let filename = CString::new("index.ts").unwrap();

        let result = unsafe { oxc_transform(source.as_ptr(), filename.as_ptr()) };
        assert!(result.error.is_null());

        let js = unsafe { CStr::from_ptr(result.javascript).to_str().unwrap() };
        assert!(!js.contains(": number"));
        assert!(js.contains("42"));

        unsafe {
            oxc_free_string(result.javascript);
            oxc_free_string(result.error);
        }
    }
}
