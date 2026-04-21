import Foundation

enum EmbeddingProvider: String, CaseIterable, Identifiable {
    case nlEmbedding
    case voyage
    case titan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nlEmbedding: "On-device (Apple NLEmbedding)"
        case .voyage: "Voyage AI — TODO"
        case .titan: "AWS Bedrock Titan — TODO"
        }
    }

    var shortLabel: String {
        switch self {
        case .nlEmbedding: "On-device"
        case .voyage: "Voyage"
        case .titan: "Titan"
        }
    }

    var isAvailable: Bool {
        self == .nlEmbedding
    }

    func makeService() -> EmbeddingService {
        switch self {
        case .nlEmbedding: NLEmbeddingService()
        case .voyage: VoyageEmbeddingService()
        case .titan: TitanEmbeddingService()
        }
    }
}
