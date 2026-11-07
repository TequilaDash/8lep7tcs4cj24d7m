// Gnoix-style in-process software tunnel: usbmuxd -> lockdown -> CoreDeviceProxy -> jktcp.

use std::ffi::{CStr, c_char};
use std::time::{SystemTime, UNIX_EPOCH};

use idevice::{
    Idevice,
    IdeviceError,
    core_device_proxy::CoreDeviceProxy,
    lockdown::LockdownClient,
    pairing_file::PairingFile,
    rsd::RsdHandshake,
    usbmuxd::UsbmuxdConnection,
};

use crate::{
    IdeviceFfiError,
    core_device_proxy::AdapterHandle,
    ffi_err,
    rsd::RsdHandshakeHandle,
    run_sync_local,
    tunnel_provider::TunnelFailureKind,
};

const SERVICE_CORE_DEVICE_PROXY: &str = "com.apple.coredevice.proxy";
const LOCKDOWN_PORT: u16 = 62078;
const LABEL: &str = "tequila";
const LOCKDOWN_HOST: &str = "127.0.0.1";
const SELF_BUID: &str = "tequila-self";

struct SoftFailure {
    kind: TunnelFailureKind,
    stage: &'static str,
    err: IdeviceError,
}

fn sf(kind: TunnelFailureKind, stage: &'static str, err: impl Into<IdeviceError>) -> SoftFailure {
    SoftFailure { kind, stage, err: err.into() }
}

fn io_err(e: std::io::Error) -> IdeviceError {
    IdeviceError::InternalError(format!("{e}"))
}

fn gen_host_id() -> String {
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    let a = n ^ 0x9E37_79B9_7F4A_7C15;
    let b = n.rotate_left(17) ^ 0x632B_E599_66D0_24A5;
    format!(
        "{:08x}-{:04x}-4{:03x}-{:04x}-{:012x}",
        a & 0xFFFF_FFFF,
        (a >> 32) & 0xFFFF,
        (b >> 48) & 0x0FFF,
        0x8000 | ((b >> 16) & 0x3FFF),
        b & 0xFFFF_FFFF_FFFF
    )
}

async fn lockdown_connect(device_id: u32) -> Result<LockdownClient, SoftFailure> {
    let conn = UsbmuxdConnection::default()
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "usbmuxd_connect", e))?;
    let idev = conn
        .connect_to_device(device_id, LOCKDOWN_PORT, LABEL)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "lockdown_connect", e))?;
    Ok(LockdownClient::new(idev))
}

async fn port_with_session(device_id: u32, pf: &PairingFile) -> Result<(LockdownClient, u16), SoftFailure> {
    let mut client = lockdown_connect(device_id).await?;
    client
        .start_session(pf)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailurePairVerify, "start_session", e))?;
    let (port, _) = client
        .start_service(SERVICE_CORE_DEVICE_PROXY)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "start_service", e))?;
    Ok((client, port))
}

async fn port_via_file(device_id: u32, path: &str) -> Result<(LockdownClient, u16), SoftFailure> {
    let pf = PairingFile::read_from_file(path)
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "read_pairing_file", e))?;
    port_with_session(device_id, &pf).await
}

async fn port_via_no_session(device_id: u32) -> Result<(LockdownClient, u16), SoftFailure> {
    let mut client = lockdown_connect(device_id).await?;
    let (port, _) = client
        .start_service(SERVICE_CORE_DEVICE_PROXY)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "start_service", e))?;
    Ok((client, port))
}

#[cfg(feature = "pair")]
async fn port_via_self_pair(udid: &str, device_id: u32) -> Result<(LockdownClient, u16), SoftFailure> {
    let mut client = lockdown_connect(device_id).await?;
    let buid = match UsbmuxdConnection::default().await {
        Ok(mut c) => c.get_buid().await.unwrap_or_default(),
        Err(_) => String::new(),
    };
    let buid = if buid.is_empty() { "tequila-buid".to_string() } else { buid };
    let pf = client
        .pair(gen_host_id(), buid, Some(LABEL))
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailurePairVerify, "lockdown_pair", e))?;
    client
        .start_session(&pf)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailurePairVerify, "start_session", e))?;
    let (port, _) = client
        .start_service(SERVICE_CORE_DEVICE_PROXY)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "start_service", e))?;
    if let Ok(bytes) = pf.serialize() {
        if let Ok(mut c) = UsbmuxdConnection::default().await {
            let _ = c.save_pair_record(udid, bytes).await;
        }
    }
    Ok((client, port))
}
// ---------------------------------------------------------------- loopback lockdown chain

async fn lockdown_connect_tcp() -> Result<LockdownClient, SoftFailure> {
    let stream = tokio::net::TcpStream::connect((LOCKDOWN_HOST, LOCKDOWN_PORT))
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "tcp_lockdown_connect", io_err(e)))?;
    Ok(LockdownClient::new(Idevice::new(Box::new(stream), LABEL)))
}

async fn tcp_service_port(mut client: LockdownClient, pf: &PairingFile) -> Result<(LockdownClient, u16), SoftFailure> {
    client
        .start_session(pf)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailurePairVerify, "tcp_start_session", e))?;
    let (port, _) = client
        .start_service(SERVICE_CORE_DEVICE_PROXY)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "tcp_start_service", e))?;
    Ok((client, port))
}

async fn port_via_tcp_file(path: &str) -> Result<(LockdownClient, u16), SoftFailure> {
    let pf = PairingFile::read_from_file(path)
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "tcp_read_record", e))?;
    let client = lockdown_connect_tcp().await?;
    tcp_service_port(client, &pf).await
}

#[cfg(feature = "pair")]
async fn port_via_tcp_self_pair() -> Result<(LockdownClient, u16), SoftFailure> {
    let mut client = lockdown_connect_tcp().await?;
    let pf = client
        .pair(gen_host_id(), SELF_BUID.to_string(), Some(LABEL))
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailurePairVerify, "tcp_lockdown_pair", e))?;
    tcp_service_port(client, &pf).await
}

async fn chain_tcp(file_path: Option<&str>) -> Result<(AdapterHandle, RsdHandshakeHandle), SoftFailure> {
    // Try an on-disk lockdown pairing record first. The remote-pairing record the app
    // keeps uses a different host identity than lockdownd itself, so this normally
    // fails and falls through to self pairing below.
    if let Some(path) = file_path {
        if let Ok((client, port)) = port_via_tcp_file(path).await {
            return finish_soft_tunnel_tcp(client, port).await;
        }
    }

    #[cfg(feature = "pair")]
    {
        let (client, port) = port_via_tcp_self_pair().await?;
        return finish_soft_tunnel_tcp(client, port).await;
    }

    #[cfg(not(feature = "pair"))]
    Err(sf(
        TunnelFailureKind::TunnelFailurePairVerify,
        "tcp_lockdown_pair",
        IdeviceError::InternalError("pair feature disabled".into()),
    ))
}

async fn finish_soft_tunnel_tcp(
    client: LockdownClient,
    port: u16,
) -> Result<(AdapterHandle, RsdHandshakeHandle), SoftFailure> {
    // Keep the lockdown session (and its socket) alive for the tunnel handshake.
    let _session = client;
    let stream = tokio::net::TcpStream::connect((LOCKDOWN_HOST, port))
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "tcp_connect_service_port", io_err(e)))?;
    let idev = Idevice::new(Box::new(stream), LABEL);
    let proxy = CoreDeviceProxy::new(idev)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureTlsHandshake, "cd_tunnel_handshake", e))?;
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let adapter = proxy
        .create_software_tunnel()
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureTlsHandshake, "software_tunnel", e))?;
    let mut handle = adapter.to_async_handle();
    let stream = handle
        .connect(rsd_port)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "rsd_port_connect", e))?;
    let handshake = RsdHandshake::new(stream)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "rsd_handshake", e))?;
    Ok((AdapterHandle(handle), RsdHandshakeHandle(handshake)))
}

async fn finish_soft_tunnel_usbmuxd(
    device_id: u32,
    client: LockdownClient,
    port: u16,
) -> Result<(AdapterHandle, RsdHandshakeHandle), SoftFailure> {
    let _client = client;
    let conn = UsbmuxdConnection::default()
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "usbmuxd_connect", e))?;
    let idev = conn
        .connect_to_device(device_id, port, LABEL)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "connect_service_port", e))?;
    let proxy = CoreDeviceProxy::new(idev)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureTlsHandshake, "cd_tunnel_handshake", e))?;
    let rsd_port = proxy.tunnel_info().server_rsd_port;
    let adapter = proxy
        .create_software_tunnel()
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureTlsHandshake, "software_tunnel", e))?;
    let mut handle = adapter.to_async_handle();
    let stream = handle
        .connect(rsd_port)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "rsd_port_connect", e))?;
    let handshake = RsdHandshake::new(stream)
        .await
        .map_err(|e| sf(TunnelFailureKind::TunnelFailureOther, "rsd_handshake", e))?;
    Ok((AdapterHandle(handle), RsdHandshakeHandle(handshake)))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn tunnel_create_soft(
    lockdown_pairing_path: *const c_char,
    out_failure_kind: *mut TunnelFailureKind,
    out_adapter: *mut *mut AdapterHandle,
    out_handshake: *mut *mut RsdHandshakeHandle,
    stage_buf: *mut c_char,
    stage_buf_len: usize,
) -> *mut IdeviceFfiError {
    let set_kind = |kind: TunnelFailureKind| {
        if !out_failure_kind.is_null() {
            unsafe { *out_failure_kind = kind };
        }
    };
    set_kind(TunnelFailureKind::TunnelFailureNone);

    let write_stage = |stage: &str| {
        if stage_buf.is_null() || stage_buf_len == 0 {
            return;
        }
        let bytes = stage.as_bytes();
        let n = bytes.len().min(stage_buf_len - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), stage_buf as *mut u8, n);
            *stage_buf.add(n) = 0;
        }
    };

    if out_adapter.is_null() || out_handshake.is_null() {
        set_kind(TunnelFailureKind::TunnelFailureOther);
        write_stage("invalid_args");
        return ffi_err!(IdeviceError::InternalError("out pointers are null".into()));
    }

    let file_path: Option<String> = if lockdown_pairing_path.is_null() {
        None
    } else {
        match unsafe { CStr::from_ptr(lockdown_pairing_path) }.to_str() {
            Ok(s) if !s.is_empty() => Some(s.to_string()),
            Ok(_) => None,
            Err(_) => {
                set_kind(TunnelFailureKind::TunnelFailureOther);
                write_stage("invalid_args");
                return ffi_err!(IdeviceError::InternalError("pairing path is not UTF-8".into()));
            }
        }
    };

    let res = run_sync_local(async move {
        let mut last: Option<SoftFailure> = None;

        // Stage 0: loopback lockdown chain (minimuxer/StikDebug style). This is the
        // only transport that exists inside the iOS sandbox: /var/run/usbmuxd is not
        // reachable there, but lockdownd listens on 127.0.0.1:62078 on the device
        // itself. Failure stages from this chain carry the tcp_ prefix.
        match chain_tcp(file_path.as_deref()).await {
            Ok(done) => return Ok(done),
            Err(f) => {
                tracing::warn!("soft tunnel: loopback lockdown failed at {}: {:?}", f.stage, f.err);
                last = Some(f);
            }
        }

        // Fallback: usbmuxd transport (jailbroken devices / desktop hosts).
        let mut conn = match UsbmuxdConnection::default().await {
            Ok(c) => c,
            Err(e) => {
                let f = sf(TunnelFailureKind::TunnelFailureOther, "usbmuxd_connect", e);
                tracing::warn!("soft tunnel: usbmuxd fallback failed at {}: {:?}", f.stage, f.err);
                return Err(last.unwrap_or(f));
            }
        };
        let devices = match conn.get_devices().await {
            Ok(d) => d,
            Err(e) => return Err(sf(TunnelFailureKind::TunnelFailureOther, "usbmuxd_get_devices", e)),
        };
        let dev = match devices.first() {
            Some(d) => d,
            None => {
                return Err(SoftFailure {
                    kind: TunnelFailureKind::TunnelFailureOther,
                    stage: "no_device",
                    err: IdeviceError::UnexpectedResponse("no device attached via usbmuxd".into()),
                });
            }
        };
        let udid = dev.udid.clone();
        let device_id = dev.device_id;
        drop(devices);

        tracing::info!("soft tunnel: device {udid} (id {device_id}), starting usbmuxd pairing chain");
        let mut client_port: Option<(LockdownClient, u16)> = None;

        match conn.get_pair_record(&udid).await {
            Ok(pf) => match port_with_session(device_id, &pf).await {
                Ok(cp) => client_port = Some(cp),
                Err(f) => {
                    tracing::warn!("soft tunnel: usbmuxd record failed at {}: {:?}", f.stage, f.err);
                    last = Some(f);
                }
            },
            Err(e) => {
                tracing::warn!("soft tunnel: no usbmuxd pair record: {e}");
                last = Some(sf(TunnelFailureKind::TunnelFailureOther, "get_pair_record", e));
            }
        }

        if client_port.is_none() {
            if let Some(path) = file_path.as_deref() {
                match port_via_file(device_id, path).await {
                    Ok(cp) => client_port = Some(cp),
                    Err(f) => {
                        tracing::warn!("soft tunnel: file record failed at {}: {:?}", f.stage, f.err);
                        last = Some(f);
                    }
                }
            }
        }

        if client_port.is_none() {
            match port_via_no_session(device_id).await {
                Ok(cp) => client_port = Some(cp),
                Err(f) => {
                    tracing::warn!("soft tunnel: session-less start failed at {}: {:?}", f.stage, f.err);
                    last = Some(f);
                }
            }
        }

        #[cfg(feature = "pair")]
        if client_port.is_none() {
            match port_via_self_pair(&udid, device_id).await {
                Ok(cp) => client_port = Some(cp),
                Err(f) => {
                    tracing::warn!("soft tunnel: self pair failed at {}: {:?}", f.stage, f.err);
                    last = Some(f);
                }
            }
        }

        let (client, port) = match client_port {
            Some(cp) => cp,
            None => {
                return Err(last.unwrap_or_else(|| {
                    sf(TunnelFailureKind::TunnelFailureOther, "pairing", IdeviceError::InternalError("no pairing strategy succeeded".into()))
                }));
            }
        };

        finish_soft_tunnel_usbmuxd(device_id, client, port).await
    });

    match res {
        Ok((adapter, handshake)) => {
            unsafe {
                *out_adapter = Box::into_raw(Box::new(adapter));
                *out_handshake = Box::into_raw(Box::new(handshake));
            }
            write_stage("ok");
            std::ptr::null_mut()
        }
        Err(f) => {
            set_kind(f.kind);
            write_stage(f.stage);
            ffi_err!(f.err)
        }
    }
}