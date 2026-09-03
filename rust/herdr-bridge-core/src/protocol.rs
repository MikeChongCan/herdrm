//! NDJSON request/response framing, compatible with herdr's socket protocol.
//!
//! Verified against the live socket for herdr 0.8.0 / protocol 19 (see
//! `CLAUDE.md`): requests are newline-delimited `{"id","method","params"}` and
//! **`params` must be present even when empty** — the server rejects a request
//! that omits it. That rule is enforced by construction here rather than left
//! to each call site to remember.

use anyhow::{bail, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

/// A request to the bridge.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub id: u64,
    pub method: String,
    /// Always serialized, as `{}` when there are no arguments.
    pub params: Value,
}

impl Request {
    /// A request with no arguments. `params` still serializes as `{}`.
    pub fn new(id: u64, method: impl Into<String>) -> Self {
        Self {
            id,
            method: method.into(),
            params: Value::Object(Map::new()),
        }
    }

    /// A request with arguments. A non-object `params` is rejected, since the
    /// server expects an object.
    pub fn with_params(id: u64, method: impl Into<String>, params: Value) -> Result<Self> {
        if !params.is_object() {
            bail!("params must be a JSON object, got {params}");
        }
        Ok(Self {
            id,
            method: method.into(),
            params,
        })
    }

    /// Encodes as one NDJSON frame, trailing newline included.
    pub fn to_ndjson(&self) -> Result<String> {
        let mut line = serde_json::to_string(self)?;
        line.push('\n');
        Ok(line)
    }
}

/// An error object in a response.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
}

/// A response to a [`Request`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Response {
    pub id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

impl Response {
    pub fn ok(id: u64, result: Value) -> Self {
        Self {
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn err(id: u64, code: i64, message: impl Into<String>) -> Self {
        Self {
            id,
            result: None,
            error: Some(RpcError {
                code,
                message: message.into(),
            }),
        }
    }

    pub fn is_ok(&self) -> bool {
        self.error.is_none()
    }
}

/// A server-pushed event.
///
/// Global events (`pane.updated` and friends) carry no `pane_id`; the
/// pane-scoped ones (`pane.agent_status_changed`, `pane.scroll_changed`,
/// `pane.output_matched`) cannot be subscribed globally and always name a pane.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Event {
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane_id: Option<String>,
    #[serde(default)]
    pub params: Value,
}

impl Event {
    pub fn global(kind: impl Into<String>, params: Value) -> Self {
        Self {
            kind: kind.into(),
            pane_id: None,
            params,
        }
    }

    pub fn for_pane(kind: impl Into<String>, pane_id: impl Into<String>, params: Value) -> Self {
        Self {
            kind: kind.into(),
            pane_id: Some(pane_id.into()),
            params,
        }
    }
}

/// Builds the `events.subscribe` payload, which takes a list of `{"type": …}`
/// objects rather than bare strings.
pub fn subscribe_params(kinds: &[&str]) -> Value {
    json!({
        "subscriptions": kinds.iter().map(|k| json!({ "type": k })).collect::<Vec<_>>()
    })
}

/// Reassembles NDJSON frames from arbitrarily chunked reads.
#[derive(Debug, Default)]
pub struct LineDecoder {
    buffer: Vec<u8>,
}

impl LineDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feeds bytes and returns every complete line, without terminators.
    /// Incomplete trailing data is retained for the next call.
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<String> {
        self.buffer.extend_from_slice(bytes);
        let mut lines = Vec::new();

        while let Some(index) = self.buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=index).collect();
            // Drop the '\n', then any '\r' from CRLF.
            let mut text = String::from_utf8_lossy(&line[..line.len() - 1]).into_owned();
            if text.ends_with('\r') {
                text.pop();
            }
            if !text.is_empty() {
                lines.push(text);
            }
        }

        lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_without_arguments_still_serializes_params() {
        // The server rejects a request with no `params` key at all.
        let line = Request::new(1, "pane.list").to_ndjson().expect("encode");
        assert_eq!(line, "{\"id\":1,\"method\":\"pane.list\",\"params\":{}}\n");
    }

    #[test]
    fn request_with_params_round_trips() {
        let request = Request::with_params(7, "pane.resize", json!({"rows": 40, "cols": 120}))
            .expect("object params");
        let encoded = serde_json::to_string(&request).expect("encode");
        let decoded: Request = serde_json::from_str(&encoded).expect("decode");
        assert_eq!(decoded, request);
        assert_eq!(decoded.params["rows"], 40);
    }

    #[test]
    fn non_object_params_are_rejected() {
        assert!(Request::with_params(1, "pane.list", json!([1, 2])).is_err());
    }

    #[test]
    fn ndjson_frame_ends_with_exactly_one_newline() {
        let line = Request::new(2, "workspace.list")
            .to_ndjson()
            .expect("encode");
        assert!(line.ends_with('\n'));
        assert_eq!(line.matches('\n').count(), 1);
    }

    #[test]
    fn response_omits_absent_result_and_error() {
        let encoded =
            serde_json::to_string(&Response::ok(3, json!({"panes": []}))).expect("encode");
        assert!(!encoded.contains("error"));
        assert!(encoded.contains("result"));
    }

    #[test]
    fn error_response_is_not_ok() {
        let response = Response::err(4, -32601, "method not found");
        assert!(!response.is_ok());
        assert_eq!(response.error.expect("error").code, -32601);
    }

    #[test]
    fn subscribe_params_wraps_kinds_in_type_objects() {
        let params = subscribe_params(&["pane.updated", "pane.added"]);
        assert_eq!(params["subscriptions"][0]["type"], "pane.updated");
        assert_eq!(params["subscriptions"][1]["type"], "pane.added");
    }

    #[test]
    fn decoder_splits_multiple_frames_in_one_read() {
        let mut decoder = LineDecoder::new();
        let lines = decoder.feed(b"{\"a\":1}\n{\"b\":2}\n");
        assert_eq!(lines, ["{\"a\":1}", "{\"b\":2}"]);
    }

    #[test]
    fn decoder_holds_a_partial_frame_until_it_completes() {
        let mut decoder = LineDecoder::new();
        assert!(decoder.feed(b"{\"a\":").is_empty());
        assert_eq!(decoder.feed(b"1}\n"), ["{\"a\":1}"]);
    }

    #[test]
    fn decoder_handles_crlf_and_skips_blank_lines() {
        let mut decoder = LineDecoder::new();
        assert_eq!(
            decoder.feed(b"{\"a\":1}\r\n\n{\"b\":2}\n"),
            ["{\"a\":1}", "{\"b\":2}"]
        );
    }

    #[test]
    fn event_uses_type_as_the_wire_key() {
        let encoded =
            serde_json::to_string(&Event::global("pane.updated", json!({}))).expect("encode");
        assert!(encoded.contains("\"type\":\"pane.updated\""));
        assert!(!encoded.contains("pane_id"));
    }

    #[test]
    fn pane_scoped_event_carries_its_pane_id() {
        let event = Event::for_pane(
            "pane.agent_status_changed",
            "pane-1",
            json!({"status":"blocked"}),
        );
        let encoded = serde_json::to_string(&event).expect("encode");
        assert!(encoded.contains("\"pane_id\":\"pane-1\""));
    }
}
