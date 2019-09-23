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

import Foundation
import VectorMath

/*
public class PictureFilter : Tx<PictureSample, PictureSample> {
    public init(_ clock: Clock,
                computeContext: ComputeContext? = nil) {
        self.clock = clock
        do {
            if let context = computeContext {
                self.context = createComputeContext(sharing: context)
            } else {
                self.context = try makeComputeContext(forType: .GPU)
            }
        } catch {
            self.context = nil
        }
        super.init()
        super.set { [weak self] sample in
            guard let strongSelf = self else {
                return .gone
            }
            
            return .just(sample)
        }
    }
    
    let clock: Clock
    var context: ComputeContext?
}
*/
