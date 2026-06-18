//
//  SubmitJobDTO.swift
//  ComfySwiftSDK
//
//  Wire-format DTO for the `POST /api/prompt` response. The Comfy Cloud
//  API returns `{ "prompt_id": "string", "error": "string?" }` per the
//  research note in the Story 1.5 Debug Log References (Task 0).
//
//  CodingKeys map snake_case wire format to lowerCamelCase Swift per
//  architecture.md §Format & Data Patterns line 311.
//
//  This file is `internal` (default visibility); the DTO never escapes
//  the SDK module.
//
//  Story 1.5.
//

import Foundation

/// Decoded body of `POST /api/prompt`.
struct SubmitJobDTO: Decodable {
    let promptId: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case promptId = "prompt_id"
        case error
    }
}
