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

import VectorMath
import Foundation
import BrightFutures

enum AnimatorError: Error {
    case noCurrentState
}

public protocol Animator {
    func setState(_ state: ElementState, _ duration: TimePoint) -> Future<Bool, Never>
}

public class PictureAnimator : Tx<PictureSample, PictureSample>, Animator {

    public init(_ clock: Clock, canvasSize: Vector2, parent: PictureAnimator? = nil, parentAnchors: [PictureAnchor] = [.anchorTopLeft]) {
        self.clock = clock
        self.currentState = nil
        self.nextState = nil
        self.currentStartTime = nil
        self.transitionDuration = nil
        self.revision = UUID().uuidString
        self.canvasSize = canvasSize
        self.parent = parent
        self.initialParentState = nil
        self.anchors = parentAnchors
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
                self.nextState = nil
                self.currentStartTime = nil
                self.transitionDuration = nil
                self.initialParentState = nil
                self.anchors = state.parentAnchor.count > 0 ? state.parentAnchor : [.anchorTopLeft]
                completion(.success(true))
            } else {
                let now = self.clock.current()
                self.currentStartTime = now
                self.clock.schedule(now + duration) { [weak self] _ in
                    self?.anchors = self?.nextState?.parentAnchor ?? [.anchorTopLeft]
                    self?.currentState = self?.nextState
                    self?.nextState = nil
                    self?.currentStartTime = nil
                    self?.transitionDuration = nil
                    self?.initialParentState = nil
                    completion(.success(true))
                }
                self.nextState = state
                self.transitionDuration = duration
            }
        }
    }
    
    func computedState(_ sample: PictureSample, parentState: ComputedPictureState? = nil) throws -> ComputedPictureState {
        guard let currentState = self.currentState else {
            throw AnimatorError.noCurrentState
        }
        let now = self.clock.current()
        let pct: Float? = {
            guard let currentStartTime = self.currentStartTime, let transitionDuration = self.transitionDuration else {
                return nil
            }
            return seconds(now - currentStartTime) / seconds(transitionDuration)
        }()
        
        return computePictureState(sample, parentState?.matrix, currentState, next: self.nextState, pct: pct, anchors: self.anchors, initialParentState: self.initialParentState)
    }
    
    func setParent( _ parent: PictureAnimator? ) {
        self.parent = parent
    }
    private func impl(_ sample: PictureSample) -> EventBox<PictureSample> {
        guard self.currentState?.hidden == false else {
            return .nothing(sample.info())
        }
        do {
            let parentState = try self.parent?.computedState(sample)
            let computedState = try self.computedState(sample, parentState: parentState)
            let opacity = parentState?.opacity ?? 1.0
            if parentState != nil && initialParentState == nil {
                initialParentState = parentState
            }
            let projection = Matrix4(self.canvasSize)
            return .just(PictureSample(sample, matrix: projection * computedState.matrix,
                                       textureMatrix: computedState.textureMatrix,
                                       borderMatrix: projection * computedState.borderMatrix,
                                       fillColor: computedState.fillColor,
                                       opacity: computedState.opacity * opacity,
                                       revision: self.revision))
        } catch {
            return .nothing(sample.info())
        }
    }
    var currentState: ElementState?
    var nextState: ElementState?
    var transitionDuration: TimePoint?
    var currentStartTime: TimePoint?
    let clock: Clock
    let revision: String
    let canvasSize: Vector2
    var anchors: [PictureAnchor]
    var initialParentState: ComputedPictureState?
    weak var parent: PictureAnimator?
}

struct ComputedPictureState {
    let matrix: Matrix4
    let textureMatrix: Matrix4
    let borderMatrix: Matrix4
    let fillColor: Vector4
    let opacity: Float
}

fileprivate func computePositionSize(_ basePos: Vector3, _ baseSize: Vector3, _ parentPos: Vector3, _ parentSizeDelta: Vector3, _ anchors: [PictureAnchor]) -> (Vector3, Vector3) {
    let relPos = basePos + Vector3(parentPos.x, parentPos.y, 0)
    var verts = [ relPos, relPos+Vector3(baseSize.x, 0, 0), relPos+Vector3(0, baseSize.y, 0) ]
    let anchors = Set(anchors)
    if anchors.contains(.anchorBottomRight) {
        verts = verts.map {
            $0 + parentSizeDelta
        }
        if anchors.contains(.anchorBottomLeft) {
            verts[0].x = relPos.x
            verts[2].x = relPos.x
        }
        if anchors.contains(.anchorTopRight) {
            verts[0].y = relPos.y
            verts[1].y = relPos.y
        }
        if anchors.contains(.anchorTopLeft) {
            verts[0] = relPos
            verts[1] = relPos + Vector3(baseSize.x, 0, 0) + Vector3(parentSizeDelta.x, 0, 0)
            verts[2] = relPos + Vector3(0, baseSize.y, 0) + Vector3(0, parentSizeDelta.y, 0)
        }
    } else if anchors.contains(.anchorTopRight) {
        verts[1] = verts[1] + Vector3(parentSizeDelta.x, 0, 0)
        if !anchors.contains(.anchorTopLeft) && !anchors.contains(.anchorBottomLeft) {
            verts[0] = verts[0] + Vector3(parentSizeDelta.x, 0, 0)
            verts[2] = verts[2] + Vector3(parentSizeDelta.x, 0, 0)
        } else if anchors.contains(.anchorBottomLeft) {
            verts[2] = verts[2] + Vector3(0, parentSizeDelta.y, 0)
        }
    } else if anchors.contains(.anchorBottomLeft) {
        verts[2] = verts[2] + Vector3(0, parentSizeDelta.y, 0)
        if !anchors.contains(.anchorTopLeft) {
            verts[1] = verts[1] + Vector3(0, parentSizeDelta.y, 0)
            verts[0] = verts[0] + Vector3(0, parentSizeDelta.y, 0)
        }
    }
   
   return (verts[0], Vector3(verts[1].x-verts[0].x, verts[2].y-verts[0].y, 1.0))
}

func computePictureState(_ sample: PictureSample,
                         _ parent: Matrix4? = nil,
                         _ current: ElementState,
                         next: ElementState?,
                         pct: Float?,
                         anchors: [PictureAnchor],
                         initialParentState: ComputedPictureState? = nil) -> ComputedPictureState {
    let state = next.map { next in
        guard let pct = pct else {
            return current
        }
        return ElementState.with {
            $0.picPos = interpolate(current.picPos, next.picPos, pct)
            $0.size = interpolate(current.size, next.size, pct)
            $0.textureOffset = interpolate(current.textureOffset, next.textureOffset, pct)
            $0.rotation = interpolate(current.rotation, next.rotation, pct)
            $0.transparency = interpolate(current.transparency, next.transparency, pct)
            $0.picAspect = next.picAspect
            $0.picOrigin = next.picOrigin
            $0.fillColor = interpolate(current.getFillColor(), next.getFillColor(), pct)
            $0.borderSize = interpolate(current.borderSize, next.borderSize, pct)
        }
    } ?? current
    
    let (parentPos, parentSize) = parent.map {
        (Vector3($0.m41, $0.m42, $0.m43), Vector3(sqrt($0.m11 * $0.m11 + $0.m12 * $0.m12), sqrt($0.m21 * $0.m21 + $0.m22 * $0.m22),0))
    } ?? (Vector3(0,0,0), Vector3(0,0,0))
    let initialParentSize = initialParentState.map {
        Vector3(sqrt($0.matrix.m11 * $0.matrix.m11 + $0.matrix.m12 * $0.matrix.m12), sqrt($0.matrix.m21 * $0.matrix.m21 + $0.matrix.m22 * $0.matrix.m22), 0)
    } ?? Vector3(0,0,0)
    let parentSizeDelta = (parentSize - initialParentSize)
    let add = state.picOrigin == .originTopLeft ? Vector3(0,0,0) : -Vector3(state.size.x / 2, state.size.y / 2,0)

    let (relPos, size) = computePositionSize(Vector3(state.picPos), Vector3(state.size, 0), parentPos, parentSizeDelta, anchors)
    let pos = relPos + add
    let borderPos = pos - Vector3(state.borderSize.x, state.borderSize.y, 0)
    let borderSize = Vector3(state.borderSize.x + size.x + state.borderSize.z, state.borderSize.y + size.y + state.borderSize.w, 1)

    let textureMatrix: Matrix4 = {
        let origAspect = sample.size().x / sample.size().y
        let geomAspect = size.x / size.y
        switch state.picAspect {
        case .aspectFit:
            let scalex = origAspect > geomAspect ? 1.0 : origAspect / geomAspect
            let scaley = origAspect <= geomAspect  ? 1.0 : geomAspect / origAspect
            return Matrix4(translation: Vector3(state.textureOffset, 0) + Vector3((1.0 - scalex) / 2, (1.0 - scaley) / 2, 0)) * Matrix4(scale: Vector3(scalex, scaley, 1.0))
        case .aspectFill:
            let scalex = origAspect <= geomAspect ? 1.0 : origAspect / geomAspect
            let scaley = origAspect > geomAspect ? 1.0 :  geomAspect / origAspect
            return Matrix4(translation: Vector3(state.textureOffset, 0) + Vector3((1.0 - scalex) / 2, (1.0 - scaley) / 2, 0)) * Matrix4(scale: Vector3(scalex, scaley, 1.0))
        default:
            return Matrix4.identity
        }
    }()
    
    let computedState = ComputedPictureState(
        matrix: Matrix4(translation: pos) * Matrix4(rotation: Vector4(0, 0, 1, state.rotation)) * Matrix4(scale: size),
        textureMatrix: textureMatrix,
        borderMatrix: Matrix4(translation: borderPos) * Matrix4(rotation: Vector4(0, 0, 1, state.rotation)) * Matrix4(scale: borderSize),
        fillColor: Vector4(state.getFillColor()),
        opacity: 1.0 - state.transparency
    )
    return computedState
}

func distance(_ lhs: Vector4, _ rhs: Vector4) -> Float {
    return sqrt(pow((rhs.x - lhs.x),2) + pow((rhs.y - lhs.y), 2))
}

func interpolate(_ lhs: Vec2, _ rhs: Vec2, _ pct: Float) -> Vec2 {
    return Vec2.with {
        $0.x = lhs.x + (rhs.x - lhs.x) * pct
        $0.y = lhs.y + (rhs.y - lhs.y) * pct
    }
}

func interpolate(_ lhs: Vec3, _ rhs: Vec3, _ pct: Float) -> Vec3 {
    return Vec3.with {
        $0.x = lhs.x + (rhs.x - lhs.x) * pct
        $0.y = lhs.y + (rhs.y - lhs.y) * pct
        $0.z = lhs.z + (rhs.z - lhs.z) * pct
    }
}

func interpolate(_ lhs: Vec4, _ rhs: Vec4, _ pct: Float) -> Vec4 {
    return Vec4.with {
        $0.x = lhs.x + (rhs.x - lhs.x) * pct
        $0.y = lhs.y + (rhs.y - lhs.y) * pct
        $0.z = lhs.z + (rhs.z - lhs.z) * pct
        $0.w = lhs.w + (rhs.w - lhs.w) * pct
    }
}

func interpolate(_ lhs: Float, _ rhs: Float, _ pct: Float) -> Float {
    return lhs + (rhs - lhs) * pct
}
extension Vector2 {
    public init(_ vec: Vec2) {
        self.init(vec.x, vec.y)
    }
}

extension Vector3 {
    public init(_ vec: Vec3) {
        self.init(vec.x, vec.y, vec.z)
    }
    public init(_ vec: Vec2, _ z: Float = 0) {
        self.init(vec.x, vec.y, z)
    }
}
extension Vector4 {
    public init(_ vec: Vec4) {
        self.init(vec.x, vec.y, vec.z, vec.w)
    }
}

extension Matrix4 {
    public init(_ ortho: Vector2) {
        self.init(2/ortho.x, 0, 0, 0,
                  0, 2/ortho.y, 0, 0,
                  0, 0, 1, 0,
                  -1, -1, 1, 1)
    }
}
extension ElementState {
    func getFillColor() -> Vec4 {
        if hasFillColor {
            return fillColor
        }
        return Vec4.with {
            $0.x = 0; $0.y = 0; $0.z = 0; $0.w = 0;
        }
    }
}
