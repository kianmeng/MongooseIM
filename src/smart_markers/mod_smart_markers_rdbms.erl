%%%----------------------------------------------------------------------------
%%% @copyright (C) 2020, Erlang Solutions Ltd.
%%% @doc
%%%    RDBMS backend for mod_smart_markers
%%% @end
%%%----------------------------------------------------------------------------
-module(mod_smart_markers_rdbms).
-author("denysgonchar").
-behavior(mod_smart_markers_backend).

-include("jlib.hrl").

-export([init/2, update_chat_marker/2, get_chat_markers/4]).
-export([get_conv_chat_marker/5]).
-export([remove_domain/2, remove_user/2, remove_to/2, remove_to_for_user/3]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
-spec init(mongooseim:host_type(), gen_mod:module_opts()) -> ok.
init(HostType, _) ->
    KeyFields = [<<"lserver">>, <<"from_luser">>, <<"to_jid">>, <<"thread">>, <<"type">>],
    UpdateFields = [<<"msg_id">>, <<"timestamp">>],
    InsertFields = KeyFields ++ UpdateFields,
    rdbms_queries:prepare_upsert(HostType, smart_markers_upsert, smart_markers,
                                 InsertFields, UpdateFields, KeyFields),
    mongoose_rdbms:prepare(smart_markers_select_conv, smart_markers,
        [lserver, from_luser, to_jid, thread, timestamp],
        <<"SELECT thread, type, msg_id, timestamp FROM smart_markers "
          "WHERE lserver = ? AND from_luser = ? AND to_jid = ? AND thread = ? AND timestamp >= ?">>),
    mongoose_rdbms:prepare(smart_markers_select, smart_markers,
        [to_jid, thread, timestamp],
        <<"SELECT lserver, from_luser, type, msg_id, timestamp FROM smart_markers "
          "WHERE to_jid = ? AND thread = ? AND timestamp >= ?">>),
    mongoose_rdbms:prepare(markers_remove_domain, smart_markers,
        [lserver], <<"DELETE FROM smart_markers WHERE lserver=?">>),
    mongoose_rdbms:prepare(markers_remove_user, smart_markers,
        [lserver, from_luser], <<"DELETE FROM smart_markers WHERE lserver=? AND from_luser=?">>),
    mongoose_rdbms:prepare(markers_remove_to, smart_markers,
        [to_jid], <<"DELETE FROM smart_markers WHERE to_jid=?">>),
    mongoose_rdbms:prepare(markers_remove_to_for_user, smart_markers,
        [lserver, from_luser, to_jid],
        <<"DELETE FROM smart_markers WHERE lserver=? AND from_luser=? AND to_jid=?">>),
    ok.

%%% @doc
%%% 'from', 'to', 'thread' and 'type' keys of the ChatMarker map serve
%%% as a composite database key. If key is not available in the database,
%%% then chat marker must be added. Otherwise this function must update
%%% chat marker record for that composite key.
%%% @end
-spec update_chat_marker(mongooseim:host_type(),
                         mod_smart_markers:chat_marker()) -> ok.
update_chat_marker(HostType, #{from := #jid{luser = LU, lserver = LS},
                               to := To, thread := Thread,
                               type := Type, timestamp := TS, id := Id}) ->
    ToEncoded = encode_jid(To),
    ThreadEncoded = encode_thread(Thread),
    TypeEncoded = encode_type(Type),
    KeyValues = [LS, LU, ToEncoded, ThreadEncoded, TypeEncoded],
    UpdateValues = [Id, TS],
    InsertValues = KeyValues ++ UpdateValues,
    Res = rdbms_queries:execute_upsert(HostType, smart_markers_upsert,
                                       InsertValues, UpdateValues, KeyValues),
    ok = check_upsert_result(Res).

-spec get_conv_chat_marker(HostType :: mongooseim:host_type(),
                           From :: jid:jid(),
                           To :: jid:jid(),
                           Thread :: mod_smart_markers:maybe_thread(),
                           Timestamp :: integer()) -> [mod_smart_markers:chat_marker()].
get_conv_chat_marker(HostType, From = #jid{luser = LU, lserver = LS}, To, Thread, TS) ->
    {selected, ChatMarkers} = mongoose_rdbms:execute_successfully(
                                HostType, smart_markers_select_conv,
                                [LS, LU, encode_jid(To), encode_thread(Thread), TS]),
    [ #{from => From,
        to => To,
        thread => decode_thread(MsgThread),
        type => decode_type(Type),
        timestamp => decode_timestamp(MsgTS),
        id => MsgId}
      || {MsgThread, Type, MsgId, MsgTS} <- ChatMarkers].


%%% @doc
%%% This function must return the latest chat markers sent to the
%%% user/room (with or w/o thread) later than provided timestamp.
%%% @end
-spec get_chat_markers(HostType :: mongooseim:host_type(),
                       To :: jid:jid(),
                       Thread :: mod_smart_markers:maybe_thread(),
                       Timestamp :: integer()) -> [mod_smart_markers:chat_marker()].
get_chat_markers(HostType, To, Thread, TS) ->
    {selected, ChatMarkers} = mongoose_rdbms:execute_successfully(
                                HostType, smart_markers_select,
                                [encode_jid(To), encode_thread(Thread), TS]),
    [ #{from => jid:make_noprep(CLUser, CLServer, <<>>),
        to => To,
        thread => Thread,
        type => decode_type(CType),
        timestamp => decode_timestamp(CTS),
        id => CMsgId}
      || {CLServer, CLUser, CType, CMsgId, CTS} <- ChatMarkers].


-spec remove_domain(mongooseim:host_type(), jid:lserver()) -> mongoose_rdbms:query_result().
remove_domain(HostType, Domain) ->
    mongoose_rdbms:execute_successfully(HostType, markers_remove_domain, [Domain]).

-spec remove_user(mongooseim:host_type(), jid:jid()) -> mongoose_rdbms:query_result().
remove_user(HostType, #jid{luser = LU, lserver = LS}) ->
    mongoose_rdbms:execute_successfully(HostType, markers_remove_user, [LS, LU]).

-spec remove_to(mongooseim:host_type(), jid:jid()) -> mongoose_rdbms:query_result().
remove_to(HostType, To) ->
    mongoose_rdbms:execute_successfully(HostType, markers_remove_to, [encode_jid(To)]).

-spec remove_to_for_user(mongooseim:host_type(), From :: jid:jid(), To :: jid:jid()) ->
    mongoose_rdbms:query_result().
remove_to_for_user(HostType, #jid{luser = LU, lserver = LS}, To) ->
    mongoose_rdbms:execute_successfully(HostType, markers_remove_to_for_user, [LS, LU, encode_jid(To)]).

%%--------------------------------------------------------------------
%% local functions
%%--------------------------------------------------------------------
encode_jid(JID) -> jid:to_binary(jid:to_lus(JID)).

encode_thread(undefined) -> <<>>;
encode_thread(Thread)    -> Thread.

encode_type(received)     -> <<"R">>;
encode_type(displayed)    -> <<"D">>;
encode_type(acknowledged) -> <<"A">>.

%% MySQL returns 1 when an upsert is an insert
%% and 2, when an upsert acts as update
check_upsert_result({updated, 1}) -> ok;
check_upsert_result({updated, 2}) -> ok;
check_upsert_result(Result) ->
    {error, {bad_result, Result}}.

decode_type(<<"R">>) -> received;
decode_type(<<"D">>) -> displayed;
decode_type(<<"A">>) -> acknowledged.

decode_timestamp(EncodedTS) ->
    mongoose_rdbms:result_to_integer(EncodedTS).
