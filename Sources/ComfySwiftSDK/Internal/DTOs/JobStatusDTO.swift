import Foundation

struct WebSocketFrameEnvelope: Decodable {
    let type: String
    let data: AnyDecodable?
}

struct ExecutedFrameData: Decodable {
    let node: String?
    let promptId: String?
    let output: NodeOutputPayload?

    enum CodingKeys: String, CodingKey {
        case node
        case promptId = "prompt_id"
        case output
    }
}

struct ExecutionErrorFrameData: Decodable {
    let promptId: String?
    let nodeType: String?
    let exceptionType: String?
    let exceptionMessage: String?

    enum CodingKeys: String, CodingKey {
        case promptId = "prompt_id"
        case nodeType = "node_type"
        case exceptionType = "exception_type"
        case exceptionMessage = "exception_message"
    }
}

struct NodeOutputPayload: Decodable {
    let images: [OutputFileRef]?
    let gifs: [OutputFileRef]?
    let videos: [OutputFileRef]?
    let audio: [OutputFileRef]?
}

struct OutputFileRef: Decodable {
    let filename: String
    let subfolder: String
    let type: String
}

struct JobDetailExecutionError: Decodable {
    let nodeId: String?
    let nodeType: String?
    let exceptionMessage: String?
    let exceptionType: String?
    let traceback: [String]?

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case nodeType = "node_type"
        case exceptionMessage = "exception_message"
        case exceptionType = "exception_type"
        case traceback
    }
}

struct JobDetailResponse: Decodable {
    let id: String?

    let status: String

    let outputs: [String: NodeOutputPayload]?

    let executionError: JobDetailExecutionError?

    let createTime: Int64?

    let updateTime: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case outputs
        case executionError = "execution_error"
        case createTime = "create_time"
        case updateTime = "update_time"
    }
}

struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if container.decodeNil() {
            value = NSNull()
        } else if let dict = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var result: [String: Any] = [:]
            for key in dict.allKeys {
                let nested = try dict.decode(AnyDecodable.self, forKey: key)
                result[key.stringValue] = nested.value
            }
            value = result
        } else if var array = try? decoder.unkeyedContainer() {
            var result: [Any] = []
            while !array.isAtEnd {
                let nested = try array.decode(AnyDecodable.self)
                result.append(nested.value)
            }
            value = result
        } else {
            value = NSNull()
        }
    }
}

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
