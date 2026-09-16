use antgrid_iroh_relay::config::Config;
use serde_json::{Value, json};

/// The advertised scheme and the wire the listener actually serves are set by
/// one flag, so the pairing a deployment could get wrong — cleartext behind an
/// `https` origin, or a TLS listener behind an `http` one — has to be refused
/// rather than merely discouraged.
fn config(overrides: Value) -> Result<Config, serde_json::Error> {
    let mut value = json!({
        "listen": "127.0.0.1:443", "adminListen": "127.0.0.1:9000",
        "tlsCert": "unused", "tlsKey": "unused",
        "admissionUrl": "http://127.0.0.1/internal/peer-admission",
        "relayUrl": "https://relay.example/",
        "admissionSecret": "a".repeat(32), "adminSecret": "b".repeat(32),
        "maxConnections": 8, "maxPendingAdmissions": 2, "maxAccounts": 2,
        "maxAccountConnections": 2, "maxEndpointConnections": 1,
        "bytesPerSecond": 1_000_000, "burstBytes": 1_000_000,
    });
    let object = value.as_object_mut().expect("object");
    for (key, replacement) in overrides.as_object().expect("overrides") {
        if replacement.is_null() {
            object.remove(key);
        } else {
            object.insert(key.clone(), replacement.clone());
        }
    }
    serde_json::from_value(value)
}

#[test]
fn tls_stays_mandatory_and_pinned_to_443_by_default() {
    assert!(config(json!({})).unwrap().validate().is_ok());
    // No flag: an http origin is refused, so a stock config cannot be pointed
    // at a cleartext relay by editing one string.
    assert!(
        config(json!({"relayUrl": "http://relay.example/"}))
            .unwrap()
            .validate()
            .is_err()
    );
    for missing in [json!({"tlsCert": null}), json!({"tlsKey": null})] {
        assert!(config(missing).unwrap().validate().is_err());
    }
    assert!(
        config(json!({"listen": "127.0.0.1:8443"}))
            .unwrap()
            .validate()
            .is_err()
    );
}

#[test]
fn dev_insecure_http_requires_an_http_origin_and_no_certificate() {
    let dev = json!({
        "devInsecureHttp": true, "relayUrl": "http://127.0.0.1:3000/",
        "tlsCert": null, "tlsKey": null, "listen": "127.0.0.1:3443",
    });
    assert!(config(dev.clone()).unwrap().validate().is_ok());

    // Serving cleartext while advertising https is the dangerous half, and it
    // is what a careless edit produces; refuse it rather than let clients dial
    // a TLS origin that answers in the clear.
    let mut https_origin = dev.clone();
    https_origin["relayUrl"] = json!("https://relay.example/");
    assert!(config(https_origin).unwrap().validate().is_err());

    // A leftover certificate means the operator believes TLS is on.
    let mut with_cert = dev.clone();
    with_cert["tlsCert"] = json!("unused");
    with_cert["tlsKey"] = json!("unused");
    assert!(config(with_cert).unwrap().validate().is_err());

    // The origin is still validated; only the scheme widened.
    for bad in [
        "http://user:secret@127.0.0.1:3000/",
        "http://127.0.0.1:3000/?token=secret",
        "http://127.0.0.1:3000/path",
        // Cleartext belongs to a network the developer controls, so a public
        // host is refused here rather than left to whatever each peer checks.
        "http://relay.example/",
        "http://8.8.8.8:3000/",
    ] {
        let mut invalid = dev.clone();
        invalid["relayUrl"] = json!(bad);
        assert!(config(invalid).unwrap().validate().is_err(), "{bad}");
    }

    // A LAN bind is the point — a phone or emulator has to reach it.
    let mut lan = dev.clone();
    lan["listen"] = json!("192.168.1.10:3443");
    lan["relayUrl"] = json!("http://192.168.1.10:3000/");
    assert!(config(lan).unwrap().validate().is_ok());
    let mut named = dev.clone();
    named["relayUrl"] = json!("http://localhost:3000/");
    assert!(config(named).unwrap().validate().is_ok());

    // Binding every interface is what turns a dev convenience into a public
    // cleartext relay, and it is refused whatever the origin says.
    for bad in ["0.0.0.0:3443", "[::]:3443", "203.0.113.4:3443"] {
        let mut invalid = dev.clone();
        invalid["listen"] = json!(bad);
        assert!(config(invalid).unwrap().validate().is_err(), "{bad}");
    }

    // The admin listener stays loopback-only regardless of the flag.
    let mut public_admin = dev;
    public_admin["adminListen"] = json!("0.0.0.0:9000");
    assert!(config(public_admin).unwrap().validate().is_err());
}
