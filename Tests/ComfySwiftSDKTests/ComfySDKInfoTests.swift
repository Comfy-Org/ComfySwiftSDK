import Testing
import Foundation
@testable import ComfySwiftSDK

@Suite("ComfySDKInfo — client traceability header")
struct ComfySDKInfoTests {
    @Test("sessionConfiguration() stamps X-Comfy-Client with the SDK version")
    func sessionConfigurationStampsClientHeader() {
        let headers = ComfySDKInfo.sessionConfiguration().httpAdditionalHeaders ?? [:]
        #expect(headers[ComfySDKInfo.clientHeaderName] as? String == ComfySDKInfo.clientHeaderValue)
    }

    @Test("client header value is comfyswiftsdk/<version>")
    func headerValueMatchesVersion() {
        #expect(ComfySDKInfo.clientHeaderValue == "comfyswiftsdk/\(ComfySDKInfo.version)")
    }
}
