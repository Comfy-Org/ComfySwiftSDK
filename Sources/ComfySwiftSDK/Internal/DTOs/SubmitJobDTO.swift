import Foundation

struct SubmitJobDTO: Decodable {
    let promptId: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case promptId = "prompt_id"
        case error
    }
}
