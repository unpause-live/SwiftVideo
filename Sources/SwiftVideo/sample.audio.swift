import VectorMath
import Foundation

public enum AudioError : Error {
    case invalidFormat
}

public enum AudioFormat {
    case s16i               // Signed, 16-bit, interlaced
    case s16p               // Signed, 16-bit, planar
    case f32i               // Float, interlaced
    case f32p               // Float, planar
    case f64i               // Double, interlaced
    case f64p               // Double, planar
    // Used for internal accumulators:
    case s64i               // Signed, 64-bit, interlaced 
    case s64p               // Signed, 64-bit, planar
    case invalid
}


public enum AudioChannelLayout {
    case mono
    case stereo
}

public class AudioSample : Event {
    public init(_ buffers: [Data], 
                frequency: Int,
                channels: Int,
                format: AudioFormat,
                sampleCount: Int,
                time: TimePoint,
                pts: TimePoint,
                assetId: String,
                workspaceId: String,
                workspaceToken: String? = nil,
                computeBuffers: [ComputeBuffer] = [],
                bufferType: BufferType = .cpu,
                constituents: [MediaConstituent]? = nil,
                eventInfo: EventInfo? = nil) {
        self.buffers = buffers
        self.frequency = frequency
        self.channels = channels
        self.sampleCount = sampleCount
        self.timePoint = time
        self.audioFormat = format
        self.presentationTimestamp = pts
        self.idAsset = assetId
        self.idWorkspace = workspaceId
        self.tokenWorkspace = workspaceToken
        self.eventInfo = eventInfo
        self.transform = Matrix3.identity
        self.computeBuffers = computeBuffers
        self.buffertype = bufferType
        self.mediaConstituents = constituents
    }

    public init(_ other: AudioSample, 
                  bufferType: BufferType? = nil, 
                  assetId: String? = nil,
                  buffers: [Data]? = nil, 
                  frequency: Int? = nil,
                  channels: Int? = nil,
                  format: AudioFormat? = nil,
                  sampleCount: Int? = nil,
                  pts: TimePoint? = nil,
                  transform: Matrix3? = nil,
                  computeBuffers: [ComputeBuffer]? = nil,
                  constituents: [MediaConstituent]? = nil,
                  eventInfo: EventInfo? = nil) {
        self.buffers = buffers ?? other.buffers
        self.computeBuffers = computeBuffers ?? other.computeBuffers
        self.buffertype = bufferType ?? other.bufferType()
        self.frequency = frequency ?? other.frequency
        self.channels = channels ?? other.channels
        self.sampleCount = sampleCount ?? other.sampleCount
        self.timePoint = other.timePoint
        self.audioFormat = format ?? other.audioFormat
        self.presentationTimestamp = pts ?? other.presentationTimestamp
        self.idAsset = assetId ?? other.idAsset
        self.idWorkspace = other.idWorkspace
        self.tokenWorkspace = other.tokenWorkspace
        self.eventInfo = eventInfo ?? other.eventInfo
        self.transform = transform ?? other.transform
        self.mediaConstituents = constituents ?? other.mediaConstituents
    }

    public func type() -> String { 
        return "soun" 
    }
    public func time() -> TimePoint {
        return timePoint
    }
    public func assetId() -> String {
        return idAsset
    }
    public func workspaceId() -> String {
        return idWorkspace
    }
    public func workspaceToken() -> String? {
        return tokenWorkspace
    }
    public func info() -> EventInfo? {
        return eventInfo
    }
    public func data() -> [Data] {
        return buffers
    }
    public func computeData() -> [ComputeBuffer] {
        return computeBuffers
    }
    public func pts() -> TimePoint {
        return presentationTimestamp
    }
    public func sampleRate() -> Int {
        return frequency
    }
    public func numberSamples() -> Int {
        return sampleCount
    }
    public func numberChannels() -> Int {
        return channels
    }
    public func format() -> AudioFormat {
        return audioFormat
    }
    public func bufferType() -> BufferType {
        return buffertype
    }
    public func constituents() -> [MediaConstituent]? {
        return self.mediaConstituents
    }

    let idAsset: String
    let idWorkspace: String
    let tokenWorkspace: String?
    let mediaConstituents: [MediaConstituent]?

    let buffers: [Data]
    let computeBuffers: [ComputeBuffer]
    let buffertype: BufferType
    let frequency : Int
    let channels : Int
    let sampleCount: Int
    let audioFormat: AudioFormat
    let presentationTimestamp : TimePoint
    let timePoint: TimePoint
    let transform: Matrix3          /// Position is represented by a single 2D circular plane.  Maybe  in the future we will add elevation, but not now.
                                    /// Gain is represented by the length of a line that starts as (0, 0) -> (0, 1).
    let eventInfo: EventInfo?

}

func numberOfChannels(_ channelLayout: AudioChannelLayout) -> Int {
    switch channelLayout {
        case .mono:
            return 1
        case .stereo:
            return 2
    }
}

func numberOfBuffers(_ format: AudioFormat, _ channelCount: Int) -> Int {
    return isPlanar(format) ? channelCount : 1
}

func numberOfBuffers(_ format: AudioFormat, _ channelLayout: AudioChannelLayout) -> Int {
    return numberOfBuffers(format, numberOfChannels(channelLayout))
}

func bytesPerSample(_ format: AudioFormat, _ channelCount: Int) -> Int {
    let sampleBytes = { () -> Int in
        switch format {
            case .s16p, .s16i:
                return 2
            case .f32p, .f32i:
                return 4
            case .f64p, .f64i, .s64p, .s64i:
                return 8
            case .invalid:
                return 0
        }
    }()
    return isPlanar(format) ? sampleBytes : sampleBytes * channelCount
}

func isPlanar(_ format: AudioFormat) -> Bool {
    switch format {
        case .s16p, .f32p, .f64p, .s64p:
            return true
        default:
            return false
    }
}


