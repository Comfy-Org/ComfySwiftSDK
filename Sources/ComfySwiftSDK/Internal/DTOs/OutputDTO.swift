//
//  OutputDTO.swift
//  ComfySwiftSDK
//
//  Architecture.md §Project Structure & Boundaries line 593 lists this
//  file in the SDK's Internal/DTOs/ folder. The DTOs that would
//  ordinarily live here (`OutputFileRef`, `NodeOutputPayload`) are
//  declared inside `JobStatusDTO.swift` because they are tightly
//  coupled to the `executed` WebSocket frame's data shape.
//
//  Story 1.5 keeps this file as a one-line placeholder so the canonical
//  layout from architecture.md is satisfied without forcing a
//  premature split. When future stories grow the output handling
//  surface (Epic 3 video flows, Epic 4 polling fallback), the
//  output-shaped DTOs will migrate here.
//
//  Story 1.5.
//

import Foundation

// Output-shaped DTOs currently live in JobStatusDTO.swift; this file
// is reserved for the canonical layout in architecture.md line 593.
