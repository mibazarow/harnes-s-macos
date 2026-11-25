// swift-tools-version: 5.9

// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.
//
// VENDORED COPY of microsoft/onnxruntime-swift-package-manager at b7fb7f7
// ("Update ORT to 1.24.2"). Upstream was deleted from GitHub on 18.11.2026
// (both microsoft/onnxruntime and the SPM wrapper return 404), so the package
// can no longer be resolved by URL.
//
// Differences from upstream:
//   - the binary target points at the local `onnxruntime.xcframework` instead
//     of downloading pod-archive-onnxruntime-c-1.24.2.zip from
//     download.onnxruntime.ai (that host no longer completes a TLS handshake);
//   - the xcframework keeps one slice, `macos-arm64`, with a thin arm64 binary
//     (`lipo -extract arm64`). iOS and simulator slices dropped: this app is
//     macOS-only;
//   - `onnxruntime_extensions` product and target removed: never linked;
//   - test targets removed: they need resources and a real ORT model.
//
// Everything under `objectivec/` is upstream source, unmodified.

import PackageDescription

let package = Package(
    name: "onnxruntime",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "onnxruntime",
                 type: .static,
                 targets: ["OnnxRuntimeBindings"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "OnnxRuntimeBindings",
                dependencies: ["onnxruntime"],
                path: "objectivec",
                exclude: ["ReadMe.md", "format_objc.sh", "test", "docs",
                            "ort_checkpoint.mm",
                            "ort_checkpoint_internal.h",
                            "ort_training_session_internal.h",
                            "ort_training_session.mm",
                            "include/ort_checkpoint.h",
                            "include/ort_training_session.h",
                            "include/onnxruntime_training.h"],
                cxxSettings: [
                    .define("SPM_BUILD"),
                ]),
        .binaryTarget(name: "onnxruntime",
                      path: "onnxruntime.xcframework"),
    ],
    cxxLanguageStandard: .cxx17
)
