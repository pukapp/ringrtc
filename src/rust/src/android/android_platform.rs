//
// Copyright (C) 2019, 2020 Signal Messenger, LLC.
// All rights reserved.
//
// SPDX-License-Identifier: GPL-3.0-only
//

//! Android Platform Interface.

use std::fmt;
use std::sync::Arc;

use jni::objects::{GlobalRef, JObject, JValue};
use jni::sys::{jint, jlong};
use jni::{JNIEnv, JavaVM};

// use crate::android::call_connection_observer::AndroidCallConnectionObserver;
use crate::android::error::AndroidError;
use crate::android::jni_util::*;
use crate::android::webrtc_java_media_stream::JavaMediaStream;
use crate::common::{ApplicationEvent, CallDirection, CallId, ConnectionId, DeviceId, Result};
use crate::core::call::Call;
use crate::core::connection::Connection;
use crate::core::platform::{Platform, PlatformItem};
use crate::webrtc::ice_candidate::IceCandidate;
use crate::webrtc::media_stream::MediaStream;

const RINGRTC_PACKAGE: &str = "org/signal/ringrtc";
const CALL_MANAGER_CLASS: &str = "CallManager";
const ICE_CANDIDATE_CLASS: &str = "org/webrtc/IceCandidate";

/// Android implmentation for platform::Platform::AppMediaStream
pub type AndroidMediaStream = JavaMediaStream;
impl PlatformItem for AndroidMediaStream {}

/// Android implmentation for platform::Platform::AppRemotePeer
pub type AndroidGlobalRef = GlobalRef;
impl PlatformItem for AndroidGlobalRef {}

/// Android implmentation for platform::Platform::AppCallContext
struct JavaCallContext {
    /// Java JVM object.
    platform:         AndroidPlatform,
    /// Java CallContext object.
    jni_call_context: GlobalRef,
}

impl Drop for JavaCallContext {
    fn drop(&mut self) {
        info!("JavaCallContext::drop()");

        // call into CMI to close CallContext object
        if let Ok(env) = self.platform.java_env() {
            let jni_call_manager = self.platform.jni_call_manager.as_obj();
            let jni_call_context = self.jni_call_context.as_obj();

            const CLOSE_CALL_METHOD: &str = "closeCall";
            const CLOSE_CALL_SIG: &str = "(Lorg/signal/ringrtc/CallManager$CallContext;)V";
            let args = [jni_call_context.into()];
            let _ = jni_call_method(
                &env,
                jni_call_manager,
                CLOSE_CALL_METHOD,
                CLOSE_CALL_SIG,
                &args,
            );
        }
    }
}

#[derive(Clone)]
pub struct AndroidCallContext {
    inner: Arc<JavaCallContext>,
}

unsafe impl Sync for AndroidCallContext {}
unsafe impl Send for AndroidCallContext {}
impl PlatformItem for AndroidCallContext {}

impl AndroidCallContext {
    pub fn new(platform: AndroidPlatform, jni_call_context: GlobalRef) -> Self {
        Self {
            inner: Arc::new(JavaCallContext {
                platform,
                jni_call_context,
            }),
        }
    }

    pub fn to_jni(&self) -> GlobalRef {
        self.inner.jni_call_context.clone()
    }
}

/// Android implmentation for platform::Platform::AppConnection
struct JavaConnection {
    /// Java JVM object.
    platform:       AndroidPlatform,
    /// Java Connection object.
    jni_connection: GlobalRef,
}

impl Drop for JavaConnection {
    fn drop(&mut self) {
        info!("JavaConnection::drop()");

        // call into CMI to close Connection object
        if let Ok(env) = self.platform.java_env() {
            let jni_call_manager = self.platform.jni_call_manager.as_obj();
            let jni_connection = self.jni_connection.as_obj();

            const CLOSE_CONNECTION_METHOD: &str = "closeConnection";
            const CLOSE_CONNECTION_SIG: &str = "(Lorg/signal/ringrtc/Connection;)V";
            let args = [jni_connection.into()];
            let _ = jni_call_method(
                &env,
                jni_call_manager,
                CLOSE_CONNECTION_METHOD,
                CLOSE_CONNECTION_SIG,
                &args,
            );
        }
    }
}

#[derive(Clone)]
pub struct AndroidConnection {
    inner: Arc<JavaConnection>,
}

unsafe impl Sync for AndroidConnection {}
unsafe impl Send for AndroidConnection {}
impl PlatformItem for AndroidConnection {}

impl AndroidConnection {
    fn new(platform: AndroidPlatform, jni_connection: GlobalRef) -> Self {
        Self {
            inner: Arc::new(JavaConnection {
                platform,
                jni_connection,
            }),
        }
    }

    pub fn to_jni(&self) -> GlobalRef {
        self.inner.jni_connection.clone()
    }
}

/// Android implementation of platform::Platform.
pub struct AndroidPlatform {
    /// Java JVM object.
    jvm:              JavaVM,
    /// Java org.signal.ringrtc.CallManager object.
    jni_call_manager: GlobalRef,
    /// Cache of Java classes needed at runtime
    class_cache:      ClassCache,
}

unsafe impl Sync for AndroidPlatform {}
unsafe impl Send for AndroidPlatform {}

impl fmt::Display for AndroidPlatform {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "AndroidPlatform")
    }
}

impl fmt::Debug for AndroidPlatform {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self)
    }
}

impl Drop for AndroidPlatform {
    fn drop(&mut self) {
        info!("Dropping AndroidPlatform");
        // ensure this thread is attached to the JVM as our GlobalRefs
        // go out of scope
        let _ = self.java_env();
    }
}

impl Platform for AndroidPlatform {
    type AppMediaStream = AndroidMediaStream;
    type AppRemotePeer = AndroidGlobalRef;
    type AppConnection = AndroidConnection;
    type AppCallContext = AndroidCallContext;

    fn create_connection(
        &mut self,
        call: &Call<Self>,
        remote_device: DeviceId,
    ) -> Result<Connection<Self>> {
        let connection_id = ConnectionId::new(call.call_id(), remote_device);

        info!("create_connection(): {}", connection_id);

        let connection = Connection::new(call.clone(), remote_device)?;

        let connection_ptr = connection.get_connection_ptr()?;
        let call_id_jlong = u64::from(call.call_id()) as jlong;
        let jni_remote_device = remote_device as jint;

        // call into CMI to create webrtc PeerConnection
        let env = self.java_env()?;
        let android_call_context = call.call_context()?;
        let jni_call_context = android_call_context.to_jni();
        let jni_call_manager = self.jni_call_manager.as_obj();

        const CREATE_CONNECTION_METHOD: &str = "createConnection";
        const CREATE_CONNECTION_SIG: &str =
            "(JJILorg/signal/ringrtc/CallManager$CallContext;)Lorg/signal/ringrtc/Connection;";
        let args = [
            (connection_ptr as jlong).into(),
            call_id_jlong.into(),
            jni_remote_device.into(),
            jni_call_context.as_obj().into(),
        ];
        let result = jni_call_method(
            &env,
            jni_call_manager,
            CREATE_CONNECTION_METHOD,
            CREATE_CONNECTION_SIG,
            &args,
        )?;

        let jni_connection = result.l()?;
        if (*jni_connection).is_null() {
            return Err(AndroidError::CreateJniConnection.into());
        }
        let jni_connection = env.new_global_ref(jni_connection)?;
        let platform = self.try_clone()?;
        let android_connection = AndroidConnection::new(platform, jni_connection);
        connection.set_app_connection(android_connection)?;

        Ok(connection)
    }

    fn on_start_call(
        &self,
        remote_peer: &Self::AppRemotePeer,
        call_id: CallId,
        direction: CallDirection,
    ) -> Result<()> {
        info!(
            "on_start_call(): call_id: {}, direction: {}",
            call_id, direction
        );

        let env = self.java_env()?;
        let jni_remote = remote_peer.as_obj();
        let jni_call_manager = self.jni_call_manager.as_obj();
        let call_id_jlong = u64::from(call_id) as jlong;
        let is_outgoing = match direction {
            CallDirection::OutGoing => true,
            CallDirection::InComing => false,
        };

        const START_CALL_METHOD: &str = "onStartCall";
        const START_CALL_SIG: &str = "(Lorg/signal/ringrtc/Remote;JZ)V";

        let args = [jni_remote.into(), call_id_jlong.into(), is_outgoing.into()];
        let _ = jni_call_method(
            &env,
            jni_call_manager,
            START_CALL_METHOD,
            START_CALL_SIG,
            &args,
        )?;
        Ok(())
    }

    fn on_event(&self, remote_peer: &Self::AppRemotePeer, event: ApplicationEvent) -> Result<()> {
        info!("on_event(): {}", event);

        let env = self.java_env()?;
        let jni_remote = remote_peer.as_obj();

        // convert rust enum into Java enum
        let class = "CallEvent";
        let class_path = format!("{}/{}${}", RINGRTC_PACKAGE, CALL_MANAGER_CLASS, class);
        let class_object = self.class_cache.get_class(&class_path)?;

        const ENUM_FROM_NATIVE_INDEX_METHOD: &str = "fromNativeIndex";
        let method_signature = format!("(I)L{};", class_path);
        let args = [JValue::from(event as i32)];
        let jni_enum = match env.call_static_method(
            class_object,
            ENUM_FROM_NATIVE_INDEX_METHOD,
            &method_signature,
            &args,
        ) {
            Ok(v) => v.l()?,
            Err(_) => {
                return Err(AndroidError::JniCallStaticMethod(
                    class_path,
                    ENUM_FROM_NATIVE_INDEX_METHOD.to_string(),
                    method_signature.to_string(),
                )
                .into())
            }
        };

        const ON_EVENT_METHOD: &str = "onEvent";
        const ON_EVENT_SIG: &str =
            "(Lorg/signal/ringrtc/Remote;Lorg/signal/ringrtc/CallManager$CallEvent;)V";

        let args = [jni_remote.into(), jni_enum.into()];

        let _ = jni_call_method(
            &env,
            self.jni_call_manager.as_obj(),
            ON_EVENT_METHOD,
            ON_EVENT_SIG,
            &args,
        )?;
        Ok(())
    }

    fn on_send_offer(
        &self,
        remote_peer: &Self::AppRemotePeer,
        connection_id: ConnectionId,
        broadcast: bool,
        description: &str,
    ) -> Result<()> {
        info!(
            "on_send_offer(): id: {}, broadcast: {}",
            connection_id, broadcast
        );

        let env = self.java_env()?;
        let jni_remote = remote_peer.as_obj();
        let jni_call_manager = self.jni_call_manager.as_obj();
        let call_id_jlong = u64::from(connection_id.call_id()) as jlong;
        let remote_device = connection_id.remote_device() as jint;

        const SEND_OFFER_MESSAGE_METHOD: &str = "onSendOffer";
        const SEND_OFFER_MESSAGE_SIG: &str = "(JLorg/signal/ringrtc/Remote;IZLjava/lang/String;)V";

        let args = [
            call_id_jlong.into(),
            jni_remote.into(),
            remote_device.into(),
            broadcast.into(),
            JObject::from(env.new_string(description)?).into(),
        ];
        let _ = jni_call_method(
            &env,
            jni_call_manager,
            SEND_OFFER_MESSAGE_METHOD,
            SEND_OFFER_MESSAGE_SIG,
            &args,
        )?;
        Ok(())
    }

    fn on_send_answer(
        &self,
        remote_peer: &Self::AppRemotePeer,
        connection_id: ConnectionId,
        broadcast: bool,
        description: &str,
    ) -> Result<()> {
        info!(
            "on_send_answer(): id: {}, broadcast: {}",
            connection_id, broadcast
        );

        let env = self.java_env()?;
        let jni_remote = remote_peer.as_obj();
        let jni_call_manager = self.jni_call_manager.as_obj();
        let call_id_jlong = u64::from(connection_id.call_id()) as jlong;
        let remote_device = connection_id.remote_device() as jint;

        const SEND_ANSWER_MESSAGE_METHOD: &str = "onSendAnswer";
        const SEND_ANSWER_MESSAGE_SIG: &str = "(JLorg/signal/ringrtc/Remote;IZLjava/lang/String;)V";

        let args = [
            call_id_jlong.into(),
            jni_remote.into(),
            remote_device.into(),
            broadcast.into(),
            JObject::from(env.new_string(description)?).into(),
        ];
        let _ = jni_call_method(
            &env,
            jni_call_manager,
            SEND_ANSWER_MESSAGE_METHOD,
            SEND_ANSWER_MESSAGE_SIG,
            &args,
        )?;
        Ok(())
    }

    fn on_send_ice_candidates(
        &self,
        remote_peer: &Self::AppRemotePeer,
        connection_id: ConnectionId,
        broadcast: bool,
        ice_candidates: &[IceCandidate],
    ) -> Result<()> {
        info!(
            "on_send_ice_candidates(): id: {}, broadcast: {}",
            connection_id, broadcast
        );

        let env = self.java_env()?;
        let jni_remote = remote_peer.as_obj();
        let jni_call_manager = self.jni_call_manager.as_obj();
        let call_id_jlong = u64::from(connection_id.call_id()) as jlong;
        let remote_device = connection_id.remote_device() as jint;

        // create Java List<org.webrtc.IceCandidate>
        let ice_candidate_class = self.class_cache.get_class(ICE_CANDIDATE_CLASS)?;
        let ice_candidate_list = jni_new_linked_list(&env)?;

        for candidate in ice_candidates {
            const ICE_CANDIDATE_CTOR_SIG: &str = "(Ljava/lang/String;ILjava/lang/String;)V";
            let sdp_mid = env.new_string(&candidate.sdp_mid)?;
            let sdp = env.new_string(&candidate.sdp)?;
            let args = [
                JObject::from(sdp_mid).into(),
                candidate.sdp_mline_index.into(),
                JObject::from(sdp).into(),
            ];
            let ice_update_message_obj =
                env.new_object(ice_candidate_class, ICE_CANDIDATE_CTOR_SIG, &args)?;
            ice_candidate_list.add(ice_update_message_obj)?;
        }

        const ON_SEND_ICE_CANDIDATES_METHOD: &str = "onSendIceCandidates";
        const ON_SEND_ICE_CANDIDATES_SIG: &str =
            "(JLorg/signal/ringrtc/Remote;IZLjava/util/List;)V";

        let args = [
            call_id_jlong.into(),
            jni_remote.into(),
            remote_device.into(),
            broadcast.into(),
            JObject::from(ice_candidate_list).into(),
        ];
        let _ = jni_call_method(
            &env,
            jni_call_manager,
            ON_SEND_ICE_CANDIDATES_METHOD,
            ON_SEND_ICE_CANDIDATES_SIG,
            &args,
        )?;
        Ok(())
    }

    fn on_send_hangup(
        &self,
        remote_peer: &Self::AppRemotePeer,
        connection_id: ConnectionId,
        broadcast: bool,
    ) -> Result<()> {
        info!(
            "on_send_hangup(): id: {}, broadcast: {}",
            connection_id, broadcast
        );

        let env = self.java_env()?;
        let jni_remote = remote_peer.as_obj();
        let jni_call_manager = self.jni_call_manager.as_obj();
        let call_id_jlong = u64::from(connection_id.call_id()) as jlong;
        let remote_device = connection_id.remote_device() as jint;

        const SEND_HANGUP_MESSAGE_METHOD: &str = "onSendHangup";
        const SEND_HANGUP_MESSAGE_SIG: &str = "(JLorg/signal/ringrtc/Remote;IZ)V";

        let args = [
            call_id_jlong.into(),
            jni_remote.into(),
            remote_device.into(),
            broadcast.into(),
        ];
        let _ = jni_call_method(
            &env,
            jni_call_manager,
            SEND_HANGUP_MESSAGE_METHOD,
            SEND_HANGUP_MESSAGE_SIG,
            &args,
        )?;
        Ok(())
    }

    fn on_send_busy(
        &self,
        remote_peer: &Self::AppRemotePeer,
        connection_id: ConnectionId,
        broadcast: bool,
    ) -> Result<()> {
        info!(
            "on_send_busy(): id: {}, broadcast: {}",
            connection_id, broadcast
        );

        let env = self.java_env()?;
        let jni_remote = remote_peer.as_obj();
        let jni_call_manager = self.jni_call_manager.as_obj();
        let call_id_jlong = u64::from(connection_id.call_id()) as jlong;
        let remote_device = connection_id.remote_device() as jint;

        const SEND_BUSY_MESSAGE_METHOD: &str = "onSendBusy";
        const SEND_BUSY_MESSAGE_SIG: &str = "(JLorg/signal/ringrtc/Remote;IZ)V";

        let args = [
            call_id_jlong.into(),
            jni_remote.into(),
            remote_device.into(),
            broadcast.into(),
        ];
        let _ = jni_call_method(
            &env,
            jni_call_manager,
            SEND_BUSY_MESSAGE_METHOD,
            SEND_BUSY_MESSAGE_SIG,
            &args,
        )?;
        Ok(())
    }

    fn create_media_stream(
        &self,
        _connection: &Connection<Self>,
        stream: MediaStream,
    ) -> Result<Self::AppMediaStream> {
        JavaMediaStream::new(stream)
    }

    fn on_connect_media(
        &self,
        _remote_peer: &Self::AppRemotePeer,
        app_call_context: &Self::AppCallContext,
        media_stream: &Self::AppMediaStream,
    ) -> Result<()> {
        info!("on_connect_media():");

        let env = self.java_env()?;
        let jni_call_manager = self.jni_call_manager.as_obj();
        let jni_call_context = app_call_context.to_jni();
        let jni_media_stream = media_stream.global_ref(&env)?;

        const CONNECT_MEDIA_METHOD: &str = "onConnectMedia";
        const CONNECT_MEDIA_SIG: &str =
            "(Lorg/signal/ringrtc/CallManager$CallContext;Lorg/webrtc/MediaStream;)V";

        let args = [
            jni_call_context.as_obj().into(),
            jni_media_stream.as_obj().into(),
        ];
        let _ = jni_call_method(
            &env,
            jni_call_manager,
            CONNECT_MEDIA_METHOD,
            CONNECT_MEDIA_SIG,
            &args,
        )?;
        Ok(())
    }

    fn on_close_media(&self, app_call_context: &Self::AppCallContext) -> Result<()> {
        info!("on_close_media():");

        let env = self.java_env()?;
        let jni_call_manager = self.jni_call_manager.as_obj();
        let jni_call_context = app_call_context.to_jni();

        const CLOSE_MEDIA_METHOD: &str = "onCloseMedia";
        const CLOSE_MEDIA_SIG: &str = "(Lorg/signal/ringrtc/CallManager$CallContext;)V";

        let args = [jni_call_context.as_obj().into()];
        let _ = jni_call_method(
            &env,
            jni_call_manager,
            CLOSE_MEDIA_METHOD,
            CLOSE_MEDIA_SIG,
            &args,
        )?;
        Ok(())
    }

    fn compare_remotes(
        &self,
        remote_peer1: &Self::AppRemotePeer,
        remote_peer2: &Self::AppRemotePeer,
    ) -> Result<bool> {
        info!("remotes_equal():");

        let env = self.java_env()?;
        let jni_call_manager = self.jni_call_manager.as_obj();
        let jni_remote1 = remote_peer1.as_obj();
        let jni_remote2 = remote_peer2.as_obj();

        const COMPARE_REMOTES_METHOD: &str = "compareRemotes";
        const COMPARE_REMOTES_SIG: &str =
            "(Lorg/signal/ringrtc/Remote;Lorg/signal/ringrtc/Remote;)Z";

        let args = [jni_remote1.into(), jni_remote2.into()];
        let result = jni_call_method(
            &env,
            jni_call_manager,
            COMPARE_REMOTES_METHOD,
            COMPARE_REMOTES_SIG,
            &args,
        )?
        .z()?;
        Ok(result)
    }

    fn on_call_concluded(&self, remote_peer: &Self::AppRemotePeer) -> Result<()> {
        info!("on_call_concluded():");

        let env = self.java_env()?;
        let jni_call_manager = self.jni_call_manager.as_obj();
        let jni_remote_peer = remote_peer.as_obj();

        const CALL_CONCLUDED_METHOD: &str = "onCallConcluded";
        const CALL_CONCLUDED_SIG: &str = "(Lorg/signal/ringrtc/Remote;)V";

        let args = [jni_remote_peer.into()];
        let _ = jni_call_method(
            &env,
            jni_call_manager,
            CALL_CONCLUDED_METHOD,
            CALL_CONCLUDED_SIG,
            &args,
        )?;
        Ok(())
    }
}

impl AndroidPlatform {
    /// Create a new AndroidPlatform object.
    pub fn new(env: &JNIEnv, jni_call_manager: GlobalRef) -> Result<Self> {
        let mut class_cache = ClassCache::new();
        for class in &[
            "org/signal/ringrtc/CallManager$CallEvent",
            ICE_CANDIDATE_CLASS,
        ] {
            class_cache.add_class(env, class)?;
        }

        Ok(Self {
            jvm: env.get_java_vm()?,
            jni_call_manager,
            class_cache,
        })
    }

    /// Return the Java JNIEnv.
    fn java_env(&self) -> Result<JNIEnv> {
        match self.jvm.get_env() {
            Ok(v) => Ok(v),
            Err(_e) => Ok(self.jvm.attach_current_thread_as_daemon()?),
        }
    }

    pub fn try_clone(&self) -> Result<Self> {
        let env = self.java_env()?;
        Ok(Self {
            jvm:              env.get_java_vm()?,
            jni_call_manager: self.jni_call_manager.clone(),
            class_cache:      self.class_cache.clone(),
        })
    }
}
