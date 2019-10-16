/*
   SwiftVideo, Copyright 2019 Unpause SAS

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*/

public enum RpcError: Error {
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
    public init(_ sourceType: MediaSourceType,
                mediaType: MediaType,
                formats: [MediaFormat],
                requestType: PermissionRequestType) {
        self.sourceType = sourceType
        self.mediaType = mediaType
        self.formats = formats
        self.requestType = requestType
    }
}
