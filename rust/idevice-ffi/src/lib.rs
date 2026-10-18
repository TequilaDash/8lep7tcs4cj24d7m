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
#[cfg(feature = "pcapd")]
pub mod pcapd;
#[cfg(feature = "preboard_service")]
pub mod preboard_service;
pub mod provider;
#[cfg(feature = "restore_service")]
pub mod restore_service;
#[cfg(feature = "remote_pairing")]
pub mod rp_pairing_file;
#[cfg(feature = "remote_pairing")]
pub mod pairable_host_run;
#[cfg(feature = "xpc")]
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

use idevice::{Idevice, IdeviceSocket, ReadWrite};
use once_cell::sync::Lazy;
use plist_ffi::PlistWrapper;
use std::{
    ffi::{CStr, CString, c_char, c_void},
    ptr::null_mut,
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

/// run_sync / run_sync_local 的返回类型必须实现本 trait：panic 时就地兑现成返回值。
///
/// v0.3.666 返工：v0.3.665 那版是给 R 加 `Send + FfiPanicFallback + 'static` 约束，
/// 实测直接编译不过 —— 全仓 130 处调用点都是
/// `let res: Result<T, IdeviceError> = run_sync(...)`，rustc 报
/// `error[E0277]: the trait bound Result<(), _>: FfiPanicFallback is not satisfied`。
/// 本 crate 130 处调用点的 R 都是 `Result<_, IdeviceError>`，由下面第一个 impl 覆盖；
/// 唯二的例外是 tunnel_provider.rs 的 4 处流式 dispatch（错误类型 TunnelFailure）
/// 与 pairable_host_run.rs:131（错误类型 String），二者都靠 `Residual` 或调用点
/// 内的 `.map_err` 先适配成 `Result<_, Residual>` / `Result<_, IdeviceError>`，
/// 再满足本 trait。其余所有函数签名与调用点一个字都不用改。
#[allow(private_bounds)]
pub trait PanicIntoResult {
    fn from_panic() -> Self;
}

impl<T> PanicIntoResult for Result<T, IdeviceError> {
    fn from_panic() -> Self {
        // FfiInvalidArg 是本 crate 既有的通用失败码（afc.rs 等都在用）
        Err(IdeviceError::FfiInvalidArg)
    }
}

/// 错误类型既不是 IdeviceError 也不是 Residual 的调用点走这条：
/// pairable_host_run.rs:131 `let res = run_sync_local(run(...));`（`Result<Paired, String>`）
/// 与 tunnel_provider.rs:578/628/716/870 的流式 dispatch（`Result<_, TunnelFailure>`）。
/// 前者在调用点 `.map_err(|m| IdeviceError::InternalError(m))`；
/// 后者先把错误 `.map_err(Residual)` 参与流式 dispatch，`? Residual` 再还原：
/// `run_sync_local(stream)` 的 `Result<(Adapter, RsdHandshake), TunnelFailure>`
/// 先 `.map_err(Residual)` 变成 `Result<_, Residual>` 参与流式 dispatch，
/// panic 时就地得到 `Err(Residual(IdeviceError::FfiInvalidArg))`，
/// 再 `.map_err(|Residual(e)| TunnelFailure::other(e))` 还原
/// （tunnel_provider.rs:132-140 已有 fn other(error: IdeviceError) -> Self）。
pub struct Residual(pub IdeviceError);

impl<T> PanicIntoResult for Result<T, Residual> {
    fn from_panic() -> Self {
        Err(Residual(IdeviceError::FfiInvalidArg))
    }
}

/// Spawn the future on the global runtime and block current (FFI) thread until result.
/// F and R must be Send + 'static.
///
/// v0.3.662：worker 里的 panic（含第三方 idevice crate 内部的 unwrap）以前走
/// `expect(...)` 直接中止进程，Swift 侧拿不到任何错误。现在收住并转成错误返回，
/// 由调用方走普通的 ffi_err! 错误路径。
/// v0.3.666：不再经 sync_channel 传结果，直接用 JoinHandle::blocking_recv，
/// 任务 panic 时拿到 Err(JoinError) ⇒ R::from_panic()。
pub fn run_sync<F, R>(fut: F) -> R
where
    F: std::future::Future<Output = R> + Send + 'static,
    // 不能写成 R: Send —— 有调用点返回 Result<*mut AfcFileHandle, _>，裸指针不是 Send
    // （Future: Send 已经蕴含 Output: Send，tokio 的 spawn 额外要求 R: Send 是多余的，
    //   而且 afc.rs:594 那个 *mut 调用点会直接过不去）
    R: PanicIntoResult + 'static,
{
    // 注意：fut 被 move 进闭包后如果 catch_unwind 报错，fut 已经没了，
    // 所以所有失败分支都只能返回 R::from_panic()，不能重试。
    let Some(runtime) = GLOBAL_RUNTIME.as_ref() else {
        tracing::error!("idevice-ffi: global tokio runtime unavailable");
        return R::from_panic();
    };

    // 已知限制（不在本文件修复范围内，见 task-10 报告 P1-x）：
    // pairable_host_run.rs:131 `run_sync_local(run(...))` 的未来非 Send —— run() 把
    // ctx: *mut c_void 带进 accept(...) 的回调闭包并跨 await 持有，本地用等价
    // stub 实测 error[E0277]: future created by async block is not Send /
    // the trait Send is not implemented for *mut c_void。run_sync_local 因此没有
    // F: Send 约束，改为在调用线程上 block_on；而 run_sync 的调用点全部满足 Send，
    // 继续保持 spawn + blocking_recv（既能收 panic，也不受 multi_thread 运行时的
    // "不能在运行时内 block_on"限制）。
    //
    // 任务本身 panic 时 fut 已经没了，只能返回错误；这里不持锁、不阻塞 worker。
    let spawned = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        runtime.handle().spawn(fut)
    }));
    let handle = match spawned {
        Ok(h) => h,
        Err(_) => {
            tracing::error!("idevice-ffi: failed to spawn task on global tokio runtime");
            return R::from_panic();
        }
    };

    // JoinHandle 在调用线程上 .blocking_recv()：任务 panic 时返回 Err(JoinError)，
    // 与原来的 sync_channel 等价，但少一次显式句柄传递。
    match handle.blocking_recv() {
        Ok(v) => v,
        // Err(JoinError)：任务 panic 或被取消
        Err(_) => {
            tracing::error!("idevice-ffi: runtime worker panicked");
            R::from_panic()
        }
    }
}

pub fn run_sync_local<F, R>(fut: F) -> R
where
    F: std::future::Future<Output = R>,
    R: PanicIntoResult + 'static,
{
    let Some(runtime) = LOCAL_RUNTIME.as_ref() else {
        tracing::error!("idevice-ffi: local tokio runtime unavailable");
        return R::from_panic();
    };
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| runtime.block_on(fut))) {
        Ok(v) => v,
        Err(_) => {
            tracing::error!("idevice-ffi: runtime block_on panicked");
            R::from_panic()
        }
    }
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
        let stream = tokio::net::TcpStream::connect(addr).await?;
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
