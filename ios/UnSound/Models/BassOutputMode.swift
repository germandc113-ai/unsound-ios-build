import Foundation

enum BassOutputMode: String, CaseIterable, Identifiable, Codable {
    case car = "CAR"
    case crusherANC2 = "CRUSHER ANC 2"
    case phone = "PHONE"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .car:
            return "Deep sub extension with cabin punch and protected headroom"
        case .crusherANC2:
            return "Low-bass slam tuned around Crusher ANC 2 + Sensory Bass"
        case .phone:
            return "iPhone upper-bass punch without wasting power below the speaker range"
        }
    }

    var systemImage: String {
        switch self {
        case .car: return "car.fill"
        case .crusherANC2: return "headphones"
        case .phone: return "iphone"
        }
    }
}
