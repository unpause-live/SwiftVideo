"flavor" protocol
----

Codename **F**ast **L**ightweight **A**wesome **V**ide**O** p**R**otocol (the p is silent like in pzebra) (i'm not doing this the british way)

- Data format: all messages are framed by isobmff-style atoms, `[4-byte size][FourCC type]`.  Atoms can have children, and those children
contribute to the size of the parent. Size includes the size and type fields, so an empty atom would have a size of 8.
- Numbers are all little-endian (because most devices are little endian these days fight me)
- This protocol is meant for reliable transports
- Dynamic data types, used with dictionaries: `in32`, `in64`, `fl32`, `fl64`, `bool` (1-byte) (?), `data`, `utf8`
- Dictionaries and arrays are present:
  ```
  [size]['dict']
    [11]['utf8']["key"] // Key
    [size][FourCC][bytes...] // Value
    [size]['utf8'][utf8 bytes] // Key
    [size][FourCC][bytes...] // Value
  ```
  - Dictionaries can embed any atom in addition to the data types above (which are really just atoms containing data)
  - Dictionaries must have a utf8 key value.  If you wish to use numerical indices, use a list instead.
- Lists look like this and support any atom:
  ```
  [size]['list']
    [size]['itm1']...
  ```
- RPC calls: `sync` and `asyn`, rpc format is as follows
  ```
  [size]['sync']
    [call_id int32 generated]
    [FourCC call type]
    [..call atom..] (if needed)
  ```
- In the case of a sync call, client must respond immediately with a reply.  Async may respond later or never, the requester shouldn't depend on it to continue.
  ```
  [size]['rply']
    [call_id int32 from request]
    [success int32 code]
    [size]['dict'][optional dictionary with response data]
  ```
- Media tracks should be given a track id, see below for transfer format
- Default port should be 3751 (or 0xEA7) and uri will be `flavor://server.com/{token}`

### Connection process

1. Client Connects
2. Server sends ping:
```
[16]['sync']
  [0]
  ['ping']
```
3. Client responds:
```
[16]['rply']
  [0]
  [0] // 0 response code indicates success
```

Connection is established.

### Pull or Push a media stream

Clients will then be interested in either pushing or pulling a stream, in this case it could send a sync request like this:

```
[56]['sync']
  [1]  // generated call_id
  ['push'] // could be 'pull' if wanting to recieve a stream the peer vends
  [60]['list']
    [12]['in32'][generated streamId] // requesting peer generates the stream id.
    [40]['utf8']['SampleUTF8Identifier?ohboy=hi'] // token to identify the stream request.  This is a freeform utf8 string that the service can use.
```

Server responds with permission granted or denied:
```
[16]['rply']
  [1] // call_id for push request
  [0] // Success == granted
```
```
[55]['rply']
  [1] // call_id for push request
  [1] // nonzero error code
  [39]['dict']
    [14]['utf8']["reason"]
    [17]['utf8']["No Access"]
```

The pusher will send an async track info atom if permission is granted.  The pulling side must not send a track info atom, it is an error. The pushing peer should consider the pulling peer misbehaving if it does.
```
[size]['asyn']
  [int32 generated call_id]
  ['mdia']
  [size]['list']
    [size]['trak']
      [FourCC codec name]
      [int32 stream id]
      [int32 track id]
      [int64 time base]
      [bool uses_dts]
      [size]['data'][extradata bytes...] // optional
    [size]['trak']
    ...
```
If multiple streams are requested, they _must_ be given unique track numbers across all strems.  If a track's properties need to be updated, it _must_ be overwritten by reusing the same track id as before and changing properties.  This should be treated as a discontinuity by the peer. 

The pulling peer _should_ respond with a list of unsupported tracks only if there are any unsupported tracks.  In this case, the pushing peer should remove those tracks using an `rmtk` command (see below) and stop sending any associated media data.
```
[80]['rply']
  [int32 mdia call_id]
  [1] // or other non-zero error code
  [65]['dict']
    [14]['utf8']["reason"]
    [17]['utf8']["unsupported"]
    [14]['utf8']["tracks"]
    [20]['list']
      [12]['in32'][1]
```

If tracks are disappearing or to unsubscribe from a track,
```
[36]['asyn']
  [int32 generated call_id]
  ['rmtk']
  [20]['list']
    [12]['in32'][track_id to remove]
```

### Transmit media

```
[size]['mdia']
  [track-id int32]
  [pts int64]
  [dts int64] // if track format requires a dts
  [size]['data'][payload data]
```
_(use a ts delta similar to rtmp? ... adds extra state to track, though)_

### Saying farewell

The peer ending the connection should send the following async command

```
[16]['asyn']
  [generated call_id int32]
  ['bye!']
```

### Other potential commands

- Encoder metadata
  ```
  [65]['asyn']
    [generated call_id int32]
    ['meta']
    [49]['dict']
      [15]['utf8']["encoder"]
      [26]['utf8']["some sweet encoder"]
      ...
  ```

- Query media support
  ```
  [size]['sync']
    [int32 generated call_id]
    ['mdqr']
    [size]['list']
      [size]['tksp']
        [FourCC codec name]
        [size]['xtra'][extradata bytes...]
      [size]['tksp']
      ...
  ```
  - in which case the peer will respond with,
    ```
    [80]['rply']
      [int32 mdia call_id]
      [1] // or other non-zero error code
      [65]['dict']
        [14]['utf8']["reason"]
        [17]['utf8']["unsupported"]
        [14]['utf8']["tracks"]
        [20]['list']
          [12]['in32'][1]
    ```
  - or a success reply if all tracks are supported
 
- Query peer capabilities
  ```
  [16]['sync']
    [int32 generated call_id]
    ['caps']
  ```
  - Response:
  ```
  [162]['rply']
    [int32 caps call_id]
    [0]
    [146]['dict']
      [12]['utf8']["motd"]
      [29]['utf8']["Welcome to flavortown"]
      [15]['utf8']["version"]
      [12]['in32'][1]
      [14]['utf8']["codecs"]
      [56]['list']
        [12]['in32']['AVC1']
        [12]['in32']['MP4A ']
        [12]['in32']['OPUS']
        [12]['in32']['AV10']
  ```


## Codecs

Codecs are passed as 4CharCodes in little-endian (so in a bytestream capture they will appear to be backwards). The codes are as follows:

- H.264/AVC: `AVC1`
- HEVC: `HVC1`
- VP8: `VP80`
- VP9: `VP90`
- AV1: `AV10` _AV2 will be `AV20`_
- AAC: `MP4A`
- Opus: `OPUS`

Obviously this is not an exhaustive list, I've used https://www.codecguide.com/klcp_ability_comparison.htm as a reference to find standardish 4cc codes for codecs, feel free to make a PR to add more codecs and formats (e.g. subtitle formats or other important data) or raise an issue to disagree.

