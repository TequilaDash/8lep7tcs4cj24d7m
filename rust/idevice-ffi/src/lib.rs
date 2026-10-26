pub mod lua_host;
pub mod mcinstall;
// Jackson Coxson

#[cfg(feature = "tunnel_tcp_stack")]
pub mod adapter;
#[cfg(feature = "afc")]
pub mod afc;
#[cfg(feature = "amfi")]
pub mod amfi;
#[cfg(feature = "bt_packet_logger")]
pub mod bt_packet_logger;
#[cfg(feature = "companion_proxy")]
pub mod companion_proxy;
#[cfg(feature = "core_device")]
pub mod core_device;
#[cfg(feature = "core_device_proxy")]
pub mod core_device_proxy;
#[cfg(feature = "crashreportcopymobile")]
pub mod crashreportcopymobile;
#[cfg(feature = "cryptexd")]
pub mod cryptexd;
#[cfg(feature = "debug_proxy")]
pub mod debug_proxy;
#[cfg(feature = "diagnostics_relay")]
pub mod diagnostics_relay;
#[cfg(feature = "dvt")]
pub mod dvt;
mod errors;
#[cfg(feature = "heartbeat")]
pub mod heartbeat;
#[cfg(feature = "house_arrest")]
pub mod house_arrest;
#[cfg(feature = "installation_proxy")]
pub mod installation_proxy;
#[cfg(feature = "installcoordination_proxy")]
pub mod installcoordination_proxy;
#[cfg(feature = "location_simulation")]
pub mod location_simulation;
pub mod lockdown;
pub mod logging;
#[cfg(feature = "misagent")]
pub mod misagent;
#[cfg(feature = "mobile_image_mounter")]
pub mod mobile_image_mounter;
#[cfg(feature = "mobileactivationd")]
pub mod mobileactivationd;
#[cfg(feature = "mobilebackup2")]
pub mod mobilebackup2;
#[cfg(feature = "notification_proxy")]
pub mod notification_proxy;
#[cfg(feature = "syslog_relay")]
pub mod os_trace_relay;
#[cfg(feature = "remote_pairing")]
pub mod pairable_host;
mod pairing_file;
#[cfg(feature = "remote_pairing")]
pub mod pairing_host;
#[cfg(feature = "pcapd")]
pub mod pcapd;
#[cfg(feature = "preboard_service")]
pub mod preboard_service;
pub mod provider;
#[cfg(feature = "remote_pairing")]
pub mod remote_pairing_lockdown;
#[cfg(feature = "restore")]
pub mod restore;
#[cfg(feature = "restore_service")]
pub mod restore_service;
#[cfg(feature = "remote_pairing")]
pub mod rp_pairing_file;
#[cfg(feature = "remote_pairing")]
pub mod pairable_host_run;
#[cfg(feature = "rsd")]
pub mod rsd;
#[cfg(feature = "screenshotr")]
pub mod screenshotr;
#[cfg(feature = "springboardservices")]
pub mod springboardservices;
#[cfg(feature = "syslog_relay")]
pub mod syslog_relay;
#[cfg(feature = "tunnel_tcp_stack")]
pub mod tcp_object_stack;
#[cfg(feature = "tunnel_tcp_stack")]
pub mod tunnel_provider;
#[cfg(feature = "usbmuxd")]
pub mod usbmuxd;
pub mod util;
#[cfg(feature = "wda")]
pub mod wda;
#[cfg(feature = "wda")]
pub mod wda_bridge;
/// Apple ID 登录 + IPA 签名（isideload sign-only 路径，IPA 侧载用）。
pub mod sideload_auth;

pub use errors::*;
pub use pairing_file::*;

use idevice::{Idevice, IdeviceError, IdeviceSocket, ReadWrite};
use once_cell::sync::Lazy;
use plist_ffi::PlistWrapper;
use std::{
    ffi::{CStr, CString, c_char, c_void},
    ptr::null_mut,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};
use tokio::runtime::{self, Runtime};

#[cfg(unix)]
use crate::util::{idevice_sockaddr, idevice_socklen_t};

// v0.3.662：build() 失败会 unwrap panic 在 Lazy 初始化里，直接中止进程（panic = abort 时）
// 或让 panic 穿出 FFI。build_runtime 收回失败并打印原因，调用点再按情况降级/报错。
fn build_runtime(enable_all: bool) -> std::io::Result<Runtime> {
    let mut builder = runtime::Builder::new_multi_thread();
    if enable_all {
        builder.enable_all();
    } else {
        builder.enable_io().enable_time();
    }
    builder.build()
}

static GLOBAL_RUNTIME: Lazy<Option<Runtime>> = Lazy::new(|| match build_runtime(false) {
    Ok(rt) => Some(rt),
    Err(e) => {
        tracing::error!("idevice-ffi: failed to build global tokio runtime: {e}");
        None
    }
});

static LOCAL_RUNTIME: Lazy<Option<Runtime>> = Lazy::new(|| match build_runtime(true) {
    Ok(rt) => Some(rt),
    Err(e) => {
        tracing::error!("idevice-ffi: failed to build local tokio runtime: {e}");
        None
    }
});

static GLOBAL_TIMEOUT: AtomicU64 = AtomicU64::new(5);

/// Spawn the future on the global runtime and block current (FFI) thread until result.
/// F and R must be Send + 'static.
///
/// v0.3.673 返工：v0.3.670-v0.3.672 三轮尝试给 R 加自定义 trait（FfiPanicFallback /
/// PanicIntoResult）想在 panic 时「就地兑现一个返回值」，全部编译不过 —— 全仓 179 处
/// 调用点的 R 至少有 7 种形态（Result<_, std::io::Error>、Option<Result<_, IdeviceError>>、
/// AdapterHandle、Option<(TcpStream, TcpStream)>、*mut IdeviceFfiError、
/// Option<Result<UsbmuxdListenEvent, _>>、Result<TcpStream, std::io::Error>），
/// CI run 39133321370 因此报了 26 条 E0277。现在回到 v0.3.669 的 sync_channel 形态：
/// 泛型只要 R: Send + 'static，**不要求任何自定义 trait**，调用点一个字都不用改。
///
/// panic 语义（与 v0.3.669 一致，明确接受）：worker 里的 panic 由 tokio 任务边界接住，
/// tx 随栈展开被 drop，调用线程 rx.recv() 得到 Err ⇒ 在**调用线程**上 panic。
/// 调用线程是 `#[unsafe(no_mangle)] pub unsafe extern "C" fn`，默认策略下会 abort，
/// 这正是 v0.3.669 及更早版本的行为，不是本轮新引入的退化。
pub fn run_sync<F, R>(fut: F) -> R
where
    F: std::future::Future<Output = R> + Send + 'static,
    R: Send + 'static,
{
    let Some(runtime) = GLOBAL_RUNTIME.as_ref() else {
        tracing::error!("idevice-ffi: global tokio runtime unavailable");
        panic!("idevice-ffi: global tokio runtime unavailable");
    };

    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    runtime.handle().spawn(async move {
        let res = fut.await;
        // best-effort send; ignore if receiver dropped
        let _ = tx.send(res);
    });

    match rx.recv() {
        Ok(v) => v,
        Err(_) => {
            tracing::error!("idevice-ffi: runtime worker panicked");
            panic!("idevice-ffi: runtime worker panicked");
        }
    }
}

/// 与 run_sync 同语义，但在调用线程上直接 block_on（不要求 F: Send）。
///
/// pairable_host_run.rs 的 run() 把 `ctx: *mut c_void` 带进回调闭包并跨 await 持有，
/// future 因此非 Send，只能走这条路径。
pub fn run_sync_local<F, R>(fut: F) -> R
where
    F: std::future::Future<Output = R>,
    R: 'static,
{
    let Some(runtime) = LOCAL_RUNTIME.as_ref() else {
        tracing::error!("idevice-ffi: local tokio runtime unavailable");
        panic!("idevice-ffi: local tokio runtime unavailable");
    };
    runtime.block_on(fut)
}


pub const LOCKDOWN_PORT: u16 = 62078;

#[repr(C)]
pub struct ReadWriteOpaque {
    pub inner: Option<Box<dyn ReadWrite>>,
}

/// Opaque C-compatible handle to an Idevice connection
pub struct IdeviceHandle(pub Idevice);
pub struct IdeviceSocketHandle(IdeviceSocket);

/// Stub to avoid header problems
#[allow(non_camel_case_types)]
pub type plist_t = *mut std::ffi::c_void;

// https://github.com/mozilla/cbindgen/issues/539
#[allow(non_camel_case_types, unused)]
struct sockaddr;

/// Creates a new Idevice connection
///
/// # Arguments
/// * [`socket`] - Socket for communication with the device
/// * [`label`] - Label for the connection
/// * [`idevice`] - On success, will be set to point to a newly allocated Idevice handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `label` must be a valid null-terminated C string
/// `idevice` must be a valid, non-null pointer to a location where the handle will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_new(
    socket: *mut IdeviceSocketHandle,
    label: *const c_char,
    idevice: *mut *mut IdeviceHandle,
) -> *mut IdeviceFfiError {
    if socket.is_null() || label.is_null() || idevice.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    // Get socket ownership
    let socket_box = unsafe { Box::from_raw(socket) };

    // Convert C string to Rust string
    let c_str = match unsafe { CStr::from_ptr(label).to_str() } {
        Ok(s) => s,
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };

    // Create new Idevice instance
    let dev = Idevice::new((*socket_box).0, c_str);
    let boxed = Box::new(IdeviceHandle(dev));
    unsafe { *idevice = Box::into_raw(boxed) };

    null_mut()
}

/// Creates an Idevice object from a socket file descriptor
///
/// # Safety
/// The socket FD must be valid.
/// The pointers must be valid and non-null.
#[cfg(unix)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_from_fd(
    fd: i32,
    label: *const c_char,
    idevice: *mut *mut IdeviceHandle,
) -> *mut IdeviceFfiError {
    if label.is_null() || idevice.is_null() || fd == 0 {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    // Get socket ownership
    let fd = unsafe { libc::dup(fd) };
    let socket = unsafe { <std::net::TcpStream as std::os::fd::FromRawFd>::from_raw_fd(fd) };
    if let Err(e) = socket.set_nonblocking(true) {
        return ffi_err!(e);
    }
    let socket = match run_sync(async move { tokio::net::TcpStream::from_std(socket) }) {
        Ok(s) => s,
        Err(e) => return ffi_err!(e),
    };

    // Convert C string to Rust string
    let c_str = match unsafe { CStr::from_ptr(label).to_str() } {
        Ok(s) => s,
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };

    // Create new Idevice instance
    let dev = Idevice::new(Box::new(socket), c_str);
    let boxed = Box::new(IdeviceHandle(dev));
    unsafe { *idevice = Box::into_raw(boxed) };

    null_mut()
}

/// Creates a new Idevice connection
///
/// # Arguments
/// * [`addr`] - The socket address to connect to
/// * [`addr_len`] - Length of the socket
/// * [`label`] - Label for the connection
/// * [`idevice`] - On success, will be set to point to a newly allocated Idevice handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `addr` must be a valid sockaddr
/// `label` must be a valid null-terminated C string
/// `idevice` must be a valid, non-null pointer to a location where the handle will be stored
#[cfg(unix)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_new_tcp_socket(
    addr: *const idevice_sockaddr,
    addr_len: idevice_socklen_t,
    label: *const c_char,
    idevice: *mut *mut IdeviceHandle,
) -> *mut IdeviceFfiError {
    use crate::util::SockAddr;

    if addr.is_null() || label.is_null() || idevice.is_null() {
        tracing::error!("null pointer(s) to idevice_new_tcp_socket");
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }
    let addr = addr as *const SockAddr;

    let label = match unsafe { CStr::from_ptr(label).to_str() } {
        Ok(s) => s,
        Err(_) => return ffi_err!(IdeviceError::FfiInvalidString),
    };

    let addr = match util::c_socket_to_rust(addr, addr_len) {
        Ok(a) => a,
        Err(e) => return ffi_err!(e),
    };

    let device = run_sync(async move {
        let stream = run_global_timeout(|| tokio::net::TcpStream::connect(addr)).await?;
        Ok::<idevice::Idevice, idevice::IdeviceError>(idevice::Idevice::new(
            Box::new(stream),
            label,
        ))
    });

    match device {
        Ok(dev) => {
            let boxed = Box::new(IdeviceHandle(dev));
            unsafe { *idevice = Box::into_raw(boxed) };
            std::ptr::null_mut()
        }
        Err(e) => ffi_err!(e),
    }
}

/// Gets the device type
///
/// # Arguments
/// * [`idevice`] - The Idevice handle
/// * [`device_type`] - On success, will be set to point to a newly allocated string containing the device type
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `idevice` must be a valid, non-null pointer to an Idevice handle
/// `device_type` must be a valid, non-null pointer to a location where the string pointer will be stored
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_get_type(
    idevice: *mut IdeviceHandle,
    device_type: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if idevice.is_null() || device_type.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    // Get the Idevice reference
    let dev = unsafe { &mut (*idevice).0 };

    // Run the get_type method in the runtime
    let result = run_sync(async { dev.get_type().await });

    match result {
        Ok(type_str) => match CString::new(type_str) {
            Ok(c_string) => {
                unsafe { *device_type = c_string.into_raw() };
                null_mut()
            }
            Err(_) => ffi_err!(IdeviceError::FfiInvalidString),
        },
        Err(e) => ffi_err!(e),
    }
}

/// Performs RSD checkin
///
/// # Arguments
/// * [`idevice`] - The Idevice handle
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `idevice` must be a valid, non-null pointer to an Idevice handle
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_rsd_checkin(idevice: *mut IdeviceHandle) -> *mut IdeviceFfiError {
    if idevice.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    // Get the Idevice reference
    let dev = unsafe { &mut (*idevice).0 };

    // Run the rsd_checkin method in the runtime
    let result = run_sync(async { dev.rsd_checkin().await });

    match result {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Starts a TLS session
///
/// # Arguments
/// * [`idevice`] - The Idevice handle
/// * [`pairing_file`] - The pairing file to use for TLS
///
/// # Returns
/// An IdeviceFfiError on error, null on success
///
/// # Safety
/// `idevice` must be a valid, non-null pointer to an Idevice handle
/// `pairing_file` must be a valid, non-null pointer to a pairing file handle
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_start_session(
    idevice: *mut IdeviceHandle,
    pairing_file: *const IdevicePairingFile,
    legacy: bool,
) -> *mut IdeviceFfiError {
    if idevice.is_null() || pairing_file.is_null() {
        return ffi_err!(IdeviceError::FfiInvalidArg);
    }

    // Get the Idevice reference
    let dev = unsafe { &mut (*idevice).0 };

    // Get the pairing file reference
    let pf = unsafe { &(*pairing_file).0 };

    // Run the start_session method in the runtime
    let result = run_sync(async move { dev.start_session(pf, legacy).await });

    match result {
        Ok(_) => null_mut(),
        Err(e) => ffi_err!(e),
    }
}

/// Sets the timeout on async calls such as TCP connections
///
/// # Safety
/// This function is safe to call from any thread at any time
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_set_global_timeout(secs: u64) {
    GLOBAL_TIMEOUT.store(secs, std::sync::atomic::Ordering::Relaxed);
}

pub(crate) async fn run_global_timeout<F, R, E>(f: impl FnOnce() -> F) -> Result<R, IdeviceError>
where
    F: Future<Output = Result<R, E>>,
    E: Into<IdeviceError>,
{
    let timeout = GLOBAL_TIMEOUT.load(Ordering::Relaxed);
    tokio::time::timeout(Duration::from_secs(timeout), f())
        .await
        .map_err(|_| IdeviceError::Timeout)?
        .map_err(Into::into)
}

/// Frees an Idevice handle
///
/// # Arguments
/// * [`idevice`] - The Idevice handle to free
///
/// # Safety
/// `idevice` must be a valid pointer to an Idevice handle that was allocated by this library,
/// or NULL (in which case this function does nothing)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_free(idevice: *mut IdeviceHandle) {
    if !idevice.is_null() {
        let _ = unsafe { Box::from_raw(idevice) };
    }
}

/// Frees a stream handle
///
/// # Safety
/// Pass a valid handle allocated by this library
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_stream_free(stream_handle: *mut ReadWriteOpaque) {
    if !stream_handle.is_null() {
        let _ = unsafe { Box::from_raw(stream_handle) };
    }
}

/// Frees a string allocated by this library
///
/// # Arguments
/// * [`string`] - The string to free
///
/// # Safety
/// `string` must be a valid pointer to a string that was allocated by this library,
/// or NULL (in which case this function does nothing)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_string_free(string: *mut c_char) {
    if !string.is_null() {
        let _ = unsafe { CString::from_raw(string) };
    }
}

/// Frees data allocated by this library
///
/// # Arguments
/// * [`data`] - The data to free
///
/// # Safety
/// `data` must be a valid pointer to data that was allocated by this library,
/// or NULL (in which case this function does nothing)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_data_free(data: *mut u8, len: usize) {
    if !data.is_null() {
        let _ = unsafe { Vec::from_raw_parts(data, len, len) };
    }
}

/// Frees an array of plists allocated by this library
///
/// # Safety
/// `data` must be a pointer to data allocated by this library,
/// NOT data allocated by libplist.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_plist_array_free(plists: *mut plist_t, len: usize) {
    if !plists.is_null() {
        let data = unsafe { std::slice::from_raw_parts(plists, len) };
        for x in data {
            unsafe { plist_ffi::creation::plist_free((*x) as *mut PlistWrapper) };
        }
    }
}

/// Frees a slice of pointers allocated by this library that had an underlying
/// vec creation.
///
/// The following functions use an underlying vec and are safe to use:
/// - idevice_usbmuxd_get_devices
///
/// # Safety
/// Pass a valid pointer passed by the Vec creating functions
#[unsafe(no_mangle)]
pub unsafe extern "C" fn idevice_outer_slice_free(slice: *mut c_void, len: usize) {
    if !slice.is_null() {
        let _ = unsafe { Vec::from_raw_parts(slice, len, len) };
    }
}

// ---------------------------------------------------------------------------
// IPA 侧载（isideload 签名）FFI 导出
// ---------------------------------------------------------------------------

/// 登录 Apple ID 并构建签名会话。阻塞；需要 2FA 时调用 `twofa_cb`。
///
/// # Safety
/// 见 `sideload_auth::apple_signin`。
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn si_apple_signin(
    apple_id: *const c_char,
    password: *const c_char,
    anisette_url: *const c_char,
    machine_name: *const c_char,
    storage_dir: *const c_char,
    twofa_cb: sideload_auth::TwoFactorCb,
    ctx: *mut c_void,
    out_session: *mut *mut sideload_auth::SignSession,
    out_summary: *mut *mut c_char,
    out_dsid: *mut *mut c_char,
    out_auth_token: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    unsafe {
        sideload_auth::apple_signin(
            apple_id, password, anisette_url, machine_name, storage_dir, twofa_cb, ctx,
            out_session, out_summary, out_dsid, out_auth_token, out_error,
        )
    }
}

/// 签名 IPA，把签名后的 `.app` 包路径写入 `*out_signed_path`。阻塞。
/// `udid` 先注册到团队（传 NULL 跳过）。
///
/// # Safety
/// 见 `sideload_auth::sign_ipa`。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_sign_ipa(
    session: *mut sideload_auth::SignSession,
    ipa_path: *const c_char,
    udid: *const c_char,
    device_name: *const c_char,
    out_signed_path: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    unsafe {
        sideload_auth::sign_ipa(session, ipa_path, udid, device_name, out_signed_path, out_error)
    }
}

/// 释放签名会话。
///
/// # Safety
/// `session` 必须为 null 或 `si_apple_signin` 返回的指针。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_sign_session_free(session: *mut sideload_auth::SignSession) {
    unsafe { sideload_auth::sign_session_free(session) }
}

/// 用已有的 dsid + xcode.auth token 恢复签名会话（跳过登录与 2FA）。
///
/// # Safety
/// 见 `sideload_auth::signin_with_session`。
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn si_signin_with_session(
    email: *const c_char,
    dsid: *const c_char,
    auth_token: *const c_char,
    anisette_url: *const c_char,
    storage_dir: *const c_char,
    machine_name: *const c_char,
    out_session: *mut *mut sideload_auth::SignSession,
    out_summary: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    unsafe {
        sideload_auth::signin_with_session(
            email, dsid, auth_token, anisette_url, storage_dir, machine_name,
            out_session, out_summary, out_error,
        )
    }
}
