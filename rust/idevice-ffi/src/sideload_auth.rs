//! IPA signer adapter: consumes Settings credentials, never logs in or provisions.
#![allow(unsafe_op_in_unsafe_fn)]

use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::Arc;

use isideload::{
    anisette::{
        remote_v3::RemoteV3AnisetteProvider, AnisetteClientInfo, AnisetteDataGenerator, AnisetteDataResponse, AnisetteProvider,
    },
    auth::apple_account::AppToken,
    auth::grandslam::GrandSlam,
    dev::{certificates::DevelopmentCertificate, developer_session::DeveloperSession, devices::DevicesApi},
    sideload::builder::{ExtensionsBehavior, ExtensionsBehaviorSelection, MaxCertsBehavior},
    sideload::{bundle::Bundle, sideloader::Sideloader, SideloaderBuilder, TeamSelection},
    util::fs_storage::FsStorage,
};

/// Sideloader 0.5.x 带 C/E 两个回调泛型。我们固定用 Error / Fixed 行为，
/// 两个 Prompt 回调永远不会被调，但类型上仍要占位 —— 用函数指针类型满足
/// Fn 超trait（手工 impl Fn 不稳定）.
type NeverMaxCertFuture = std::future::Ready<Result<Option<Vec<String>>, rootcause::Report>>;
type NeverExtFuture = std::future::Ready<Result<ExtensionsBehavior, rootcause::Report>>;
type NeverMaxCertCb = fn(Vec<DevelopmentCertificate>) -> NeverMaxCertFuture;
type NeverExtCb = fn(&[Bundle]) -> NeverExtFuture;
type AppSideloader = Sideloader<NeverMaxCertCb, NeverExtCb>;

/// 不透明句柄：持有 tokio runtime 与构建好的 Sideloader。
pub struct SignSession {
    rt: tokio::runtime::Runtime,
    sideloader: AppSideloader,
    /// `Sideloader` 不暴露 machine_name，保留它以对齐 SideInstaller。
    #[allow(dead_code)]
    machine_name: String,
    #[allow(dead_code)]
    storage_dir: PathBuf,
}

// 只在自己的 runtime 里使用，Swift 侧单队列串行调用。
unsafe impl Send for SignSession {}

unsafe fn opt(p: *const c_char, default: &str) -> String {
    if p.is_null() {
        return default.to_string();
    }
    CStr::from_ptr(p).to_str().unwrap_or(default).to_string()
}

/// 在首次 TLS 使用前显式选择 rustls crypto provider。
/// 我们的 crate 默认 ring，而 isideload 依赖链启用 aws-lc-rs —— 两个 provider
/// feature 同时开启时 rustls 无法自动确定，运行时报
/// "Could not automatically determine the process-level CryptoProvider"。
/// install_default 全局幂等（重复调用返回 Err，忽略即可）。
pub(crate) fn install_rustls_provider() {
    use rustls::crypto::CryptoProvider;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = CryptoProvider::get_default();
}

/// 把当前设备注册进会话所选团队（SideStore 做法：登录/切户成功后立刻注册，把 Apple
/// 的「注册 → 描述文件可用」传播空窗挪到签名关键路径之外——8220 的根）.
///
/// 与 `sign_ipa` 里的 ensure 同源（get_team + ensure_device_registered），区别是只注册
/// 不签名，且空 `udid` 直接报错——签名路径静默跳过是历史行为，预注册不该静默.
///
/// # Safety
/// `session` 必须是 `signin_with_session` 返回的有效指针；out 指针有效.
pub unsafe fn register_device(
    session: *mut SignSession,
    udid: *const c_char,
    device_name: *const c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if session.is_null() {
        *out_error = cstr("null session");
        return 2;
    }
    install_rustls_provider();
    let session = &mut *session;
    let udid = opt(udid, "");
    let device_name = opt(device_name, "");
    if udid.is_empty() {
        *out_error = cstr("empty udid");
        return 2;
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        session.rt.block_on(async {
            let team = session
                .sideloader
                .get_team()
                .await
                .map_err(|e| format!("device registration failed for UDID {udid}: {e}"))?;
            let name = if device_name.is_empty() {
                "iPhone"
            } else {
                device_name.as_str()
            };
            tracing::info!("Pre-registering device {udid} ({name}) on team {}", team.team_id);
            session
                .sideloader
                .get_dev_session()
                .ensure_device_registered(&team, name, &udid, None)
                .await
                .map_err(|e| format!("device registration failed for UDID {udid}: {e}"))?;
            tracing::info!("Device {udid} pre-registered on team {}", team.team_id);
            Ok::<_, String>(team.team_id)
        })
    }));
    match result {
        Ok(Ok(_)) => 0,
        Ok(Err(e)) => {
            *out_error = cstr(e);
            1
        }
        Err(_) => {
            *out_error = cstr("panic during device registration");
            2
        }
    }
}

/// 签名 `ipa_path` 处的 IPA，把签名后的 `.app` 包路径写入 `*out_signed_path`。
///
/// `udid` 会先注册到团队（空串跳过）——不注册 Apple 会以 8220 拒绝描述文件。
///
/// # Safety
/// `session` 必须是 `signin_with_session` 返回的有效指针；out 指针有效。
pub unsafe fn sign_ipa(
    session: *mut SignSession,
    ipa_path: *const c_char,
    udid: *const c_char,
    device_name: *const c_char,
    out_signed_path: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if session.is_null() {
        *out_error = cstr("null session");
        return 2;
    }
    install_rustls_provider();
    let session = &mut *session;
    let ipa_path = opt(ipa_path, "");
    let udid = opt(udid, "");
    let device_name = opt(device_name, "");

    let result = catch_unwind(AssertUnwindSafe(|| {
        session.rt.block_on(async {
            if udid.is_empty() {
                tracing::warn!(
                    "No device UDID provided; skipping registration — provisioning \
                     profile download may fail with developer error 8220."
                );
            } else {
                let team = session
                    .sideloader
                    .get_team()
                    .await
                    .map_err(|e| format!("device registration failed for UDID {udid}: {e}"))?;
                let name = if device_name.is_empty() {
                    "iPhone"
                } else {
                    device_name.as_str()
                };
                tracing::info!("Ensuring device {udid} ({name}) is registered on team {}", team.team_id);
                session
                    .sideloader
                    .get_dev_session()
                    .ensure_device_registered(&team, name, &udid, None)
                    .await
                    .map_err(|e| format!("device registration failed for UDID {udid}: {e}"))?;
                tracing::info!("Device {udid} is registered on the team");
            }

            tracing::info!("Signing IPA at {ipa_path}");
            let (signed, _special) = session
                .sideloader
                .sign_app(
                    PathBuf::from(&ipa_path),
                    None,
                    false,
                    None::<fn(f32) -> std::future::Ready<()>>,
                    None,
                    None,
                )
                .await
                .map_err(|e| format!("sign_app failed: {e}"))?;
            Ok::<_, String>(signed.to_string_lossy().to_string())
        })
    }));

    match result {
        Ok(Ok(path)) => {
            tracing::info!("Signed bundle at {path}");
            *out_signed_path = cstr(path);
            0
        }
        Ok(Err(e)) => {
            *out_error = cstr(e);
            1
        }
        Err(_) => {
            *out_error = cstr("panic during signing");
            2
        }
    }
}

/// Read-only adapter. The sole owner of provisioning is the Settings provider.
struct SettingsAnisetteProvider(RemoteV3AnisetteProvider);

#[async_trait::async_trait]
impl AnisetteProvider for SettingsAnisetteProvider {
    async fn get_anisette_data(&self) -> Result<AnisetteDataResponse, rootcause::Report> {
        self.0.get_anisette_data().await
    }

    async fn get_client_info(&self) -> Result<AnisetteClientInfo, rootcause::Report> {
        self.0.get_client_info().await
    }

    async fn provision(&mut self, _gs: &Arc<GrandSlam>, _force_recheck: bool) -> Result<(), rootcause::Report> {
        Err(rootcause::report!("Settings Anisette identity is unavailable; retry in Apple ID settings"))
    }
}

/// 用已有的 dsid + xcode.auth token 恢复签名会话——**跳过登录与 2FA**。
///
/// 为什么可行：TequilaDash「更多 → 设置」的 Apple ID 登录（AppleAuthenticator，
/// GrandSlam 协议）保存的 authToken 就是 `com.apple.gs.xcode.auth` 的 app token。
/// isideload 的 `DeveloperSession::new(AppToken, adsid, GrandSlam, anisette)`
/// 可以直接用 token + dsid 构造，无需重新走 SRP 握手/2FA。
/// Invalid credentials are reported to Settings; no independent login fallback.
///
/// # Safety
/// 所有 `*const c_char` 参数必须为 null 或合法的 C 字符串；out 指针必须有效。
#[allow(clippy::too_many_arguments)]
pub unsafe fn signin_with_session(
    email: *const c_char,
    dsid: *const c_char,
    auth_token: *const c_char,
    anisette_url: *const c_char,
    storage_dir: *const c_char,
    machine_name: *const c_char,
    client_info: *const c_char,
    out_session: *mut *mut SignSession,
    out_summary: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    install_rustls_provider();
    let email = opt(email, "");
    let dsid = opt(dsid, "");
    let token = opt(auth_token, "");
    let anisette_url = opt(anisette_url, "https://ani.sidestore.io");
    let storage_dir = opt(storage_dir, ".");
    let machine_name = opt(machine_name, "TequilaDash");
    let client_info = opt(client_info, "");

    let result = catch_unwind(AssertUnwindSafe(|| {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| format!("failed to start runtime: {e}"))?;

        let (sideloader, summary) = rt.block_on(async {
            tracing::info!("Session: building anisette provider ({anisette_url})");
            if email.is_empty() || dsid.is_empty() || token.is_empty() || client_info.is_empty() {
                return Err("Settings account session is incomplete".to_string());
            }
            let mut provider = RemoteV3AnisetteProvider::new(
                &anisette_url,
                Box::new(FsStorage::new(PathBuf::from(&storage_dir))),
                "0".to_string(),
            )
            .map_err(|e| format!("anisette provider: {e}"))?
            .set_client_info_override(Some(
                AnisetteClientInfo {
                    client_info: client_info.clone(),
                    user_agent: "akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0".to_string(),
                }));

            // Never call RemoteV3::provision: it creates/resets an independent identity.
            let bytes = std::fs::read(PathBuf::from(&storage_dir).join("anisette_state"))
                .map_err(|e| format!("Settings anisette snapshot: {e}"))?;
            let snapshot = plist::Value::from_reader_xml(std::io::Cursor::new(&bytes))
                .map_err(|e| format!("Settings anisette snapshot: {e}"))?;
            let dict = snapshot.as_dictionary().ok_or("Settings anisette snapshot is not a dictionary")?;
            // Upstream's 16-byte deserializer unwraps: validate before invoking it.
            if dict.get("keychain_identifier").and_then(plist::Value::as_data).map(|v| v.len()) != Some(16)
                || dict.get("adi_pb").and_then(plist::Value::as_data).is_none_or(|v| v.is_empty()) {
                return Err("Settings Anisette identity is incomplete".to_string());
            }
            provider.state = Some(plist::from_bytes(&bytes).map_err(|e| format!("Settings anisette state: {e}"))?);
            let provider = SettingsAnisetteProvider(provider);
            tracing::info!("Session: importing Settings Xcode token (no login/provision)");
            let client_info = provider
                .get_client_info()
                .await
                .map_err(|e| format!("client info: {e}"))?;
            let client = Arc::new(
                GrandSlam::new(client_info, false, None)
                    .await
                    .map_err(|e| format!("grandslam: {e}"))?,
            );

            let dev = DeveloperSession::new(
                AppToken {
                    token: token.clone(),
                    duration: 0,
                    expiry: 0,
                },
                dsid.clone(),
                client,
                AnisetteDataGenerator::new(Arc::new(tokio::sync::RwLock::new(provider))),
            );

            let mut sideloader =
                SideloaderBuilder::<NeverMaxCertCb, NeverExtCb>::new(dev, email.clone())
                    .team_selection(TeamSelection::First)
                    .max_certs_behavior(MaxCertsBehavior::Error)
                    .extensions_behavior(ExtensionsBehaviorSelection::Fixed(
                        ExtensionsBehavior::ReuseMain,
                    ))
                    .storage(Box::new(FsStorage::new(PathBuf::from(&storage_dir))))
                    .machine_name(machine_name.clone())
                    .build();

            let team = sideloader
                .get_team()
                .await
                .map_err(|e| format!("get_team: {e}"))?;
            let summary = format!(
                "team: {} ({})",
                team.name.as_deref().unwrap_or("<unnamed>"),
                team.team_id
            );
            Ok::<_, String>((sideloader, summary))
        })?;

        Ok::<_, String>((rt, sideloader, summary))
    }));

    match result {
        Ok(Ok((rt, sideloader, summary))) => {
            let session = Box::new(SignSession {
                rt,
                sideloader,
                machine_name,
                storage_dir: PathBuf::from(&storage_dir),
            });
            *out_session = Box::into_raw(session);
            *out_summary = cstr(summary);
            0
        }
        Ok(Err(e)) => {
            *out_error = cstr(e);
            1
        }
        Err(panic) => {
            let msg = panic_message(&panic);
            *out_error = cstr(format!("panic during session restore: {msg}"));
            2
        }
    }
}

/// 释放 `SignSession`。
///
/// # Safety
/// `session` 必须为 null 或 `signin_with_session` 返回的指针。
pub unsafe fn sign_session_free(session: *mut SignSession) {
    if !session.is_null() {
        drop(Box::from_raw(session));
    }
}

// ---------------------------------------------------------------------------
// C 字符串助手（移植自 SideInstaller 的 ffi_util.rs）
// ---------------------------------------------------------------------------

/// 提取 catch_unwind 捕获的 panic 消息（&str / String / 未知）。
pub fn panic_message(panic: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = panic.downcast_ref::<&str>() {
        s.to_string()
    } else if let Some(s) = panic.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic payload".to_string()
    }
}

/// 分配一个调用方用 `si_string_free` 释放的 C 字符串。
pub fn cstr(s: impl Into<Vec<u8>>) -> *mut c_char {
    use std::ffi::CString;
    let c = CString::new(s).unwrap_or_default();
    unsafe { c.into_raw() }
}

/// 释放 `cstr` 产生的堆 C 字符串。
///
/// # Safety
/// `p` 必须为 null 或 `cstr`/`into_raw` 返回的指针。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn si_string_free(p: *mut c_char) {
    use std::ffi::CString;
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}
