import BrightFutures
import VectorMath

public protocol LiveAsset {
    func assetId() -> String
    func workspaceId() -> String
    func workspaceToken() -> String?
    func uuid() -> String
    func liveType() -> MediaSourceType
    func dialedOut() -> Bool
}

public protocol LivePublisher : LiveAsset {
    func acceptedFormats() -> [MediaFormat]
    func uri() -> String?
}

public protocol LiveSubscriber : LiveAsset {
    func suppliedFormats() -> [MediaFormat]
}


public typealias LiveOnConnection = (LivePublisher?, LiveSubscriber?) -> Future<Bool, RpcError>
public typealias LiveOnEnded = (String) -> ()