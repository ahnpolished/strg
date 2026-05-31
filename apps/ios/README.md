# strg iOS App

Swift iOS client for the strg-model workout extraction API.

## Overview

This iOS app provides a native interface to the strg-model API server. It lets users:

1. Take or select a photo of a handwritten workout journal page
2. Send it to the API server for analysis
3. View structured workout data extracted by the AI model

## Architecture

```
apps/ios/strg-ios/
├── strg-ios/
│   ├── Models/          # WorkoutEntry, WorkoutPage schema (mirrors Python)
│   ├── Networking/      # StrgAPIClient (HTTP client)
│   ├── Views/           # SwiftUI views
│   ├── Resources/       # Assets, Info.plist
│   └── StrgApp.swift    # App entry point
├── .gitignore
└── README.md
```

## Requirements

- iOS 17.0+
- Xcode 15.0+
- strg-model API server running (see `model/README.md`)

## Setup

1. Open `strg-ios.xcodeproj` in Xcode
2. Update the server URL in the app UI (default: `http://localhost:8000`)
3. Build and run on simulator or device

## API Client

```swift
let client = StrgAPIClient(baseURL: URL(string: "http://your-server:8000")!)

// Health check
let health = try await client.health()

// Predict
let result = try await client.predict(image: uiImage)
print("Extracted \(result.entryCount) entries")
```

## Data Flow

```
[iPhone Camera] --photo--> [strg-model API] --JSON--> [iOS App]
                                    |
                            Fine-tuned Qwen2-VL
                            + LoRA adapter (W&B artifact)
```
