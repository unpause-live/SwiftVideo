import CFFmpeg
import SwiftFFmpeg

extension AVCodecID {
    public static let OPUS = AV_CODEC_ID_OPUS
    public static let SMPTE_KLV = AV_CODEC_ID_SMPTE_KLV
}

extension AVMediaType: Hashable {}

extension AVCodecID: Hashable {}
