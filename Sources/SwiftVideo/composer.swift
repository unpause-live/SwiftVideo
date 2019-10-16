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
import Logging

public class Composer {
    // swiftlint:disable:next function_body_length
    public init(_ clock: Clock,
                assetId: String,
                workspaceId: String,
                workspaceToken: String?,
                compute: ComputeContext,
                composition: RpcMakeComposition,
                audioBus: Bus<AudioSample>,
                pictureBus: Bus<PictureSample>,
                epoch: Int64? = nil,
                logger: Logging.Logger = Logger(label: "SwiftVideo")) {

        self.idAsset = assetId
        self.idWorkspace = workspaceId
        self.tokenWorkspace = workspaceToken
        self.clock = clock
        self.computeContext = compute
        self.logger = logger
        let frameDuration = composition.video.hasFrameDuration ?
            composition.video.frameDuration : TimePoint(1000, 30000)
        let statsReport = StatsReport(assetId: assetId, clock: clock)
        let sampleRate = Int(composition.audio.sampleRate > 0 ? composition.audio.sampleRate : 48000)
        let epoch = epoch ?? clock.toUnixTime(clock.current())
        self.epoch = epoch
        #if os(Linux)
        let outputFormat = PixelFormat.y420p
        #else
        let outputFormat = PixelFormat.nv12
        #endif
        let canvasSize = Vector2(Scalar(composition.video.width), Scalar(composition.video.height))
        let audioMixer = AudioMixer(clock,
                                  workspaceId: workspaceId,
                                  frameDuration: TimePoint(960, Int64(sampleRate)),
                                  sampleRate: sampleRate,
                                  channelCount: composition.audio.channels > 0 ? Int(composition.audio.channels) : 2,
                                  delay: TimePoint(1920, Int64(sampleRate)),
                                  outputFormat: .s16i,
                                  assetId: assetId,
                                  statsReport: statsReport,
                                  epoch: epoch)
        let videoMixer = VideoMixer(clock,
                  workspaceId: workspaceId, frameDuration: frameDuration,
                  outputSize: canvasSize,
                  outputFormat: outputFormat,
                  computeContext: compute,
                  assetId: assetId,
                  statsReport: statsReport,
                  epoch: epoch)
        self.pictureTx = videoMixer >>> pictureBus
        self.audioTx = audioMixer >>> audioStats() >>> audioBus
        self.audioBus = audioBus
        self.pictureBus = pictureBus
        self.audioMixer = audioMixer
        self.videoMixer = videoMixer
        self.curScene = ""
        self.scenes = composition.composition.scenes
        self.elements = Dictionary(uniqueKeysWithValues: composition.composition.scenes.reduce(Set<String>())
          { $0.union($1.value.elements.keys) }.map { ($0,
                ElementAnimator(PictureAnimator(clock, canvasSize: canvasSize),
                SoundAnimator(clock), [:])) })
        // setup complete, set default scene
        self.setScene(composition.composition.initialScene)
    }

    public func bind(_ assetId: String, elementId: String) {
        if let element = elements[elementId] {
            logger.info("found element \(elementId), connecting")
            self.elements[elementId] = ElementAnimator(element.picAnimator,
                element.sounAnimator, element.states, assetId: assetId)
        }
        connectElement(elementId, setInitialState: true)
    }

    public func unbind(_ elementId: String) {
      if let element = elements[elementId] {
          self.elements[elementId] = ElementAnimator(element.picAnimator, element.sounAnimator, element.states)
       }
       disconnectElement(elementId)
    }

    public func setScene(_ sceneId: String) {
        //self.videoMixer.queue.async { [weak self] in
          //guard let strongSelf = self else {
          //    return
          //}
          let strongSelf = self
          if let scene = strongSelf.scenes[sceneId] {
              strongSelf.curScene = sceneId
              // setup animations
              // 1. disconnect current elements
              strongSelf.elements = Dictionary(uniqueKeysWithValues: strongSelf.elements.map { element in
                let states = strongSelf.scenes[sceneId]?.elements[element.0]?.states
                element.1.picAnimator.setParent(nil)
                element.1.sounAnimator.setParent(nil)
                return (element.0, ElementAnimator(element.1.picAnimator,
                    element.1.sounAnimator,
                    states ?? [:],
                    assetId: element.1.assetId))
              })
              // 2. connect elements used in the scene
              scene.elements.forEach { element in
                  strongSelf.connectElement(element.0, setInitialState: true)
                  if let slot = strongSelf.elements[element.0] {
                      slot.setParent(strongSelf.elements[element.1.parent])
                  }
              }
          }
        //}

    }

    public func currentScene() -> String {
        return curScene
    }
    public func currentState(for elementId: String) -> String? {
        return elements[elementId]?.currentState
    }

    private func runCommand(_ command: RpcComposerCommand.Command,
                            action: @escaping (RpcComposerCommand.Command.OneOf_Command) -> Future<[Bool], Never>?) {
        guard let oneof = command.command else {
          return
        }
        let future: Future<[Bool], Never>? = {
          switch oneof {
          case .scene(let sceneId):
              setScene(sceneId)
              return action(oneof)
          case .elementState(let state):
              return setState(state.elementID, state.stateID, state.duration)
          case .bind(let req):
              bind(req.assetID, elementId: req.elementID)
              return action(oneof)
          case .loadFile, .playFile, .stopFile:
              return action(oneof)
          case .setText:
              return action(oneof)
          }
        }()

        if let future = future {
            future.onComplete { [weak self] _ in
                guard let strongSelf = self else {
                    return
                }
                command.after.forEach { strongSelf.runCommand($0, action: action) }
            }
        } else {
            command.after.forEach { self.runCommand($0, action: action) }
        }
    }

    public func runCommand(_ command: RpcComposerCommand,
                           action: @escaping (RpcComposerCommand.Command.OneOf_Command) -> Future<[Bool], Never>?) {
        for command in command.commands {
            runCommand(command, action: action)
        }
    }

    public func setState(_ elementId: String,
                         _ stateId: String,
                         _ duration: TimePoint = TimePoint(0, 1000)) -> Future<[Bool], Never>? {
        if let element = elements[elementId],
           let state = element.states[stateId] {
            elements[elementId]?.currentState = stateId
            let futs = [element.picAnimator.setState(state, duration), element.sounAnimator.setState(state, duration)]
            return futs.sequence()
        }
        return nil
    }

    public func mixers() -> (AudioMixer, VideoMixer) {
        return (audioMixer, videoMixer)
    }

    public func clockEpoch() -> Int64 { return epoch }

    private func connectElement(_ elementId: String, setInitialState: Bool = false) {
      if let element = self.elements[elementId],
          let assetId = element.assetId,
          let states = self.scenes[self.currentScene()]?.elements[elementId]?.states {
          // We have an asset bound to the element, so create two transforms: audio and video
          let pictureAnim = element.picAnimator
          let audioAnim = element.sounAnimator
          let pic = self.pictureBus <<| (assetFilter(assetId) >>> GPUBarrierUpload(computeContext)
                >>> Repeater(self.clock, interval: videoMixer.frameDuration) >>> pictureAnim >>> self.videoMixer)
          let soun = self.audioBus <<| (assetFilter(assetId) >>> AudioSampleRateConversion(
            audioMixer.getSampleRate(), audioMixer.getChannels(), audioMixer.getAudioFormat()) >>>
                audioAnim  >>> self.audioMixer)
          self.elements[elementId] = ElementAnimator(pictureAnim,
                                            audioAnim, states, picTx: pic, audioTx: soun, assetId: assetId)
          if let initialState = self.scenes[self.currentScene()]?.elements[elementId]?.initialState,
            setInitialState == true {
              _ = setState(elementId, initialState)
          }
      }
    }

    private func disconnectElement(_ elementId: String) {
        if let element = self.elements[elementId],
          let assetId = element.assetId {
            self.elements[elementId] = ElementAnimator(element.picAnimator,
                element.sounAnimator, element.states, assetId: assetId)
        }
    }
    let idAsset: String
    let idWorkspace: String
    let tokenWorkspace: String?
    let clock: Clock
    let audioMixer: AudioMixer
    let videoMixer: VideoMixer
    let audioBus: Bus<AudioSample>
    let pictureBus: Bus<PictureSample>
    let pictureTx: Tx<PictureSample, ResultEvent>
    let audioTx: Tx<AudioSample, ResultEvent>
    let computeContext: ComputeContext
    let epoch: Int64
    let logger: Logging.Logger

    private var curScene: String
    private var scenes: [String: Scene]
    private var elements: [String: ElementAnimator]

    private struct ElementAnimator {
        init(_ picAnimator: PictureAnimator,
             _ sounAnimator: SoundAnimator,
             _ states: [String: ElementState],
             picTx: Tx<PictureSample, PictureSample>? = nil,
             audioTx: Tx<AudioSample, AudioSample>? = nil,
             assetId: String? = nil) {
          self.picAnimator = picAnimator
          self.sounAnimator = sounAnimator
          self.states = states
          self.picTx = picTx
          self.audioTx = audioTx
          self.assetId = assetId
        }
        func setParent(_ element: ElementAnimator?) {
            picAnimator.setParent(element?.picAnimator)
            sounAnimator.setParent(element?.sounAnimator)
        }
        let picAnimator: PictureAnimator
        let sounAnimator: SoundAnimator
        let states: [String: ElementState]
        let picTx: Tx<PictureSample, PictureSample>?
        let audioTx: Tx<AudioSample, AudioSample>?
        let assetId: String?
        var currentState: String = ""
    }
}
