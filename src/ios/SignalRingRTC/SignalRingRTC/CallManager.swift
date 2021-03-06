//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import SignalRingRTC.RingRTC
import WebRTC
import SignalCoreKit

// Errors that the Call Manager APIs can throw.
public enum CallManagerError: Error {
    case apiFailed(description: String)
}

/// Primary events a Call UI can act upon.
public enum CallManagerEvent: Int32 {
    /// Inbound call only: The call signaling (ICE) is complete.
    case ringingLocal = 0
    /// Outbound call only: The call signaling (ICE) is complete.
    case ringingRemote = 1
    /// The local side has accepted and connected the call.
    case connectedLocal = 2
    /// The remote side has accepted and connected the call.
    case connectedRemote = 3
    /// The call ended because of a local hangup.
    case endedLocalHangup = 4
    /// The call ended because of a remote hangup.
    case endedRemoteHangup = 5
    /// The call ended because of a remote busy message.
    case endedRemoteBusy = 6
    /// The call ended because of glare (received offer from same remote).
    case endedRemoteGlare = 7
    /// The call ended because it timed out during setup.
    case endedTimeout = 8
    /// The call ended because of an internal error condition.
    case endedInternalFailure = 9
    /// The call ended because a signaling message couldn't be sent.
    case endedSignalingFailure = 10
    /// The call ended because setting up the connection failed.
    case endedConnectionFailure = 11
    /// The call ended because the application wanted to drop the call.
    case endedDropped = 12
    /// The remote side has enabled video.
    case remoteVideoEnable = 13
    /// The remote side has disabled video.
    case remoteVideoDisable = 14
    /// The call dropped while connected and is now reconnecting.
    case reconnecting = 15
    /// The call dropped while connected and is now reconnected.
    case reconnected = 16
    /// The received offer is expired.
    case endedReceivedOfferExpired = 17
    /// Received an offer while already handling an active call.
    case endedReceivedOfferWhileActive = 18
}

// We define our own structure for Ice Candidates so that the
// Call Service doesn't need a direct WebRTC dependency and
// we don't need the SSKProtoCallMessageIceUpdate dependency.
public class CallManagerIceCandidate {
    public let sdpMid: String
    public let sdpMLineIndex: Int32
    public let sdp: String

    public init(sdp: String, sdpMLineIndex: Int32, sdpMid: String) {
        self.sdp = sdp
        self.sdpMLineIndex = sdpMLineIndex
        self.sdpMid = sdpMid
    }
}

public protocol CallManagerDelegate: class {

    associatedtype CallManagerDelegateCallType: CallManagerCallReference

    /**
     * A call, either outgoing or incoming, should be started by the application.
     * Invoked on the main thread, asychronously.
     */
    func callManager(_ callManager: CallManager<CallManagerDelegateCallType, Self>, shouldStartCall call: CallManagerDelegateCallType, callId: UInt64, isOutgoing: Bool)

    /**
     * onEvent will be invoked in response to Call Manager library operations.
     * Invoked on the main thread, asychronously.
     */
    func callManager(_ callManager: CallManager<CallManagerDelegateCallType, Self>, onEvent call: CallManagerDelegateCallType, event: CallManagerEvent)

    /**
     * An Offer message should be sent to the given remote.
     * Invoked on the main thread, asychronously.
     * If there is any error, the UI can reset UI state and invoke the reset() API.
     */
    func callManager(_ callManager: CallManager<CallManagerDelegateCallType, Self>, shouldSendOffer callId: UInt64, call: CallManagerDelegateCallType, destDevice: UInt32?, sdp: String)

    /**
     * An Answer message should be sent to the given remote.
     * Invoked on the main thread, asychronously.
     * If there is any error, the UI can reset UI state and invoke the reset() API.
     */
    func callManager(_ callManager: CallManager<CallManagerDelegateCallType, Self>, shouldSendAnswer callId: UInt64, call: CallManagerDelegateCallType, destDevice: UInt32?, sdp: String)

    /**
     * An Ice Candidate message should be sent to the given remote.
     * Invoked on the main thread, asychronously.
     * If there is any error, the UI can reset UI state and invoke the reset() API.
     */
    func callManager(_ callManager: CallManager<CallManagerDelegateCallType, Self>, shouldSendIceCandidates callId: UInt64, call: CallManagerDelegateCallType, destDevice: UInt32?, candidates: [CallManagerIceCandidate])

    /**
     * A Hangup message should be sent to the given remote.
     * Invoked on the main thread, asychronously.
     * If there is any error, the UI can reset UI state and invoke the reset() API.
     */
    func callManager(_ callManager: CallManager<CallManagerDelegateCallType, Self>, shouldSendHangup callId: UInt64, call: CallManagerDelegateCallType, destDevice: UInt32?)

    /**
     * A Busy message should be sent to the given remote.
     * Invoked on the main thread, asychronously.
     * If there is any error, the UI can reset UI state and invoke the reset() API.
     */
    func callManager(_ callManager: CallManager<CallManagerDelegateCallType, Self>, shouldSendBusy callId: UInt64, call: CallManagerDelegateCallType, destDevice: UInt32?)

    /**
     * Two call 'remote' pointers should be compared to see if they refer to the same
     * remote peer/contact.
     * Invoked on the main thread, *synchronously*.
     */
    func callManager(_ callManager: CallManager<CallManagerDelegateCallType, Self>, shouldCompareCalls call1: CallManagerDelegateCallType, call2: CallManagerDelegateCallType) -> Bool

    /**
     * The local video track has been enabled and can be connected to the
     * UI's display surface/view for the outgoing media.
     * Invoked on the main thread, asychronously.
     */
    func callManager(_ callManager: CallManager<CallManagerDelegateCallType, Self>, onUpdateLocalVideoSession call: CallManagerDelegateCallType, session: AVCaptureSession?)

    /**
     * The remote peer has connected and their video track can be connected to the
     * UI's display surface/view for the incoming media.
     * Invoked on the main thread, asychronously.
     */
    func callManager(_ callManager: CallManager<CallManagerDelegateCallType, Self>, onAddRemoteVideoTrack call: CallManagerDelegateCallType, track: RTCVideoTrack)
}

public protocol CallManagerCallReference: AnyObject { }

// Implementation of the Call Manager for iOS.
public class CallManager<CallType, CallManagerDelegateType>: CallManagerInterfaceDelegate, VideoCaptureDelegate where CallManagerDelegateType: CallManagerDelegate, CallManagerDelegateType.CallManagerDelegateCallType == CallType {

    public weak var delegate: CallManagerDelegateType?

    private var factory: RTCPeerConnectionFactory?

    private var ringRtcCallManager: UnsafeMutableRawPointer!

    private var videoCaptureController: VideoCaptureController?

    public init() {
        // Initialize the global object (mainly for logging).
        _ = CallManagerGlobal.shared

        // Initialize the WebRTC factory.
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)

        // Create an anonymous Call Manager interface. Ownership will
        // be transferred to RingRTC.
        let interface = CallManagerInterface(delegate: self)

        // Create the RingRTC Call Manager itself.
        guard let ringRtcCallManager = ringrtcCreate(Unmanaged.passUnretained(self).toOpaque(), interface.getWrapper()) else {
            owsFail("unable to create ringRtcCallManager")
        }

        self.ringRtcCallManager = ringRtcCallManager

        Logger.debug("object! CallManager created... \(ObjectIdentifier(self))")
    }

    deinit {
        // Close the RingRTC Call Manager.
        let retPtr = ringrtcClose(self.ringRtcCallManager)
        if retPtr == nil {
            Logger.warn("Call Manager couldn't be properly closed")
        }

        Logger.debug("object! CallManager destroyed... \(ObjectIdentifier(self))")
    }

    // MARK: - Control API

    public func placeCall(call: CallType) throws {
        AssertIsOnMainThread()
        Logger.debug("call")

        let unmanagedCall: Unmanaged<CallType> = Unmanaged.passUnretained(call)

        let retPtr = ringrtcCall(ringRtcCallManager, unmanagedCall.toOpaque())
        if retPtr == nil {
            throw CallManagerError.apiFailed(description: "call() function failure")
        }

        // Keep the call reference around until rust says we're done with the call.
        _ = unmanagedCall.retain()
    }

    public func accept(callId: UInt64) throws {
        AssertIsOnMainThread()
        Logger.debug("accept")

        let retPtr = ringrtcAccept(ringRtcCallManager, callId)
        if retPtr == nil {
            throw CallManagerError.apiFailed(description: "accept() function failure")
        }
    }

    public func hangup() throws {
        AssertIsOnMainThread()
        Logger.debug("hangup")

        let retPtr = ringrtcHangup(ringRtcCallManager)
        if retPtr == nil {
            throw CallManagerError.apiFailed(description: "hangup() function failure")
        }
    }

    // MARK: - Flow API

    public func proceed(callId: UInt64, iceServers: [RTCIceServer], hideIp: Bool, deviceList: [UInt32]) throws {
        AssertIsOnMainThread()
        Logger.debug("proceed")

        // Create a shared media sources.
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = self.factory!.audioSource(with: audioConstraints)
        let audioTrack = self.factory!.audioTrack(with: audioSource, trackId: "ARDAMSa0")
        audioTrack.isEnabled = false

        let videoSource = self.factory!.videoSource()
        let videoTrack = self.factory!.videoTrack(with: videoSource, trackId: "ARDAMSv0")
        videoTrack.isEnabled = false

        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        let videoCaptureController = VideoCaptureController(capturer: capturer, settingsDelegate: self)

        // Create a call context object to hold on to some of
        // the settings needed by the application when actually
        // creating the connection.
        let appCallContext = CallContext(iceServers: iceServers, hideIp: hideIp, audioSource: audioSource, audioTrack: audioTrack, videoSource: videoSource, videoTrack: videoTrack, videoCaptureController: videoCaptureController)

        let retPtr = ringrtcProceed(ringRtcCallManager, callId, appCallContext.getWrapper(), deviceList, deviceList.count)
        if retPtr == nil {
            throw CallManagerError.apiFailed(description: "proceed() function failure")
        }
    }

    public func drop(callId: UInt64) {
        AssertIsOnMainThread()
        Logger.debug("drop")

        let retPtr = ringrtcDrop(ringRtcCallManager, callId)
        if retPtr == nil {
            owsFailDebug("ringrtcDrop() function failure")
        }
    }

    public func signalingMessageDidSend(callId: UInt64) throws {
        AssertIsOnMainThread()
        Logger.debug("signalingMessageDidSend")

        let retPtr = ringrtcMessageSent(ringRtcCallManager, callId)
        if retPtr == nil {
            throw CallManagerError.apiFailed(description: "ringrtcMessageSent() function failure")
        }
    }

    public func signalingMessageDidFail(callId: UInt64) {
        AssertIsOnMainThread()
        Logger.debug("signalingMessageDidFail")

        let retPtr = ringrtcMessageSendFailure(ringRtcCallManager, callId)
        if retPtr == nil {
            owsFailDebug("ringrtcMessageSendFailure() function failure")
        }
    }

    public func reset() {
        AssertIsOnMainThread()
        Logger.debug("reset")

        let retPtr = ringrtcReset(ringRtcCallManager)
        if retPtr == nil {
            owsFailDebug("ringrtcReset() function failure")
        }
    }

    public func setLocalAudioEnabled(enabled: Bool) {
        AssertIsOnMainThread()
        Logger.debug("setLocalAudioEnabled(\(enabled))")

        let retPtr = ringrtcGetActiveCallContext(ringRtcCallManager)
        guard let callContext = retPtr else {
            if enabled {
                owsFailDebug("Can't enable audio on non-existent context")
            }
            return
        }

        let appCallContext: CallContext = Unmanaged.fromOpaque(callContext).takeUnretainedValue()

        appCallContext.setAudioEnabled(enabled: enabled)
    }

    public func setLocalVideoEnabled(enabled: Bool, call: CallType) {
        AssertIsOnMainThread()
        Logger.debug("setLocalVideoEnabled(\(enabled))")

        let retPtr = ringrtcGetActiveCallContext(ringRtcCallManager)
        guard let callContext = retPtr else {
            if enabled {
                owsFailDebug("Can't enable video on non-existent context")
            }
            return
        }

        let appCallContext: CallContext = Unmanaged.fromOpaque(callContext).takeUnretainedValue()

        if appCallContext.setVideoEnabled(enabled: enabled) {
            // The setting changed, so actually update components to the new state.

            appCallContext.setCameraEnabled(enabled: enabled)

            if ringrtcSetVideoEnable(ringRtcCallManager, enabled) == nil {
                owsFailDebug("ringrtcSetVideoEnable() function failure")
                return
            }

            DispatchQueue.main.async {
                Logger.debug("setLocalVideoEnabled - main async")

                guard let delegate = self.delegate else { return }

                if enabled {
                    delegate.callManager(self, onUpdateLocalVideoSession: call, session: appCallContext.getCaptureSession())
                } else {
                    delegate.callManager(self, onUpdateLocalVideoSession: call, session: nil)
                }
            }
        }
    }

    public func setCameraSource(isUsingFrontCamera: Bool) {
        AssertIsOnMainThread()
        Logger.debug("setCameraSource(\(isUsingFrontCamera))")

        let retPtr = ringrtcGetActiveCallContext(ringRtcCallManager)
        guard let callContext = retPtr else {
            Logger.debug("Can't set the camera on non-existent context")
            return
        }

        let appCallContext: CallContext = Unmanaged.fromOpaque(callContext).takeUnretainedValue()

        appCallContext.setCameraSource(isUsingFrontCamera: isUsingFrontCamera)
    }

    // MARK: - Signaling API

    public func receivedOffer<CallType: CallManagerCallReference>(call: CallType, sourceDevice: UInt32, callId: UInt64, sdp: String, timestamp: UInt64) throws {
        AssertIsOnMainThread()
        Logger.debug("receivedOffer")

        let bytes = Array(sdp.utf8)
        let offer = AppByteSlice(
            bytes: bytes,
            len: bytes.count)

        let unmanagedRemote: Unmanaged<CallType> = Unmanaged.passUnretained(call)
        let retPtr = ringrtcReceivedOffer(ringRtcCallManager, callId, unmanagedRemote.toOpaque(), sourceDevice, offer, timestamp)
        if retPtr == nil {
            throw CallManagerError.apiFailed(description: "receivedOffer() function failure")
        }
        // Keep the call reference around until rust says we're done with the call.
        _ = unmanagedRemote.retain()
    }

    public func receivedAnswer(sourceDevice: UInt32, callId: UInt64, sdp: String) throws {
        AssertIsOnMainThread()
        Logger.debug("receivedAnswer")

        let bytes = Array(sdp.utf8)
        let answer = AppByteSlice(
            bytes: bytes,
            len: bytes.count)

        let retPtr = ringrtcReceivedAnswer(ringRtcCallManager, callId, sourceDevice, answer)
        if retPtr == nil {
            throw CallManagerError.apiFailed(description: "receivedAnswer() function failure")
        }
    }

    public func receivedIceCandidates(sourceDevice: UInt32, callId: UInt64, candidates: [CallManagerIceCandidate]) throws {
        AssertIsOnMainThread()
        Logger.debug("receivedIceCandidates")

        for candidate in candidates {
            let sdpBytes = Array(candidate.sdp.utf8)
            let sdp = AppByteSlice(
                bytes: sdpBytes,
                len: sdpBytes.count)

            let sdpMidBytes = Array(candidate.sdpMid.utf8)
            let sdpMid = AppByteSlice(
                bytes: sdpMidBytes,
                len: sdpMidBytes.count)

            let retPtr = ringrtcReceivedIceCandidate(ringRtcCallManager, callId, sourceDevice, AppIceCandidate(sdpMid: sdpMid, sdpMLineIndex: candidate.sdpMLineIndex, sdp: sdp))
            if retPtr == nil {
                throw CallManagerError.apiFailed(description: "ringrtcReceivedIceCandidates() function failure")
            }
        }
    }

    public func receivedHangup(sourceDevice: UInt32, callId: UInt64) throws {
        AssertIsOnMainThread()
        Logger.debug("receivedHangup")

        let retPtr = ringrtcReceivedHangup(ringRtcCallManager, callId, sourceDevice)
        if retPtr == nil {
            throw CallManagerError.apiFailed(description: "receivedHangup() function failure")
        }
    }

    public func receivedBusy(sourceDevice: UInt32, callId: UInt64) throws {
        AssertIsOnMainThread()
        Logger.debug("receivedBusy")

        let retPtr = ringrtcReceivedBusy(ringRtcCallManager, callId, sourceDevice)
        if retPtr == nil {
            throw CallManagerError.apiFailed(description: "receivedBusy() function failure")
        }
    }

    // MARK: - Event Observers

    func onStartCall(remote: UnsafeRawPointer, callId: UInt64, isOutgoing: Bool) {
        Logger.debug("onStartCall")

        DispatchQueue.main.async {
            Logger.debug("onStartCall - main.async")

            guard let delegate = self.delegate else { return }

            let callReference: CallType = Unmanaged.fromOpaque(remote).takeUnretainedValue()
            delegate.callManager(self, shouldStartCall: callReference, callId: callId, isOutgoing: isOutgoing)
        }
    }

    func onEvent(remote: UnsafeRawPointer, event: CallManagerEvent) {
        Logger.debug("onEvent")

        DispatchQueue.main.async {
            Logger.debug("onEvent - main.async")

            guard let delegate = self.delegate else { return }

            let callReference: CallType = Unmanaged.fromOpaque(remote).takeUnretainedValue()
            delegate.callManager(self, onEvent: callReference, event: event)
        }
    }

    // MARK: - Signaling Observers

    func onSendOffer(callId: UInt64, remote: UnsafeRawPointer, deviceId: UInt32?, offer: String) {
        Logger.debug("onSendOffer")

        DispatchQueue.main.async {
            Logger.debug("onSendOffer - main.async")

            guard let delegate = self.delegate else { return }

            let callReference: CallType = Unmanaged.fromOpaque(remote).takeUnretainedValue()
            delegate.callManager(self, shouldSendOffer: callId, call: callReference, destDevice: deviceId, sdp: offer)
        }
    }

    func onSendAnswer(callId: UInt64, remote: UnsafeRawPointer, deviceId: UInt32?, answer: String) {
        Logger.debug("onSendAnswer")

        DispatchQueue.main.async {
            Logger.debug("onSendAnswer - main.async")

            guard let delegate = self.delegate else { return }

            let callReference: CallType = Unmanaged.fromOpaque(remote).takeUnretainedValue()
            delegate.callManager(self, shouldSendAnswer: callId, call: callReference, destDevice: deviceId, sdp: answer)
        }
    }

    func onSendIceCandidates(callId: UInt64, remote: UnsafeRawPointer, deviceId: UInt32?, candidates: [CallManagerIceCandidate]) {
        Logger.debug("onSendIceCandidates")

        DispatchQueue.main.async {
            Logger.debug("onSendIceCandidates - main.async")

            guard let delegate = self.delegate else { return }

            let callReference: CallType = Unmanaged.fromOpaque(remote).takeUnretainedValue()
            delegate.callManager(self, shouldSendIceCandidates: callId, call: callReference, destDevice: deviceId, candidates: candidates)
        }
    }

    func onSendHangup(callId: UInt64, remote: UnsafeRawPointer, deviceId: UInt32?) {
        Logger.debug("onSendHangup")

        DispatchQueue.main.async {
            Logger.debug("onSendHangup - main.async")

            guard let delegate = self.delegate else { return }

            let callReference: CallType = Unmanaged.fromOpaque(remote).takeUnretainedValue()
            delegate.callManager(self, shouldSendHangup: callId, call: callReference, destDevice: deviceId)
        }
    }

    func onSendBusy(callId: UInt64, remote: UnsafeRawPointer, deviceId: UInt32?) {
        Logger.debug("onSendBusy")

        DispatchQueue.main.async {
            Logger.debug("onSendBusy - main.async")

            guard let delegate = self.delegate else { return }

            let callReference: CallType = Unmanaged.fromOpaque(remote).takeUnretainedValue()
            delegate.callManager(self, shouldSendBusy: callId, call: callReference, destDevice: deviceId)
        }
    }

    // MARK: - Utility Observers

    func onCreateConnection(pcObserver: UnsafeMutableRawPointer?, deviceId: UInt32, appCallContext: CallContext) -> (connection: Connection, pc: UnsafeMutableRawPointer?) {
        Logger.debug("onCreateConnection")

        // We create default configuration settings here as per
        // Signal Messenger policies.

        // Create the configuration.
        let configuration = RTCConfiguration()

        // Update the configuration with the provided Ice Servers.
        // @todo Validate and if none, set a backup value, don't expect
        // application to know what the backup should be.
        configuration.iceServers = appCallContext.iceServers

        // Initialize the configuration.
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require

        if appCallContext.hideIp {
            configuration.iceTransportPolicy = .relay
        }

        // Create the default media constraints.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])

        Logger.debug("Create application connection object...")
        let connection = Connection()

        Logger.debug("Initializing the application connection object with custom observer...")
        let pc = connection.initialize(withCustomObserver: pcObserver!,
                                                  factory: self.factory!,
                                            configuration: configuration,
                                              constraints: constraints)
        // If pc is nil Call Manager will handle internally.

        Logger.debug("RTCPeerConnection: \(pc)")

        // We always negotiate for both audio and video streams, add
        // them to the connection so WebRTC sets them up.

        // Add an Audio Sender to the connection.
        connection.createAudioSender(audioTrack: appCallContext.audioTrack)

        // Add a Video Sender to the connection.
        connection.createVideoSender(videoTrack: appCallContext.videoTrack)

        return (connection, pc)
    }

    func onConnectMedia(remote: UnsafeRawPointer, appCallContext: CallContext, stream: RTCMediaStream) {
        Logger.debug("onConnectMedia")

        guard stream.videoTracks.count > 0 else {
            owsFailDebug("Missing video stream")
            return
        }

        DispatchQueue.main.async {
            Logger.debug("onConnectMedia - main async")

            guard let delegate = self.delegate else { return }

            let callReference: CallType = Unmanaged.fromOpaque(remote).takeUnretainedValue()
            delegate.callManager(self, onAddRemoteVideoTrack: callReference, track: stream.videoTracks[0])
        }
    }

    func onCompareRemotes(remote1: UnsafeRawPointer, remote2: UnsafeRawPointer) -> Bool {
        Logger.debug("onCompareRemotes")

        // Invoke the delegate function synchronously.

        guard let delegate = self.delegate else {
            return false
        }

        let callReference1: CallType = Unmanaged.fromOpaque(remote1).takeUnretainedValue()
        let callReference2: CallType = Unmanaged.fromOpaque(remote2).takeUnretainedValue()
        return delegate.callManager(self, shouldCompareCalls: callReference1, call2: callReference2)
    }

    func onCallConcluded(remote: UnsafeRawPointer) {
        Logger.debug("onCallConcluded")

        DispatchQueue.main.async {
            Logger.debug("onCallConcluded - main.async")

            let unmanagedRemote: Unmanaged<CallType> = Unmanaged.fromOpaque(remote)

            // rust lib has signaled that it's done with the call reference
            unmanagedRemote.release()
        }
    }

    // MARK: - Video Capture Observers

    var videoWidth: Int32 {
        return 400
    }

    var videoHeight: Int32 {
        return 400
    }
}
