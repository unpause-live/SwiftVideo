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
