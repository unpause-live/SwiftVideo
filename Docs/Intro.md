## SwiftVideo

SwiftVideo is a cross-platform high-level framework for developing creating workflows. Current OS compatibility is Linux,
macOS and iOS/iPadOS/tvOS. In the future Windows will be supported but this requires better Windows support from Swift.


### Basic concepts

Like VideoCore before it, and of course gstreamer and Microsoft Media Foundation and others, SwiftVideo uses a pipes and
filters pattern to decouple components and allow them to be chained together to created different kinds of workflows. The 
system itself is push-oriented because it is mainly intended for live processing, but it would be possible to do pull - or
at least simulate it.

Building a pipleine in SwiftVideo is done via functional composition instead of initializing classes. There are a couple
of advantages here - first, you do not need to keep references to every part of the pipeline, just the parts you care about
accessing later, and of course one strong reference to the whole thing. Second, with functional composition you can create
in-line filters if you wish to.


#### Events

Events and samples are data containers that are passed between transforms to be changed in some useful way. You may pass
a CodedMediaSample to an audio decoder and it will subsequently pass an AudioSample to a mixer. 

Samples conform to the `Event` protocol. Objects conforming to the `Event` protocol can be contained in the `EventBox` enum
which is what is passed as a result from transforms. EventBox can represent several states: 

- `.just(value)` - In this state the EventBox contains an event that can be unwrapped by the next transform (flatMapped).
- `.nothing(info)` - In this state there is no sample to be passed to the next transform, so processing stops here. The `info` parameter is optional telemetry data via StatsReport.
- `.error(error)` - Some error occurred, the parameter is of the EventError type.
- `.gone` - This transform has been deallocated.

#### Transforms

A transform is based on the `Tx` class, it can either be a subclass or it can use the `Tx` class directly if it doesn't
need to retain any state. On a basic level, transforms provide a function in the form `A -> EventBox<B>` and the previous
transform's result is flatmapped to this transform. For example:

```
let x = EventBox<Int>.just(1)
let y = x >>- Tx { .just(Float($0)) }

y = .just(Float(1.0))
```

The `>>-` operator performs flatMap. In this case, `Tx` would be of type `Tx<Int, Float>`.

#### Operators

There are several relevant operators involved here

- `>>>` - The most common operator is the **compose** operator. This takes two transforms (of type `Tx`) and returns a new
`Tx` that is the combination of the two provided.

```swift
aPlusB = a >>> b
```

As noted above you can compose anonymous inline transforms as well

```swift
aPlusAnon: Terminal<CodedMediaSample> = a >>> Tx { dump($0); return .nothing(nil) }
```

- `|>>` - The **mapping compose** operator is for usage with elements that may emit a list of samples. The composition `Tx<A, [B]> |>> Tx<B, C>` will
end up with the type `Tx<A, [C]>`. When a new sample arrives in the transform on the left-hand side, the transform will
do its work and then it will perform the flatmap operation using each resulting sample in the list, returning a map of
result types. Your downstream transforms do not need to accomodate lists.

- `<<|` - The **observe** operator will register a composition as an observer for a bus.

- `>>-` - The **flat map** operator will take a value wrapped by an EventBox, pass it to a composition and return the appropriate result wrapped in an EventBox.

see ../Sources/SwiftVideo/bus.swift and ../Sources/SwiftVideo/event.swift for implementation details.

#### Buses

Transforms can only have a single output, therefore if you need to split an output (into Audio and Video for example), or you wish to pool
samples you need to use a bus. Typically when a bus receives a new sample it will then map the sample to all of the observers and pass the results to the digest receiver, if there is one. Buses can be configured with a granularity, so instead of dispatching samples immediately, a bus can queue samples for some period of time and then dispatch them all once that time period has elapsed. They also can be configured with multiple threads for parallel execution - though each observer registered will be assigned a specific queue in the thread pool so execution for a single observer is always serial.

Example usage,

```swift
let bus = Bus<PictureSample>()
bus.setDigestReceiver { results in 
    results.map { print("Got result \($0)") }
}

let camera = CameraSource() >>> bus
let observerA = bus <<| Tx { print("Got sample \($0)"); return .nothing(nil) }
let observerB = bus <<| Tx { print("I also got a sample \($0)"); return .nothing($0.info()) }
```

In this case observerA and observerB will both receive the same sample. Observer B will return a nothing response with the stats report that may be contained by the sample, whereas Observer A returns nothing.  Once both Observer A and Observer B have returned their results, the digest receiver function will be executed and be passed both results.
