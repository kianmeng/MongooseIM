When a client enters a conversation after being offline for a while, such client might want to know what was the last message-id that was marked according to the rules defined in [XEP-0333 - Chat Markers][chat-markers], in order to know where he left of, and build an enhanced UI.

MongooseIM provides such functionality, using [mod_smart_markers](../modules/mod_smart_markers.md)

## Namespace
'esl:xmpp:smart-markers:0'

## Fetching a conversation's latest markers

### Individual fetch

Given a peer, i.e., another user or a muc room, we can fetch the marker we last sent, to the main thread or any other sub-thread, with an IQ like the following:
```xml
<iq id='iq-unique-id' type='get'>
  <query xmlns='esl:xmpp:smart-markers:0' peer='<peer-bare-jid>' [thread='<thread-id>' after='<RFC3339-timestamp>'] />
</iq>
```
where:

* `<peer-bare-jid>` MUST be the bare jid of the peer whose last marker wants to be checked.
* `<thread>` is an optional attribute that indicates if the check refers to specific a thread in the conversation. If not provided, defaults to the main conversation thread.
* `<after>` is an optional attribute indicating whether markers sent only after a certain timestamp are desired.

Then the following would be received, was there to be any marker:
```xml
<iq from='user-bare-jid' to='user-jid' id='iq-unique-id' type='result'>
  <query xmlns='esl:xmpp:smart-markers:0' entity='peer-bare-jid' >
    <marker id='<message-id>' type='<type>' timestamp='<RFC3339>' [thread='<thread-id>'] />
  </query>
</iq>
```
where `peer-bare-jid` matches the requested bare jid and the subelements are `marker` xml payloads with the following attributes:

* `<id>` is the message id associated to this marker.
* `<type>` is a marker as described in [XEP-0333][chat-markers].
* `<timestamp>` contains an RFC3339 timestamp indicating when the marker was sent
* `<thread>` is an optional attribute that indicates if the marker refers to specific a thread in the conversation, or the main conversation if absent.

[chat-markers]: https://xmpp.org/extensions/xep-0333.html
