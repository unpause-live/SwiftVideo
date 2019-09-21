public enum RpcError : Error {
    case timedOut
    case gone
    case invalidConfiguration
    case unknown
}

extension RpcAssetPermissionResponse {
    public init(_ granted: Bool) {
        self.granted = granted
    }
}

extension RpcAssetPermissionRequest {
    public init(_ sourceType: MediaSourceType, mediaType: MediaType, formats: [MediaFormat], requestType: PermissionRequestType) {
        self.sourceType = sourceType
        self.mediaType = mediaType
        self.formats = formats
        self.requestType = requestType
    }
}