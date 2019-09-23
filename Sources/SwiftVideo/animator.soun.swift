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
import BrightFutures

public class SoundAnimator : Tx<AudioSample, AudioSample>, Animator {
    public init(_ clock: Clock, parent: SoundAnimator? = nil) {
        self.clock = clock
        self.currentState = nil
        self.nextState = nil
        self.currentStartTime = nil
        self.transitionDuration = nil
        self.parent = parent
        super.init()
        super.set { [weak self] in
            guard let strongSelf = self else {
                return .gone
            }
            return strongSelf.impl($0)
        }
    }
    
    public func setState(_ state: ElementState, _ duration: TimePoint) -> Future<Bool, Never> {
        return Future { completion in
            if self.currentState == nil || duration.value <= 0 {
                self.currentState = state
                completion(.success(true))
            } else {
                let now = self.clock.current()
                self.currentStartTime = now
                self.clock.schedule(now + duration) { [weak self] _ in
                    self?.currentState = self?.nextState
                    self?.nextState = nil
                    self?.currentStartTime = nil
                    self?.transitionDuration = nil
                    completion(.success(true))
                }
                self.nextState = state
                self.transitionDuration = duration
            }
        }
    }
    
    func computedState() throws -> ComputedAudioState {
        guard let currentState = self.currentState else {
            throw AnimatorError.noCurrentState
        }
        guard let transitionDuration = self.transitionDuration,
            let currentStartTime = self.currentStartTime,
            let nextState = self.nextState else {
                return computeAudioState(currentState, next: nil, pct: nil)
        }
        let now = self.clock.current()
        let pct = seconds(now - currentStartTime) / seconds(transitionDuration)
        return computeAudioState(currentState, next: nextState, pct: pct)
    }
    
    func setParent( _ parent: SoundAnimator? ) {
        self.parent = parent
    }
    
    private func impl(_ sample: AudioSample) -> EventBox<AudioSample> {
        guard currentState?.muted == false else {
            return .nothing(sample.info())
        }
        
        do {
            let computedState = try self.computedState()
            let parentState = try self.parent?.computedState()
            let transform = computedState.matrix * (parentState?.matrix ?? Matrix3.identity) * sample.transform
            return .just(AudioSample(sample, transform: transform))
        } catch {
            return .just(sample)
        }
    }
    var currentState: ElementState?
    var nextState: ElementState?
    var transitionDuration: TimePoint?
    var currentStartTime: TimePoint?
    let clock: Clock
    weak var parent: SoundAnimator?
}

struct ComputedAudioState {
    let matrix: Matrix3
    let gain: Float
}

func computeAudioState( _ current: ElementState, next: ElementState?, pct: Float?) -> ComputedAudioState {
    let state = next.map { next in
        guard let pct = pct else {
            return current
        }
        return ElementState.with {
            $0.audioGain = interpolate(current.audioGain, next.audioGain, pct)
            $0.audioPos = interpolate(current.audioPos, next.audioPos, pct)
        }
        } ?? current
    
    return ComputedAudioState(matrix: Matrix3(translation: Vector2(state.audioPos)) * Matrix3(scale: Vector2(state.audioGain, state.audioGain)),
                              gain: state.audioGain)
}
