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

#if USE_FFMPEG

import CFFmpeg
import SwiftFFmpeg

// swiftlint:disable identifier_name
extension AVCodecID {
    public static let OPUS = AV_CODEC_ID_OPUS
    public static let SMPTE_KLV = AV_CODEC_ID_SMPTE_KLV
}

extension AVMediaType: Hashable {}

extension AVCodecID: Hashable {}

extension AVPixelFormat: Hashable {}

#endif // USE_FFMPEG
