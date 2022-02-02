## Module Description

Smart markers are an experimental feature, described in detail as our [Open XMPP Extension](../open-extensions/smart-markers.md).

## Options

### `modules.mod_smart_markers.iqdisc`
* **Syntax:** array of strings, out of `"displayed"`, `"received"`, `"acknowledged"`
* **Default:** `["displayed"]`
* **Example:** `reset_markers = ["received"]`

* **Syntax:** string, one of `"one_queue"`, `"no_queue"`, `"queues"`, `"parallel"`
* **Default:** `"no_queue"`

Strategy to handle incoming IQ requests. For details, please refer to
[IQ processing policies](../configuration/Modules.md#iq-processing-policies).

### `modules.mod_smart_markers.backend`
* **Syntax:** string, only `"rdbms"` is supported at the moment.
* **Default:** `"rdbms"`
* **Example:** `backend = "rdbms"`

## Example configuration

```toml
[modules.mod_smart_markers]
  backend = "rdbms"
  iqdisc = "parallel"
```

## Implementation details
The current implementation has some limitations:

* It does not verify that markers only move forwards, hence a user can, intentionally or accidentally, send a marker to an older message, and this would override newer ones.
* It stores markers sent only for users served on a local domain. It does not store received markers, so if the peer is reached across federation, this module won't track markers for federated users. Therefore extensions that desire seeing not only the sender's markers but also the peer's markers, won't work with the current implementation across federated users.
